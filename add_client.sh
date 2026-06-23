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

if [[ ! -f "/etc/wireguard/wg0.conf" ]]; then
    echo -e "${RED}Error: Server configuration not found. Please run setup_server.sh first.${NC}"
    exit 1
fi

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 Cookie's WireGuard Client Setup${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

clear
print_banner
echo -en "${GREEN}Enter device name (no spaces or special characters): ${NC}"
read -r raw_device_name
DEVICE_NAME=$(echo "$raw_device_name" | tr -cd '[:alnum:]_-')

if [[ -z "$DEVICE_NAME" ]]; then
    echo -e "${RED}Invalid device name.${NC}"
    exit 1
fi

# P2: Detection of optional stealth components
HAS_CLOAK=false
HAS_SS=false
HAS_V2RAY=false
[[ -d "/etc/cloak" ]] && HAS_CLOAK=true
[[ -d "/etc/shadowsocks-rust" ]] && HAS_SS=true
[[ -f "/usr/local/bin/v2ray" ]] && HAS_V2RAY=true

STEALTH_MODE="n"
if [[ "$HAS_CLOAK" == true || "$HAS_SS" == true || "$HAS_V2RAY" == true ]]; then
    echo -en "${GREEN}Enable Stealth Mode (WireGuard over Cloak/SS/V2Ray) [y/n]? ${NC}"
    read -r STEALTH_MODE
else
    echo -en "${GREEN}Stealth layer not detected. Install it now? [y/n]: ${NC}"
    read -r install_stealth
    if [[ "$install_stealth" =~ ^[Yy]$ ]]; then
        if [[ -f "./Cloak2-Installer.sh" ]]; then
            chmod +x ./Cloak2-Installer.sh
            ./Cloak2-Installer.sh
            [[ -d "/etc/cloak" ]] && HAS_CLOAK=true
            [[ -d "/etc/shadowsocks-rust" ]] && HAS_SS=true
            echo -en "${GREEN}Enable Stealth Mode for this client [y/n]? ${NC}"
            read -r STEALTH_MODE
        else
            echo -e "${RED}Error: Cloak2-Installer.sh not found.${NC}"
        fi
    fi
fi

echo -en "${GREEN}Is QR-code suitable for output [y/n]? ${NC}"
read -r IS_QRCODE

mkdir -p /etc/wireguard/clients
chmod 700 /etc/wireguard/clients

DEVICE_PRIVATE=$(wg genkey)
DEVICE_PUBLIC=$(echo "$DEVICE_PRIVATE" | wg pubkey)
SERVER_PUBLIC=$(cat /etc/wireguard/server_public.key)

# P1: More reliable IP detection
get_public_ip() {
    local services=("ifconfig.me" "icanhazip.com" "api.ipify.org" "ident.me")
    for svc in "${services[@]}"; do
        local ip
        ip=$(curl -4 -s "$svc" || true)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback to dig
    dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || echo "UNKNOWN_IP"
}
IP_ADR=$(get_public_ip)
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

if [[ "$STEALTH_MODE" =~ ^[Yy]$ ]]; then
    # P2: Advanced Stealth - Conditional Instructions

    # Defaults
    cat <<EOF > "$CLIENT_CONF"
