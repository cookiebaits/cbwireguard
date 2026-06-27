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

echo -e "${GREEN}Choose port for VPN (Recommended Stealthy Ports):${NC}"
echo "[1] 443 (HTTPS/QUIC - Most Stealthy)"
echo "[2] 53 (DNS)"
echo "[3] 123 (NTP)"
echo "[4] 1194 (OpenVPN UDP)"
echo "[5] 500 (ISAKMP)"
echo "[6] 4500 (IPsec NAT-T)"
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


echo -e "${GREEN}Choose port for Xray VLESS (Recommended Cloudflare/CDN Ports):${NC}"
echo "[1] 8880 (HTTP/CDN - Default)"
echo "[2] 443 (HTTPS - Best for TLS)"
echo "[3] 8443 (Alt-HTTPS)"
echo "[4] 2053 (Alt-HTTPS)"
echo "[5] 2083 (Alt-HTTPS)"
echo "[6] 2087 (Alt-HTTPS)"
echo -en "${PURPLE}Select option [1-6] or enter custom port [Default 8880]: ${NC}"
read -r input_VLESS_PORT

while true; do
    case "$input_VLESS_PORT" in
        1) XRAY_VLESS_PORT="8880" ;;
        2) XRAY_VLESS_PORT="443" ;;
        3) XRAY_VLESS_PORT="8443" ;;
        4) XRAY_VLESS_PORT="2053" ;;
        5) XRAY_VLESS_PORT="2083" ;;
        6) XRAY_VLESS_PORT="2087" ;;
        "") XRAY_VLESS_PORT="8880" ;;
        *)
            if [[ "$input_VLESS_PORT" =~ ^[0-9]+$ ]]; then
                XRAY_VLESS_PORT="$input_VLESS_PORT"
            else
                XRAY_VLESS_PORT="8880"
                echo -e "${RED}Invalid input. Defaulting to 8880.${NC}"
            fi
            ;;
    esac

    if check_port_usage "$XRAY_VLESS_PORT"; then
        echo -e "${RED}Error: Port ${XRAY_VLESS_PORT} is already in use by another process!${NC}"
        echo -en "${GREEN}Please enter another port or select from the menu above: ${NC}"
        read -r input_VLESS_PORT
    elif [[ "$XRAY_VLESS_PORT" == "$PORT" ]]; then
        echo -e "${RED}Error: Port ${XRAY_VLESS_PORT} is already selected for WireGuard!${NC}"
        echo -en "${GREEN}Please enter a different port for VLESS: ${NC}"
        read -r input_VLESS_PORT
    else
        break
    fi
done

export XRAY_VLESS_PORT

mkdir -p /root/easy_wireguard
echo "XRAY_VLESS_PORT=${XRAY_VLESS_PORT}" >> /root/easy_wireguard/settings.conf

echo -en "${GREEN}Enter MTU, leave blank for default [${MTU}]: ${NC}"
read -r input_MTU
if [[ -n "$input_MTU" ]]; then
    MTU="$input_MTU"
fi

SERVER_PRIVATE_IP="10.18.0.1"

echo -e "${GREEN}Installing WireGuard and required dependencies...${NC}"
# Scan for existing WireGuard services
if systemctl list-units --type=service | grep -q "wg-quick@"; then
    echo -e "${PURPLE}Existing WireGuard service detected. Bringing it down for clean installation...${NC}"
    for service in $(systemctl list-units --type=service | grep "wg-quick@" | awk '{print $1}'); do
        systemctl stop "$service" || true
        systemctl disable "$service" || true
    done
    # We do not fully uninstall packages here as we are immediately reinstalling/reconfiguring,
    # but we ensure the service is completely stopped.
fi

apt-get update -y
apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2 jq

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
PostUp = iptables -t nat -A POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
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
if ! systemctl restart wg-quick@wg0.service; then
    echo -e "${RED}Error: Failed to start WireGuard service.${NC}"
    echo -e "${PURPLE}--- Diagnostic Logs ---${NC}"
    journalctl -xeu wg-quick@wg0.service | tail -n 20
    echo -e "${PURPLE}-----------------------${NC}"
    systemctl status wg-quick@wg0.service --no-pager
    exit 1
fi
systemctl status --no-pager -l wg-quick@wg0.service

echo -e "${GREEN}Deploying Xray Stealth Protocol...${NC}"
if [[ ! -f "./Xray-Installer.sh" ]]; then
    echo -e "${PURPLE}Fetching Xray-Installer.sh from repository...${NC}"
    curl -sSfL "${GIT_REPO:-https://raw.githubusercontent.com/cookiebaits/cbwireguard/main}/Xray-Installer.sh" -o ./Xray-Installer.sh || true
    if [[ ! -f "./Xray-Installer.sh" ]]; then
        echo -e "${RED}Failed to fetch Xray-Installer.sh. Please place it in the directory manually.${NC}"
        return 1 2>/dev/null || true
    fi
    chmod +x ./Xray-Installer.sh
fi
./Xray-Installer.sh --install

echo -en "${GREEN}Install wstunnel (WireGuard over TLS) for stealth? [y/N]: ${NC}"
read -r install_wstunnel
if [[ "$install_wstunnel" =~ ^[Yy]$ ]]; then
    echo -en "${GREEN}Choose a port for wstunnel [Default 4433]: ${NC}"
    read -r WSTUNNEL_PORT
    WSTUNNEL_PORT=${WSTUNNEL_PORT:-4433}

    echo "WSTUNNEL_PORT=${WSTUNNEL_PORT}" >> /root/easy_wireguard/settings.conf

    echo -e "${GREEN}Downloading and installing wstunnel...${NC}"
    curl -sSL "https://github.com/erebe/wstunnel/releases/download/v10.5.5/wstunnel_10.5.5_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin wstunnel
    chmod +x /usr/local/bin/wstunnel

    cat <<EOF > /etc/systemd/system/wstunnel.service
[Unit]
Description=wstunnel server
After=network.target

[Service]
ExecStart=/usr/local/bin/wstunnel server wss://[::]:${WSTUNNEL_PORT} --restrict-to 127.0.0.1:${PORT}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wstunnel
    systemctl restart wstunnel

    ufw allow "$WSTUNNEL_PORT/tcp"
fi

echo -en "${GREEN}Enable default Split Tunneling for streaming services (Netflix, Hulu, Disney+, etc.)? [y/N]: ${NC}"
read -r split_tunnel_choice
if [[ "$split_tunnel_choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring default bypass domains...${NC}"
    cat <<EOF > /etc/wireguard/bypass_domains.txt
netflix.com
hulu.com
disneyplus.com
hbomax.com
max.com
EOF
    chmod 600 /etc/wireguard/bypass_domains.txt
    if [[ -f "./domain_bypass.sh" ]]; then
        echo -e "${GREEN}Applying routes...${NC}"
        ./domain_bypass.sh << 'EOF_INPUT' || true
4
0
EOF_INPUT
    fi
fi

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your WireGuard server is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"
