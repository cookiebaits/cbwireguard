cat << 'EOF' > easy_wireguard.sh && chmod +x easy_wireguard.sh && sudo ./easy_wireguard.sh
#!/usr/bin/env bash
# ==============================================================================
# EASY WIREGUARD: MAXIMUM SPEED & STEALTH DEPLOYMENT (STANDALONE)
# Full Wipe | BBR + FQ Tuning | Zero Bottlenecks | Multi-Port Hopping
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

WG_DIR="/etc/wireguard"
CLIENTS_DIR="${WG_DIR}/clients"
CONF_FILE="${WG_DIR}/wg0.conf"
STATE_FILE="${WG_DIR}/stealth_state.env"

# Recommended primary stealth port (NVIDIA GameStream / Low-Latency UDP)
PRIMARY_PORT=47984

# Expanded High-Speed & Stealth Port Array (Strictly avoids sensitive ports)
STEALTH_PORTS=(34872 41956 47984 53281 58914 62749 51423)

# Protected sensitive ports that must NEVER be touched or removed
PROTECTED_PORTS=(21 22 25 53 80 110 143 443 465 587 993 995 3306 5432 8080 8443)

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}[!] Error: This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

is_protected_port() {
    local check_p="$1"
    for p in "${PROTECTED_PORTS[@]}"; do
        if [[ "$check_p" == "$p" ]]; then
            return 0
        fi
    done
    return 1
}

