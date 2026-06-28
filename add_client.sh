#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

SETTINGS_FILE="/root/easy_wireguard/settings.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# P3: Defaults from settings
MTU=${DEFAULT_MTU:-1280}
DNS=${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}
ALLOWED_IPS=${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1"}

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

get_master_pass() {
    if [[ -z "${MASTER_PASS:-}" ]]; then
        echo -en "${GREEN}Enter Master Password for Client Encryption/Decryption: ${NC}"
        read -rs MASTER_PASS
        echo
        export MASTER_PASS
    fi
}

if [[ "${WG_TYPE:-standard}" == "amnezia" ]]; then
    CONF_DIR="/etc/amnezia/amneziawg"
    WG_IFACE="awg0"
    WG_CMD="awg"
else
    CONF_DIR="/etc/wireguard"
    WG_IFACE="wg0"
    WG_CMD="wg"
fi

if [[ ! -f "$CONF_DIR/$WG_IFACE.conf" ]]; then
    echo -e "${RED}Error: Server configuration not found. Please run setup_server.sh first.${NC}"
    exit 1
fi

echo -en "${GREEN}Enter device name (no spaces or special characters): ${NC}"
read -r raw_device_name
DEVICE_NAME=$(echo "$raw_device_name" | tr -cd '[:alnum:]_-')

if [[ -z "$DEVICE_NAME" ]]; then
    echo -e "${RED}Invalid device name.${NC}"
    exit 1
fi

echo -en "${GREEN}Is QR-code suitable for output [y/n]? ${NC}"
read -r IS_QRCODE

mkdir -p "$CONF_DIR/clients"
chmod 700 "$CONF_DIR/clients"

DEVICE_PRIVATE=$($WG_CMD genkey)
DEVICE_PUBLIC=$(echo "$DEVICE_PRIVATE" | $WG_CMD pubkey)
SERVER_PUBLIC=$(cat "$CONF_DIR/server_public.key")

IP_ADR=$(curl -4 -s ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || echo "UNKNOWN_IP")
PORT=$(grep -i "^ListenPort" "$CONF_DIR/$WG_IFACE.conf" | awk '{print $3}')
# P3: Respect MTU from server config if it exists
SERVER_MTU=$(grep -i "^MTU" "$CONF_DIR/$WG_IFACE.conf" | awk '{print $3}' || echo "$MTU")
MTU=${SERVER_MTU:-$MTU}

IP_PORT="$IP_ADR:$PORT"

SERVER_PRIVATE_IP_PREFIX="10.18.0"
LAST_IP=$(grep -oP "AllowedIPs\s*=\s*10\.18\.0\.\K[0-9]+" "$CONF_DIR/$WG_IFACE.conf" | sort -n | tail -n 1 || true)

if [[ -z "$LAST_IP" ]]; then
    NEXT_IP=2
else
    NEXT_IP=$((LAST_IP + 1))
fi

CLIENT_IP="$SERVER_PRIVATE_IP_PREFIX.$NEXT_IP"

CLIENT_CONF="$CONF_DIR/clients/$DEVICE_NAME.conf"

# Extract Amnezia specific obfuscation parameters from server config if present
if [[ "${WG_TYPE:-standard}" == "amnezia" ]]; then
    OBFS_BLOCK=$(grep -E "^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)\s*=" "$CONF_DIR/$WG_IFACE.conf" || true)
    if [[ -n "$OBFS_BLOCK" ]]; then
        OBFS_BLOCK=$'\n'"$OBFS_BLOCK"
    fi
else
    OBFS_BLOCK=""
fi

cat <<EOF > "$CLIENT_CONF"
[Interface]
PrivateKey = $DEVICE_PRIVATE
Address = $CLIENT_IP/32
DNS = $DNS
MTU = $MTU$OBFS_BLOCK

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $IP_PORT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF"

cat <<EOF >> "$CONF_DIR/$WG_IFACE.conf"

[Peer]
# USER_START: $DEVICE_NAME
PublicKey = $DEVICE_PUBLIC
AllowedIPs = $CLIENT_IP/32
# USER_END: $DEVICE_NAME
EOF

$WG_CMD set $WG_IFACE peer "$DEVICE_PUBLIC" allowed-ips "$CLIENT_IP/32"

# P3: Encryption of client config
encrypt_config() {
    get_master_pass
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:$MASTER_PASS" -in "$CLIENT_CONF" -out "${CLIENT_CONF}.enc"
    # Keep the plain text for the current display, then delete
}

if [[ "$IS_QRCODE" == "y" || -z "$IS_QRCODE" ]]; then
    if ! command -v qrencode &> /dev/null; then
        apt-get update -y && apt-get install -y qrencode
    fi
    qrencode -t ansiutf8 < "$CLIENT_CONF"
    if [[ "${WG_TYPE:-standard}" == "amnezia" ]]; then
        echo -e "${PURPLE}^^^ Scan this QR-code with the AmneziaWG App ^^^${NC}"
    else
        echo -e "${PURPLE}^^^ Scan this QR-code with the WireGuard App ^^^${NC}"
    fi
else 
    echo -e "${GREEN}Config for client ${DEVICE_NAME}:${PURPLE}"
    cat "$CLIENT_CONF"
    echo -e "${NC}"
fi

if [[ "${WG_TYPE:-standard}" == "amnezia" ]]; then
    echo -e "\n${PURPLE}======================================================${NC}"
    echo -e "${GREEN}AmneziaWG (Stealth VPN) is enabled!${NC}"
    echo -e "${PURPLE}You can import this directly into your AmneziaWG client apps.${NC}"
    echo -e "${PURPLE}======================================================${NC}\n"
fi

encrypt_config
rm -f "$CLIENT_CONF"
