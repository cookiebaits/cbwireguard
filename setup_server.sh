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
ORANGE='\033[0;33m'
NC='\033[0m'

SETTINGS_FILE="/root/easy_wireguard/settings.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# P3: Default MTU from settings or 1420
MTU=${DEFAULT_MTU:-1420}

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
        if [[ "$PORT" == "443" ]] && docker ps -q -f name=dokploy-traefik >/dev/null 2>&1; then
            echo -e "${ORANGE}dokploy-traefik detected on port 443. Configuring internal routing...${NC}"
            INTERNAL_PORT="51820"
            break
        else
            echo -e "${RED}Error: Port ${PORT} is already in use by another process!${NC}"
            echo -en "${GREEN}Please enter another port or select from the menu above: ${NC}"
            read -r input_VPN_PORT
        fi
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

echo -en "${GREEN}Do you want to add a domain exemption for split tunneling? Enter domain or leave blank to skip: ${NC}"
read -r input_BYPASS
if [[ -n "$input_BYPASS" ]]; then
    HAS_BYPASS=true
    BYPASS_DOMAIN="$input_BYPASS"
else
    HAS_BYPASS=false
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
# Patch everything to latest version for security
apt-get install -y wireguard ufw dnsutils qrencode iptables iproute2 jq python3 golang git make

echo -e "${GREEN}Compiling stealth wireguard-go...${NC}"
TEMP_DIR=$(mktemp -d)
git clone https://git.zx2c4.com/wireguard-go "$TEMP_DIR"
(
    cd "$TEMP_DIR"
    if [[ -f device/messages.go ]]; then
        sed -i -E 's/messageInitiationType\s*=\s*1/messageInitiationType = 5/i' device/messages.go
        sed -i -E 's/messageResponseType\s*=\s*2/messageResponseType = 6/i' device/messages.go
        sed -i -E 's/messageCookieReplyType\s*=\s*3/messageCookieReplyType = 7/i' device/messages.go
        sed -i -E 's/messageTransportType\s*=\s*4/messageTransportType = 8/i' device/messages.go
    elif [[ -f device/noise-protocol.go ]]; then
        sed -i -E 's/MessageInitiationType\s*=\s*1/MessageInitiationType = 5/i' device/noise-protocol.go
        sed -i -E 's/MessageResponseType\s*=\s*2/MessageResponseType = 6/i' device/noise-protocol.go
        sed -i -E 's/MessageCookieReplyType\s*=\s*3/MessageCookieReplyType = 7/i' device/noise-protocol.go
        sed -i -E 's/MessageTransportType\s*=\s*4/MessageTransportType = 8/i' device/noise-protocol.go
    fi
    make
    mv wireguard-go /usr/local/bin/wireguard-go
)
rm -rf "$TEMP_DIR"

