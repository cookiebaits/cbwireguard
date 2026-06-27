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

echo -en "${GREEN}Enable WireGuard over TLS (Stealth Mode) using wstunnel? [y/N]: ${NC}"
read -r input_WSTUNNEL
if [[ "$input_WSTUNNEL" =~ ^[Yy]$ ]]; then
    echo -en "${GREEN}Enter wstunnel port [Default 443]: ${NC}"
    read -r input_WSTUNNEL_PORT
    if [[ -z "$input_WSTUNNEL_PORT" ]]; then
        WSTUNNEL_PORT="443"
    else
        WSTUNNEL_PORT="$input_WSTUNNEL_PORT"
    fi
    # Add to settings.conf
    if grep -q "^WSTUNNEL_PORT=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^WSTUNNEL_PORT=.*|WSTUNNEL_PORT=${WSTUNNEL_PORT}|" "$SETTINGS_FILE"
    else
        echo "WSTUNNEL_PORT=${WSTUNNEL_PORT}" >> "$SETTINGS_FILE"
    fi
else
    # Remove if it existed before
    if [[ -f "$SETTINGS_FILE" ]]; then
        sed -i '/^WSTUNNEL_PORT=/d' "$SETTINGS_FILE"
    fi
fi

SERVER_PRIVATE_IP="10.18.0.1"
SERVER_SUBNET="10.18.0.0/24"

echo -e "${GREEN}Installing WireGuard and required dependencies...${NC}"
apt-get update -y
apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2 jq bc

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

PostUp = iptables -I FORWARD 1 -i wg0 -j ACCEPT
PostUp = iptables -I FORWARD 1 -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s $SERVER_SUBNET -o $NETWORK_DEVICE -j MASQUERADE
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -D FORWARD -i wg0 -j ACCEPT
PreDown = iptables -D FORWARD -o wg0 -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -s $SERVER_SUBNET -o $NETWORK_DEVICE -j MASQUERADE
PreDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

chmod 600 /etc/wireguard/wg0.conf

echo -e "${GREEN}Optimizing Network Throughput (BBR & Forwarding)...${NC}"
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.all.rp_filter/d' /etc/sysctl.conf
sed -i '/net.ipv4.conf.default.rp_filter/d' /etc/sysctl.conf

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
if [[ -n "${WSTUNNEL_PORT:-}" ]]; then
    ufw allow "$WSTUNNEL_PORT/tcp"
fi
ufw --force enable

if [[ -n "${WSTUNNEL_PORT:-}" ]]; then
    echo -e "${GREEN}Installing and configuring wstunnel...${NC}"
    WSTUNNEL_VER="10.5.5"
    if ! command -v wstunnel &> /dev/null; then
        wget -qO /tmp/wstunnel.tar.gz "https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER}_linux_amd64.tar.gz"
        tar -xzf /tmp/wstunnel.tar.gz -C /tmp/
        mv /tmp/wstunnel /usr/local/bin/wstunnel
        chmod +x /usr/local/bin/wstunnel
        rm -f /tmp/wstunnel.tar.gz
    fi

    cat <<EOF > /etc/systemd/system/wstunnel.service
[Unit]
Description=wstunnel service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/wstunnel server ws://0.0.0.0:${WSTUNNEL_PORT} --restrict-to 127.0.0.1:${PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wstunnel.service
    if ! systemctl restart wstunnel.service; then
        echo -e "${RED}Error: Failed to start wstunnel service.${NC}"
        journalctl -xeu wstunnel.service | tail -n 20
        systemctl status wstunnel.service --no-pager
        exit 1
    fi
fi

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
