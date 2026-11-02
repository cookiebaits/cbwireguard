#!/bin/bash
# ==============================================================================
# Cookie's Easy WireGuard Manager - Unified Production Suite (v2.0)
# Strict mode for maximum stability, security, and idempotency
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

# --- Terminal Color Palette (Preserved from v1) ---
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Core Paths & Constants ---
GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
CLIENTS_DIR="${INSTALL_DIR}/clients"
BACKUPS_DIR="${INSTALL_DIR}/backups"
SPLIT_TUNNEL_DIR="${INSTALL_DIR}/split_tunnel"
DOMAINS_FILE="${SPLIT_TUNNEL_DIR}/bypass_domains.txt"
EXCLUDED_CIDRS_V4="${SPLIT_TUNNEL_DIR}/excluded_v4.txt"
EXCLUDED_CIDRS_V6="${SPLIT_TUNNEL_DIR}/excluded_v6.txt"
REFRESH_SCRIPT="/usr/local/sbin/wg-split-tunnel-refresh.sh"
CRON_FILE="/etc/cron.d/wg-split-tunnel"

WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
SYSCTL_WG_CONF="/etc/sysctl.d/99-wireguard-speed-privacy.conf"

# Default WireGuard Internal Subnets (Dual-Stack IPv4 + ULA IPv6 to prevent leaks)
WG_IPV4_SUBNET="10.66.66.0/24"
WG_IPV4_GW="10.66.66.1"
WG_IPV6_SUBNET="fd42:42:42::/64"
WG_IPV6_GW="fd42:42:42::1"

# Sensitive / Protected Ports (Never allow WireGuard to bind or cleanup to close these)
# Protects SSH, DNS, HTTP/HTTPS, Mail, Dokploy, Traefik, Cloudflare tunnels, and DBs
readonly PROTECTED_PORTS=(
    21 22 25 53 80 110 143 443 465 587 993 995
    2222 3000 3306 5432 6379 8000 8080 8443 9000 9090
)

# ==============================================================================
# 0. PRIVILEGE & ENVIRONMENT INITIALIZATION
# ==============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

init_environment() {
    mkdir -p "$INSTALL_DIR" "$CLIENTS_DIR" "$BACKUPS_DIR" "$SPLIT_TUNNEL_DIR"
    chmod 700 "$INSTALL_DIR" "$CLIENTS_DIR" "$BACKUPS_DIR" "$SPLIT_TUNNEL_DIR"

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        cat <<EOF > "$SETTINGS_FILE"
DEFAULT_MTU=1360
DEFAULT_DNS="94.140.14.49, 9.9.9.9, 94.140.14.59, 2a10:50c0::ad1:ff, 2620:fe::fe"
DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"
ENFORCE_DNS_REDIRECT="true"
BLOCK_WEBRTC_STUN="false"
EOF
        chmod 600 "$SETTINGS_FILE"
    fi

    touch "$DOMAINS_FILE" "$EXCLUDED_CIDRS_V4" "$EXCLUDED_CIDRS_V6"
    chmod 600 "$DOMAINS_FILE" "$EXCLUDED_CIDRS_V4" "$EXCLUDED_CIDRS_V6"
}

init_environment

if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# Ensure defaults if upgrading from older settings.conf
DEFAULT_MTU="${DEFAULT_MTU:-1360}"
DEFAULT_DNS="${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59, 2a10:50c0::ad1:ff, 2620:fe::fe"}"
DEFAULT_ALLOWED_IPS="${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"}"
ENFORCE_DNS_REDIRECT="${ENFORCE_DNS_REDIRECT:-"true"}"
BLOCK_WEBRTC_STUN="${BLOCK_WEBRTC_STUN:-"false"}"

# ==============================================================================
# 1. UTILITY & HELPER FUNCTIONS
# ==============================================================================

pause_prompt() {
    echo -en "\n${GREEN}Press Enter to continue...${NC}"
    read -r _
}

is_protected_port() {
    local check_port="$1"
    local p
    for p in "${PROTECTED_PORTS[@]}"; do
        if [[ "$check_port" == "$p" ]]; then
            return 0
        fi
    done
    return 1
}

is_port_in_use() {
    local check_port="$1"
    if ss -ulpn 2>/dev/null | grep -qE ":${check_port}\b"; then
        return 0
    fi
    if ss -tlpn 2>/dev/null | grep -qE ":${check_port}\b"; then
        return 0
    fi
    return 1
}

get_primary_wan_if() {
    local wan_if
    wan_if=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1 || true)
    if [[ -z "$wan_if" ]]; then
        wan_if=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 || true)
    fi
    echo "${wan_if:-eth0}"
}

