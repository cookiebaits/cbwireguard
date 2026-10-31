#!/usr/bin/env bash
# ==============================================================================
# WireGuard Ultra-Stealth & High-Speed Server Manager (100% Server-Side)
# Zero extra client software required | Pure copy-paste .conf output
# ==============================================================================

set -e

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
CLIENT_DIR="${WG_DIR}/clients"
STATE_FILE="${WG_DIR}/stealth_state.env"
SYSCTL_CONF="/etc/sysctl.d/99-wg-stealth-speed.conf"

# Default Non-Standard Stealth Ports (Avoids 80, 443, 51820)
DEFAULT_PRIMARY_PORT="47843"
# Discrete uncommon UDP ports (mimics custom gaming/voice/ephemeral UDP)
DEFAULT_STEALTH_PORTS="19305,27038,34784,41952,55280,61420"
# Continuous port-hopping range redirected natively by kernel
DEFAULT_HOP_RANGE="48000:48500"
# Clean Geolocation-Aligned DNS (Cloudflare / Quad9)
DEFAULT_LOC_DNS="1.1.1.1"
DEFAULT_MTU="1380"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root (use sudo).${NC}"
        exit 1
    fi
}

get_public_nic() {
    ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1
}

get_public_ip() {
    local ip=""
    ip=$(ip -4 addr show dev "$(get_public_nic)" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [[ -z "$ip" ]] || [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
        ip=$(curl -4 -s --max-time 4 https://icanhazip.com || curl -4 -s --max-time 4 https://api.ipify.org || echo "$ip")
    fi
    echo "$ip"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
    else
        PRIMARY_PORT="$DEFAULT_PRIMARY_PORT"
        STEALTH_PORTS="$DEFAULT_STEALTH_PORTS"
        HOP_RANGE="$DEFAULT_HOP_RANGE"
        LOC_DNS="$DEFAULT_LOC_DNS"
        TUNNEL_MTU="$DEFAULT_MTU"
        PUBLIC_NIC="$(get_public_nic)"
        PUBLIC_IP="$(get_public_ip)"
    fi
}

save_state() {
    mkdir -p "$WG_DIR"
    cat > "$STATE_FILE" <<EOF
PRIMARY_PORT="${PRIMARY_PORT}"
STEALTH_PORTS="${STEALTH_PORTS}"
HOP_RANGE="${HOP_RANGE}"
LOC_DNS="${LOC_DNS}"
TUNNEL_MTU="${TUNNEL_MTU}"
PUBLIC_NIC="${PUBLIC_NIC}"
PUBLIC_IP="${PUBLIC_IP}"
EOF
    chmod 600 "$STATE_FILE"
}

install_base_dependencies() {
    if ! command -v wg &>/dev/null || ! command -v iptables &>/dev/null; then
        echo -e "${CYAN}[*] Checking base system packages (wireguard, iptables)...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools iptables iproute2 curl
        elif command -v dnf &>/dev/null; then
            dnf install -y -q wireguard-tools iptables iproute curl
        elif command -v yum &>/dev/null; then
            yum install -y -q wireguard-tools iptables iproute curl
        fi
    fi
}

apply_kernel_speed_and_stealth() {
    echo -e "${CYAN}[*] Applying kernel speed & anti-fingerprinting parameters...${NC}"
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true

    cat > "$SYSCTL_CONF" <<EOF
# --- Routing & Forwarding ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- Congestion Control & Queue Discipline (BBR + FQ) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- High-Throughput Socket & UDP Buffers (64MB Max) ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# --- Low-Latency & Anti-Probing ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# --- Server-Side Anti-Fingerprinting & ICMP Stealth ---
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1
    echo -e "${GREEN}[+] Kernel BBR, 64MB UDP buffers, and stealth stack enabled.${NC}"
}

write_firewall_scripts() {
    mkdir -p "$WG_DIR"

    # Generate PostUp Script
    cat > "${WG_DIR}/stealth-up.sh" <<EOF
#!/usr/bin/env bash
NIC="${PUBLIC_NIC}"
WG_IF="wg0"
WG_SUB="10.66.66.0/24"
WG_SUB6="fd42:42:42::/64"
PRIMARY="${PRIMARY_PORT}"
MULTI_PORTS="${STEALTH_PORTS}"
HOP="${HOP_RANGE}"
DNS_TARGET="${LOC_DNS}"

# 1. Ensure Forwarding & Input Access for Primary + Stealth Hopping Ports
iptables -I INPUT 1 -i "\$WG_IF" -j ACCEPT
iptables -I INPUT 1 -i "\$NIC" -p udp --dport "\$PRIMARY" -j ACCEPT
iptables -I INPUT 1 -i "\$NIC" -p udp -m multiport --dports "\$MULTI_PORTS" -j ACCEPT
iptables -I INPUT 1 -i "\$NIC" -p udp --dport "\$HOP" -j ACCEPT

iptables -I FORWARD 1 -i "\$WG_IF" -o "\$NIC" -j ACCEPT
iptables -I FORWARD 1 -i "\$NIC" -o "\$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -I FORWARD 1 -i "\$WG_IF" -o "\$NIC" -j ACCEPT 2>/dev/null || true
ip6tables -I FORWARD 1 -i "\$NIC" -o "\$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# 2. NAT Masquerade (Routes all client traffic out via Server IP)
iptables -t nat -A POSTROUTING -s "\$WG_SUB" -o "\$NIC" -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s "\$WG_SUB6" -o "\$NIC" -j MASQUERADE 2>/dev/null || true

# 3. Server-Side Stealth Port Hopping (Redirects Unique Ports -> Primary WG Port)
iptables -t nat -A PREROUTING -i "\$NIC" -p udp -m multiport --dports "\$MULTI_PORTS" -j REDIRECT --to-ports "\$PRIMARY"
iptables -t nat -A PREROUTING -i "\$NIC" -p udp --dport "\$HOP" -j REDIRECT --to-ports "\$PRIMARY"

# 4. LOCATION OVERRIDE ENFORCEMENT (Forces All Tunnel Traffic to Server Geo Profile)
# 4a. Transparent DNS Hijack: Force any client DNS query to use the clean Server-side DNS
iptables -t nat -A PREROUTING -i "\$WG_IF" -p udp --dport 53 -j DNAT --to-destination "\${DNS_TARGET}:53"
iptables -t nat -A PREROUTING -i "\$WG_IF" -p tcp --dport 53 -j DNAT --to-destination "\${DNS_TARGET}:53"
# Block IPv6 DNS inside tunnel so all resolution stays strictly on hijacked IPv4 path
ip6tables -I FORWARD 1 -i "\$WG_IF" -p udp --dport 53 -j REJECT 2>/dev/null || true
ip6tables -I FORWARD 1 -i "\$WG_IF" -p tcp --dport 53 -j REJECT 2>/dev/null || true

# 4b. Block Outbound QUIC (UDP 443/80) & STUN Leak Ports inside tunnel
# Forces browsers to TCP where MSS clamping & location headers remain strictly bound to WG
iptables -I FORWARD 1 -i "\$WG_IF" -p udp -m multiport --dports 80,443,3478,5349,19302 -j REJECT --reject-with icmp-port-unreachable
ip6tables -I FORWARD 1 -i "\$WG_IF" -p udp -m multiport --dports 80,443,3478,5349,19302 -j REJECT 2>/dev/null || true

# 5. Deep Packet Inspection (DPI) Evasion & Anti-Fingerprinting (Mangle Table)
# Clamp TCP MSS dynamically to PMTU so zero packet fragmentation occurs
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

# Normalize TTL/Hop-Limit to 64 so upstream providers cannot detect VPN hop depth
iptables -t mangle -A POSTROUTING -o "\$NIC" -j TTL --ttl-set 64 2>/dev/null || true
ip6tables -t mangle -A POSTROUTING -o "\$NIC" -j HL --hl-set 64 2>/dev/null || true

# Strip DSCP / ToS bits to prevent inner-packet traffic classification
iptables -t mangle -A POSTROUTING -o "\$NIC" -j TOS --set-tos 0x00 2>/dev/null || true
EOF

    # Generate PostDown Script
    cat > "${WG_DIR}/stealth-down.sh" <<EOF
#!/usr/bin/env bash
NIC="${PUBLIC_NIC}"
WG_IF="wg0"
WG_SUB="10.66.66.0/24"
WG_SUB6="fd42:42:42::/64"
PRIMARY="${PRIMARY_PORT}"
MULTI_PORTS="${STEALTH_PORTS}"
HOP="${HOP_RANGE}"
DNS_TARGET="${LOC_DNS}"

iptables -D INPUT -i "\$WG_IF" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "\$NIC" -p udp --dport "\$PRIMARY" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "\$NIC" -p udp -m multiport --dports "\$MULTI_PORTS" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "\$NIC" -p udp --dport "\$HOP" -j ACCEPT 2>/dev/null || true

iptables -D FORWARD -i "\$WG_IF" -o "\$NIC" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "\$NIC" -o "\$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
ip6tables -D FORWARD -i "\$WG_IF" -o "\$NIC" -j ACCEPT 2>/dev/null || true
ip6tables -D FORWARD -i "\$NIC" -o "\$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

iptables -t nat -D POSTROUTING -s "\$WG_SUB" -o "\$NIC" -j MASQUERADE 2>/dev/null || true
ip6tables -t nat -D POSTROUTING -s "\$WG_SUB6" -o "\$NIC" -j MASQUERADE 2>/dev/null || true

iptables -t nat -D PREROUTING -i "\$NIC" -p udp -m multiport --dports "\$MULTI_PORTS" -j REDIRECT --to-ports "\$PRIMARY" 2>/dev/null || true
iptables -t nat -D PREROUTING -i "\$NIC" -p udp --dport "\$HOP" -j REDIRECT --to-ports "\$PRIMARY" 2>/dev/null || true

iptables -t nat -D PREROUTING -i "\$WG_IF" -p udp --dport 53 -j DNAT --to-destination "\${DNS_TARGET}:53" 2>/dev/null || true
iptables -t nat -D PREROUTING -i "\$WG_IF" -p tcp --dport 53 -j DNAT --to-destination "\${DNS_TARGET}:53" 2>/dev/null || true
ip6tables -D FORWARD -i "\$WG_IF" -p udp --dport 53 -j REJECT 2>/dev/null || true
ip6tables -D FORWARD -i "\$WG_IF" -p tcp --dport 53 -j REJECT 2>/dev/null || true

iptables -D FORWARD -i "\$WG_IF" -p udp -m multiport --dports 80,443,3478,5349,19302 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true
ip6tables -D FORWARD -i "\$WG_IF" -p udp -m multiport --dports 80,443,3478,5349,19302 -j REJECT 2>/dev/null || true

iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D POSTROUTING -o "\$NIC" -j TTL --ttl-set 64 2>/dev/null || true
ip6tables -t mangle -D POSTROUTING -o "\$NIC" -j HL --hl-set 64 2>/dev/null || true
iptables -t mangle -D POSTROUTING -o "\$NIC" -j TOS --set-tos 0x00 2>/dev/null || true
EOF

    chmod +x "${WG_DIR}/stealth-up.sh" "${WG_DIR}/stealth-down.sh"
}

prompt_optional_qr() {
    local conf_file="$1"
    echo ""
    read -r -p "Would you like to generate a QR code for this config? (y/N): " qr_choice
    if [[ "$qr_choice" =~ ^[Yy]$ ]]; then
        if ! command -v qrencode &>/dev/null; then
            echo -e "${YELLOW}[*] qrencode is not installed. Install it now to render the QR code? (y/N): ${NC}"
            read -r install_qr
            if [[ "$install_qr" =~ ^[Yy]$ ]]; then
                if command -v apt-get &>/dev/null; then
                    apt-get update -qq && apt-get install -y -qq qrencode
                elif command -v dnf &>/dev/null; then
                    dnf install -y -q qrencode
                elif command -v yum &>/dev/null; then
                    yum install -y -q qrencode
                fi
            fi
        fi
        if command -v qrencode &>/dev/null; then
            echo -e "\n${CYAN}--- Scan QR Code in WireGuard Client ---${NC}"
            qrencode -t ansiutf8 < "$conf_file"
            echo ""
        else
            echo -e "${YELLOW}[!] Skipping QR generation (qrencode not present). Copy-paste the config above.${NC}"
        fi
    fi
}

setup_server() {
    load_state
    install_base_dependencies
    mkdir -p "$WG_DIR" "$CLIENT_DIR"
    chmod 700 "$WG_DIR" "$CLIENT_DIR"

    echo -e "\n${CYAN}=== 1) Initial Stealth Server Setup ===${NC}"
    read -r -p "Detected Public Interface [${PUBLIC_NIC}]: " input_nic
    PUBLIC_NIC="${input_nic:-$PUBLIC_NIC}"

    read -r -p "Detected Public IP [${PUBLIC_IP}]: " input_ip
    PUBLIC_IP="${input_ip:-$PUBLIC_IP}"

    read -r -p "Primary Listener UDP Port (non-standard) [${PRIMARY_PORT}]: " input_port
    PRIMARY_PORT="${input_port:-$PRIMARY_PORT}"

    read -r -p "Unique Stealth Multi-Ports [${STEALTH_PORTS}]: " input_multi
    STEALTH_PORTS="${input_multi:-$STEALTH_PORTS}"

    read -r -p "Stealth Port-Hopping Range [${HOP_RANGE}]: " input_hop
    HOP_RANGE="${input_hop:-$HOP_RANGE}"

    read -r -p "Location-Override Target DNS [${LOC_DNS}]: " input_dns
    LOC_DNS="${input_dns:-$LOC_DNS}"

    save_state
    apply_kernel_speed_and_stealth
    write_firewall_scripts

    if [[ ! -f "${WG_DIR}/server_private.key" ]]; then
        wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
        chmod 600 "${WG_DIR}/server_private.key"
    fi
    SERVER_PRIV_KEY=$(cat "${WG_DIR}/server_private.key")

    systemctl stop wg-quick@wg0 2>/dev/null || true

    cat > "$WG_CONF" <<EOF
[Interface]
Address = 10.66.66.1/24, fd42:42:42::1/64
ListenPort = ${PRIMARY_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = ${TUNNEL_MTU}
PostUp = ${WG_DIR}/stealth-up.sh
PostDown = ${WG_DIR}/stealth-down.sh
EOF
    chmod 600 "$WG_CONF"

    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl restart wg-quick@wg0

    echo -e "${GREEN}[+] Stealth WireGuard Server deployed and running on Primary Port ${PRIMARY_PORT}!${NC}"
    echo -e "${GREEN}[+] Active Stealth Alias Ports: ${STEALTH_PORTS} and Range ${HOP_RANGE}${NC}"
}

add_client() {
    load_state
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "${RED}[!] Server is not initialized yet. Run Option 1 first.${NC}"
        return
    fi

    echo -e "\n${CYAN}=== 2) Add New Stealth Client ===${NC}"
    read -r -p "Enter a name for the client (e.g., laptop, phone): " client_name
    client_name=$(echo "$client_name" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$client_name" ]]; then
        echo -e "${RED}[!] Invalid client name.${NC}"
        return
    fi

    local client_conf="${CLIENT_DIR}/${client_name}.conf"
    if [[ -f "$client_conf" ]]; then
        echo -e "${RED}[!] Client '${client_name}' already exists.${NC}"
        return
    fi

    echo -e "\nAvailable Stealth Endpoint Ports (all route to server):"
    echo -e "  • Primary Port : ${GREEN}${PRIMARY_PORT}${NC}"
    echo -e "  • Unique Ports : ${GREEN}${STEALTH_PORTS}${NC}"
    echo -e "  • Hop Range    : ${GREEN}${HOP_RANGE}${NC}"
    read -r -p "Select Endpoint Port for this client [${PRIMARY_PORT}]: " chosen_port
    chosen_port="${chosen_port:-$PRIMARY_PORT}"

    # Determine next available IP in 10.66.66.X
    local octet=2
    while grep -q "10.66.66.${octet}/32" "$WG_CONF"; do
        ((octet++))
    done

    local client_priv client_pub client_psk server_pub
    client_priv=$(wg genkey)
    client_pub=$(echo "$client_priv" | wg pubkey)
    client_psk=$(wg genpsk)
    server_pub=$(cat "${WG_DIR}/server_public.key")

    # Append peer to server config
    cat >> "$WG_CONF" <<EOF

# BEGIN_PEER ${client_name}
[Peer]
PublicKey = ${client_pub}
PresharedKey = ${client_psk}
AllowedIPs = 10.66.66.${octet}/32, fd42:42:42::${octet}/128
# END_PEER ${client_name}
EOF

    # Live sync without dropping existing connections
    wg syncconf wg0 <(wg-quick strip wg0)

    # Generate pure client configuration
    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = ${client_priv}
Address = 10.66.66.${octet}/32, fd42:42:42::${octet}/128
DNS = ${LOC_DNS}
MTU = ${TUNNEL_MTU}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${client_psk}
Endpoint = ${PUBLIC_IP}:${chosen_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 21
EOF
    chmod 600 "$client_conf"

    echo -e "\n${GREEN}[+] Client '${client_name}' created and activated on server!${NC}"
    echo -e "${YELLOW}[i] Tip: You can change the port in 'Endpoint = ${PUBLIC_IP}:${chosen_port}' at any time to any port in [${STEALTH_PORTS}] or [${HOP_RANGE}].${NC}"
    echo -e "\n${CYAN}================ COPY BELOW THIS LINE ================${NC}"
    cat "$client_conf"
    echo -e "${CYAN}================ COPY ABOVE THIS LINE ================${NC}"

    prompt_optional_qr "$client_conf"
}

view_client() {
    mkdir -p "$CLIENT_DIR"
    echo -e "\n${CYAN}=== 3) View / Export Existing Client Config ===${NC}"
    local clients=("$CLIENT_DIR"/*.conf)
    if [[ ! -e "${clients[0]}" ]]; then
        echo -e "${YELLOW}[!] No clients found.${NC}"
        return
    fi

    echo "Existing Clients:"
    local i=1
    for c in "${clients[@]}"; do
        echo "  $i) $(basename "$c" .conf)"
        ((i++))
    done

    read -r -p "Select client number: " c_num
    local selected="${clients[$((c_num - 1))]}"
    if [[ -z "$selected" || ! -f "$selected" ]]; then
        echo -e "${RED}[!] Invalid selection.${NC}"
        return
    fi

    echo -e "\n${CYAN}================ COPY BELOW THIS LINE ================${NC}"
    cat "$selected"
    echo -e "${CYAN}================ COPY ABOVE THIS LINE ================${NC}"

    prompt_optional_qr "$selected"
}

remove_client() {
    mkdir -p "$CLIENT_DIR"
    echo -e "\n${CYAN}=== 4) Remove a Client ===${NC}"
    local clients=("$CLIENT_DIR"/*.conf)
    if [[ ! -e "${clients[0]}" ]]; then
        echo -e "${YELLOW}[!] No clients found.${NC}"
        return
    fi

    local i=1
    for c in "${clients[@]}"; do
        echo "  $i) $(basename "$c" .conf)"
        ((i++))
    done

    read -r -p "Select client number to remove: " c_num
    local selected="${clients[$((c_num - 1))]}"
    if [[ -z "$selected" || ! -f "$selected" ]]; then
        echo -e "${RED}[!] Invalid selection.${NC}"
        return
    fi

    local c_name
    c_name=$(basename "$selected" .conf)
    sed -i "/# BEGIN_PEER ${c_name}/,/# END_PEER ${c_name}/d" "$WG_CONF"
    rm -f "$selected"

    wg syncconf wg0 <(wg-quick strip wg0)
    echo -e "${GREEN}[+] Client '${c_name}' removed from server.${NC}"
}

update_stealth_ports_and_location() {
    load_state
    if [[ ! -f "$WG_CONF" ]]; then
        echo -e "${RED}[!] Server is not initialized yet. Run Option 1 first.${NC}"
        return
    fi

    echo -e "\n${CYAN}=== 5) Update Stealth Ports & Location Override Routing ===${NC}"
    echo -e "Current Primary Port       : ${GREEN}${PRIMARY_PORT}${NC}"
    echo -e "Current Unique Port List   : ${GREEN}${STEALTH_PORTS}${NC}"
    echo -e "Current Port-Hopping Range : ${GREEN}${HOP_RANGE}${NC}"
    echo -e "Current Location DNS Target: ${GREEN}${LOC_DNS}${NC}"
    echo ""

    read -r -p "New Primary Listener Port [${PRIMARY_PORT}]: " new_primary
    new_primary="${new_primary:-$PRIMARY_PORT}"

    read -r -p "New Unique Stealth Ports (comma-separated) [${STEALTH_PORTS}]: " new_multi
    new_multi="${new_multi:-$STEALTH_PORTS}"

    read -r -p "New Port-Hopping Range (start:end) [${HOP_RANGE}]: " new_hop
    new_hop="${new_hop:-$HOP_RANGE}"

    read -r -p "New Location Override DNS Target [${LOC_DNS}]: " new_dns
    new_dns="${new_dns:-$LOC_DNS}"

    # Bring down current firewall rules cleanly before updating
    systemctl stop wg-quick@wg0

    PRIMARY_PORT="$new_primary"
    STEALTH_PORTS="$new_multi"
    HOP_RANGE="$new_hop"
    LOC_DNS="$new_dns"

    save_state
    write_firewall_scripts

    # Update ListenPort in wg0.conf
    sed -i "s/^ListenPort = .*/ListenPort = ${PRIMARY_PORT}/" "$WG_CONF"

    systemctl start wg-quick@wg0
    echo -e "${GREEN}[+] Stealth port matrix & Location Override DNS rules updated and reloaded!${NC}"
}

show_status() {
    load_state
    echo -e "\n${CYAN}=== 6) Server Stealth, Routing & Speed Status ===${NC}"
    echo -e "Public Interface      : ${GREEN}${PUBLIC_NIC}${NC} (${PUBLIC_IP})"
    echo -e "Primary WG Port       : ${GREEN}${PRIMARY_PORT}/UDP${NC}"
    echo -e "Unique Stealth Ports  : ${GREEN}${STEALTH_PORTS}${NC}"
    echo -e "Port-Hopping Range    : ${GREEN}${HOP_RANGE}${NC}"
    echo -e "Location DNS Override : ${GREEN}${LOC_DNS}:53 (Enforced via PREROUTING DNAT)${NC}"
    echo -e "Congestion Control    : ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC}"
    echo -e "IPv4 Forwarding       : ${GREEN}$(sysctl -n net.ipv4.ip_forward 2>/dev/null)${NC}"
    echo -e "\n${CYAN}--- Active WireGuard Interface ---${NC}"
    wg show || echo -e "${YELLOW}WireGuard interface wg0 is not currently active.${NC}"
}

main_menu() {
    check_root
    while true; do
        echo -e "\n${CYAN}============================================================${NC}"
        echo -e "${GREEN}   WireGuard Ultra-Stealth & Speed Server Manager (v2.0)   ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo "  1) Initial Server Setup (Kernel Speed + Stealth Ports + WG0)"
        echo "  2) Add New Client (Outputs Copy-Paste .conf + Optional QR)"
        echo "  3) View / Export Existing Client .conf"
        echo "  4) Remove a Client"
        echo "  5) Update Stealth Ports & Location Override Routing"
        echo "  6) Check Server Status & Active Peers"
        echo "  0) Exit"
        echo -e "${CYAN}------------------------------------------------------------${NC}"
        read -r -p "Select an option [0-6]: " opt

        case "$opt" in
            1) setup_server ;;
            2) add_client ;;
            3) view_client ;;
            4) remove_client ;;
            5) update_stealth_ports_and_location ;;
            6) show_status ;;
            0) echo -e "${GREEN}Exiting.${NC}"; exit 0 ;;
            *) echo -e "${RED}[!] Invalid option.${NC}" ;;
        esac
    done
}

main_menu