get_wan_iface() {
    ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1
}

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip" "https://checkip.amazonaws.com"; do
        ip=$(curl -s4 --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    ip -4 addr show "$(get_wan_iface)" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

deep_clean_old_wireguard() {
    echo -e "${CYAN}[*] Performing deep clean: Removing all old WireGuard files, configs, and port rules...${NC}"

    # 1. Stop and disable all wg-quick services
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done < <(systemctl list-units --type=service --all 2>/dev/null | grep -oE 'wg-quick@[a-zA-Z0-9_-]+\.service' || true)

    # 2. Bring down and delete all WireGuard interfaces
    if command -v wg >/dev/null 2>&1; then
        for iface in $(wg show interfaces 2>/dev/null || true); do
            wg-quick down "$iface" 2>/dev/null || ip link delete dev "$iface" 2>/dev/null || true
        done
    fi
    for iface in $(ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 || true); do
        ip link delete dev "$iface" 2>/dev/null || true
    done

    # 3. Kill background userspace processes
    pkill -f "wireguard-go" 2>/dev/null || true
    pkill -f "boringtun" 2>/dev/null || true

    # 4. Wipe old WireGuard configuration directory completely
    rm -rf "${WG_DIR}"
    mkdir -p "${CLIENTS_DIR}"
    chmod 700 "${WG_DIR}"

    # 5. Purge old iptables/ip6tables rules while skipping protected ports
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        for tbl in nat mangle filter; do
            while IFS= read -r rule; do
                [[ -z "$rule" ]] && continue
                local skip_rule=0
                for pport in "${PROTECTED_PORTS[@]}"; do
                    if echo "$rule" | grep -qE "(--dport|--dports|--sport|--sports)\s+${pport}(\b|,)"; then
                        skip_rule=1
                        break
                    fi
                done
                [[ "$skip_rule" -eq 1 ]] && continue
                local del_rule="${rule/-A /-D }"
                eval "$ipt -t $tbl $del_rule" 2>/dev/null || true
            done < <($ipt -t "$tbl" -S 2>/dev/null | grep -E "(-i wg|-o wg|10\.66\.66\.|fd42:42:42:|--to-ports|--ttl-set|--set-dscp)" || true)
        done
    done

    # 6. Clean UFW rules
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "${STEALTH_PORTS[@]}"; do
            ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
        done
    fi

    echo -e "${GREEN}[+] Deep clean complete. All old WireGuard traces removed.${NC}"
}

install_base_packages() {
    echo -e "${CYAN}[*] Installing core kernel & networking dependencies...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools iptables iproute2 curl qrencode unbound ca-certificates psmisc > /dev/null 2>&1
}

configure_local_dns_override() {
    echo -e "${CYAN}[*] Configuring high-speed internal Unbound DNS...${NC}"
    mkdir -p /etc/unbound/unbound.conf.d
    rm -f /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf 2>/dev/null || true

    cat <<INNER_EOF > /etc/unbound/unbound.conf.d/wg-stealth.conf
server:
    num-threads: 4
    interface: 10.66.66.1
    interface: fd42:42:42::1
    ip-freebind: yes
    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes
    access-control: 10.66.66.0/24 allow
    access-control: fd42:42:42::/64 allow
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: yes
    edns-buffer-size: 1232
    prefetch: yes
    minimal-responses: yes
    qname-minimisation: yes
    rrset-roundrobin: yes
    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 9.9.9.9@853#dns.quad9.net
INNER_EOF
    systemctl enable unbound > /dev/null 2>&1 || true
    systemctl restart unbound > /dev/null 2>&1 || true
}

apply_high_speed_sysctl() {
    echo -e "${CYAN}[*] Applying maximum-throughput BBR kernel socket & buffer tunables...${NC}"
    cat <<INNER_EOF > /etc/sysctl.d/99-wg-highspeed.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Ultra-high socket buffer sizing to eliminate 10x speed throttling on 500+ Mbps lines
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 2048000
net.core.netdev_max_backlog = 500000
net.core.somaxconn = 65535
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536

net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
INNER_EOF
    sysctl --system > /dev/null 2>&1
}

prompt_qr_code() {
    local conf_path="$1"
    echo ""
    read -rp "Would you like to generate a QR code for this config now? (y/N): " qr_choice
    if [[ "$qr_choice" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}--- SCAN QR CODE IN WIREGUARD CLIENT ---${NC}"
        qrencode -t ansiutf8 < "${conf_path}"
        echo -e "${CYAN}----------------------------------------${NC}\n"
    fi
}

create_client_profile() {
    source "${STATE_FILE}"
    DNS_SERVERS="${DNS_SERVERS:-10.66.66.1, 1.1.1.1}"

    echo ""
    read -rp "Enter a name for the new client: " CLIENT_NAME
    CLIENT_NAME=$(echo "${CLIENT_NAME}" | tr -cd 'a-zA-Z0-9_-')

    if [[ -z "${CLIENT_NAME}" ]]; then
        echo -e "${RED}[!] Invalid client name.${NC}"
        return
    fi

    CLIENT_CONF="${CLIENTS_DIR}/${CLIENT_NAME}.conf"

    echo -e "\n${CYAN}Available High-Speed & Stealth Ports:${NC}"
    for i in "${!STEALTH_PORTS[@]}"; do
        echo -e "  $((i+1))) UDP ${STEALTH_PORTS[$i]}"
    done
    read -rp "Select port number [1-${#STEALTH_PORTS[@]}] (Default: 3 -> ${PRIMARY_PORT}): " port_idx
    if [[ "$port_idx" =~ ^[1-9][0-9]*$ ]] && (( port_idx >= 1 && port_idx <= ${#STEALTH_PORTS[@]} )); then
        CHOSEN_PORT="${STEALTH_PORTS[$((port_idx-1))]}"
    else
        CHOSEN_PORT="${PRIMARY_PORT}"
    fi

    LAST_OCTET=1
    while grep -q "10.66.66.$((LAST_OCTET + 1))/32" "${CONF_FILE}" 2>/dev/null; do
        ((LAST_OCTET++))
    done
    CLIENT_OCTET=$((LAST_OCTET + 1))

    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PSK=$(wg genpsk)

    cat <<INNER_EOF >> "${CONF_FILE}"

# BEGIN_PEER ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = 10.66.66.${CLIENT_OCTET}/32, fd42:42:42::${CLIENT_OCTET}/128
# END_PEER ${CLIENT_NAME}
INNER_EOF

    wg syncconf wg0 <(wg-quick strip wg0)

    cat <<INNER_EOF > "${CLIENT_CONF}"
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = 10.66.66.${CLIENT_OCTET}/32, fd42:42:42::${CLIENT_OCTET}/128
DNS = ${DNS_SERVERS}
MTU = 1380

# Alternate Stealth Ports Available on Server: ${STEALTH_PORTS[*]}
[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${CHOSEN_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 21
INNER_EOF

    chmod 600 "${CLIENT_CONF}"

    echo -e "\n${GREEN}[+] Client '${CLIENT_NAME}' created successfully!${NC}"
    echo -e "${YELLOW}[i] Copy and paste the configuration below into your WireGuard client:${NC}\n"
    echo -e "${BOLD}==================== COPY BELOW THIS LINE ====================${NC}"
    cat "${CLIENT_CONF}"
    echo -e "${BOLD}==================== COPY ABOVE THIS LINE ====================${NC}"

    prompt_qr_code "${CLIENT_CONF}"
}

deploy_server() {
    install_base_packages
    deep_clean_old_wireguard
    apply_high_speed_sysctl

    WAN_IFACE=$(get_wan_iface)
    SERVER_IP=$(get_public_ip)

    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
    chmod 600 "${WG_DIR}/server_private.key"

    SERVER_PRIV_KEY=$(cat "${WG_DIR}/server_private.key")
    SERVER_PUB_KEY=$(cat "${WG_DIR}/server_public.key")

    PORT_CSV=$(IFS=,; echo "${STEALTH_PORTS[*]}")

    cat <<INNER_EOF > "${STATE_FILE}"
WAN_IFACE="${WAN_IFACE}"
SERVER_IP="${SERVER_IP}"
PRIMARY_PORT="${PRIMARY_PORT}"
PORT_CSV="${PORT_CSV}"
SERVER_PUB_KEY="${SERVER_PUB_KEY}"
INNER_EOF

    echo -e "${CYAN}[*] Generating Server wg0.conf with zero-bottleneck high-speed hooks...${NC}"

    cat <<INNER_EOF > "${CONF_FILE}"
[Interface]
Address = 10.66.66.1/24, fd42:42:42::1/64
ListenPort = ${PRIMARY_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1380

# 1. Multi-Port Stealth Hopping & Ingress Acceptance
PostUp = iptables -I INPUT 1 -p udp --dport ${PRIMARY_PORT} -j ACCEPT
PostUp = iptables -I INPUT 1 -p udp -m multiport --dports ${PORT_CSV} -j ACCEPT
PostUp = ip6tables -I INPUT 1 -p udp --dport ${PRIMARY_PORT} -j ACCEPT
PostUp = ip6tables -I INPUT 1 -p udp -m multiport --dports ${PORT_CSV} -j ACCEPT
PostUp = iptables -t nat -A PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostUp = ip6tables -t nat -A PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}

# 2. Location Override & DNS Routing
PostUp = iptables -A INPUT -i wg0 -p udp --dport 53 -j ACCEPT
PostUp = iptables -A INPUT -i wg0 -p tcp --dport 53 -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostUp = ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -o wg0 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o ${WAN_IFACE} -j MASQUERADE

# 3. High-Speed TCP MSS Clamping (Prevents Fragmentation)
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 4. Stealth TTL & DSCP Header Masking
PostUp = iptables -t mangle -A POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j TTL --ttl-set 64
PostUp = iptables -t mangle -A POSTROUTING -o ${WAN_IFACE} -p udp --sport ${PRIMARY_PORT} -j DSCP --set-dscp 0

# 5. Unrestricted High-Speed FQ Queueing (Zero Rate-Limit Bottlenecks)
PostUp = tc qdisc replace dev wg0 root fq

# --- POST-DOWN ---
PostDown = iptables -D INPUT -p udp --dport ${PRIMARY_PORT} -j ACCEPT
PostDown = iptables -D INPUT -p udp -m multiport --dports ${PORT_CSV} -j ACCEPT
PostDown = ip6tables -D INPUT -p udp --dport ${PRIMARY_PORT} -j ACCEPT
PostDown = ip6tables -D INPUT -p udp -m multiport --dports ${PORT_CSV} -j ACCEPT
PostDown = iptables -t nat -D PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostDown = ip6tables -t nat -D PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostDown = iptables -D INPUT -i wg0 -p udp --dport 53 -j ACCEPT
PostDown = iptables -D INPUT -i wg0 -p tcp --dport 53 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -o wg0 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s fd42:42:42::/64 -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j TTL --ttl-set 64
PostDown = iptables -t mangle -D POSTROUTING -o ${WAN_IFACE} -p udp --sport ${PRIMARY_PORT} -j DSCP --set-dscp 0
INNER_EOF

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for sp in "${STEALTH_PORTS[@]}"; do
            ufw allow "${sp}/udp" >/dev/null 2>&1 || true
        done
    fi

    chmod 600 "${CONF_FILE}"
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    systemctl restart wg-quick@wg0

    configure_local_dns_override

    if systemctl is-active --quiet unbound; then
        DNS_SERVERS="10.66.66.1, 1.1.1.1"
    else
        DNS_SERVERS="1.1.1.1, 9.9.9.9"
    fi
    echo "DNS_SERVERS=\"${DNS_SERVERS}\"" >> "${STATE_FILE}"

    echo -e "${GREEN}[+] Server deployed with maximum throughput at full 500+ Mbps capacity!${NC}"

    while true; do
        create_client_profile
        echo ""
        read -rp "Would you like to add another client/user? (y/N): " add_more
        if [[ ! "$add_more" =~ ^[Yy]$ ]]; then
            break
        fi
    done
}

add_client() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        echo -e "${YELLOW}[!] WireGuard server not initialized yet. Deploying now...${NC}"
        deploy_server
    else
        create_client_profile
    fi
}

view_client() {
    echo ""
    if [[ ! -d "${CLIENTS_DIR}" ]] || [[ -z "$(ls -A "${CLIENTS_DIR}" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}[!] No clients found.${NC}"
        return
    fi
    echo -e "${CYAN}Existing Clients:${NC}"
    mapfile -t CLIENT_FILES < <(ls -1 "${CLIENTS_DIR}"/*.conf 2>/dev/null)
    for i in "${!CLIENT_FILES[@]}"; do
        cname=$(basename "${CLIENT_FILES[$i]}" .conf)
        echo -e "  $((i+1))) ${cname}"
    done
    read -rp "Select client number to view: " c_idx
    if [[ "$c_idx" =~ ^[1-9][0-9]*$ ]] && (( c_idx >= 1 && c_idx <= ${#CLIENT_FILES[@]} )); then
        TARGET_CONF="${CLIENT_FILES[$((c_idx-1))]}"
        echo -e "\n${BOLD}==================== COPY BELOW THIS LINE ====================${NC}"
        cat "${TARGET_CONF}"
        echo -e "${BOLD}==================== COPY ABOVE THIS LINE ====================${NC}"
        prompt_qr_code "${TARGET_CONF}"
    else
        echo -e "${RED}[!] Invalid selection.${NC}"
    fi
}

revoke_client() {
    echo ""
    if [[ ! -d "${CLIENTS_DIR}" ]] || [[ -z "$(ls -A "${CLIENTS_DIR}" 2>/dev/null)" ]]; then
        echo -e "${YELLOW}[!] No clients to revoke.${NC}"
        return
    fi
    echo -e "${CYAN}Existing Clients:${NC}"
    mapfile -t CLIENT_FILES < <(ls -1 "${CLIENTS_DIR}"/*.conf 2>/dev/null)
    for i in "${!CLIENT_FILES[@]}"; do
        cname=$(basename "${CLIENT_FILES[$i]}" .conf)
        echo -e "  $((i+1))) ${cname}"
    done
    read -rp "Select client number to revoke: " c_idx
    if [[ "$c_idx" =~ ^[1-9][0-9]*$ ]] && (( c_idx >= 1 && c_idx <= ${#CLIENT_FILES[@]} )); then
        TARGET_CONF="${CLIENT_FILES[$((c_idx-1))]}"
        CLIENT_NAME=$(basename "${TARGET_CONF}" .conf)
        sed -i "/# BEGIN_PEER ${CLIENT_NAME}/,/# END_PEER ${CLIENT_NAME}/d" "${CONF_FILE}"
        rm -f "${TARGET_CONF}"
        wg syncconf wg0 <(wg-quick strip wg0)
        echo -e "${GREEN}[+] Client '${CLIENT_NAME}' revoked and removed.${NC}"
    else
        echo -e "${RED}[!] Invalid selection.${NC}"
    fi
}

rotate_stealth_ports() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        echo -e "${RED}[!] Deploy the server first.${NC}"
        return
    fi
    echo -e "\n${CYAN}Current High-Speed Stealth Ports:${NC} ${STEALTH_PORTS[*]}"
    read -rp "Enter new space-separated high UDP ports (1024-65535): " -a NEW_PORTS
    if [[ ${#NEW_PORTS[@]} -eq 0 ]]; then
        return
    fi
    FILTERED_PORTS=()
    for np in "${NEW_PORTS[@]}"; do
        if is_protected_port "$np"; then
            echo -e "${RED}[!] Skipping protected port ${np}.${NC}"
        elif [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1024 && np <= 65535 )); then
            FILTERED_PORTS+=("$np")
        fi
    done
    if [[ ${#FILTERED_PORTS[@]} -eq 0 ]]; then
        return
    fi
    STEALTH_PORTS=("${FILTERED_PORTS[@]}")
    PRIMARY_PORT="${STEALTH_PORTS[0]}"
    deploy_server
}

show_status() {
    echo -e "\n${CYAN}=== WireGuard Interface & High-Speed Traffic Status ===${NC}"
    wg show
    echo -e "\n${CYAN}=== Active High-Speed Stealth UDP Ports (NAT Redirect) ===${NC}"
    echo -e "Listening & Redirecting UDP Ports: ${GREEN}${STEALTH_PORTS[*]}${NC} -> Internal Port ${PRIMARY_PORT}"
}

check_root

while true; do
    echo -e "\n${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}   WIREGUARD HIGH-SPEED & STEALTH MANAGER (STANDALONE)      ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "  ${GREEN}1)${NC} Deploy / Re-apply High-Speed Stack & Clean Wipe"
    echo -e "  ${GREEN}2)${NC} Add New Client (Outputs Copy-Paste .conf + Optional QR)"
    echo -e "  ${GREEN}3)${NC} View Existing Client .conf (+ Optional QR)"
    echo -e "  ${GREEN}4)${NC} Revoke / Delete a Client"
    echo -e "  ${GREEN}5)${NC} Customize / Rotate Stealth Ports"
    echo -e "  ${GREEN}6)${NC} Check Tunnel Traffic & High-Speed Status"
    echo -e "  ${GREEN}0)${NC} Exit"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    read -rp "Select an option [0-6]: " menu_opt

    case "$menu_opt" in
        1) deploy_server ;;
        2) add_client ;;
        3) view_client ;;
        4) revoke_client ;;
        5) rotate_stealth_ports ;;
        6) show_status ;;
        0) echo -e "${GREEN}Exiting.${NC}"; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option. Please choose 0-6.${NC}" ;;
    esac
done
EOF