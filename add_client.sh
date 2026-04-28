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

# Ensure the config exists before proceeding
if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
    echo -e "${RED}Error: Server configuration not found. Please run setup_server.sh first.${NC}"
    exit 1
fi

echo -en "${GREEN}Enter device name (no spaces or special characters): ${NC}"
read -r raw_device_name
# Clean input to prevent malicious or broken filenames
DEVICE_NAME=$(echo "$raw_device_name" | tr -cd '[:alnum:]_-')

if [[ -z "$DEVICE_NAME" ]]; then
    echo -e "${RED}Invalid device name.${NC}"
    exit 1
fi

echo -en "${GREEN}Is QR-code suitable for output [y/n]? ${NC}"
read -r IS_QRCODE

# P2: Secure client directory
mkdir -p /etc/wireguard/clients
chmod 700 /etc/wireguard/clients

# Generate keys in memory and write securely
DEVICE_PRIVATE=$(wg genkey)
DEVICE_PUBLIC=$(echo "$DEVICE_PRIVATE" | wg pubkey)

# Get constants for further actions
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

# More reliable external IP lookup, fallback to OpenDNS if blocked
IP_ADR=$(curl -4 -s ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || echo "UNKNOWN_IP")
PORT=$(grep -i "^ListenPort" /etc/wireguard/wg0.conf | awk '{print $3}')
IP_PORT="$IP_ADR:$PORT"

# P3: Robust Next IP Calculation (avoids the tail -n 1 bug)
SERVER_PRIVATE_IP_PREFIX="10.18.0"
# Find all currently used IPs in the config, sort them, and grab the highest number
LAST_IP=$(grep -oP "AllowedIPs\s*=\s*10\.18\.0\.\K[0-9]+" /etc/wireguard/wg0.conf | sort -n | tail -n 1 || true)

# If no clients exist yet, start at .2. Otherwise, increment the highest existing IP.
if [[ -z "$LAST_IP" ]]; then
    NEXT_IP=2
else
    NEXT_IP=$((LAST_IP + 1))
fi

CLIENT_IP="$SERVER_PRIVATE_IP_PREFIX.$NEXT_IP"

echo -e "\nServer public - $SERVER_PUBLIC"
echo "Device public - $DEVICE_PUBLIC"
echo "Device private - $DEVICE_PRIVATE"
echo -e "Endpoint - $IP_PORT; Assigned IP - $CLIENT_IP\n"

# Create client config
CLIENT_CONF="/etc/wireguard/clients/$DEVICE_NAME.conf"

cat <<EOF > "$CLIENT_CONF"
[Interface]
PrivateKey = $DEVICE_PRIVATE
Address = $CLIENT_IP/32
DNS = 1.1.1.1, 8.8.8.8, 9.9.9.9, 76.76.19.19, 94.140.14.14, 208.67.222.222

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $IP_PORT
AllowedIPs = 0.0.0.0/0
EOF

# Lock down client config so only root can read the private key
chmod 600 "$CLIENT_CONF"

# Add client info to persistent server config
cat <<EOF >> /etc/wireguard/wg0.conf

[Peer]
# $DEVICE_NAME
PublicKey = $DEVICE_PUBLIC
AllowedIPs = $CLIENT_IP/32
EOF

# P3: Zero-Downtime Hot Reload
# Instead of taking the whole interface down (which drops all users), 
# we instantly inject the new peer into the live WireGuard interface.
wg set wg0 peer "$DEVICE_PUBLIC" allowed-ips "$CLIENT_IP/32"

# Print output data
if [[ "$IS_QRCODE" == "y" || -z "$IS_QRCODE" ]]; then
    # Only try to install qrencode if it's missing
    if ! command -v qrencode &> /dev/null; then
        apt-get update -y && apt-get install -y qrencode
    fi
    qrencode -t ansiutf8 < "$CLIENT_CONF"
    echo -e "${PURPLE}^^^ Scan this QR-code with the WireGuard App ^^^${NC}"
else 
    echo -e "${GREEN}Config for client ${DEVICE_NAME}:${PURPLE}"
    cat "$CLIENT_CONF"
    echo -e "${NC}"
fi