[Interface]
PrivateKey = $DEVICE_PRIVATE
Address = $CLIENT_IP/32
DNS = $DNS
MTU = 1280

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $IP_ADR:$PORT
AllowedIPs = $ALLOWED_IPS
EOF

    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}Stealth Mode Instructions:${NC}"
    echo -e "${PURPLE}By default, this config points to the Server IP for standard use.${NC}"

    if [[ "$HAS_V2RAY" == true ]]; then
        v2_uuid=$(cat /usr/local/etc/v2ray/client_uuid.txt 2>/dev/null || echo "UUID")
        echo -e "To enable ${GREEN}V2Ray (VMess + WS)${NC} obfuscation:"
        echo -e "1. Change the ${GREEN}Endpoint${NC} in your WireGuard app to ${PURPLE}127.0.0.1:1080${NC}"
        echo -e "2. Use a V2Ray client (like v2rayN/v2rayNG) with these settings:"
        echo -e "   - Address: ${PURPLE}$IP_ADR${NC}, Port: ${PURPLE}8888${NC}, ID: ${PURPLE}$v2_uuid${NC}"
        echo -e "   - Transport: ${PURPLE}ws${NC}, Path: ${PURPLE}/video${NC}"
        echo -e "   - SOCKS Proxy: ${PURPLE}127.0.0.1:1080${NC} (This is where WG connects)"
    fi

    if [[ "$HAS_CLOAK" == true && "$HAS_SS" == true ]]; then
        ck_port=$(grep "^PORT=" /etc/cloak/ckport.txt | cut -d= -f2 || echo "443")
        ck_uid=$(grep "^ckaauid=" /etc/cloak/ckport.txt | cut -d= -f2 | tr -d '"' || echo "UID")
        ss_pass=$(jq -r '.password' /etc/shadowsocks-rust/config.json || echo "PASSWORD")

        echo -e "\nTo enable ${GREEN}Shadowsocks + Cloak${NC} obfuscation:"
        echo -e "1. Change the ${GREEN}Endpoint${NC} in your WireGuard app to ${PURPLE}127.0.0.1:1080${NC}"
        echo -e "2. Run Cloak client: ${PURPLE}ck-client -s $IP_ADR -p $ck_port -a $ck_uid -l 1984 -c ckclient.json &${NC}"
        echo -e "3. Run Shadowsocks client: ${PURPLE}ss-local -s 127.0.0.1 -p 1984 -l 1080 -k $ss_pass -m aes-256-gcm &${NC}"
    elif [[ "$HAS_SS" == true ]]; then
        ss_port=$(jq -r '.server_port' /etc/shadowsocks-rust/config.json || echo "8388")
        ss_pass=$(jq -r '.password' /etc/shadowsocks-rust/config.json || echo "PASSWORD")
        echo -e "To enable ${GREEN}Shadowsocks Only${NC} obfuscation:"
        echo -e "1. Change the ${GREEN}Endpoint${NC} in your WireGuard app to ${PURPLE}127.0.0.1:1080${NC}"
        echo -e "2. Run Shadowsocks client: ${PURPLE}ss-local -s $IP_ADR -p $ss_port -l 1080 -k $ss_pass -m aes-256-gcm &${NC}"
    elif [[ "$HAS_CLOAK" == true ]]; then
        ck_port=$(grep "^PORT=" /etc/cloak/ckport.txt | cut -d= -f2 || echo "443")
        ck_uid=$(grep "^ckaauid=" /etc/cloak/ckport.txt | cut -d= -f2 | tr -d '"' || echo "UID")
        echo -e "To enable ${GREEN}Cloak Only${NC} obfuscation:"
        echo -e "1. Change the ${GREEN}Endpoint${NC} in your WireGuard app to ${PURPLE}127.0.0.1:1080${NC}"
        echo -e "2. Run Cloak client: ${PURPLE}ck-client -s $IP_ADR -p $ck_port -a $ck_uid -l 1080 -c ckclient.json &${NC}"
    fi
    echo -e "${PURPLE}======================================================${NC}"
else
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
EOF
fi

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
get_master_pass() {
    if [[ -z "${MASTER_PASS:-}" ]]; then
        echo -en "${GREEN}Enter Master Password for Client Encryption: ${NC}"
        read -rs MASTER_PASS
        echo
        export MASTER_PASS
    fi
}

encrypt_config() {
    get_master_pass
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:$MASTER_PASS" -in "$CLIENT_CONF" -out "${CLIENT_CONF}.enc"
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

encrypt_config
rm -f "$CLIENT_CONF"
