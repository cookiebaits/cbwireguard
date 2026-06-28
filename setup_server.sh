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

echo -e "\n${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}║${NC} ${GREEN}Choose port for VPN:${NC}                                       ${PURPLE}║${NC}"
echo -e "${PURPLE}╠════════════════════════════════════════════════════════════╣${NC}"
echo -e "${PURPLE}║${NC} [1] 443                                                    ${PURPLE}║${NC}"
echo -e "${PURPLE}║${NC} [2] 53 (DNS)                                               ${PURPLE}║${NC}"
echo -e "${PURPLE}║${NC} [3] 123 (NTP)                                              ${PURPLE}║${NC}"
echo -e "${PURPLE}║${NC} [4] 1194 (OpenVPN UDP)                                     ${PURPLE}║${NC}"
echo -e "${PURPLE}║${NC} [5] 500 (ISAKMP)                                           ${PURPLE}║${NC}"
echo -e "${PURPLE}║${NC} [6] 4500 (IPsec NAT-T)                                     ${PURPLE}║${NC}"
echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
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

echo -en "${GREEN}Install AmneziaWG (Stealth VPN) for an all-in-one obfuscated client? [y/N]: ${NC}"
read -r input_AMNEZIA
if [[ "$input_AMNEZIA" =~ ^[Yy]$ ]]; then
    WG_TYPE="amnezia"
    WG_IFACE="awg0"
    WG_CMD="awg"
    WG_QUICK="awg-quick"
    if grep -q "^WG_TYPE=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^WG_TYPE=.*|WG_TYPE=${WG_TYPE}|" "$SETTINGS_FILE"
    else
        echo "WG_TYPE=${WG_TYPE}" >> "$SETTINGS_FILE"
    fi
else
    WG_TYPE="standard"
    WG_IFACE="wg0"
    WG_CMD="wg"
    WG_QUICK="wg-quick"
    if grep -q "^WG_TYPE=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^WG_TYPE=.*|WG_TYPE=${WG_TYPE}|" "$SETTINGS_FILE"
    else
        echo "WG_TYPE=${WG_TYPE}" >> "$SETTINGS_FILE"
    fi
fi

# Cleanup old wstunnel settings if they existed
if [[ -f "$SETTINGS_FILE" ]]; then
    sed -i '/^WSTUNNEL_PORT=/d' "$SETTINGS_FILE"
fi

SERVER_PRIVATE_IP="10.18.0.1"
SERVER_SUBNET="10.18.0.0/24"

echo -e "${GREEN}Installing dependencies...${NC}"
apt-get update -y
apt-get install -y ufw dnsutils qrencode iptables iproute2 jq bc

if [[ "$WG_TYPE" == "amnezia" ]]; then
    echo -e "${GREEN}Installing AmneziaWG...${NC}"
    # Suppress output of add-apt-repository
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || true
    apt-get update -y >/dev/null 2>&1
    apt-get install -y amneziawg-tools amneziawg-dkms
else
    echo -e "${GREEN}Installing Standard WireGuard...${NC}"
    apt-get install -y wireguard
fi

echo -e "${GREEN}Generating secure encryption keys...${NC}"
if [[ "$WG_TYPE" == "amnezia" ]]; then
    mkdir -p /etc/amnezia
    chmod 700 /etc/amnezia
    CONF_DIR="/etc/amnezia"
else
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    CONF_DIR="/etc/wireguard"
fi

SERVER_PRIVATE=$($WG_CMD genkey)
SERVER_PUBLIC=$(echo "$SERVER_PRIVATE" | $WG_CMD pubkey)

echo "$SERVER_PRIVATE" > "$CONF_DIR/server_private.key"
echo "$SERVER_PUBLIC" > "$CONF_DIR/server_public.key"
chmod 600 "$CONF_DIR"/server_*.key

NETWORK_DEVICE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -1)

# Generate Amnezia Obfuscation parameters if enabled
if [[ "$WG_TYPE" == "amnezia" ]]; then
    # Randomly generate values
    JC=$((RANDOM % 120 + 3))
    JMIN=$((RANDOM % 50 + 10))
    JMAX=$((RANDOM % 700 + 300))
    S1=$((RANDOM % 100 + 15))
    S2=$((RANDOM % 100 + 15))
    H1=1
    H2=2
    H3=3
    H4=4
    OBFS_BLOCK="
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4"
else
    OBFS_BLOCK=""
fi

echo -e "${GREEN}Configuring interface ($WG_IFACE)...${NC}"
cat <<EOF > "$CONF_DIR/$WG_IFACE.conf"
[Interface]
PrivateKey = $SERVER_PRIVATE
Address = $SERVER_PRIVATE_IP/24
ListenPort = $PORT
MTU = $MTU$OBFS_BLOCK
SaveConfig = false

PostUp = iptables -I FORWARD 1 -i $WG_IFACE -j ACCEPT
PostUp = iptables -I FORWARD 1 -o $WG_IFACE -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s $SERVER_SUBNET -o $NETWORK_DEVICE -j MASQUERADE
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -D FORWARD -i $WG_IFACE -j ACCEPT
PreDown = iptables -D FORWARD -o $WG_IFACE -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -s $SERVER_SUBNET -o $NETWORK_DEVICE -j MASQUERADE
PreDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

chmod 600 "$CONF_DIR/$WG_IFACE.conf"

echo -e "${GREEN}Optimizing Network Throughput (BBR & Forwarding)...${NC}"
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.all.rp_filter/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.default.rp_filter/d' /etc/sysctl.conf
sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_mtu_probing/d' /etc/sysctl.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
# Advanced TCP Buffer and MTU Optimizations for Max Throughput
echo "net.core.rmem_max=2500000" >> /etc/sysctl.conf
echo "net.core.wmem_max=2500000" >> /etc/sysctl.conf
echo "net.ipv4.tcp_rmem=4096 87380 2500000" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem=4096 16384 2500000" >> /etc/sysctl.conf
echo "net.ipv4.tcp_mtu_probing=1" >> /etc/sysctl.conf
# P2: Harden network stack (using loose mode to prevent routing drops)
echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf
echo "net.ipv4.conf.default.rp_filter=2" >> /etc/sysctl.conf
sysctl -p

echo -e "${GREEN}Configuring UFW Firewall...${NC}"
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/' /etc/ufw/sysctl.conf || true
ufw allow "$PORT/udp"
ufw allow "$SSH_PORT/tcp"
ufw --force enable

echo -e "${GREEN}Starting $WG_TYPE service...${NC}"
systemctl enable ${WG_QUICK}@${WG_IFACE}.service
if ! systemctl restart ${WG_QUICK}@${WG_IFACE}.service; then
    echo -e "${RED}Error: Failed to start $WG_TYPE service.${NC}"
    echo -e "${PURPLE}--- Diagnostic Logs ---${NC}"
    journalctl -xeu ${WG_QUICK}@${WG_IFACE}.service | tail -n 20
    echo -e "${PURPLE}-----------------------${NC}"
    systemctl status ${WG_QUICK}@${WG_IFACE}.service --no-pager
    exit 1
fi
systemctl status --no-pager -l ${WG_QUICK}@${WG_IFACE}.service

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your VPN server ($WG_TYPE) is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"
