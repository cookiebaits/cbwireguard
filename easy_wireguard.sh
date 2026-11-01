#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager (High-Speed, Stealth & Split-Tunnel Edition)
# ==============================================================================
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
BYPASS_DOMAINS_FILE="${INSTALL_DIR}/bypass_domains.txt"
SPLIT_MODE_FILE="${INSTALL_DIR}/split_mode.txt"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

init_environment() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
    chmod 700 "$INSTALL_DIR"

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        cat <<EOF > "$SETTINGS_FILE"
DEFAULT_MTU=1420
DEFAULT_DNS="94.140.14.49, 9.9.9.9, 94.140.14.59"
DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
EOF
        chmod 600 "$SETTINGS_FILE"
    fi

    [[ ! -f "$BYPASS_DOMAINS_FILE" ]] && touch "$BYPASS_DOMAINS_FILE"
    [[ ! -f "$SPLIT_MODE_FILE" ]] && echo "BYPASS" > "$SPLIT_MODE_FILE"
}

init_environment

if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# ------------------------------------------------------------------------------
# Helper: Live Progress Bar & Strip 'clear' so everything stays in one window
# ------------------------------------------------------------------------------
show_progress_bar() {
    local percent="$1"
    local step_text="$2"
    local bar_width=28
    local num_filled=$(( (percent * bar_width) / 100 ))
    local num_empty=$(( bar_width - num_filled ))
    local bar_str=""
    local i

    for ((i=0; i<num_filled; i++)); do bar_str+="█"; done
    for ((i=0; i<num_empty; i++)); do bar_str+="░"; done

    printf "\r  ${CYAN}[%3d%%]${NC} [${GREEN}%s${NC}] ${WHITE}%-54s${NC}\033[K" "$percent" "$bar_str" "$step_text"
    if [[ "$percent" -ge 100 ]]; then
        echo ""
    fi
}

strip_clear_from_script() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sed -i -E 's/^[[:space:]]*(clear|tput[[:space:]]+reset)[[:space:]]*$/: # clear disabled/g' "$file" 2>/dev/null || true
    fi
}

# Safe bounded iptables rule deletion (prevents infinite loops or xtables lock hangs)
safe_ipt_del() {
    local cmd="$1"
    shift
    local tries=0
    while [[ $tries -lt 10 ]]; do
        if ! "$cmd" -w 2 "$@" >/dev/null 2>&1; then
            break
        fi
        tries=$((tries + 1))
    done
}

# ------------------------------------------------------------------------------
# 1. Sensitive Port Protection & Port-In-Use Verification
# ------------------------------------------------------------------------------
isSensitivePort() {
    local port="$1"
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017)
    for sp in "${sensitive_ports[@]}"; do
        if [[ "$port" -eq "$sp" ]]; then
            return 0
        fi
    done
    return 1
}