get_public_endpoint_ip() {
    local pub_ip=""
    # Query privacy-respecting HTTPS endpoints without leaking hostname metadata
    for url in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip"; do
        pub_ip=$(curl -4 -sSf --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
    done
    if [[ -z "$pub_ip" ]]; then
        pub_ip=$(ip -4 addr show dev "$(get_primary_wan_if)" | awk '/inet / {split($2,a,"/"); print a[1]}' | head -n1 || true)
    fi
    echo "$pub_ip"
}

update_setting() {
    local key="$1"
    local value="$2"
    local tmp_file="${SETTINGS_FILE}.tmp"

    if grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k {$0=k"="v} 1' "$SETTINGS_FILE" > "$tmp_file"
        mv "$tmp_file" "$SETTINGS_FILE"
    else
        echo "${key}=${value}" >> "$SETTINGS_FILE"
    fi
    chmod 600 "$SETTINGS_FILE"
}

install_dependencies() {
    echo -e "${GREEN}[*] Checking and installing required system packages...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq wireguard wireguard-tools iptables ipset qrencode curl dnsutils python3 cron procps iproute2 >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q wireguard-tools iptables ipset qrencode curl bind-utils python3 cronie procps-ng iproute >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q epel-release >/dev/null || true
        yum install -y -q wireguard-tools iptables ipset qrencode curl bind-utils python3 cronie procps-ng iproute >/dev/null
    else
        echo -e "${RED}[!] Unsupported package manager. Please install wireguard-tools, qrencode, ipset, and python3 manually.${NC}"
        return 1
    fi
}

# Safely remove firewall rules for a non-protected UDP port
clean_port_firewall_rules() {
    local port="$1"
    if [[ -z "$port" ]] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if is_protected_port "$port"; then
        echo -e "${YELLOW}[!] Skipping port ${port} cleanup (Protected System/Web Port).${NC}"
        return 0
    fi

    echo -e "${CYAN}[*] Cleaning firewall rules for old WireGuard UDP port ${port}...${NC}"
    # Clean iptables / ip6tables INPUT rules for this UDP port
    while iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
    while ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done

    # Clean UFW rules if UFW is installed
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
    fi

    # Clean firewalld rules if active
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

# ==============================================================================
# 2. PRE-INSTALL CLEANUP & PORT RECLAMATION (P5)
# ==============================================================================

pre_install_cleanup() {
    echo -e "\n${PURPLE}======================================================${NC}"
    echo -e "${GREEN}   🔍 Pre-Install Audit & Legacy Instance Cleanup     ${NC}"
    echo -e "${PURPLE}======================================================${NC}"

    local found_legacy=0
    local old_ports=()

    # 1. Discover ports from active WireGuard interfaces
    if command -v wg >/dev/null 2>&1; then
        while read -r _ port; do
            if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
                old_ports+=("$port")
                found_legacy=1
            fi
        done < <(wg show all listen-port 2>/dev/null || true)
    fi

    # 2. Discover ports from any existing /etc/wireguard/*.conf files
    if [[ -d "$WG_DIR" ]]; then
        local conf_file
        for conf_file in "$WG_DIR"/*.conf; do
            [[ -e "$conf_file" ]] || continue
            found_legacy=1
            local cfg_port
            cfg_port=$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf_file" | head -n1 || true)
            if [[ -n "$cfg_port" && "$cfg_port" =~ ^[0-9]+$ ]]; then
                old_ports+=("$cfg_port")
            fi
        done
    fi

    # 3. Stop and disable any active wg-quick@ services
    local unit
    while read -r unit; do
        [[ -z "$unit" ]] && continue
        found_legacy=1
        echo -e "${CYAN}[*] Stopping and disabling active service: ${unit}${NC}"
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    done < <(systemctl list-units --type=service --state=active,failed "wg-quick@*" --no-legend 2>/dev/null | awk '{print $1}' || true)

    # 4. Tear down lingering virtual wireguard interfaces
    local wg_dev
    while read -r wg_dev; do
        [[ -z "$wg_dev" ]] && continue
        found_legacy=1
        echo -e "${CYAN}[*] Removing lingering WireGuard interface: ${wg_dev}${NC}"
        ip link set down dev "$wg_dev" 2>/dev/null || true
        ip link delete dev "$wg_dev" 2>/dev/null || true
    done < <(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 || true)

    # 5. Clean up discovered WireGuard UDP ports (strictly excluding 80, 443, 22, etc.)
    if [[ "${#old_ports[@]}" -gt 0 ]]; then
        local unique_ports
        mapfile -t unique_ports < <(printf "%s\n" "${old_ports[@]}" | sort -u)
        local p
        for p in "${unique_ports[@]}"; do
            clean_port_firewall_rules "$p"
        done
    fi

    # 6. Clean up legacy split-tunnel firewall hooks & ipsets
    while iptables -t mangle -D PREROUTING -i "$WG_IF" -m set --match-set wg_bypass_v4 dst -j MARK --set-mark 0x66 2>/dev/null; do :; done
    while ip6tables -t mangle -D PREROUTING -i "$WG_IF" -m set --match-set wg_bypass_v6 dst -j MARK --set-mark 0x66 2>/dev/null; do :; done
    ipset destroy wg_bypass_v4 2>/dev/null || true
    ipset destroy wg_bypass_v6 2>/dev/null || true

    # 7. Backup and clean old /etc/wireguard configs if re-running install
    if [[ -f "$WG_CONF" ]]; then
        local pre_bak="${BACKUPS_DIR}/pre_install_auto_$(date +%Y%m%d_%H%M%S).tar.gz"
        echo -e "${YELLOW}[*] Archiving previous configuration to ${pre_bak}...${NC}"
        tar -czf "$pre_bak" -C / etc/wireguard 2>/dev/null || true
        chmod 600 "$pre_bak" 2>/dev/null || true
        rm -f "${WG_DIR}"/*.conf "${WG_DIR}"/server_*.key 2>/dev/null || true
    fi

    if [[ "$found_legacy" -eq 1 ]]; then
        echo -e "${GREEN}[✓] Legacy WireGuard instances, interfaces, and non-sensitive ports cleaned.${NC}"
    else
        echo -e "${GREEN}[✓] No conflicting WireGuard instances found. System is clean.${NC}"
    fi
}

# ==============================================================================
# 3. SPEED OPTIMIZATION & ZERO-LEAK KERNEL HARDENING (P2 & P3)
# ==============================================================================

apply_kernel_speed_and_privacy_tuning() {
    echo -e "${GREEN}[*] Applying Kernel Speed (TCP BBR + 64MB Buffers) & Anti-Leak Hardening...${NC}"

    # Load TCP BBR congestion control module if available
    modprobe tcp_bbr 2>/dev/null || true

    cat <<EOF > "$SYSCTL_WG_CONF"
# ==============================================================================
# Cookie's Easy WireGuard: Speed Optimization & Privacy Hardening
# ==============================================================================

# 1. Packet Forwarding (Dual-Stack IPv4 + IPv6)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# 2. High-Throughput Congestion Control (Google TCP BBR + Fair Queuing)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 3. 64MB Socket Buffers for High-Speed Upload & Download Over UDP
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 65536
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# 4. High-Packet-Rate Queue & Backlog Tuning
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# 5. Anti-Fingerprinting & ISP Metadata Leak Prevention
# Disable TCP timestamps to prevent remote clock-skew device tracking
net.ipv4.tcp_timestamps = 0
# Ignore broadcast/bogus ICMP and prevent ICMP redirect routing leaks
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

    chmod 600 "$SYSCTL_WG_CONF"
    sysctl --system >/dev/null 2>&1 || true

    # Boost WAN interface txqueuelen immediately
    local wan_if
    wan_if=$(get_primary_wan_if)
    ip link set dev "$wan_if" txqueuelen 10000 2>/dev/null || true
    echo -e "${GREEN}[✓] Kernel BBR, 64MB UDP/TCP buffers, and anti-fingerprinting sysctls active.${NC}"
}

# ==============================================================================
# 4. STEALTH UDP PORT SELECTION ENGINE (P4)
# ==============================================================================

select_stealth_port() {
    echo -e "\n${PURPLE}┌────────────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│               🕵️  Stealth UDP Port Selection (Excludes 80/443)             │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[1] UDP 123   (NTP - Network Time Protocol)${NC}                                ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Mandatory OS clock sync traffic. ISPs & firewalls rarely ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     block or throttle UDP 123 because dropping it breaks TLS & Kerberos.   ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[2] UDP 3478  (STUN / WebRTC Video Calling - Recommended)${NC}                  ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Used by Zoom, MS Teams, Discord & FaceTime media streams.${PURPLE}│${NC}"
    echo -e "${PURPLE}│     Continuous high-bandwidth UDP looks identical to a live video call.    ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[3] UDP 19302 (Google STUN / Google Meet & Chrome WebRTC)${NC}                  ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Mimics Google Meet & Android/Chrome WebRTC voice/video   ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     relays; prioritized for low latency across carrier & guest NATs.       ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[4] UDP 4500  (IPsec NAT-Traversal / Apple Wi-Fi Calling)${NC}                  ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Standard port for iOS/Android VoWiFi (Wi-Fi Calling) and ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     enterprise IKEv2 tunnels. High-entropy encrypted UDP is expected here. ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[5] UDP 500   (ISAKMP / IKEv2 Key Exchange)${NC}                                ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Core mobile carrier Wi-Fi Calling negotiation port;      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     whitelisted on restricted hotel, airline, and corporate Wi-Fi.         ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[6] UDP 27015 (Valve Source Engine / Steam Multiplayer Gaming)${NC}             ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Matches real-time gaming UDP packet cadence; consumer    ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ISP QoS profiles prioritize this port for minimal packet jitter.       ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[7] UDP 1194  (OpenVPN Standard UDP)${NC}                                       ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     ${CYAN}Why stealthy:${NC} Blends in on enterprise networks that permit legacy      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│     corporate OpenVPN gateways while blocking random high UDP ports.       ${PURPLE}│${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${GREEN}[8] Custom Stealth UDP Port${NC} (Validated against protected ports 80/443/etc) ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────────────────────────────┘${NC}"

    local candidate_port=""
    while true; do
        echo -en "${GREEN}Select port option [1-8] (Default: 2 -> UDP 3478): ${NC}"
        read -r port_choice
        port_choice="${port_choice:-2}"

        case "$port_choice" in
            1) candidate_port=123 ;;
            2) candidate_port=3478 ;;
            3) candidate_port=19302 ;;
            4) candidate_port=4500 ;;
            5) candidate_port=500 ;;
            6) candidate_port=27015 ;;
            7) candidate_port=1194 ;;
            8)
                echo -en "${GREEN}Enter custom UDP port (1-65535, excluding 80/443/22/etc.): ${NC}"
                read -r candidate_port
                ;;
            *)
                echo -e "${RED}[!] Invalid selection. Choose 1-8.${NC}"
                continue
                ;;
        esac

        if ! [[ "$candidate_port" =~ ^[0-9]+$ ]] || (( candidate_port < 1 || candidate_port > 65535 )); then
            echo -e "${RED}[!] Port must be a valid integer between 1 and 65535.${NC}"
            continue
        fi

        if is_protected_port "$candidate_port"; then
            echo -e "${RED}[!] Port ${candidate_port} is a protected system/web port (e.g., 80, 443, 22, Dokploy). Choose another.${NC}"
            continue
        fi

        # If UDP 123 is chosen and systemd-timesyncd/ntpd is holding UDP 123, check listener
        if is_port_in_use "$candidate_port"; then
            echo -e "${YELLOW}[!] Notice: Port ${candidate_port} is currently in use on this host.${NC}"
            ss -ulpn | grep -E ":${candidate_port}\b" || true
            echo -en "${YELLOW}Choose a different stealth port? [Y/n]: ${NC}"
            read -r retry_port
            if [[ "${retry_port:-Y}" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        SELECTED_WG_PORT="$candidate_port"
        echo -e "${GREEN}[✓] Selected Stealth WireGuard Port: UDP ${SELECTED_WG_PORT}${NC}"
        break
    done
}

# ==============================================================================
# 5. SERVER SETUP MODULE (Option 1 - replaces setup_server.sh)
# ==============================================================================

generate_postup_postdown_scripts() {
    local wan_if="$1"
    local wg_port="$2"
    local post_up_script="${WG_DIR}/postup.sh"
    local post_down_script="${WG_DIR}/postdown.sh"

    cat <<EOF > "$post_up_script"
#!/bin/bash
# High-Speed Queue & MTU Clamping
ip link set dev ${WG_IF} txqueuelen 10000 2>/dev/null || true
ip link set dev ${wan_if} txqueuelen 10000 2>/dev/null || true

# Allow WireGuard UDP Port
iptables -I INPUT 1 -p udp --dport ${wg_port} -j ACCEPT
ip6tables -I INPUT 1 -p udp --dport ${wg_port} -j ACCEPT

# Forwarding Rules for WireGuard Tunnel
iptables -I FORWARD 1 -i ${WG_IF} -j ACCEPT
iptables -I FORWARD 1 -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -I FORWARD 1 -i ${WG_IF} -j ACCEPT
ip6tables -I FORWARD 1 -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT Masquerading (Hides internal client IPs behind server endpoint)
iptables -t nat -A POSTROUTING -s ${WG_IPV4_SUBNET} -o ${wan_if} -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s ${WG_IPV6_SUBNET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true

# Speed Enhancement: Dynamic TCP MSS Clamping (Eliminates PMTU blackholes on upload/download)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Privacy Hardening: Normalize Outgoing TTL/Hop-Limit to 64 (Hides client OS & hop distance)
iptables -t mangle -A POSTROUTING -s ${WG_IPV4_SUBNET} -o ${wan_if} -j TTL --ttl-set 64 2>/dev/null || true
ip6tables -t mangle -A POSTROUTING -s ${WG_IPV6_SUBNET} -o ${wan_if} -j HL --hl-set 64 2>/dev/null || true

# Privacy Hardening: Drop ICMP Timestamp Requests/Replies (Prevents clock fingerprinting)
iptables -I FORWARD 1 -i ${WG_IF} -p icmp --icmp-type 13 -j DROP
iptables -I FORWARD 1 -i ${WG_IF} -p icmp --icmp-type 14 -j DROP

# Optional DNS Leak Enforcement: Redirect any rogue plaintext DNS queries to primary privacy DNS
if grep -q 'ENFORCE_DNS_REDIRECT="true"' "${SETTINGS_FILE}" 2>/dev/null; then
    PRIMARY_V4_DNS=\$(awk -F'"' '/^DEFAULT_DNS=/ {print \$2}' "${SETTINGS_FILE}" | tr ',' '\n' | grep -E '^[[:space:]]*[0-9]+\.' | head -n1 | tr -d '[:space:]')
    if [[ -n "\$PRIMARY_V4_DNS" ]]; then
        iptables -t nat -A PREROUTING -i ${WG_IF} -p udp --dport 53 -j DNAT --to-destination "\${PRIMARY_V4_DNS}:53"
        iptables -t nat -A PREROUTING -i ${WG_IF} -p tcp --dport 53 -j DNAT --to-destination "\${PRIMARY_V4_DNS}:53"
    fi
fi

# Optional WebRTC STUN Leak Block inside tunnel
if grep -q 'BLOCK_WEBRTC_STUN="true"' "${SETTINGS_FILE}" 2>/dev/null; then
    iptables -I FORWARD 1 -i ${WG_IF} -p udp --dport 3478 -j DROP
    iptables -I FORWARD 1 -i ${WG_IF} -p udp --dport 19302 -j DROP
    iptables -I FORWARD 1 -i ${WG_IF} -p udp --dport 5349 -j DROP
fi

# Server-Side Domain Split-Tunneling IPSet Restoration
if command -v ipset >/dev/null 2>&1; then
    ipset create wg_bypass_v4 hash:net family inet -exist
    ipset create wg_bypass_v6 hash:net family inet6 -exist
    if [[ -x "${REFRESH_SCRIPT}" ]]; then
        "${REFRESH_SCRIPT}" >/dev/null 2>&1 || true
    fi
fi
EOF

    cat <<EOF > "$post_down_script"
#!/bin/bash
iptables -D INPUT -p udp --dport ${wg_port} -j ACCEPT 2>/dev/null || true
ip6tables -D INPUT -p udp --dport ${wg_port} -j ACCEPT 2>/dev/null || true

iptables -D FORWARD -i ${WG_IF} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
ip6tables -D FORWARD -i ${WG_IF} -j ACCEPT 2>/dev/null || true
ip6tables -D FORWARD -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

iptables -t nat -D POSTROUTING -s ${WG_IPV4_SUBNET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true
ip6tables -t nat -D POSTROUTING -s ${WG_IPV6_SUBNET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true

iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

iptables -t mangle -D POSTROUTING -s ${WG_IPV4_SUBNET} -o ${wan_if} -j TTL --ttl-set 64 2>/dev/null || true
ip6tables -t mangle -D POSTROUTING -s ${WG_IPV6_SUBNET} -o ${wan_if} -j HL --hl-set 64 2>/dev/null || true

iptables -D FORWARD -i ${WG_IF} -p icmp --icmp-type 13 -j DROP 2>/dev/null || true
iptables -D FORWARD -i ${WG_IF} -p icmp --icmp-type 14 -j DROP 2>/dev/null || true

iptables -t nat -F PREROUTING 2>/dev/null || true

iptables -D FORWARD -i ${WG_IF} -p udp --dport 3478 -j DROP 2>/dev/null || true
iptables -D FORWARD -i ${WG_IF} -p udp --dport 19302 -j DROP 2>/dev/null || true
iptables -D FORWARD -i ${WG_IF} -p udp --dport 5349 -j DROP 2>/dev/null || true
EOF

    chmod 700 "$post_up_script" "$post_down_script"
}

setup_server_module() {
    echo -e "\n${PURPLE}======================================================${NC}"
    echo -e "${GREEN}          🚀 WireGuard Server Setup Wizard            ${NC}"
    echo -e "${PURPLE}======================================================${NC}"

    install_dependencies
    pre_install_cleanup
    apply_kernel_speed_and_privacy_tuning

    local wan_if
    wan_if=$(get_primary_wan_if)
    local detected_ip
    detected_ip=$(get_public_endpoint_ip)

    echo -e "\n${CYAN}[*] Detected Primary Network Interface:${NC} ${wan_if}"
    echo -en "${GREEN}Public IPv4 or Domain for Client Endpoint (Default: ${detected_ip}): ${NC}"
    read -r server_endpoint
    server_endpoint="${server_endpoint:-$detected_ip}"

    if [[ -z "$server_endpoint" ]]; then
        echo -e "${RED}[!] Error: Could not determine public endpoint IP. Please enter it manually.${NC}"
        pause_prompt
        return 1
    fi

    SELECTED_WG_PORT=3478
    select_stealth_port

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    # Generate Server Cryptographic Keys
    umask 077
    local server_priv_key
    local server_pub_key
    server_priv_key=$(wg genkey)
    server_pub_key=$(echo "$server_priv_key" | wg pubkey)

    echo "$server_priv_key" > "${WG_DIR}/server_private.key"
    echo "$server_pub_key" > "${WG_DIR}/server_public.key"
    chmod 600 "${WG_DIR}/server_private.key" "${WG_DIR}/server_public.key"

    # Persist Server Metadata in settings.conf
    update_setting "SERVER_ENDPOINT" "\"${server_endpoint}\""
    update_setting "SERVER_PORT" "${SELECTED_WG_PORT}"
    update_setting "SERVER_PUB_KEY" "\"${server_pub_key}\""
    update_setting "WAN_INTERFACE" "\"${wan_if}\""

    # Reload updated settings
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"

    generate_postup_postdown_scripts "$wan_if" "$SELECTED_WG_PORT"

    cat <<EOF > "$WG_CONF"
[Interface]
Address = ${WG_IPV4_GW}/24, ${WG_IPV6_GW}/64
ListenPort = ${SELECTED_WG_PORT}
PrivateKey = ${server_priv_key}
MTU = ${DEFAULT_MTU}
SaveConfig = false
PostUp = ${WG_DIR}/postup.sh
PostDown = ${WG_DIR}/postdown.sh

# === PEERS BEGIN ===
EOF
    chmod 600 "$WG_CONF"

    # Open UFW port if UFW is active (never touching protected ports)
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${SELECTED_WG_PORT}/udp" comment "EasyWireGuard Stealth UDP" >/dev/null 2>&1 || true
    fi

    # Enable and start WireGuard service
    systemctl daemon-reload
    systemctl enable "wg-quick@${WG_IF}.service" >/dev/null 2>&1
    systemctl restart "wg-quick@${WG_IF}.service"

    echo -e "\n${GREEN}[✓] WireGuard Server successfully deployed on Stealth Port UDP ${SELECTED_WG_PORT}!${NC}"
    echo -e "${CYAN}    • Endpoint:${NC} ${server_endpoint}:${SELECTED_WG_PORT}"
    echo -e "${CYAN}    • Tunnel Subnets:${NC} ${WG_IPV4_SUBNET} & ${WG_IPV6_SUBNET} (Dual-Stack Leak Guard)"
    echo -e "${CYAN}    • Speed Profile:${NC} TCP BBR + 64MB Buffers + MTU ${DEFAULT_MTU} + MSS Clamping"

    echo -en "\n${GREEN}Would you like to create your first client (peer) now? [Y/n]: ${NC}"
    read -r create_first
    if [[ "${create_first:-Y}" =~ ^[Yy]$ ]]; then
        add_client_module
    else
        pause_prompt
    fi
}

# ==============================================================================
# 6. CLIENT CREATION MODULE (Option 2 - replaces add_client.sh)
# ==============================================================================

get_next_available_octet() {
    local octet=2
    while (( octet <= 254 )); do
        if ! grep -q "10\.66\.66\.${octet}/32" "$WG_CONF" 2>/dev/null; then
            echo "$octet"
            return 0
        fi
        ((octet++))
    done
    return 1
}

compute_effective_allowed_ips() {
    # If split-tunnel domains are active and excluded CIDRs exist, use the calculated CIDR list
    if [[ -s "$DOMAINS_FILE" && -s "$EXCLUDED_CIDRS_V4" ]]; then
        local v4_cidrs
        v4_cidrs=$(tr '\n' ',' < "$EXCLUDED_CIDRS_V4" | sed 's/,$//; s/,/, /g')
        local v6_cidrs="::/1, 8000::/1"
        if [[ -s "$EXCLUDED_CIDRS_V6" ]]; then
            v6_cidrs=$(tr '\n' ',' < "$EXCLUDED_CIDRS_V6" | sed 's/,$//; s/,/, /g')
        fi
        echo "${v4_cidrs}, ${v6_cidrs}"
    else
        echo "${DEFAULT_ALLOWED_IPS}"
    fi
}

add_client_module() {
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "\n${RED}[!] WireGuard server is not configured yet. Run [1] Setup WireGuard server first.${NC}"
        pause_prompt
        return 1
    fi

    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"

    echo -e "\n${PURPLE}======================================================${NC}"
    echo -e "${GREEN}               ➕ Add New WireGuard Client            ${NC}"
    echo -e "${PURPLE}======================================================${NC}"

    echo -en "${GREEN}Enter client name (alphanumeric/dash/underscore, e.g. laptop-main): ${NC}"
    read -r raw_client_name
    local client_name
    client_name=$(echo "$raw_client_name" | tr -cd 'a-zA-Z0-9_-')

    if [[ -z "$client_name" ]]; then
        echo -e "${RED}[!] Error: Client name cannot be empty.${NC}"
        pause_prompt
        return 1
    fi

    if grep -q "^# BEGIN_PEER ${client_name}$" "$WG_CONF" 2>/dev/null || [[ -f "${CLIENTS_DIR}/${client_name}.conf" ]]; then
        echo -e "${RED}[!] Error: A client named '${client_name}' already exists.${NC}"
        pause_prompt
        return 1
    fi

    local octet
    octet=$(get_next_available_octet) || {
        echo -e "${RED}[!] Error: Subnet ${WG_IPV4_SUBNET} is full.${NC}"
        pause_prompt
        return 1
    }

    local client_ipv4="10.66.66.${octet}"
    local client_ipv6="fd42:42:42::${octet}"

    umask 077
    local client_priv_key
    local client_pub_key
    local client_psk
    client_priv_key=$(wg genkey)
    client_pub_key=$(echo "$client_priv_key" | wg pubkey)
    client_psk=$(wg genpsk)

    local effective_allowed_ips
    effective_allowed_ips=$(compute_effective_allowed_ips)

    # Append Peer block to Server Config with clear delimiters for surgical management
    cat <<EOF >> "$WG_CONF"
# BEGIN_PEER ${client_name}
[Peer]
PublicKey = ${client_pub_key}
PresharedKey = ${client_psk}
AllowedIPs = ${client_ipv4}/32, ${client_ipv6}/128
# END_PEER ${client_name}
EOF

    # Write Client Configuration File
    local client_conf="${CLIENTS_DIR}/${client_name}.conf"
    cat <<EOF > "$client_conf"
# Client: ${client_name}
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# PrivKey_Backup: ${client_priv_key}
# PubKey_Backup: ${client_pub_key}
[Interface]
PrivateKey = ${client_priv_key}
Address = ${client_ipv4}/32, ${client_ipv6}/128
DNS = ${DEFAULT_DNS}
MTU = ${DEFAULT_MTU}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${client_psk}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = ${effective_allowed_ips}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"

    # Hot-reload WireGuard interface without dropping existing peer sessions
    if systemctl is-active --quiet "wg-quick@${WG_IF}.service"; then
        wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
    else
        systemctl start "wg-quick@${WG_IF}.service"
    fi

    echo -e "\n${GREEN}[✓] Client '${client_name}' created and activated!${NC}"
    echo -e "${CYAN}    • Assigned IPv4:${NC} ${client_ipv4}/32"
    echo -e "${CYAN}    • Assigned IPv6:${NC} ${client_ipv6}/128 (Anti-IPv6 Leak)"
    echo -e "${CYAN}    • Config File:${NC}   ${client_conf}\n"

    if command -v qrencode >/dev/null 2>&1; then
        echo -e "${PURPLE}Scan QR Code with the WireGuard Mobile App:${NC}"
        qrencode -t ansiutf8 < "$client_conf"
    fi

    pause_prompt
}

# ==============================================================================
# 7. CLIENT CONFIGURATION MANAGER (Option 3 - replaces user_manager.sh)
# ==============================================================================

list_configured_clients() {
    if [[ ! -f "$WG_CONF" ]]; then
        return 0
    fi
    awk '/^# BEGIN_PEER / {print $3}' "$WG_CONF"
}

user_manager_module() {
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "\n${RED}[!] WireGuard server is not configured yet.${NC}"
        pause_prompt
        return 1
    fi

    while true; do
        clear
        print_banner
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│          Configure Clients (Check/Edit/Remove)     │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│ ${NC}[1] List all clients & live connection status     ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[2] Show client config & QR code                  ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[3] Edit client MTU / DNS / AllowedIPs            ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[4] Change Server Stealth Port (Live Update)      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${RED}[5] Revoke & remove a client                      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
        echo -en "${GREEN}Option: ${NC}"
        read -r um_opt

        case "$um_opt" in
            1)
                echo -e "\n${PURPLE}=== Configured WireGuard Peers ===${NC}"
                local clients=()
                mapfile -t clients < <(list_configured_clients)
                if [[ "${#clients[@]}" -eq 0 ]]; then
                    echo -e "${YELLOW}No clients configured yet.${NC}"
                else
                    local idx=1
                    local c
                    for c in "${clients[@]}"; do
                        local c_ip=""
                        if [[ -f "${CLIENTS_DIR}/${c}.conf" ]]; then
                            c_ip=$(awk -F'=' '/^Address[[:space:]]*=/ {print $2}' "${CLIENTS_DIR}/${c}.conf" | tr -d '[:space:]')
                        fi
                        echo -e "${GREEN}[${idx}] ${c}${NC} -> ${CYAN}${c_ip}${NC}"
                        ((idx++))
                    done
                    echo -e "\n${PURPLE}=== Live WireGuard Interface Telemetry ===${NC}"
                    wg show "$WG_IF" 2>/dev/null || echo -e "${YELLOW}Interface ${WG_IF} is not currently running.${NC}"
                fi
                pause_prompt
                ;;
            2)
                local clients=()
                mapfile -t clients < <(list_configured_clients)
                if [[ "${#clients[@]}" -eq 0 ]]; then
                    echo -e "\n${YELLOW}No clients available.${NC}"
                    pause_prompt
                    continue
                fi
                echo -e "\n${GREEN}Available Clients:${NC}"
                local i=1
                for c in "${clients[@]}"; do
                    echo -e "  [${i}] ${c}"
                    ((i++))
                done
                echo -en "${GREEN}Select client number: ${NC}"
                read -r c_num
                if [[ "$c_num" =~ ^[0-9]+$ ]] && (( c_num >= 1 && c_num <= ${#clients[@]} )); then
                    local target_c="${clients[$((c_num-1))]}"
                    local target_file="${CLIENTS_DIR}/${target_c}.conf"
                    if [[ -f "$target_file" ]]; then
                        echo -e "\n${PURPLE}--- ${target_file} ---${NC}"
                        grep -vE '^# (PrivKey_Backup|PubKey_Backup):' "$target_file"
                        echo -e "${PURPLE}----------------------------------${NC}\n"
                        if command -v qrencode >/dev/null 2>&1; then
                            qrencode -t ansiutf8 < "$target_file"
                        fi
                    else
                        echo -e "${RED}[!] Client file ${target_file} not found.${NC}"
                    fi
                else
                    echo -e "${RED}[!] Invalid selection.${NC}"
                fi
                pause_prompt
                ;;
            3)
                local clients=()
                mapfile -t clients < <(list_configured_clients)
                if [[ "${#clients[@]}" -eq 0 ]]; then
                    echo -e "\n${YELLOW}No clients available to edit.${NC}"
                    pause_prompt
                    continue
                fi
                echo -e "\n${GREEN}Select Client to Edit:${NC}"
                local i=1
                for c in "${clients[@]}"; do
                    echo -e "  [${i}] ${c}"
                    ((i++))
                done
                echo -en "${GREEN}Select client number: ${NC}"
                read -r c_num
                if [[ "$c_num" =~ ^[0-9]+$ ]] && (( c_num >= 1 && c_num <= ${#clients[@]} )); then
                    local target_c="${clients[$((c_num-1))]}"
                    local target_file="${CLIENTS_DIR}/${target_c}.conf"
                    if [[ ! -f "$target_file" ]]; then
                        echo -e "${RED}[!] Client config file missing.${NC}"
                        pause_prompt
                        continue
                    fi
                    echo -en "${GREEN}New MTU (Enter to keep current): ${NC}"
                    read -r edit_mtu
                    if [[ -n "$edit_mtu" && "$edit_mtu" =~ ^[0-9]+$ ]]; then
                        sed -i "s|^MTU = .*|MTU = ${edit_mtu}|" "$target_file"
                    fi
                    echo -en "${GREEN}New DNS (Enter to keep current): ${NC}"
                    read -r edit_dns
                    if [[ -n "$edit_dns" ]]; then
                        sed -i "s|^DNS = .*|DNS = ${edit_dns}|" "$target_file"
                    fi
                    echo -en "${GREEN}New AllowedIPs (Enter to keep current): ${NC}"
                    read -r edit_ips
                    if [[ -n "$edit_ips" ]]; then
                        sed -i "s|^AllowedIPs = .*|AllowedIPs = ${edit_ips}|" "$target_file"
                    fi
                    echo -e "${GREEN}[✓] Updated ${target_c}.conf. Re-scan QR or re-import config on client device.${NC}"
                fi
                pause_prompt
                ;;
            4)
                # shellcheck source=/dev/null
                source "$SETTINGS_FILE"
                local old_port="${SERVER_PORT:-3478}"
                select_stealth_port
                if [[ "$SELECTED_WG_PORT" != "$old_port" ]]; then
                    sed -i "s|^ListenPort = .*|ListenPort = ${SELECTED_WG_PORT}|" "$WG_CONF"
                    update_setting "SERVER_PORT" "$SELECTED_WG_PORT"
                    generate_postup_postdown_scripts "${WAN_INTERFACE:-$(get_primary_wan_if)}" "$SELECTED_WG_PORT"
                    clean_port_firewall_rules "$old_port"
                    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
                        ufw allow "${SELECTED_WG_PORT}/udp" comment "EasyWireGuard Stealth UDP" >/dev/null 2>&1 || true
                    fi
                    # Update all client configs with the new port
                    for cf in "${CLIENTS_DIR}"/*.conf; do
                        [[ -e "$cf" ]] || continue
                        sed -i "s|^Endpoint = \(.*\):[0-9]*|Endpoint = \1:${SELECTED_WG_PORT}|" "$cf"
                    done
                    systemctl restart "wg-quick@${WG_IF}.service"
                    echo -e "${GREEN}[✓] Server port migrated from UDP ${old_port} to UDP ${SELECTED_WG_PORT} and client configs updated!${NC}"
                fi
                pause_prompt
                ;;
            5)
                local clients=()
                mapfile -t clients < <(list_configured_clients)
                if [[ "${#clients[@]}" -eq 0 ]]; then
                    echo -e "\n${YELLOW}No clients available to remove.${NC}"
                    pause_prompt
                    continue
                fi
                echo -e "\n${RED}Select Client to Revoke & Delete:${NC}"
                local i=1
                for c in "${clients[@]}"; do
                    echo -e "  [${i}] ${c}"
                    ((i++))
                done
                echo -en "${RED}Select client number: ${NC}"
                read -r c_num
                if [[ "$c_num" =~ ^[0-9]+$ ]] && (( c_num >= 1 && c_num <= ${#clients[@]} )); then
                    local target_c="${clients[$((c_num-1))]}"
                    echo -en "${RED}Confirm permanent revocation of '${target_c}'? [y/N]: ${NC}"
                    read -r confirm_del
                    if [[ "${confirm_del:-N}" =~ ^[Yy]$ ]]; then
                        sed -i "/^# BEGIN_PEER ${target_c}$/,/^# END_PEER ${target_c}$/d" "$WG_CONF"
                        rm -f "${CLIENTS_DIR}/${target_c}.conf"
                        if systemctl is-active --quiet "wg-quick@${WG_IF}.service"; then
                            wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
                        fi
                        echo -e "${GREEN}[✓] Client '${target_c}' revoked and removed.${NC}"
                    fi
                fi
                pause_prompt
                ;;
            b|B) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

# ==============================================================================
# 8. BACKUP & RESTORE MANAGER (Option 4 - replaces backup_manager.sh)
# ==============================================================================

backup_manager_module() {
    while true; do
        clear
        print_banner
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│              Backup & Restore Manager              │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│ ${NC}[1] Create full snapshot backup now               ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[2] List available backups                        ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[3] Restore from a backup snapshot                ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${RED}[4] Delete a backup snapshot                      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
        echo -en "${GREEN}Option: ${NC}"
        read -r bak_opt

        case "$bak_opt" in
            1)
                local ts
                ts=$(date +%Y%m%d_%H%M%S)
                local archive="${BACKUPS_DIR}/wg_backup_${ts}.tar.gz"
                echo -e "\n${GREEN}[*] Creating encrypted-permissions archive: ${archive}...${NC}"
                tar --exclude="${BACKUPS_DIR}" -czf "$archive" -C / etc/wireguard root/easy_wireguard 2>/dev/null || true
                chmod 600 "$archive"
                echo -e "${GREEN}[✓] Backup saved to: ${archive}${NC}"
                pause_prompt
                ;;
            2)
                echo -e "\n${PURPLE}=== Available Snapshots in ${BACKUPS_DIR} ===${NC}"
                local snaps=()
                mapfile -t snaps < <(find "$BACKUPS_DIR" -maxdepth 1 -name "*.tar.gz" -printf "%f\n" 2>/dev/null | sort -r)
                if [[ "${#snaps[@]}" -eq 0 ]]; then
                    echo -e "${YELLOW}No backup snapshots found.${NC}"
                else
                    local idx=1
                    for s in "${snaps[@]}"; do
                        local sz
                        sz=$(du -h "${BACKUPS_DIR}/${s}" | awk '{print $1}')
                        echo -e "  ${GREEN}[${idx}]${NC} ${s} (${CYAN}${sz}${NC})"
                        ((idx++))
                    done
                fi
                pause_prompt
                ;;
            3)
                local snaps=()
                mapfile -t snaps < <(find "$BACKUPS_DIR" -maxdepth 1 -name "*.tar.gz" -printf "%f\n" 2>/dev/null | sort -r)
                if [[ "${#snaps[@]}" -eq 0 ]]; then
                    echo -e "\n${YELLOW}No backup snapshots available to restore.${NC}"
                    pause_prompt
                    continue
                fi
                echo -e "\n${GREEN}Select Snapshot to Restore:${NC}"
                local idx=1
                for s in "${snaps[@]}"; do
                    echo -e "  [${idx}] ${s}"
                    ((idx++))
                done
                echo -en "${GREEN}Snapshot number: ${NC}"
                read -r s_num
                if [[ "$s_num" =~ ^[0-9]+$ ]] && (( s_num >= 1 && s_num <= ${#snaps[@]} )); then
                    local chosen_snap="${BACKUPS_DIR}/${snaps[$((s_num-1))]}"
                    echo -en "${YELLOW}Restore ${chosen_snap} and restart WireGuard? [y/N]: ${NC}"
                    read -r confirm_res
                    if [[ "${confirm_res:-N}" =~ ^[Yy]$ ]]; then
                        systemctl stop "wg-quick@${WG_IF}.service" 2>/dev/null || true
                        tar -xzf "$chosen_snap" -C /
                        # shellcheck source=/dev/null
                        source "$SETTINGS_FILE"
                        systemctl daemon-reload
                        systemctl restart "wg-quick@${WG_IF}.service"
                        echo -e "${GREEN}[✓] Backup restored and WireGuard restarted successfully!${NC}"
                    fi
                fi
                pause_prompt
                ;;
            4)
                local snaps=()
                mapfile -t snaps < <(find "$BACKUPS_DIR" -maxdepth 1 -name "*.tar.gz" -printf "%f\n" 2>/dev/null | sort -r)
                if [[ "${#snaps[@]}" -eq 0 ]]; then
                    echo -e "\n${YELLOW}No backup snapshots to delete.${NC}"
                    pause_prompt
                    continue
                fi
                local idx=1
                for s in "${snaps[@]}"; do
                    echo -e "  [${idx}] ${s}"
                    ((idx++))
                done
                echo -en "${RED}Select snapshot number to delete: ${NC}"
                read -r s_num
                if [[ "$s_num" =~ ^[0-9]+$ ]] && (( s_num >= 1 && s_num <= ${#snaps[@]} )); then
                    rm -f "${BACKUPS_DIR}/${snaps[$((s_num-1))]}"
                    echo -e "${GREEN}[✓] Snapshot deleted.${NC}"
                fi
                pause_prompt
                ;;
            b|B) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

# ==============================================================================
# 9. FIXED DOMAIN-BASED SPLIT TUNNELING ENGINE (Option 5 - P1)
# ==============================================================================
# Why Split Tunneling Previously Failed & How This Fixes It:
# 1. WireGuard [Peer] AllowedIPs only understands IPv4/IPv6 CIDRs, not domains.
# 2. If a client has AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ALL traffic is forced
#    into wg0 on the client OS.
# 3. This engine resolves all A/AAAA records (including CNAME chains) for every
#    domain in bypass_domains.txt, uses Python's `ipaddress` module to compute
#    the exact CIDR set-subtraction from 0.0.0.0/0 and ::/0, updates client
#    .conf files automatically, AND maintains a server-side `ipset` with a
#    15-minute cron auto-refresh for dynamic CDNs.

install_split_tunnel_refresh_script() {
    cat <<'EOF' > "$REFRESH_SCRIPT"
#!/bin/bash
set -euo pipefail
DOMAINS_FILE="/root/easy_wireguard/split_tunnel/bypass_domains.txt"
[[ -f "$DOMAINS_FILE" ]] || exit 0

if command -v ipset >/dev/null 2>&1; then
    ipset create wg_bypass_v4 hash:net family inet -exist
    ipset create wg_bypass_v6 hash:net family inet6 -exist
    ipset flush wg_bypass_v4 2>/dev/null || true
    ipset flush wg_bypass_v6 2>/dev/null || true

    while IFS= read -r domain || [[ -n "$domain" ]]; do
        domain=$(echo "$domain" | tr -d '[:space:]')
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue

        # Resolve IPv4 A records (root + www)
        for host_target in "$domain" "www.${domain}"; do
            while read -r ip4; do
                if [[ "$ip4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    ipset add wg_bypass_v4 "${ip4}/24" -exist 2>/dev/null || true
                fi
            done < <(dig +short A "$host_target" @9.9.9.9 2>/dev/null || getent ahostsv4 "$host_target" 2>/dev/null | awk '{print $1}' || true)

            # Resolve IPv6 AAAA records
            while read -r ip6; do
                if [[ "$ip6" =~ : ]]; then
                    ipset add wg_bypass_v6 "${ip6}/64" -exist 2>/dev/null || true
                fi
            done < <(dig +short AAAA "$host_target" @9.9.9.9 2>/dev/null || getent ahostsv6 "$host_target" 2>/dev/null | awk '{print $1}' || true)
        done
    done < "$DOMAINS_FILE"
fi
EOF
    chmod 700 "$REFRESH_SCRIPT"

    cat <<EOF > "$CRON_FILE"
# Auto-refresh dynamic CDN IPs for Easy WireGuard Split Tunneling every 15 minutes
*/15 * * * * root ${REFRESH_SCRIPT} >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
}

recalculate_split_tunnel_cidrs() {
    install_split_tunnel_refresh_script
    "$REFRESH_SCRIPT" || true

    if [[ ! -s "$DOMAINS_FILE" ]]; then
        : > "$EXCLUDED_CIDRS_V4"
        : > "$EXCLUDED_CIDRS_V6"
        # Restore standard full-tunnel AllowedIPs across all clients
        for cf in "${CLIENTS_DIR}"/*.conf; do
            [[ -e "$cf" ]] || continue
            sed -i "s|^AllowedIPs = .*|AllowedIPs = ${DEFAULT_ALLOWED_IPS}|" "$cf"
        done
        echo -e "${GREEN}[✓] Split-tunnel list is empty. Restored full-tunnel AllowedIPs to all client configs.${NC}"
        return 0
    fi

    echo -e "${CYAN}[*] Resolving domain A/AAAA records & computing exact client AllowedIPs CIDR exclusions...${NC}"

    python3 - "$DOMAINS_FILE" "$EXCLUDED_CIDRS_V4" "$EXCLUDED_CIDRS_V6" <<'PYEOF'
import ipaddress
import socket
import subprocess
import sys

domains_path, out_v4_path, out_v6_path = sys.argv[1], sys.argv[2], sys.argv[3]

v4_Input_Nets = set()
v6_Input_Nets = set()

with open(domains_path, "r", encoding="utf-8") as f:
    domains = [line.strip() for line in f if line.strip() and not line.strip().startswith("#")]

for d in domains:
    for target in (d, f"www.{d}"):
        # Use dig if available for thorough CDN resolution
        try:
            out4 = subprocess.check_output(["dig", "+short", "A", target, "@9.9.9.9"], text=True, timeout=4)
            for line in out4.splitlines():
                line = line.strip()
                try:
                    ip = ipaddress.IPv4Address(line)
                    # Exclude the /24 subnet to cover rotating edge CDN nodes in the same POP
                    v4_Input_Nets.add(ipaddress.ip_network(f"{ip}/24", strict=False))
                except ValueError:
                    pass
        except Exception:
            pass

        try:
            out6 = subprocess.check_output(["dig", "+short", "AAAA", target, "@9.9.9.9"], text=True, timeout=4)
            for line in out6.splitlines():
                line = line.strip()
                try:
                    ip6 = ipaddress.IPv6Address(line)
                    v6_Input_Nets.add(ipaddress.ip_network(f"{ip6}/64", strict=False))
                except ValueError:
                    pass
        except Exception:
            pass

        # Fallback socket resolution
        try:
            for res in socket.getaddrinfo(target, None):
                addr = res[4][0]
                try:
                    ip = ipaddress.ip_address(addr)
                    if isinstance(ip, ipaddress.IPv4Address):
                        v4_Input_Nets.add(ipaddress.ip_network(f"{ip}/24", strict=False))
                    else:
                        v6_Input_Nets.add(ipaddress.ip_network(f"{ip}/64", strict=False))
                except ValueError:
                    pass
        except Exception:
            pass

# Subtract excluded IPv4 networks from 0.0.0.0/0
allowed_v4 = [ipaddress.ip_network("0.0.0.0/0")]
for ex_net in sorted(v4_Input_Nets):
    next_allowed = []
    for net in allowed_v4:
        if net.overlaps(ex_net):
            if ex_net.subnet_of(net):
                next_allowed.extend(net.address_exclude(ex_net))
            else:
                next_allowed.append(net)
        else:
            next_allowed.append(net)
    allowed_v4 = next_allowed

# Subtract excluded IPv6 networks from ::/0
allowed_v6 = [ipaddress.ip_network("::/0")]
for ex_net6 in sorted(v6_Input_Nets):
    next_allowed6 = []
    for net6 in allowed_v6:
        if net6.overlaps(ex_net6):
            if ex_net6.subnet_of(net6):
                next_allowed6.extend(net6.address_exclude(ex_net6))
            else:
                next_allowed6.append(net6)
        else:
            next_allowed6.append(net6)
    allowed_v6 = next_allowed6

with open(out_v4_path, "w", encoding="utf-8") as f4:
    for n in ipaddress.collapse_addresses(allowed_v4):
        f4.write(f"{n}\n")

with open(out_v6_path, "w", encoding="utf-8") as f6:
    for n6 in ipaddress.collapse_addresses(allowed_v6):
        f6.write(f"{n6}\n")
PYEOF

    local effective_ips
    effective_ips=$(compute_effective_allowed_ips)

    local updated_count=0
    for cf in "${CLIENTS_DIR}"/*.conf; do
        [[ -e "$cf" ]] || continue
        sed -i "s|^AllowedIPs = .*|AllowedIPs = ${effective_ips}|" "$cf"
        ((updated_count++)) || true
    done

    echo -e "${GREEN}[✓] Split-Tunneling CIDRs computed and synced to ${updated_count} client configuration(s).${NC}"
    echo -e "${YELLOW}[i] Note: Re-import or re-scan the updated client QR code in [3] Configure clients so your device applies the new routing table.${NC}"
}

domain_bypass_module() {
    while true; do
        clear
        print_banner
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│           Domain-Based Split Tunneling             │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│ ${NC}[1] View current bypassed domains & CIDR count    ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[2] Add domain(s) to bypass tunnel                ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[3] Remove a domain from bypass list              ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${NC}[4] Force refresh CDN IPs & sync client configs   ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${RED}[5] Clear all bypassed domains (Full Tunnel)      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
        echo -en "${GREEN}Option: ${NC}"
        read -r st_opt

        case "$st_opt" in
            1)
                echo -e "\n${PURPLE}=== Bypassed Domains (${DOMAINS_FILE}) ===${NC}"
                if [[ ! -s "$DOMAINS_FILE" ]]; then
                    echo -e "${YELLOW}No domains currently bypassing the tunnel (Full-Tunnel Mode active).${NC}"
                else
                    nl -w2 -s'. ' "$DOMAINS_FILE"
                    local v4_count
                    v4_count=$(wc -l < "$EXCLUDED_CIDRS_V4" 2>/dev/null || echo 0)
                    echo -e "\n${CYAN}Active Client AllowedIPs Route Prefixes:${NC} ${v4_count} IPv4 blocks + IPv6 blocks"
                fi
                pause_prompt
                ;;
            2)
                echo -en "\n${GREEN}Enter domain(s) to bypass (comma or space separated, e.g. netflix.com twitch.tv): ${NC}"
                read -r raw_domains
                local d
                for d in $(echo "$raw_domains" | tr ',' ' '); do
                    # Strip protocol/path if pasted as URL
                    d=$(echo "$d" | sed -E 's|^https?://||; s|/.*$||; s|^www\.||' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')
                    if [[ -n "$d" && "$d" =~ \. ]]; then
                        if ! grep -qxF "$d" "$DOMAINS_FILE" 2>/dev/null; then
                            echo "$d" >> "$DOMAINS_FILE"
                            echo -e "${GREEN}[+] Added:${NC} $d"
                        else
                            echo -e "${YELLOW}[i] Already present:${NC} $d"
                        fi
                    fi
                done
                recalculate_split_tunnel_cidrs
                pause_prompt
                ;;
            3)
                if [[ ! -s "$DOMAINS_FILE" ]]; then
                    echo -e "\n${YELLOW}Bypass list is already empty.${NC}"
                    pause_prompt
                    continue
                fi
                echo -e "\n${GREEN}Current Bypassed Domains:${NC}"
                nl -w2 -s'. ' "$DOMAINS_FILE"
                echo -en "${RED}Enter line number or exact domain to remove: ${NC}"
                read -r rem_input
                if [[ "$rem_input" =~ ^[0-9]+$ ]]; then
                    sed -i "${rem_input}d" "$DOMAINS_FILE"
                else
                    grep -vxF "$rem_input" "$DOMAINS_FILE" > "${DOMAINS_FILE}.tmp" || true
                    mv "${DOMAINS_FILE}.tmp" "$DOMAINS_FILE"
                fi
                chmod 600 "$DOMAINS_FILE"
                recalculate_split_tunnel_cidrs
                pause_prompt
                ;;
            4)
                recalculate_split_tunnel_cidrs
                pause_prompt
                ;;
            5)
                echo -en "${RED}Clear all split-tunnel domains and restore 100% Full Tunnel? [y/N]: ${NC}"
                read -r confirm_clr
                if [[ "${confirm_clr:-N}" =~ ^[Yy]$ ]]; then
                    : > "$DOMAINS_FILE"
                    recalculate_split_tunnel_cidrs
                fi
                pause_prompt
                ;;
            b|B) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

# ==============================================================================
# 10. DEEP-CLEAN UNINSTALLER MODULE (Option r - P6)
# ==============================================================================

remove_server_module() {
    echo -e "\n${RED}======================================================${NC}"
    echo -e "${RED}   ⚠️  DEEP UNINSTALL: WireGuard Server & Artifacts   ${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "${YELLOW}This will deeply clean all WireGuard services, virtual interfaces, ipsets,${NC}"
    echo -e "${YELLOW}cron jobs, sysctl tuning, configs, and WireGuard UDP ports.${NC}"
    echo -e "${CYAN}Protected ports (80, 443, 22, 53, 3000, 8080, 8443, etc.) will NOT be touched.${NC}\n"

    echo -en "${RED}Type 'UNINSTALL' to confirm complete removal: ${NC}"
    read -r confirm_uninstall
    if [[ "$confirm_uninstall" != "UNINSTALL" ]]; then
        echo -e "${GREEN}[*] Uninstall cancelled. System was not modified.${NC}"
        pause_prompt
        return 1
    fi

    # 1. Discover any WireGuard UDP ports before removing configs
    local ports_to_clean=()
    if [[ -f "$SETTINGS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SETTINGS_FILE"
        if [[ -n "${SERVER_PORT:-}" ]]; then
            ports_to_clean+=("$SERVER_PORT")
        fi
    fi

    if command -v wg >/dev/null 2>&1; then
        while read -r _ p; do
            [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && ports_to_clean+=("$p")
        done < <(wg show all listen-port 2>/dev/null || true)
    fi

    if [[ -d "$WG_DIR" ]]; then
        for cf in "$WG_DIR"/*.conf; do
            [[ -e "$cf" ]] || continue
            local cp
            cp=$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' "$cf" | head -n1 || true)
            [[ -n "$cp" && "$cp" =~ ^[0-9]+$ ]] && ports_to_clean+=("$cp")
        done
    fi

    # 2. Stop & disable all wg-quick services
    echo -e "${CYAN}[*] Stopping and disabling WireGuard systemd services...${NC}"
    systemctl stop "wg-quick@${WG_IF}.service" 2>/dev/null || true
    systemctl disable "wg-quick@${WG_IF}.service" 2>/dev/null || true

    local unit
    while read -r unit; do
        [[ -z "$unit" ]] && continue
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    done < <(systemctl list-units --type=service --state=active,failed "wg-quick@*" --no-legend 2>/dev/null | awk '{print $1}' || true)

    # 3. Execute PostDown script if present and tear down virtual interfaces
    if [[ -x "${WG_DIR}/postdown.sh" ]]; then
        "${WG_DIR}/postdown.sh" 2>/dev/null || true
    fi

    local wg_dev
    while read -r wg_dev; do
        [[ -z "$wg_dev" ]] && continue
        ip link set down dev "$wg_dev" 2>/dev/null || true
        ip link delete dev "$wg_dev" 2>/dev/null || true
    done < <(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 || true)

    # 4. Reclaim non-sensitive WireGuard UDP ports (strictly protecting 80, 443, 22, etc.)
    if [[ "${#ports_to_clean[@]}" -gt 0 ]]; then
        local uniq_p
        mapfile -t uniq_p < <(printf "%s\n" "${ports_to_clean[@]}" | sort -u)
        for p in "${uniq_p[@]}"; do
            clean_port_firewall_rules "$p"
        done
    fi

    # 5. Clean up split-tunnel cron jobs, refresh scripts, and ipsets
    echo -e "${CYAN}[*] Removing split-tunnel cron jobs, scripts, and kernel ipsets...${NC}"
    rm -f "$CRON_FILE" "$REFRESH_SCRIPT"
    ipset destroy wg_bypass_v4 2>/dev/null || true
    ipset destroy wg_bypass_v6 2>/dev/null || true

    # 6. Remove sysctl tuning file and reload kernel defaults
    echo -e "${CYAN}[*] Removing WireGuard sysctl tuning profile...${NC}"
    rm -f "$SYSCTL_WG_CONF"
    sysctl --system >/dev/null 2>&1 || true

    # 7. Wipe /etc/wireguard and /root/easy_wireguard
    echo -e "${CYAN}[*] Wiping /etc/wireguard and ${INSTALL_DIR}...${NC}"
    rm -rf "$WG_DIR"
    rm -rf "$INSTALL_DIR"

    # 8. Optional package purge
    echo -en "${YELLOW}Also purge wireguard & wireguard-tools packages from the OS? [y/N]: ${NC}"
    read -r purge_pkgs
    if [[ "${purge_pkgs:-N}" =~ ^[Yy]$ ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get remove --purge -y wireguard wireguard-tools >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf remove -y wireguard-tools >/dev/null 2>&1 || true
        fi
    fi

    systemctl daemon-reload
    echo -e "${GREEN}[✓] Deep clean completed. All WireGuard services, files, and non-sensitive ports removed.${NC}"
    return 0
}

# ==============================================================================
# 11. SETTINGS & MAIN MENU (Exact UI Look Preserved - P0)
# ==============================================================================

settings_menu() {
    while true; do
        clear
        print_banner
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│                      Settings                      │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        printf "${PURPLE}│ ${GREEN}[1] Default MTU: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_MTU:-1360}"
        printf "${PURPLE}│ ${GREEN}[2] Default DNS: ${NC}%-33.33s ${PURPLE}│${NC}\n" "${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}"
        printf "${PURPLE}│ ${GREEN}[3] Default Allowed IPs: ${NC}%-25.25s ${PURPLE}│${NC}\n" "${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"}"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
        echo -en "${PURPLE}Select option: ${NC}"
        read -r SET_OPT

        case "$SET_OPT" in
            1)
                echo -en "${GREEN}Enter new Default MTU (1280-1500, recommended 1360): ${NC}"
                read -r NEW_MTU
                if [[ "$NEW_MTU" =~ ^[0-9]+$ ]] && (( NEW_MTU >= 1280 && NEW_MTU <= 1500 )); then
                    update_setting "DEFAULT_MTU" "$NEW_MTU"
                    DEFAULT_MTU="$NEW_MTU"
                    if [[ -f "$WG_CONF" ]]; then
                        sed -i "s|^MTU = .*|MTU = ${NEW_MTU}|" "$WG_CONF"
                    fi
                else
                    echo -e "${RED}[!] Invalid MTU value (must be 1280-1500).${NC}"
                    sleep 1
                fi
                ;;
            2)
                echo -en "${GREEN}Enter new Default DNS (comma separated): ${NC}"
                read -r NEW_DNS
                if [[ -n "$NEW_DNS" ]]; then
                    update_setting "DEFAULT_DNS" "\"$NEW_DNS\""
                    DEFAULT_DNS="$NEW_DNS"
                fi
                ;;
            3)
                echo -en "${GREEN}Enter new Default Allowed IPs: ${NC}"
                read -r NEW_IPS
                if [[ -n "$NEW_IPS" ]]; then
                    update_setting "DEFAULT_ALLOWED_IPS" "\"$NEW_IPS\""
                    DEFAULT_ALLOWED_IPS="$NEW_IPS"
                fi
                ;;
            b) break ;;
        esac
    done
}

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 Cookie's Easy WireGuard Manager${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│                  Main Menu Actions                 │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Setup WireGuard server                        ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Add new client (peer)                         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[3] Configure clients (Check/Edit/Remove)         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[4] Backup & Restore Manager                      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[5] Domain-Based Split Tunneling                  ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[6] Real-Time Logging (Errors)                    ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[s] Settings (MTU, DNS, AllowedIPs)               ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[r] Remove WireGuard server from this system      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[q] Exit                                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

main() {
    while true; do
        clear
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r OPTION

        case "$OPTION" in
            1) setup_server_module ;;
            2) add_client_module ;;
            3) user_manager_module ;;
            4) backup_manager_module ;;
            5) domain_bypass_module ;;
            6)
                echo -e "\n${GREEN}Starting Real-Time Logging for WireGuard errors (last 12 hours)...${NC}"
                echo -e "${PURPLE}Press Ctrl+C to stop logging and return to menu.${NC}\n"
                journalctl -u "wg-quick@${WG_IF}.service" --since "12 hours ago" -p err -f || true
                pause_prompt
                ;;
            s) settings_menu ;;
            r)
                if remove_server_module; then
                    break
                fi
                ;;
            q)
                echo -e "${PURPLE}Exit: The system was not modified.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

main