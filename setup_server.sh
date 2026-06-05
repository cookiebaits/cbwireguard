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

SETTINGS_FILE="settings.conf"
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

echo -e "${GREEN}Choose port for VPN (Top 5 Stealthiest):${NC}"
echo "[1] 443 (HTTPS/QUIC - Most Stealthy)"
echo "[2] 53 (DNS)"
echo "[3] 123 (NTP)"
echo "[4] 80 (HTTP)"
echo "[5] 51820 (WireGuard Default)"
echo -en "${PURPLE}Select option [1-5] or enter custom port: ${NC}"
read -r input_VPN_PORT

case "$input_VPN_PORT" in
    1) PORT="443" ;;
    2) PORT="53" ;;
    3) PORT="123" ;;
    4) PORT="80" ;;
    5) PORT="51820" ;;
    "") 
        PORT=$((RANDOM % 60000 + 1025))
        echo -e "${PURPLE}Selected random port: ${PORT}${NC}"
        ;;
    *)
        if [[ "$input_VPN_PORT" =~ ^[0-9]+$ ]]; then
            PORT="$input_VPN_PORT"
        else
            PORT="443"
            echo -e "${RED}Invalid input. Defaulting to 443.${NC}"
        fi
        ;;
esac

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

SERVER_PRIVATE_IP="10.18.0.1"

echo -e "${GREEN}Installing WireGuard and required dependencies...${NC}"
apt-get update -y
apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2

echo -e "${GREEN}Generating secure encryption keys...${NC}"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

SERVER_PRIVATE=$(wg genkey)
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)

echo "$SERVER_PRIVATE" > /etc/wireguard/server_private.key
echo "$SERVER_PUBLIC" > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_*.key

NETWORK_DEVICE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -1)

echo -e "${GREEN}Configuring WireGuard interface (wg0)...${NC}"
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $SERVER_PRIVATE_IP/24
ListenPort = $PORT
MTU = $MTU
SaveConfig = false

PostUp = ufw route allow in on wg0 out on $NETWORK_DEVICE
PostUp = iptables -t nat -I POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
PreDown = ufw route delete allow in on wg0 out on $NETWORK_DEVICE
PreDown = iptables -t nat -D POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
EOF

chmod 600 /etc/wireguard/wg0.conf

echo -e "${GREEN}Optimizing Network Throughput (BBR & Forwarding)...${NC}"
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
# P2: Harden network stack
echo "net.ipv4.conf.all.rp_filter=1" >> /etc/sysctl.conf
echo "net.ipv4.conf.default.rp_filter=1" >> /etc/sysctl.conf
sysctl -p

echo -e "${GREEN}Configuring UFW Firewall...${NC}"
ufw allow "$PORT/udp"
ufw allow "$SSH_PORT/tcp"
ufw --force enable

echo -e "${GREEN}Starting WireGuard service...${NC}"
systemctl enable wg-quick@wg0.service
systemctl restart wg-quick@wg0.service
systemctl status --no-pager -l wg-quick@wg0.service

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your WireGuard server is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"
