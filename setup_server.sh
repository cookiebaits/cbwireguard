#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# P2: Security Check - Require root access
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

echo -en "${GREEN}Choose port for VPN (1024-65535), leave blank for random: ${NC}"
read -r input_VPN_PORT

# Bug Fix: Original script had a typo '$input' instead of '$input_VPN_PORT'
if [[ -z "$input_VPN_PORT" ]]; then
    # Generate a random unprivileged port between 1025 and 61024 for security
    PORT=$((RANDOM % 60000 + 1025))
    echo -e "${PURPLE}Selected random port: ${PORT}${NC}"
else
    PORT="$input_VPN_PORT"
fi

echo -en "${GREEN}Enter your SSH port, leave blank for default [22]: ${NC}"
read -r input_SSH_PORT
if [[ -z "$input_SSH_PORT" ]]; then
    SSH_PORT="22"
else
    SSH_PORT="$input_SSH_PORT"
fi

SERVER_PRIVATE_IP="10.18.0.1"

# P1: Pulling the latest versions securely
echo -e "${GREEN}Installing WireGuard and required dependencies...${NC}"
apt-get update -y
# Added qrencode and iptables to ensure peer generation works smoothly later
apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2

# P2: Secure directory and key setup
echo -e "${GREEN}Generating secure encryption keys...${NC}"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Generate keys in memory to prevent interception
SERVER_PRIVATE=$(wg genkey)
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | wg pubkey)

# Write to files and lock permissions down so only root can read them
echo "$SERVER_PRIVATE" > /etc/wireguard/server_private.key
echo "$SERVER_PUBLIC" > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_*.key

# P3: Optimize Network Routing Discovery
NETWORK_DEVICE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -1)

echo -e "${GREEN}Configuring WireGuard interface (wg0)...${NC}"
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $SERVER_PRIVATE_IP/24
ListenPort = $PORT
SaveConfig = false

PostUp = ufw route allow in on wg0 out on $NETWORK_DEVICE
PostUp = iptables -t nat -I POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
PreDown = ufw route delete allow in on wg0 out on $NETWORK_DEVICE
PreDown = iptables -t nat -D POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
EOF

# Lock down the main configuration file
chmod 600 /etc/wireguard/wg0.conf

# P3: Optimize IPv4 Forwarding (Cleans up previous entries to avoid bloat)
echo -e "${GREEN}Optimizing IP forwarding...${NC}"
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Configure Firewall
echo -e "${GREEN}Configuring UFW Firewall...${NC}"
ufw allow "$PORT/udp"
ufw allow "$SSH_PORT/tcp"
ufw --force enable

# Enable and start WireGuard service
echo -e "${GREEN}Starting WireGuard service...${NC}"
systemctl enable wg-quick@wg0.service
systemctl restart wg-quick@wg0.service

# Check status without hanging the terminal
systemctl status --no-pager -l wg-quick@wg0.service

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your WireGuard server is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"

# Updated to match the new modular execution flow of easy_wireguard.sh
echo -e "To add clients, return to the main wrapper menu and select ${GREEN}[3] Add new client (peer)${NC}."
