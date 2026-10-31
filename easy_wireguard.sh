cat << 'EOF' > wg-stealth-deploy.sh
#!/usr/bin/env bash
# ==============================================================================
# WIREGUARD STEALTH & SPEED SERVER DEPLOYMENT (STANDALONE EDITION)
# Server-Side DPI Evasion | BBR Speed Tuning | Location Override | Pure .conf
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

# Unique, non-standard UDP ports (Avoids 80, 443, 53, 51820, 8080, 8443)
PRIMARY_PORT=47984
STEALTH_PORTS=(34872 41956 47984 53281 58914 62749)

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}[!] Error: This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

get_wan_iface() {
    ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n1
}

get_public_ip() {
    local ip=""
    # Hardened multi-fallback IP lookup without -f to prevent curl exit code 22
    for url in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip" "https://checkip.amazonaws.com"; do
        ip=$(curl -s4 --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback to interface IP if all external endpoints are blocked
    ip -4 addr show "$(get_wan_iface)" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

install_base_packages() {
    echo -e "${CYAN}[*] Checking and installing core kernel & WireGuard dependencies...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq wireguard wireguard-tools iptables iproute2 curl qrencode unbound > /dev/null
}

configure_local_dns_override() {
    echo -e "${CYAN}[*] Configuring internal Unbound DNS for strict Location Override...${NC}"
    mkdir -p /etc/unbound/unbound.conf.d
    cat <<INNER_EOF > /etc/unbound/unbound.conf.d/wg-stealth.conf
server:
    num-threads: 2
    interface: 10.66.66.1
    interface: fd42:42:42::1
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
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 9.9.9.9@853#dns.quad9.net
INNER_EOF
    systemctl enable unbound > /dev/null 2>&1 || true
    systemctl restart unbound || true
}

apply_speed_and_stealth_sysctl() {
    echo -e "${CYAN}[*] Applying kernel BBR speed optimizations & stealth stack hardening...${NC}"
    cat <<INNER_EOF > /etc/sysctl.d/99-wg-stealth-speed.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 250000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
INNER_EOF
    sysctl --system > /dev/null 2>&1
}

deploy_server() {
    install_base_packages
    apply_speed_and_stealth_sysctl
    configure_local_dns_override

    mkdir -p "${CLIENTS_DIR}"
    chmod 700 "${WG_DIR}"

    WAN_IFACE=$(get_wan_iface)
    SERVER_IP=$(get_public_ip)

    if [[ ! -f "${WG_DIR}/server_private.key" ]]; then
        wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
        chmod 600 "${WG_DIR}/server_private.key"
    fi

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

    echo -e "${CYAN}[*] Generating Server wg0.conf with embedded Stealth & Speed hooks...${NC}"

    cat <<INNER_EOF > "${CONF_FILE}"
[Interface]
Address = 10.66.66.1/24, fd42:42:42::1/64
ListenPort = ${PRIMARY_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
MTU = 1380

# 1. Multi-Port Stealth Hopping
PostUp = iptables -t nat -A PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostUp = ip6tables -t nat -A PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}

# 2. Strict Location Override & DNS Leak Interception
PostUp = iptables -t nat -A PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination 10.66.66.1:53
PostUp = iptables -t nat -A PREROUTING -i wg0 -p tcp --dport 53 -j DNAT --to-destination 10.66.66.1:53
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostUp = ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -A FORWARD -o wg0 -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o ${WAN_IFACE} -j MASQUERADE

# 3. Dynamic TCP MSS Clamping
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 4. Server-Side Stealth: TTL Normalization & DSCP Scrubbing
PostUp = iptables -t mangle -A POSTROUTING -o ${WAN_IFACE} -j TTL --ttl-set 64
PostUp = iptables -t mangle -A POSTROUTING -o ${WAN_IFACE} -p udp -j DSCP --set-dscp 0

# 5. Kernel Traffic Shaping
PostUp = tc qdisc replace dev wg0 root fq maxrate 10gbit

# --- POST-DOWN: Clean Teardown ---
PostDown = iptables -t nat -D PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostDown = ip6tables -t nat -D PREROUTING -i ${WAN_IFACE} -p udp -m multiport --dports ${PORT_CSV} -j REDIRECT --to-ports ${PRIMARY_PORT}
PostDown = iptables -t nat -D PREROUTING -i wg0 -p udp --dport 53 -j DNAT --to-destination 10.66.66.1:53
PostDown = iptables -t nat -D PREROUTING -i wg0 -p tcp --dport 53 -j DNAT --to-destination 10.66.66.1:53
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o ${WAN_IFACE} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -D FORWARD -o wg0 -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -s fd42:42:42::/64 -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -t mangle -D POSTROUTING -o ${WAN_IFACE} -j TTL --ttl-set 64
PostDown = iptables -t mangle -D POSTROUTING -o ${WAN_IFACE} -p udp -j DSCP --set-dscp 0
INNER_EOF

    chmod 600 "${CONF_FILE}"
    systemctl enable wg-quick@wg0 > /dev/null 2>&1
    systemctl restart wg-quick@wg0

    echo -e "${GREEN}[+] Server deployed and running on IP: ${SERVER_IP}${NC}"
    echo -e "${YELLOW}[i] Active Unique Stealth UDP Ports:${NC} ${STEALTH_PORTS[*]}"
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

add_client() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        echo -e "${YELLOW}[!] WireGuard server not initialized yet. Deploying now...${NC}"
        deploy_server
    fi

    source "${STATE_FILE}"

    echo ""
    read -rp "Enter a name for the new client (e.g., phone, laptop): " CLIENT_NAME
    CLIENT_NAME=$(echo "${CLIENT_NAME}" | tr -cd 'a-zA-Z0-9_-')

    if [[ -z "${CLIENT_NAME}" ]]; then
        echo -e "${RED}[!] Invalid client name.${NC}"
        return
    fi

    CLIENT_CONF="${CLIENTS_DIR}/${CLIENT_NAME}.conf"
    if [[ -f "${CLIENT_CONF}" ]]; then
        echo -e "${RED}[!] Client '${CLIENT_NAME}' already exists.${NC}"
        return
    fi

    echo -e "\n${CYAN}Available Unique Stealth Ports:${NC}"
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
    while grep -q "10.66.66.$((LAST_OCTET + 1))/32" "${CONF_FILE}"; do
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
DNS = 10.66.66.1, fd42:42:42::1
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
    echo -e "\n${CYAN}Current Unique Stealth Ports:${NC} ${STEALTH_PORTS[*]}"
    read -rp "Enter new space-separated high UDP ports (e.g. 31892 44910 51992 60432): " -a NEW_PORTS
    if [[ ${#NEW_PORTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}[!] No ports entered. Keeping existing ports.${NC}"
        return
    fi
    STEALTH_PORTS=("${NEW_PORTS[@]}")
    PRIMARY_PORT="${STEALTH_PORTS[0]}"
    systemctl stop wg-quick@wg0 || true
    deploy_server
    echo -e "${GREEN}[+] Stealth ports updated! Update the Endpoint port in your client .conf to any of: ${STEALTH_PORTS[*]}${NC}"
}

show_status() {
    echo -e "\n${CYAN}=== WireGuard Interface & Peer Traffic Status ===${NC}"
    wg show
    echo -e "\n${CYAN}=== Active Unique Stealth UDP Ports (NAT Redirect) ===${NC}"
    echo -e "Listening & Redirecting UDP Ports: ${GREEN}${STEALTH_PORTS[*]}${NC} -> Internal Port ${PRIMARY_PORT}"
    echo -e "\n${CYAN}=== Kernel Congestion Control & Queueing ===${NC}"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
}

check_root

while true; do
    echo -e "\n${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}   WIREGUARD STEALTH + SPEED SERVER MANAGER (STANDALONE)    ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "  ${GREEN}1)${NC} Deploy / Re-apply Stealth & Speed Server Stack"
    echo -e "  ${GREEN}2)${NC} Add New Client (Outputs Copy-Paste .conf + Optional QR)"
    echo -e "  ${GREEN}3)${NC} View Existing Client .conf (+ Optional QR)"
    echo -e "  ${GREEN}4)${NC} Revoke / Delete a Client"
    echo -e "  ${GREEN}5)${NC} Customize / Rotate Unique Stealth Ports"
    echo -e "  ${GREEN}6)${NC} Check Tunnel Traffic, Stealth Ports & BBR Status"
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