isPortInUse() {
    local port="$1"
    local proto="${2:-udp}"
    if command -v ss &>/dev/null; then
        if [[ "$proto" == "udp" ]]; then
            ss -uln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        else
            ss -tln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        fi
    elif command -v netstat &>/dev/null; then
        if [[ "$proto" == "udp" ]]; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        else
            netstat -tln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 2. Fast, Non-Blocking Pre-Install Cleanup & Deep Uninstaller
# ------------------------------------------------------------------------------
cleanupOldWireguard() {
    local mode="${1:-preinstall}"
    echo -e "\n${CYAN}${BOLD}[*] Cleaning up existing WireGuard instances, ports, and cached files...${NC}"

    show_progress_bar 15 "Scanning configs & kernel for WireGuard interfaces/ports..."
    local OLD_PORTS=()
    local OLD_IFACES=("wg0" "wg1")

    if [[ -d /etc/wireguard ]]; then
        for conf in /etc/wireguard/*.conf; do
            [[ ! -f "$conf" ]] && continue
            local iface_name
            iface_name=$(basename "$conf" .conf)
            OLD_IFACES+=("$iface_name")

            local extracted_ports
            extracted_ports=$(grep -iE "^[[:space:]]*ListenPort[[:space:]]*=" "$conf" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || true)
            for p in $extracted_ports; do
                [[ "$p" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$p")
            done
        done

        for param_file in /etc/wireguard/params /etc/wireguard/manager.env "$SETTINGS_FILE"; do
            if [[ -f "$param_file" ]]; then
                local p_vals
                p_vals=$(grep -iE "(PORT|LISTEN)" "$param_file" 2>/dev/null | awk -F'=' '{print $2}' | tr -d '"'\'' \t\r\n' || true)
                for p in $p_vals; do
                    [[ "$p" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$p")
                done
            fi
        done
    fi

    if command -v wg &>/dev/null; then
        local live_ifaces
        live_ifaces=$(timeout 3 wg show interfaces 2>/dev/null || true)
        for liface in $live_ifaces; do
            OLD_IFACES+=("$liface")
            local lport
            lport=$(timeout 2 wg show "$liface" listen-port 2>/dev/null | tr -d ' \t\r\n' || true)
            [[ "$lport" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$lport")
        done
    fi

    local link_ifaces
    link_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wg[0-9a-zA-Z_-]*' || true)
    for kiface in $link_ifaces; do
        OLD_IFACES+=("$kiface")
    done

    local conf_files=()
    while IFS= read -r -d '' cf; do
        conf_files+=("$cf")
    done < <(find /etc/wireguard "$INSTALL_DIR" /root /home -maxdepth 2 -type f -name "*.conf" -print0 2>/dev/null || true)

    for cf in "${conf_files[@]}"; do
        while IFS= read -r ep_line; do
            local ep_port="${ep_line##*:}"
            ep_port=$(echo "$ep_port" | tr -d ' \t\r\n')
            [[ "$ep_port" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$ep_port")
        done < <(grep -E "^[[:space:]]*Endpoint[[:space:]]*=" "$cf" 2>/dev/null || true)
    done

    local UNIQUE_IFACES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && UNIQUE_IFACES+=("$line")
    done < <(printf "%s\n" "${OLD_IFACES[@]}" | sort -u)

    local UNIQUE_PORTS=()
    if [[ ${#OLD_PORTS[@]} -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && UNIQUE_PORTS+=("$line")
        done < <(printf "%s\n" "${OLD_PORTS[@]}" | sort -u)
    fi

    show_progress_bar 35 "Stopping WireGuard systemd services and active tunnels..."
    timeout 10 systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
    timeout 10 systemctl disable "wg-quick@*" >/dev/null 2>&1 || true

    local wg_units
    wg_units=$(timeout 5 systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '(^wg-quick|wireguard|cbwireguard)' || true)
    for unit in $wg_units; do
        timeout 5 systemctl stop "$unit" >/dev/null 2>&1 || true
        timeout 5 systemctl disable "$unit" >/dev/null 2>&1 || true
    done

    show_progress_bar 55 "Removing virtual WireGuard interfaces (${UNIQUE_IFACES[*]})..."
    for iface in "${UNIQUE_IFACES[@]}"; do
        timeout 5 systemctl stop "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        timeout 5 systemctl disable "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        if command -v wg-quick &>/dev/null; then
            timeout 5 wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        ip link set "$iface" down >/dev/null 2>&1 || true
        ip link delete dev "$iface" >/dev/null 2>&1 || true

        safe_ipt_del iptables -D FORWARD -i "$iface" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o "$iface" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        safe_ipt_del iptables -D INPUT -i "$iface" -j ACCEPT
        safe_ipt_del ip6tables -D FORWARD -i "$iface" -j ACCEPT
        safe_ipt_del ip6tables -D FORWARD -o "$iface" -j ACCEPT
        safe_ipt_del ip6tables -D FORWARD -i "$iface" -j REJECT
        safe_ipt_del ip6tables -D OUTPUT -o "$iface" -j REJECT
    done

    show_progress_bar 75 "Cleaning old WireGuard UDP ports (sensitive ports protected)..."
    local cleaned_ports_list=()
    for port in "${UNIQUE_PORTS[@]}"; do
        if isSensitivePort "$port"; then
            continue
        fi
        cleaned_ports_list+=("${port}/udp")
        safe_ipt_del iptables -D INPUT -p udp --dport "$port" -j ACCEPT
        safe_ipt_del iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
        safe_ipt_del ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT
        safe_ipt_del ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT

        if command -v ufw &>/dev/null && timeout 3 ufw status 2>/dev/null | grep -q "Status: active"; then
            timeout 5 ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            timeout 5 ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            timeout 5 firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            timeout 5 firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
            timeout 5 firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    done

    show_progress_bar 88 "Flushing WireGuard NAT, TCPMSS mangle, and IPSet tables..."
    local wg_subnets=("10.18.0.0/24" "10.19.0.0/24" "10.8.0.0/24" "10.0.0.0/24" "10.66.66.0/24" "10.7.0.0/24" "10.10.0.0/24")
    local def_nic
    def_nic=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

    for sub in "${wg_subnets[@]}"; do
        safe_ipt_del iptables -D FORWARD -s "$sub" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -d "$sub" -j ACCEPT
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" -j MASQUERADE
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" -o "$def_nic" -j MASQUERADE
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" ! -o wg0 -j MASQUERADE
    done

    safe_ipt_del iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    safe_ipt_del iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    safe_ipt_del iptables -t mangle -D POSTROUTING -o "$def_nic" -j TTL --ttl-set 64
    safe_ipt_del iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64

    if command -v ipset &>/dev/null; then
        local wg_ipsets
        wg_ipsets=$(ipset list -n 2>/dev/null | grep -iE '^(wg_|geo_|vpn_)' || true)
        for setname in $wg_ipsets; do
            safe_ipt_del iptables -D INPUT -m set --match-set "$setname" src -j DROP
            safe_ipt_del iptables -D FORWARD -m set --match-set "$setname" src -j DROP
            safe_ipt_del iptables -t nat -D POSTROUTING -m set --match-set "$setname" dst -o "$def_nic" -j MASQUERADE
            ipset flush "$setname" 2>/dev/null || true
            ipset destroy "$setname" 2>/dev/null || true
        done
    fi

    show_progress_bar 96 "Purging old cached WireGuard scripts, temp files & sockets..."
    rm -f "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/.*.sh 2>/dev/null || true
    rm -rf /run/wireguard /var/run/wireguard /tmp/*wireguard* /tmp/*wg* /var/tmp/*wireguard* /var/tmp/*wg* 2>/dev/null || true
    rm -f /var/cache/apt/archives/*wireguard* /etc/wireguard/wg*.conf /etc/wireguard/params /etc/wireguard/manager.env /etc/wireguard/.*.swp 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    show_progress_bar 100 "Cleanup & cache purge complete!"

    if [[ "$mode" == "preinstall" ]]; then
        echo -e "  ${GREEN}├─ Interfaces Cleaned:${NC} ${UNIQUE_IFACES[*]}"
        if [[ ${#cleaned_ports_list[@]} -gt 0 ]]; then
            echo -e "  ${GREEN}├─ Old Ports Freed:${NC}    ${cleaned_ports_list[*]}"
        else
            echo -e "  ${GREEN}├─ Old Ports Freed:${NC}    None active"
        fi
        echo -e "  ${GREEN}└─ Cache & Security:${NC}   Cached WireGuard files purged; sensitive ports (80, 443, 22) untouched."
    fi
}

deep_remove_wireguard() {
    echo -e "\n${RED}${BOLD}=================================================================${NC}"
    echo -e "${RED}${BOLD}   ⚠️  DEEP REMOVAL: WIREGUARD SERVER, CONFIGS, PORTS & FILES    ${NC}"
    echo -e "${RED}${BOLD}=================================================================${NC}"
    echo -en "${YELLOW}Are you sure you want to completely remove all WireGuard services, configs, and ports? [y/N]: ${NC}"
    read -r CONFIRM_DEL
    if [[ ! "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
        echo -e "${PURPLE}Removal cancelled. Returning to main menu...${NC}"
        return 0
    fi

    show_progress_bar 10 "Running uninstaller script (auto-confirming prompts)..."
    local rem_script=""
    if [[ -f "./remove_server.sh" ]]; then
        rem_script="./remove_server.sh"
    elif [[ -f "${INSTALL_DIR}/remove_server.sh" ]]; then
        rem_script="${INSTALL_DIR}/remove_server.sh"
    elif curl -sSfL --connect-timeout 4 --max-time 10 "${GIT_REPO}/remove_server.sh" -o "${INSTALL_DIR}/remove_server.sh" 2>/dev/null; then
        rem_script="${INSTALL_DIR}/remove_server.sh"
    fi

    if [[ -n "$rem_script" && -f "$rem_script" ]]; then
        strip_clear_from_script "$rem_script"
        chmod 700 "$rem_script" 2>/dev/null || true
        yes "y" 2>/dev/null | timeout 15 "$rem_script" >/dev/null 2>&1 || true
    fi

    cleanupOldWireguard "deep"

    show_progress_bar 50 "Unloading WireGuard kernel module..."
    if lsmod 2>/dev/null | grep -q "^wireguard"; then
        timeout 5 modprobe -r wireguard 2>/dev/null || true
    fi

    show_progress_bar 70 "Scanning /root, /home, /etc, and /tmp for WireGuard client configs..."
    local removed_files_count=0
    local client_search_dirs=("/root" "/home" "/tmp" "/var/tmp" "/etc/wireguard" "/opt")
    for sdir in "${client_search_dirs[@]}"; do
        [[ ! -d "$sdir" ]] && continue
        while IFS= read -r -d '' f; do
            local bname
            bname=$(basename "$f")
            [[ "$bname" == "resolv.conf" || "$bname" == "sysctl.conf" || "$bname" == "host.conf" || "$bname" == "nsswitch.conf" ]] && continue
            if grep -qE "(\[Interface\]|\[Peer\]|PrivateKey[[:space:]]*=|AllowedIPs[[:space:]]*=|wg-quick)" "$f" 2>/dev/null || [[ "$bname" == *.conf.enc ]]; then
                rm -f "$f" 2>/dev/null || true
                removed_files_count=$((removed_files_count + 1))
            fi
        done < <(find "$sdir" -maxdepth 3 -type f \( -name "*.conf" -o -name "*.conf.enc" -o -name "*.key" \) -print0 2>/dev/null || true)
    done

    show_progress_bar 85 "Removing WireGuard sysctl, dnsmasq, and systemd drop-in files..."
    local sys_dirs=("/etc/sysctl.d" "/etc/dnsmasq.d" "/etc/systemd/system" "/etc/cron.d" "/etc/cron.daily" "/etc/cron.hourly")
    for sysd in "${sys_dirs[@]}"; do
        [[ ! -d "$sysd" ]] && continue
        while IFS= read -r -d '' sysf; do
            if echo "$sysf" | grep -qiE "(wireguard|wg0|wg1|wg-quick|wg_split|cbwireguard|stealth)" || grep -qiE "(wireguard|wg-quick|wg0|wg_split)" "$sysf" 2>/dev/null; then
                rm -f "$sysf" 2>/dev/null || true
                removed_files_count=$((removed_files_count + 1))
            fi
        done < <(find "$sysd" -maxdepth 2 \( -type f -o -type l \) -print0 2>/dev/null || true)
    done

    show_progress_bar 95 "Purging WireGuard directories, backups, and package caches..."
    rm -rf /etc/wireguard /opt/cbwireguard "$INSTALL_DIR" /root/wireguard_backup* /home/*/easy_wireguard /var/cache/apt/archives/*wireguard* 2>/dev/null || true

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    if command -v dnsmasq &>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
        timeout 5 systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi

    init_environment
    show_progress_bar 100 "Deep removal complete! (${removed_files_count} config/system files purged)"

    echo -e "\n${GREEN}${BOLD}[✔] Deep removal finished! All WireGuard services, cached files, folders, and ports were removed.${NC}"
    echo -e "${GREEN}${BOLD}[✔] Sensitive ports (80, 443, 22, etc.) and host services remain completely untouched.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Max Speed (BBR + 64MB Buffers + Offload) & Security/Location Masking
# ------------------------------------------------------------------------------
apply_speed_and_stealth_optimizations() {
    echo -e "\n${CYAN}${BOLD}[*] Applying Max Speed (BBR + 64MB Buffers) & Security/Location Masking...${NC}"

    show_progress_bar 20 "Loading BBR congestion control and packet mangle kernel modules..."
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe iptable_nat >/dev/null 2>&1 || true
    modprobe iptable_mangle >/dev/null 2>&1 || true
    modprobe xt_mark >/dev/null 2>&1 || true
    modprobe ipt_TTL >/dev/null 2>&1 || true

    show_progress_bar 45 "Applying 64MB UDP/TCP buffers, BBR & anti-spoofing sysctl rules..."
    local sysctl_file="/etc/sysctl.d/99-wireguard-speed-stealth.conf"
    cat << 'SYSCTL_EOF' > "$sysctl_file"
# IP Forwarding & Asymmetric Split-Route Compatibility
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Maximum Download / Upload Socket Buffers (64MB) & Queue Depth
net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 2048000
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 3240000

# Low-Latency TCP & PMTU Probing
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Security & Anti-Spoofing / Anti-Fingerprinting Hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
SYSCTL_EOF

    if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> "$sysctl_file"
    fi

    sysctl --system -q >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1 || true

    show_progress_bar 70 "Tuning txqueuelen (10000) and NIC GRO/GSO/TSO hardware offload..."
    local def_nic
    def_nic=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

    ip link set dev wg0 txqueuelen 10000 2>/dev/null || true
    ip link set dev "$def_nic" txqueuelen 10000 2>/dev/null || true

    if command -v ethtool &>/dev/null; then
        ethtool -K "$def_nic" gro on gso on tso on >/dev/null 2>&1 || true
    fi

    show_progress_bar 90 "Applying TCP MSS clamping, TTL=64 masking, and DNS ECS privacy..."
    safe_ipt_del iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    safe_ipt_del iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    safe_ipt_del iptables -t mangle -D POSTROUTING -o "$def_nic" -j TTL --ttl-set 64
    iptables -t mangle -A POSTROUTING -o "$def_nic" -j TTL --ttl-set 64 2>/dev/null || true

    if command -v dnsmasq &>/dev/null && [[ -d /etc/dnsmasq.d ]]; then
        cat << 'DNS_PRIV_EOF' > /etc/dnsmasq.d/00-wg-location-stealth.conf
# Strip EDNS0 Client Subnet (ECS) so upstream DNS servers never see VPS/Client subnet location
no-edns0
bogus-priv
filterwin2k
DNS_PRIV_EOF
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            timeout 5 systemctl reload dnsmasq >/dev/null 2>&1 || timeout 5 systemctl restart dnsmasq >/dev/null 2>&1 || true
        fi
    fi

    show_progress_bar 100 "Speed, Security & Location Masking Optimizations Active!"
}

# ------------------------------------------------------------------------------
# 4. Post-Install Client Config & QR Code Display
# ------------------------------------------------------------------------------
display_post_install_configs() {
    local found_configs=()
    local search_paths=("/etc/wireguard/clients" "$INSTALL_DIR" "/root" "/etc/wireguard")
    if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
        search_paths+=("/home/${SUDO_USER}")
    fi

    for spath in "${search_paths[@]}"; do
        [[ ! -d "$spath" ]] && continue
        while IFS= read -r -d '' cfg; do
            local base
            base=$(basename "$cfg")
            [[ "$base" == "wg0.conf" || "$base" == "wg1.conf" || "$base" == "settings.conf" || "$base" == "resolv.conf" || "$base" == "sysctl.conf" ]] && continue
            if grep -q "\[Interface\]" "$cfg" 2>/dev/null && grep -q "Endpoint" "$cfg" 2>/dev/null; then
                found_configs+=("$cfg")
            fi
        done < <(find "$spath" -maxdepth 2 -type f -name "*.conf" -print0 2>/dev/null || true)
    done

    local unique_configs=()
    local seen_names="|"
    for c in "${found_configs[@]}"; do
        local bname
        bname=$(basename "$c")
        if [[ "$seen_names" != *"|${bname}|"* ]]; then
            seen_names+="${bname}|"
            unique_configs+=("$c")
        fi
    done

    if [[ ${#unique_configs[@]} -eq 0 ]]; then
        echo -e "\n${CYAN}[*] Generating initial client configuration...${NC}"
        fetch_and_run "add_client.sh"
        for spath in "${search_paths[@]}"; do
            [[ ! -d "$spath" ]] && continue
            while IFS= read -r -d '' cfg; do
                local base
                base=$(basename "$cfg")
                [[ "$base" == "wg0.conf" || "$base" == "wg1.conf" || "$base" == "settings.conf" ]] && continue
                if grep -q "\[Interface\]" "$cfg" 2>/dev/null && grep -q "Endpoint" "$cfg" 2>/dev/null; then
                    if [[ "$seen_names" != *"|${base}|"* ]]; then
                        seen_names+="${base}|"
                        unique_configs+=("$cfg")
                    fi
                fi
            done < <(find "$spath" -maxdepth 2 -type f -name "*.conf" -print0 2>/dev/null || true)
        done
    fi

    if [[ ${#unique_configs[@]} -gt 0 ]]; then
        for cfg_file in "${unique_configs[@]}"; do
            local cname
            cname=$(basename "$cfg_file")
            echo -e "\n${PURPLE}=================================================================${NC}"
            echo -e "${GREEN}${BOLD}📋 COPY & PASTE CLIENT CONFIGURATION (${cname}):${NC}"
            echo -e "${YELLOW}File Location: ${cfg_file}${NC}"
            echo -e "${PURPLE}-----------------------------------------------------------------${NC}"
            cat "$cfg_file"
            echo -e "${PURPLE}-----------------------------------------------------------------${NC}\n"

            if command -v qrencode &>/dev/null; then
                echo -e "${CYAN}${BOLD}📱 SCAN QR CODE FOR MOBILE / CLIENT (${cname}):${NC}\n"
                qrencode -t ansiutf8 < "$cfg_file" || true
                echo ""
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# 5. Pre-fetch Fresh Companion Scripts (With Progress Bar & Timeouts)
# ------------------------------------------------------------------------------
prefetch_companion_scripts() {
    local scripts=("setup_server.sh" "add_client.sh" "user_manager.sh" "backup_manager.sh" "domain_bypass.sh" "geo_vpn_filter.sh" "remove_server.sh")
    local total=${#scripts[@]}
    local count=0

    echo -e "\n${CYAN}${BOLD}[*] Fetching fresh companion scripts into ${INSTALL_DIR}...${NC}"
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    for s in "${scripts[@]}"; do
        count=$((count + 1))
        local pct=$(( (count * 100) / total ))
        show_progress_bar "$pct" "Syncing ${s} (${count}/${total})..."

        if [[ -f "./${s}" ]]; then
            cp -f "./${s}" "${INSTALL_DIR}/${s}"
            strip_clear_from_script "${INSTALL_DIR}/${s}"
            chmod 700 "${INSTALL_DIR}/${s}"
        else
            if curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/${s}" -o "${INSTALL_DIR}/${s}" 2>/dev/null; then
                strip_clear_from_script "${INSTALL_DIR}/${s}"
                chmod 700 "${INSTALL_DIR}/${s}"
            else
                if [[ "$s" == "geo_vpn_filter.sh" ]]; then
                    cat << 'EOF' > "${INSTALL_DIR}/geo_vpn_filter.sh"
#!/bin/bash
exit 0
EOF
                    chmod 700 "${INSTALL_DIR}/geo_vpn_filter.sh"
                fi
            fi
        fi
    done
}

# ------------------------------------------------------------------------------
# 6. Patch & Run Setup Server (Python 3.12 Safe Parser + Single Port Selection)
# ------------------------------------------------------------------------------
run_setup_server() {
    cleanupOldWireguard "preinstall"
    prefetch_companion_scripts

    local target_script="${INSTALL_DIR}/setup_server.sh"
    if [[ ! -f "$target_script" ]]; then
        echo -e "\n${GREEN}Fetching latest version of setup_server.sh...${NC}"
        if ! curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/setup_server.sh" -o "$target_script"; then
            echo -e "${RED}Error: Failed to pull setup_server.sh from ${GIT_REPO}.${NC}"
            return 1
        fi
    fi
    strip_clear_from_script "$target_script"
    chmod 700 "$target_script"

    local port_selector_file="${INSTALL_DIR}/.port_selector.sh"
    cat << 'PORT_EOF' > "$port_selector_file"
# Safe defaults to guarantee zero unbound variables under set -u
input_VPN_PORT="${input_VPN_PORT:-4500}"
VPN_PORT="${VPN_PORT:-4500}"
PORT="${PORT:-4500}"
SERVER_PORT="${SERVER_PORT:-4500}"
WG_PORT="${WG_PORT:-4500}"

select_safe_wg_port() {
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017)
    is_sens() {
        local p="$1"
        for sp in "${sensitive_ports[@]}"; do [[ "$p" -eq "$sp" ]] && return 0; done
        return 1
    }
    is_used() {
        local p="$1"
        if command -v ss &>/dev/null; then
            ss -uln 2>/dev/null | grep -qE "(:|\])${p}[[:space:]]" && return 0
        elif command -v netstat &>/dev/null; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${p}[[:space:]]" && return 0
        fi
        return 1
    }

    echo -e "\n\033[0;36m\033[1mSelect WireGuard UDP Port:\033[0m"
    echo -e "   1) \033[0;32m4500\033[0m  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling) \033[0;35m[RECOMMENDED]\033[0m"
    echo -e "   2) \033[0;32m3478\033[0m  (STUN / WebRTC Media UDP | VoIP Bypass)"
    echo -e "   3) \033[0;32m500\033[0m   (IKEv2 / IPsec Signaling UDP)"
    echo -e "   4) \033[0;32m853\033[0m   (DNS-over-QUIC UDP)"
    echo -e "   5) \033[0;32m51820\033[0m (Official WireGuard Standard Port)"
    echo -e "   6) \033[0;32m41194\033[0m (Disguised High Tunnel UDP)"
    echo -e "   7) Random High-Entropy Stealth Port (49152-65535)"
    echo -e "   8) Custom Port (Or type any port directly, e.g. 8008)"

    while true; do
        read -rp "Select Port option [1-8, or type port directly, default 1 (4500)]: " PORT_OPT
        PORT_OPT=${PORT_OPT:-1}

        if [[ "$PORT_OPT" =~ ^[0-9]+$ ]] && [[ "$PORT_OPT" -ge 1024 && "$PORT_OPT" -le 65535 ]]; then
            if is_sens "$PORT_OPT"; then
                echo -e "\033[0;31m[!] Port ${PORT_OPT} is a sensitive service port (80/443/22/etc.). Please choose a safe port.\033[0m"
                continue
            fi
            if is_used "$PORT_OPT"; then
                echo -e "\033[1;33m[!] Warning: Port ${PORT_OPT}/udp is currently in use on this host. Choose another.\033[0m"
                continue
            fi
            SELECTED_WG_PORT="$PORT_OPT"
            break
        fi

        case "$PORT_OPT" in
            1) SELECTED_WG_PORT=4500 ; break ;;
            2) SELECTED_WG_PORT=3478 ; break ;;
            3) SELECTED_WG_PORT=500 ; break ;;
            4) SELECTED_WG_PORT=853 ; break ;;
            5) SELECTED_WG_PORT=51820 ; break ;;
            6) SELECTED_WG_PORT=41194 ; break ;;
            7)
                SELECTED_WG_PORT=$(( (RANDOM % 16383) + 49152 ))
                echo -e "\033[0;32m[✔] Generated Random Stealth High Port: ${SELECTED_WG_PORT}/udp\033[0m"
                break
                ;;
            8)
                while true; do
                    read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "8008" CUSTOM_P
                    if ! [[ "$CUSTOM_P" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_P" -lt 1024 || "$CUSTOM_P" -gt 65535 ]]; then
                        echo -e "\033[0;31m[!] Invalid port. Enter a port between 1024 and 65535.\033[0m"
                        continue
                    fi
                    if is_sens "$CUSTOM_P"; then
                        echo -e "\033[0;31m[!] Port ${CUSTOM_P} conflicts with sensitive services (80/443/22/etc.). Choose another.\033[0m"
                        continue
                    fi
                    if is_used "$CUSTOM_P"; then
                        echo -e "\033[1;33m[!] Warning: Port ${CUSTOM_P}/udp is currently in use. Choose another.\033[0m"
                        continue
                    fi
                    SELECTED_WG_PORT="$CUSTOM_P"
                    break
                done
                break
                ;;
            *)
                echo -e "\033[0;31m[!] Invalid option. Enter 1-8 or a port number (1024-65535).\033[0m"
                ;;
        esac
    done
    echo -e "\033[0;32m[✔] WireGuard Port Confirmed: ${SELECTED_WG_PORT}/udp\033[0m\n"
    input_VPN_PORT="$SELECTED_WG_PORT"
    VPN_PORT="$SELECTED_WG_PORT"
    PORT="$SELECTED_WG_PORT"
    SERVER_PORT="$SELECTED_WG_PORT"
    WG_PORT="$SELECTED_WG_PORT"
}
PORT_EOF

    if command -v python3 &>/dev/null; then
        python3 - "$target_script" "$port_selector_file" << 'PY_EOF'
import sys, re

script_path = sys.argv[1]
selector_path = sys.argv[2]

with open(script_path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

with open(selector_path, 'r', encoding='utf-8', errors='replace') as f:
    selector_code = f.read()

content = re.sub(
    r'(?m)^[ \t]*(clear|tput[ \t]+reset)[ \t]*$',
    lambda _: ': # clear disabled',
    content
)

content = re.sub(
    r'PostUp\s*=\s*(/root/easy_wireguard/geo_vpn_filter\.sh\s+--apply)(?!\s*\|\|)',
    lambda m: f'PostUp = test -x /root/easy_wireguard/geo_vpn_filter.sh && {m.group(1)} || true',
    content
)

if 'select_safe_wg_port()' not in content:
    lines = content.splitlines()
    out_lines = []
    injected_header = False
    replaced_port_prompt = False
    in_port_case = False

    read_port_idx = -1
    for idx, line in enumerate(lines):
        if re.search(r'^\s*read\b.*\b(input_VPN_PORT|VPN_PORT|PORT|SERVER_PORT)\b', line):
            read_port_idx = idx
            break

    for idx, line in enumerate(lines):
        if not injected_header:
            out_lines.append(line)
            if re.match(r'^\s*set\s+-euo\s+pipefail', line) or (idx == 0 and line.startswith('#!') and 'set -euo pipefail' not in content):
                out_lines.append('')
                out_lines.extend(selector_code.splitlines())
                out_lines.append('')
                injected_header = True
            continue

        if read_port_idx != -1 and (read_port_idx - 18) <= idx < read_port_idx:
            if re.search(r'(^\s*echo\b.*(\[[1-9]\]|port|Port|Select option)|^\s*printf\b.*port)', line):
                out_lines.append('# ' + line + ' # replaced by select_safe_wg_port')
                continue

        if idx == read_port_idx:
            out_lines.append('select_safe_wg_port')
            replaced_port_prompt = True
            continue

        if replaced_port_prompt and not in_port_case and read_port_idx < idx <= read_port_idx + 6:
            if re.search(r'^\s*case\s+["\']?\$\{?(input_VPN_PORT|VPN_PORT|PORT)\}?["\']?\s+in', line):
                in_port_case = True
                out_lines.append('# ' + line)
                continue

        if in_port_case:
            out_lines.append('# ' + line)
            if re.match(r'^\s*esac\b', line):
                in_port_case = False
                out_lines.append('VPN_PORT="$SELECTED_WG_PORT"')
                out_lines.append('input_VPN_PORT="$SELECTED_WG_PORT"')
            continue

        out_lines.append(line)

    final_text = '\n'.join(out_lines) + '\n'
    if not replaced_port_prompt:
        dep_match = re.search(r'(Installing WireGuard and required dependencies[\s\S]*?(?:apt-get|apt|yum|dnf|pacman|apk)\s+install[^\n]+\n(?:\s*fi\n)?)', final_text)
        if dep_match:
            pos = dep_match.end()
            final_text = final_text[:pos] + '\nselect_safe_wg_port\n' + final_text[pos:]

    content = final_text

with open(script_path, 'w', encoding='utf-8') as f:
    f.write(content)
PY_EOF
    fi

    rm -f "$port_selector_file"
    "$target_script"

    apply_speed_and_stealth_optimizations
    display_post_install_configs
}

# ------------------------------------------------------------------------------
# 7. Verified Domain-Based Split Tunneling Engine (With Live Progress Bar)
# ------------------------------------------------------------------------------
recalculate_and_apply_split_tunnel() {
    echo -e "\n${CYAN}${BOLD}[*] Updating Domain-Based Split Tunneling Routes...${NC}"

    show_progress_bar 15 "Checking DNS & IPSet routing utilities..."
    for tool_pkg in "dig:dnsutils" "ipset:ipset" "python3:python3" "qrencode:qrencode"; do
        local bin="${tool_pkg%%:*}"
        local pkg="${tool_pkg##*:}"
        if ! command -v "$bin" &>/dev/null && command -v apt-get &>/dev/null; then
            apt-get update -o Acquire::Languages=none -qq >/dev/null 2>&1 || true
            apt-get install -y -qq "$pkg" >/dev/null 2>&1 || true
        fi
    done

    local mode
    mode=$(cat "$SPLIT_MODE_FILE" 2>/dev/null || echo "BYPASS")

    show_progress_bar 45 "Resolving domain A records across multiple DNS resolvers..."

    python3 - "$BYPASS_DOMAINS_FILE" "$SETTINGS_FILE" "$mode" "$INSTALL_DIR" << 'PY_SPLIT_EOF'
import sys, os, re, socket, subprocess, ipaddress

domains_file = sys.argv[1]
settings_file = sys.argv[2]
mode = sys.argv[3].strip().upper()
install_dir = sys.argv[4]

raw_domains = []
if os.path.isfile(domains_file):
    with open(domains_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            d = line.strip().lower()
            if d and not d.startswith('#'):
                d = re.sub(r'^https?://', '', d).split('/')[0].strip()
                if d and d not in raw_domains:
                    raw_domains.append(d)

dns_ips = set()
if os.path.isfile(settings_file):
    with open(settings_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('DEFAULT_DNS='):
                val = line.split('=', 1)[1].strip().strip('"\'')
                for part in val.split(','):
                    ip_str = part.strip()
                    try:
                        ip_obj = ipaddress.ip_address(ip_str)
                        if ip_obj.version == 4:
                            dns_ips.add(ip_obj)
                    except ValueError:
                        pass

expanded_domains = set()
for d in raw_domains:
    expanded_domains.add(d)
    if not d.startswith('www.'):
        expanded_domains.add('www.' + d)
    if 'netflix.com' in d:
        expanded_domains.update(['nflxext.com', 'nflxso.net', 'nflxvideo.net', 'nflximg.net'])
    elif 'amazon.com' in d:
        expanded_domains.update(['completion.amazon.com', 'images-amazon.com', 'media-amazon.com', 'ssl-images-amazon.com'])
    elif 'paypal.com' in d:
        expanded_domains.update(['paypalobjects.com', 'www.paypalobjects.com', 'api-m.paypal.com', 'checkout.paypal.com'])
    elif 'openai.com' in d or 'chatgpt.com' in d:
        expanded_domains.update(['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com'])
    elif 'linkedin.com' in d:
        expanded_domains.update(['www.linkedin.com', 'licdn.com', 'media.licdn.com', 'static.licdn.com'])

resolved_v4 = set()
for dom in sorted(expanded_domains):
    try:
        for res in socket.getaddrinfo(dom, None, socket.AF_INET):
            ip_str = res[4][0]
            resolved_v4.add(ipaddress.IPv4Address(ip_str))
    except Exception:
        pass

    for resolver in ['1.1.1.1', '8.8.8.8']:
        try:
            out = subprocess.check_output(
                ['dig', '+time=2', '+tries=1', '+short', f'@{resolver}', dom, 'A'],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3
            )
            for token in out.splitlines():
                token = token.strip()
                try:
                    resolved_v4.add(ipaddress.IPv4Address(token))
                except ValueError:
                    pass
        except Exception:
            pass

try:
    subprocess.run(['ipset', 'create', 'wg_split_v4', 'hash:net', 'family', 'inet'], stderr=subprocess.DEVNULL, timeout=3)
    subprocess.run(['ipset', 'flush', 'wg_split_v4'], stderr=subprocess.DEVNULL, timeout=3)
    for ip_obj in resolved_v4:
        subprocess.run(['ipset', 'add', 'wg_split_v4', f'{ip_obj}/24'], stderr=subprocess.DEVNULL, timeout=2)
except Exception:
    pass

if not raw_domains or not resolved_v4:
    final_allowed_ips = "0.0.0.0/1, 128.0.0.0/1"
    subnet_count = 0
else:
    raw_nets = []
    for ip_obj in resolved_v4:
        net24 = ipaddress.IPv4Network(f"{ip_obj}/24", strict=False)
        if any(d_ip in net24 for d_ip in dns_ips):
            if ip_obj not in dns_ips:
                raw_nets.append(ipaddress.IPv4Network(f"{ip_obj}/32", strict=False))
        else:
            raw_nets.append(net24)

    target_nets = list(ipaddress.collapse_addresses(raw_nets))
    subnet_count = len(target_nets)

    if mode == "ONLY_VPN":
        include_nets = list(target_nets) + [ipaddress.IPv4Network(f"{d_ip}/32") for d_ip in dns_ips]
        collapsed_inc = list(ipaddress.collapse_addresses(include_nets))
        final_allowed_ips = ", ".join(str(n) for n in collapsed_inc)
    else:
        allowed_pool = [ipaddress.IPv4Network("0.0.0.0/1"), ipaddress.IPv4Network("128.0.0.0/1")]
        for excl in target_nets:
            next_pool = []
            for net in allowed_pool:
                if net.overlaps(excl):
                    if excl.subnet_of(net):
                        next_pool.extend(net.address_exclude(excl))
                else:
                    next_pool.append(net)
            allowed_pool = next_pool
        collapsed_pool = list(ipaddress.collapse_addresses(allowed_pool))
        final_allowed_ips = ", ".join(str(n) for n in collapsed_pool)

settings_lines = []
found_key = False
if os.path.isfile(settings_file):
    with open(settings_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('DEFAULT_ALLOWED_IPS='):
                settings_lines.append(f'DEFAULT_ALLOWED_IPS="{final_allowed_ips}"\n')
                found_key = True
            else:
                settings_lines.append(line)
if not found_key:
    settings_lines.append(f'DEFAULT_ALLOWED_IPS="{final_allowed_ips}"\n')

with open(settings_file, 'w', encoding='utf-8') as f:
    f.writelines(settings_lines)

search_dirs = ['/etc/wireguard/clients', install_dir, '/root', '/etc/wireguard']
updated_files = []
seen_realpaths = set()

for sdir in search_dirs:
    if not os.path.isdir(sdir):
        continue
    for fname in os.listdir(sdir):
        if not fname.endswith('.conf') or fname in ('wg0.conf', 'wg1.conf', 'settings.conf', 'resolv.conf', 'sysctl.conf'):
            continue
        fpath = os.path.join(sdir, fname)
        if not os.path.isfile(fpath):
            continue
        rpath = os.path.realpath(fpath)
        if rpath in seen_realpaths:
            continue
        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                c_text = f.read()
            if '[Interface]' in c_text and '[Peer]' in c_text and 'Endpoint' in c_text:
                new_text = re.sub(
                    r'(?m)^(\s*AllowedIPs\s*=\s*).*$',
                    lambda m: m.group(1) + final_allowed_ips,
                    c_text
                )
                with open(fpath, 'w', encoding='utf-8') as f:
                    f.write(new_text)
                seen_realpaths.add(rpath)
                updated_files.append(fpath)
        except Exception:
            pass

with open('/tmp/.wg_split_summary', 'w', encoding='utf-8') as sf:
    sf.write(f"  \033[0;32m├─ Split Mode:\033[0m        {mode} ({len(raw_domains)} base domain(s) -> {subnet_count} CIDR block(s))\n")
    sf.write(f"  \033[0;32m└─ Client Configs:\033[0m    Updated {len(updated_files)} client .conf file(s) & {settings_file}\n")
PY_SPLIT_EOF

    show_progress_bar 100 "Split-tunnel CIDR calculation & client config update complete!"
    if [[ -f /tmp/.wg_split_summary ]]; then
        cat /tmp/.wg_split_summary
        rm -f /tmp/.wg_split_summary
    fi

    if [[ -f "$SETTINGS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$SETTINGS_FILE"
    fi
}

domain_split_tunnel_menu() {
    while true; do
        [[ ! -f "$BYPASS_DOMAINS_FILE" ]] && touch "$BYPASS_DOMAINS_FILE"
        [[ ! -f "$SPLIT_MODE_FILE" ]] && echo "BYPASS" > "$SPLIT_MODE_FILE"

        local mode
        mode=$(cat "$SPLIT_MODE_FILE" 2>/dev/null || echo "BYPASS")
        local dom_count
        dom_count=$(awk '!/^(#|[[:space:]]*$)/ {c++} END {print c+0}' "$BYPASS_DOMAINS_FILE" 2>/dev/null || echo 0)

        echo -e "\n${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│             ${GREEN}${BOLD}🌐 Domain-Based Split Tunneling Manager${NC}          ${PURPLE}│${NC}"
        echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│${NC} ${BOLD}Active Mode:${NC}    ${CYAN}${mode}${NC} (Updates Client AllowedIPs & IPSet)   ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} ${BOLD}Active Domains:${NC} ${YELLOW}${dom_count} domain(s) configured${NC}                    ${PURPLE}│${NC}"
        echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│${NC} [1] Add Domain(s) (e.g. netflix.com, amazon.com, paypal.com) ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [2] Remove a Domain                                          ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [3] Add Preset Category (Streaming, Banking, AI, Gaming)     ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [4] Toggle Mode (BYPASS VPN vs ROUTE ONLY LISTED VIA VPN)    ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [5] View Active Split Domains & Print Updated Client Config  ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [6] Clear All Split Domains (Reset to Full Tunnel)           ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [b] Back to Main Menu                                        ${PURPLE}│${NC}"
        echo -e "${PURPLE}└──────────────────────────────────────────────────────────────┘${NC}"
        echo -en "${GREEN}Select option: ${NC}"
        read -r SPLIT_OPT

        case "$SPLIT_OPT" in
            1)
                echo -en "${GREEN}Enter domain(s) to split-tunnel (comma or space separated): ${NC}"
                read -r INPUT_DOMS
                local added=0
                for raw_d in ${INPUT_DOMS//,/ }; do
                    local clean_d
                    clean_d=$(echo "$raw_d" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r\n')
                    if [[ -n "$clean_d" && "$clean_d" == *.* ]]; then
                        if ! grep -q -i "^${clean_d}$" "$BYPASS_DOMAINS_FILE" 2>/dev/null; then
                            echo "$clean_d" >> "$BYPASS_DOMAINS_FILE"
                            echo -e "${GREEN}[✔] Added: ${clean_d}${NC}"
                            added=$((added + 1))
                        else
                            echo -e "${YELLOW}[!] ${clean_d} is already in the list.${NC}"
                        fi
                    fi
                done
                if [[ $added -gt 0 ]]; then
                    recalculate_and_apply_split_tunnel
                    echo -en "\n${CYAN}Display updated client .conf and QR code now? [Y/n]: ${NC}"
                    read -r SHOW_CFG
                    if [[ "${SHOW_CFG:-y}" =~ ^[Yy]$ ]]; then
                        display_post_install_configs
                    fi
                fi
                ;;
            2)
                if [[ "$dom_count" -eq 0 ]]; then
                    echo -e "${YELLOW}No domains currently configured.${NC}"
                else
                    echo -e "\n${CYAN}Configured Domains:${NC}"
                    awk '!/^(#|[[:space:]]*$)/ {printf "  %2d) %s\n", ++i, $0}' "$BYPASS_DOMAINS_FILE"
                    echo -en "${GREEN}Enter number to remove [1-${dom_count}]: ${NC}"
                    read -r DEL_IDX
                    if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [[ "$DEL_IDX" -ge 1 && "$DEL_IDX" -le "$dom_count" ]]; then
                        local target_d
                        target_d=$(awk '!/^(#|[[:space:]]*$)/ {if (++i == idx) print $0}' idx="$DEL_IDX" "$BYPASS_DOMAINS_FILE")
                        grep -v -F -x "$target_d" "$BYPASS_DOMAINS_FILE" > "${BYPASS_DOMAINS_FILE}.tmp" || true
                        mv "${BYPASS_DOMAINS_FILE}.tmp" "$BYPASS_DOMAINS_FILE"
                        echo -e "${GREEN}[✔] Removed '${target_d}'.${NC}"
                        recalculate_and_apply_split_tunnel
                    else
                        echo -e "${RED}Invalid selection.${NC}"
                    fi
                fi
                ;;
            3)
                echo -e "\n${CYAN}Select Preset Category:${NC}"
                echo "  1) Streaming (Netflix, Hulu, Disney+, Prime Video, Max, Spotify)"
                echo "  2) Banking & Payments (PayPal, Stripe, Chase, Bank of America, Wells Fargo)"
                echo "  3) AI Services (ChatGPT, OpenAI, Claude, Gemini, Perplexity)"
                echo "  4) Gaming & Social (Discord, Twitch, Steam, Epic Games, LinkedIn)"
                echo -en "${GREEN}Select preset [1-4]: ${NC}"
                read -r PRESET_CHOICE
                local preset_list=()
                case "$PRESET_CHOICE" in
                    1) preset_list=("netflix.com" "hulu.com" "disneyplus.com" "primevideo.com" "amazon.com" "max.com" "spotify.com") ;;
                    2) preset_list=("paypal.com" "stripe.com" "chase.com" "bankofamerica.com" "wellsfargo.com" "cardinalcommerce.com") ;;
                    3) preset_list=("openai.com" "chatgpt.com" "claude.ai" "anthropic.com" "gemini.google.com" "perplexity.ai") ;;
                    4) preset_list=("discord.com" "twitch.tv" "steampowered.com" "epicgames.com" "linkedin.com") ;;
                    *) echo -e "${RED}Invalid preset.${NC}" ;;
                esac
                if [[ ${#preset_list[@]} -gt 0 ]]; then
                    for pd in "${preset_list[@]}"; do
                        grep -q -i "^${pd}$" "$BYPASS_DOMAINS_FILE" 2>/dev/null || echo "$pd" >> "$BYPASS_DOMAINS_FILE"
                    done
                    recalculate_and_apply_split_tunnel
                    echo -en "\n${CYAN}Display updated client .conf and QR code now? [Y/n]: ${NC}"
                    read -r SHOW_CFG
                    if [[ "${SHOW_CFG:-y}" =~ ^[Yy]$ ]]; then
                        display_post_install_configs
                    fi
                fi
                ;;
            4)
                if [[ "$mode" == "BYPASS" ]]; then
                    echo "ONLY_VPN" > "$SPLIT_MODE_FILE"
                    echo -e "${GREEN}[✔] Switched to ONLY_VPN Mode (Only listed domains route through WireGuard; all other traffic uses local ISP).${NC}"
                else
                    echo "BYPASS" > "$SPLIT_MODE_FILE"
                    echo -e "${GREEN}[✔] Switched to BYPASS Mode (Listed domains bypass WireGuard via local ISP; all other traffic uses VPN).${NC}"
                fi
                recalculate_and_apply_split_tunnel
                ;;
            5)
                echo -e "\n${CYAN}--- Active Split Domains (${mode} Mode) ---${NC}"
                if [[ "$dom_count" -eq 0 ]]; then
                    echo -e "${YELLOW}No domains configured (Full Tunnel: 0.0.0.0/1, 128.0.0.0/1).${NC}"
                else
                    awk '!/^(#|[[:space:]]*$)/ {printf "  %2d) %s\n", ++i, $0}' "$BYPASS_DOMAINS_FILE"
                fi
                display_post_install_configs
                ;;
            6)
                > "$BYPASS_DOMAINS_FILE"
                echo "BYPASS" > "$SPLIT_MODE_FILE"
                recalculate_and_apply_split_tunnel
                echo -e "${GREEN}[✔] All split domains cleared. Restored standard Full Tunnel (0.0.0.0/1, 128.0.0.0/1).${NC}"
                ;;
            b|B)
                break
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 8. Modular Sub-script Fetcher & Settings Management
# ------------------------------------------------------------------------------
fetch_and_run() {
    local script_name="$1"
    local script_path="./${script_name}"

    if [[ -f "$script_path" ]]; then
        echo -e "\n${GREEN}Running local version of ${script_name}...${NC}"
        strip_clear_from_script "$script_path"
        chmod +x "$script_path"
        cp -f "$script_path" "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
        chmod 700 "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
        "$script_path"
    else
        script_path="${INSTALL_DIR}/${script_name}"
        echo -e "\n${GREEN}Fetching latest version of ${script_name}...${NC}"

        if curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/${script_name}" -o "$script_path"; then
            strip_clear_from_script "$script_path"
            chmod 700 "$script_path"
            "$script_path"
        else
            echo -e "${RED}Error: Failed to pull ${script_name} from ${GIT_REPO}.${NC}"
            return 1
        fi
    fi
}

update_setting() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SETTINGS_FILE"
    else
        echo "${key}=${value}" >> "$SETTINGS_FILE"
    fi
}

settings_menu() {
    while true; do
        echo ""
        print_banner
        local display_ips="${DEFAULT_ALLOWED_IPS:-0.0.0.0/1, 128.0.0.0/1}"
        if [[ ${#display_ips} -gt 25 ]]; then
            display_ips="${display_ips:0:22}..."
        fi
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│                      Settings                      │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        printf "${PURPLE}│ ${GREEN}[1] Default MTU: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_MTU:-1420}"
        printf "${PURPLE}│ ${GREEN}[2] Default DNS: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}"
        printf "${PURPLE}│ ${GREEN}[3] Default Allowed IPs: ${NC}%-25s ${PURPLE}│${NC}\n" "$display_ips"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
        echo -en "${PURPLE}Select option: ${NC}"
        read -r SET_OPT

        case "$SET_OPT" in
            1)
                echo -en "${GREEN}Enter new Default MTU: ${NC}"
                read -r NEW_MTU
                update_setting "DEFAULT_MTU" "$NEW_MTU"
                DEFAULT_MTU="$NEW_MTU"
                ;;
            2)
                echo -en "${GREEN}Enter new Default DNS (comma separated): ${NC}"
                read -r NEW_DNS
                update_setting "DEFAULT_DNS" "\"$NEW_DNS\""
                DEFAULT_DNS="$NEW_DNS"
                ;;
            3)
                echo -en "${GREEN}Enter new Default Allowed IPs: ${NC}"
                read -r NEW_IPS
                update_setting "DEFAULT_ALLOWED_IPS" "\"$NEW_IPS\""
                DEFAULT_ALLOWED_IPS="$NEW_IPS"
                ;;
            b|B) break ;;
        esac
    done
}

print_banner() {
    echo -e "\n${PURPLE}======================================================${NC}"
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
    echo -e "${PURPLE}│ ${NC}[7] Geo-IP & Anti-VPN Shield (US/CA Only)         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[s] Settings (MTU, DNS, AllowedIPs)               ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[r] Remove WireGuard server from this system      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[q] Exit                                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

main() {
    while true; do
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r OPTION

        case "$OPTION" in
            1)
                run_setup_server
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            2)
                fetch_and_run "add_client.sh"
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            3) fetch_and_run "user_manager.sh" ;;
            4) fetch_and_run "backup_manager.sh" ;;
            5) domain_split_tunnel_menu ;;
            6) 
                echo -e "\n${GREEN}Starting Real-Time Logging for WireGuard errors (last 12 hours)...${NC}"
                echo -e "${PURPLE}Press Ctrl+C to stop logging and return to menu.${NC}\n"
                journalctl -u wg-quick@wg0.service --since "12 hours ago" -p err -f || true
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            7) fetch_and_run "geo_vpn_filter.sh" ;;
            s|S) settings_menu ;;
            r|R)
                deep_remove_wireguard
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            q|Q)
                echo -e "${PURPLE}Exit: Goodbye!${NC}"
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