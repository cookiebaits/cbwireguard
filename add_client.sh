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

if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
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

mkdir -p /etc/wireguard/clients
chmod 700 /etc/wireguard/clients

DEVICE_PRIVATE=$(wg genkey)
DEVICE_PUBLIC=$(echo "$DEVICE_PRIVATE" | wg pubkey)
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

IP_ADR=$(curl -4 -s ifconfig.me || dig +short myip.opendns.com @resolver1.opendns.com || echo "UNKNOWN_IP")
PORT=$(grep -i "^ListenPort" /etc/wireguard/wg0.conf | awk '{print $3}')
# P3: Respect MTU from server config if it exists
SERVER_MTU=$(grep -i "^MTU" /etc/wireguard/wg0.conf | awk '{print $3}' || echo "$MTU")
MTU=${SERVER_MTU:-$MTU}
IP_PORT="$IP_ADR:$PORT"

SERVER_PRIVATE_IP_PREFIX="10.18.0"
LAST_IP=$(grep -oP "AllowedIPs\s*=\s*10\.18\.0\.\K[0-9]+" /etc/wireguard/wg0.conf | sort -n | tail -n 1 || true)

if [[ -z "$LAST_IP" ]]; then
    NEXT_IP=2
else
    NEXT_IP=$((LAST_IP + 1))
fi

CLIENT_IP="$SERVER_PRIVATE_IP_PREFIX.$NEXT_IP"

CLIENT_CONF="/etc/wireguard/clients/$DEVICE_NAME.conf"

cat <<EOF > "$CLIENT_CONF"
[Interface]
PrivateKey = $DEVICE_PRIVATE
Address = $CLIENT_IP/32
DNS = $DNS
MTU = $MTU

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $IP_PORT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF"

cat <<EOF >> /etc/wireguard/wg0.conf

[Peer]
# USER_START: $DEVICE_NAME
PublicKey = $DEVICE_PUBLIC
AllowedIPs = $CLIENT_IP/32
# USER_END: $DEVICE_NAME
EOF

wg set wg0 peer "$DEVICE_PUBLIC" allowed-ips "$CLIENT_IP/32"

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
    echo -e "${PURPLE}^^^ Scan this QR-code with the WireGuard App ^^^${NC}"
else 
    echo -e "${GREEN}Config for client ${DEVICE_NAME}:${PURPLE}"
    cat "$CLIENT_CONF"
    echo -e "${NC}"
fi

if [[ "${WSTUNNEL_ENABLED:-false}" == "true" ]]; then
    CLIENT_INSTALLER="/etc/wireguard/clients/${DEVICE_NAME}_installer.sh"
    cat <<EOF > "$CLIENT_INSTALLER"
#!/bin/bash
set -euo pipefail

# Check for root
if [[ "\$EUID" -ne 0 ]]; then
    echo "Please run this script as root (sudo)."
    exit 1
fi

echo "Installing WireGuard..."
apt-get update -y
apt-get install -y wireguard resolvconf

echo "Installing WStunnel..."
WSTUNNEL_LATEST_VERSION=\$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/erebe/wstunnel/releases/latest | grep -o '[^/]*$')
WSTUNNEL_DL_URL="https://github.com/erebe/wstunnel/releases/download/\${WSTUNNEL_LATEST_VERSION}/wstunnel_\${WSTUNNEL_LATEST_VERSION#v}_linux_amd64.tar.gz"
curl -sL "\$WSTUNNEL_DL_URL" -o /tmp/wstunnel.tar.gz
tar -xzf /tmp/wstunnel.tar.gz -C /tmp
mv /tmp/wstunnel /usr/local/bin/wstunnel
chmod +x /usr/local/bin/wstunnel
rm -f /tmp/wstunnel.tar.gz

echo "Setting up WStunnel systemd service..."
cat <<SVC > /etc/systemd/system/wstunnel-client.service
[Unit]
Description=WStunnel Client
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel client -L 'udp://${PORT}:127.0.0.1:${PORT}?timeout_sec=0' ws://${IP_ADR}:${WSTUNNEL_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable wstunnel-client.service
systemctl restart wstunnel-client.service

echo "Setting up WireGuard client..."
cat <<WGCONF > /etc/wireguard/${DEVICE_NAME}.conf
[Interface]
PrivateKey = $DEVICE_PRIVATE
Address = $CLIENT_IP/32
DNS = $DNS
MTU = $MTU

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = 127.0.0.1:${PORT}
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
WGCONF

chmod 600 /etc/wireguard/${DEVICE_NAME}.conf

echo "Starting WireGuard client..."
systemctl enable wg-quick@${DEVICE_NAME}.service
systemctl restart wg-quick@${DEVICE_NAME}.service

echo "Client setup complete! Connected to ${IP_ADR} via WStunnel."
EOF
    chmod +x "$CLIENT_INSTALLER"

    echo -e "\n${GREEN}=== Stealth Mode (WStunnel) One-Tap Installer ===${NC}"
    echo -e "${PURPLE}A one-tap client installer script has been generated at:${NC}"
    echo -e "${GREEN}${CLIENT_INSTALLER}${NC}"
    echo -e "${PURPLE}Transfer this script to your client machine (Ubuntu/Debian or other Linux distro) and run it as root:${NC}"
    echo -e "  sudo ./${DEVICE_NAME}_installer.sh"
    echo -e "${RED}Note: This script assumes a Debian/Ubuntu-based system for 'apt-get'. If using Windows or macOS, please install WireGuard and WStunnel manually using the original instructions.${NC}"
    echo -e "${GREEN}=================================================${NC}\n"
fi

encrypt_config
rm -f "$CLIENT_CONF"