mkdir -p /etc/systemd/system/wg-quick@wg0.service.d/
cat <<EOF_SYSTEMD > /etc/systemd/system/wg-quick@wg0.service.d/override.conf
[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
EOF_SYSTEMD
systemctl daemon-reload

echo -e "${GREEN}Generating secure encryption keys...${NC}"
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if [[ "$HAS_BYPASS" == "true" ]]; then
    echo "$BYPASS_DOMAIN" >> /etc/wireguard/bypass_domains.txt
fi

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
ListenPort = ${INTERNAL_PORT:-$PORT}
MTU = $MTU
SaveConfig = false

PostUp = ufw route allow in on wg0 out on $NETWORK_DEVICE
PostUp = iptables -t nat -A POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
PostUp = iptables -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A POSTROUTING -o $NETWORK_DEVICE -j TTL --ttl-set 64
PostUp = ip6tables -A FORWARD -i wg0 -j REJECT
PostUp = ip6tables -A OUTPUT -o wg0 -j REJECT
PreDown = ufw route delete allow in on wg0 out on $NETWORK_DEVICE
PreDown = iptables -t nat -D POSTROUTING -o $NETWORK_DEVICE -j MASQUERADE
PreDown = iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown = iptables -t mangle -D POSTROUTING -o $NETWORK_DEVICE -j TTL --ttl-set 64
PreDown = ip6tables -D FORWARD -i wg0 -j REJECT
PreDown = ip6tables -D OUTPUT -o wg0 -j REJECT
EOF

chmod 600 /etc/wireguard/wg0.conf

echo -e "${GREEN}Optimizing Network & Hardening Security...${NC}"
set_sysctl "net.ipv4.ip_forward" "1"
set_sysctl "net.core.default_qdisc" "fq"
set_sysctl "net.ipv4.tcp_congestion_control" "bbr"
set_sysctl "net.ipv4.tcp_mtu_probing" "1"
set_sysctl "net.core.rmem_max" "16777216"
set_sysctl "net.core.wmem_max" "16777216"
set_sysctl "net.core.rmem_default" "262144"
set_sysctl "net.core.wmem_default" "262144"
set_sysctl "net.core.netdev_max_backlog" "10000"
set_sysctl "net.ipv4.tcp_rmem" "4096 87380 16777216"
set_sysctl "net.ipv4.tcp_wmem" "4096 65536 16777216"
# Security Hardening
set_sysctl "net.ipv4.conf.all.rp_filter" "1"
set_sysctl "net.ipv4.conf.default.rp_filter" "1"
set_sysctl "net.ipv4.conf.all.accept_redirects" "0"
set_sysctl "net.ipv4.conf.all.send_redirects" "0"
set_sysctl "net.ipv4.conf.all.accept_source_route" "0"
# Disable IPv6 routing only on the interface where applicable, keep host IPv6 enabled
set_sysctl "net.ipv6.conf.all.disable_ipv6" "0"
set_sysctl "net.ipv6.conf.default.disable_ipv6" "0"
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

if [[ "$HAS_BYPASS" == "true" && -f /root/easy_wireguard/domain_bypass.sh ]]; then
    echo -e "${GREEN}Calculating Split Tunneling AllowedIPs...${NC}"
    # Execute update_routes function or similar from domain_bypass.sh non-interactively
    bash /root/easy_wireguard/domain_bypass.sh --cli-update || true
fi

if [[ -n "${INTERNAL_PORT:-}" ]]; then
    echo -e "${GREEN}Configuring Dokploy Traefik proxy for port 443 -> $INTERNAL_PORT...${NC}"
    TRAEFIK_CONTAINER=$(docker ps -q -f name=dokploy-traefik | head -n 1)
    TRAEFIK_NETWORK=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$TRAEFIK_CONTAINER" | jq -r 'keys[0]')
    GATEWAY_IP=$(docker network inspect "$TRAEFIK_NETWORK" -f '{{(index .IPAM.Config 0).Gateway}}')
    # Dynamically verify Dokploy Traefik is exposing UDP port 443 via standard Docker metadata
    HAS_UDP_443=$(docker inspect "$TRAEFIK_CONTAINER" | jq -r '.[0].NetworkSettings.Ports | to_entries[] | select(.value != null and .value[0].HostPort == "443" and (.key | endswith("/udp"))) | .key')
    if [[ -z "$HAS_UDP_443" ]]; then
        echo -e "${RED}Error: dokploy-traefik is not exposing UDP port 443. Aborting dokploy integration.${NC}"
        exit 1
    fi
    # Remove existing bridge container if it exists
    docker rm -f wg-dokploy-bridge >/dev/null 2>&1 || true
    # Start socat bridge container
    # Omitting traefik.udp.routers.wg.entrypoints forces Traefik to attach to all available UDP entrypoints natively.
    docker run -d --name wg-dokploy-bridge --network "$TRAEFIK_NETWORK" --restart always \
        -l "traefik.enable=true" \
        -l "traefik.udp.routers.wg.service=wg" \
        -l "traefik.udp.services.wg.loadbalancer.server.port=$INTERNAL_PORT" \
        alpine/socat udp-listen:"$INTERNAL_PORT",fork,reuseaddr udp-connect:"$GATEWAY_IP":"$INTERNAL_PORT" >/dev/null 2>&1
    echo -e "${GREEN}Proxy container started!${NC}"
fi

echo -e "\n${PURPLE}======================================================${NC}"
echo -e "${GREEN}Server Setup Complete!${NC}"
echo -e "${PURPLE}Your WireGuard server is running on port: ${PORT}${NC}"
echo -e "${PURPLE}======================================================${NC}\n"
