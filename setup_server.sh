#!/bin/bash
set -euo pipefail

# P1: OS Detection to fix unbound 'distro' variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    distro=$ID
else
    distro="unknown"
fi

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

SETTINGS_FILE="/root/easy_wireguard/settings.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# P3: Default MTU from settings or 1280
MTU=${DEFAULT_MTU:-1280}

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

check_port_usage() {
    local port=$1
    if ss -lnup | grep -q ":${port} "; then
        return 0 # Port is in use
    fi
    return 1 # Port is free
}

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 Cookie's WireGuard Server Setup${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

clear
print_banner
echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
echo -e "${PURPLE}│      VPN Port Selection (Recommended Stealthy)     │${NC}"
echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
echo -e "${PURPLE}│ ${NC}[1] 443 (HTTPS/QUIC - Most Stealthy)             ${PURPLE}│${NC}"
echo -e "${PURPLE}│ ${NC}[2] 53 (DNS)                                     ${PURPLE}│${NC}"
echo -e "${PURPLE}│ ${NC}[3] 123 (NTP)                                    ${PURPLE}│${NC}"
echo -e "${PURPLE}│ ${NC}[4] 1194 (OpenVPN UDP)                           ${PURPLE}│${NC}"
echo -e "${PURPLE}│ ${NC}[5] 500 (ISAKMP)                                  ${PURPLE}│${NC}"
echo -e "${PURPLE}│ ${NC}[6] 4500 (IPsec NAT-T)                            ${PURPLE}│${NC}"
echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
echo -en "${PURPLE}Select option [1-6] or enter custom port [Default 443]: ${NC}"
read -r input_VPN_PORT

while true; do
    case "$input_VPN_PORT" in
        1) PORT="443" ;;
        2) PORT="53" ;;
        3) PORT="123" ;;
        4) PORT="1194" ;;
        5) PORT="500" ;;
        6) PORT="4500" ;;
    "") PORT="443" ;;
        *)
            if [[ "$input_VPN_PORT" =~ ^[0-9]+$ ]]; then
                PORT="$input_VPN_PORT"
            else
                PORT="443"
                echo -e "${RED}Invalid input. Defaulting to 443.${NC}"
            fi
            ;;
    esac

    if check_port_usage "$PORT"; then
        echo -e "${RED}Error: Port ${PORT} is already in use by another process!${NC}"
        echo -en "${GREEN}Please enter another port or select from the menu above: ${NC}"
        read -r input_VPN_PORT
    else
        break
    fi
done

echo -en "${GREEN}Enter your SSH port, leave blank for default [22]: ${NC}"
read -r input_SSH_PORT
if [[ -z "$input_SSH_PORT" ]]; then
    SSH_PORT="22"
else
    SSH_PORT="$input_SSH_PORT"
fi

echo -en "${GREEN}Enter MTU, leave blank for default [${MTU}]: ${NC}"
read -r input_MTU
if [[ -n "$input_MTU" ]]; then
    MTU="$input_MTU"
fi

set_sysctl() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" /etc/sysctl.conf
    else
        echo "${key}=${value}" >> /etc/sysctl.conf
    fi
}

SERVER_PRIVATE_IP="10.18.0.1"

# P1: Cleanup old instances before fresh install
echo -e "${GREEN}Cleaning up any existing WireGuard instances...${NC}"
active_wg_services=$(systemctl list-units --type=service --state=active | grep -o "wg-quick@.*\.service" || true)
if [[ -n "$active_wg_services" ]]; then
    for svc in $active_wg_services; do
        systemctl stop "$svc"
        systemctl disable "$svc"
    done
fi
if systemctl is-active --quiet wg-quick@wg0.service; then
    systemctl stop wg-quick@wg0.service
    systemctl disable wg-quick@wg0.service
fi
sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
apt-get purge -y wireguard wireguard-tools >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true
rm -rf /etc/wireguard
rm -rf /root/easy_wireguard/clients 2>/dev/null || true

echo -e "${GREEN}Installing WireGuard and required dependencies...${NC}"
# P2: Removed apt-get update
apt-get update -y && apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2 jq

echo -e "${GREEN}Generating secure encryption keys...${NC}"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

SERVER_PRIVATE=$(wg genkey)
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)

echo "$SERVER_PRIVATE" > /etc/wireguard/server_private.key
echo "$SERVER_PUBLIC" > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_*.key

# P1: Enhanced network device detection
NETWORK_DEVICE=$(ip route get 8.8.8.8 2>/dev/null | grep -Po '(?<=dev )(\S+)' | head -1)
if [[ -z "$NETWORK_DEVICE" ]]; then
    NETWORK_DEVICE=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|wg' | head -n1)
fi

echo -e "${GREEN}Configuring WireGuard interface (wg0)...${NC}"
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $SERVER_PRIVATE_IP/24
ListenPort = $PORT
MTU = $MTU
SaveConfig = false

PostUp = ufw route allow in on wg0 out on $NETWORK_DEVICE
PostUp = iptables -t nat -A POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
PreDown = ufw route delete allow in on wg0 out on $NETWORK_DEVICE
PreDown = iptables -t nat -D POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
EOF

chmod 600 /etc/wireguard/wg0.conf

echo -e "${GREEN}Optimizing Network & Hardening Security...${NC}"
set_sysctl "net.ipv4.ip_forward" "1"
set_sysctl "net.core.default_qdisc" "fq"
set_sysctl "net.ipv4.tcp_congestion_control" "bbr"
# Security Hardening
set_sysctl "net.ipv4.conf.all.rp_filter" "1"
set_sysctl "net.ipv4.conf.default.rp_filter" "1"
set_sysctl "net.ipv4.conf.all.accept_redirects" "0"
set_sysctl "net.ipv4.conf.all.send_redirects" "0"
set_sysctl "net.ipv4.conf.all.accept_source_route" "0"
set_sysctl "net.ipv6.conf.all.disable_ipv6" "0"
sysctl -p

echo -e "${GREEN}Configuring UFW Firewall...${NC}"
ufw allow "$PORT/udp"
ufw allow "$SSH_PORT/tcp"
ufw --force enable

echo -e "${GREEN}Starting WireGuard service...${NC}"
systemctl enable wg-quick@wg0.service
if ! systemctl restart wg-quick@wg0.service; then
    echo -e "${RED}Error: Failed to start WireGuard service.${NC}"
    echo -e "${PURPLE}--- Diagnostic Logs ---${NC}"
    journalctl -xeu wg-quick@wg0.service | tail -n 20
    echo -e "${PURPLE}-----------------------${NC}"
    systemctl status wg-quick@wg0.service --no-pager
    exit 1
fi
systemctl status --no-pager -l wg-quick@wg0.service

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your WireGuard server is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"
