#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
NC='\033[0m'

# P2: Security Check - Require root access to remove core system packages
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 WireGuard Server Removal Utility${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

clear
print_banner
echo -e "${RED}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${RED}│   WARNING: This will completely REMOVE WireGuard!            │${NC}"
echo -e "${RED}│   All configurations, keys, and client access destroyed.      │${NC}"
echo -e "${RED}└──────────────────────────────────────────────────────────────┘${NC}"
echo -en "${PURPLE}Are you absolutely sure you want to proceed? [y/N]: ${NC}"
read -r FLAG

# Default to "No" for safety. Only proceed if user explicitly types y or Y.
if [[ "$FLAG" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Starting removal process...${NC}"

    # 1. Safely shut down the service to prevent network hanging
    echo -e "${GREEN}Stopping WireGuard services...${NC}"
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

    # 2. Revert the IP forwarding vulnerability
    echo -e "${GREEN}Reverting IP forwarding settings...${NC}"
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    # Suppress output of sysctl to keep the terminal clean
    sysctl -p &> /dev/null

    # 3. Remove firewall rules and proxy containers for configured ports
    echo -e "${GREEN}Cleaning up firewall rules and proxy containers...${NC}"
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        extracted_ports=$(grep -E '^(ListenPort|# ExternalPort)' /etc/wireguard/wg0.conf | awk -F'=' '{print $2}' | tr -d ' ' || true)
        for p in $extracted_ports; do
            if [[ -n "$p" ]]; then
                ufw delete allow "$p/udp" >/dev/null 2>&1 || true
                iptables -D INPUT -p udp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
                echo -e "${GREEN}- Removed firewall rule for port: $p/udp${NC}"
            fi
        done
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker ps -a --format '{{.Names}}' | grep -Eq "^wg-dokploy-bridge$"; then
            docker rm -f wg-dokploy-bridge >/dev/null 2>&1 || true
            echo -e "${GREEN}- Removed docker container: wg-dokploy-bridge${NC}"
        fi
    fi

    # 4. Completely wipe the packages
    echo -e "${GREEN}Uninstalling WireGuard...${NC}"
    # Purge destroys the app configurations; autoremove cleans up unused dependencies
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
    apt-get purge -y wireguard wireguard-tools wireguard-dkms wireguard-go qrencode >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    # 5. Destroy the sensitive keys and configuration directory
    echo -e "${GREEN}Deleting WireGuard keys and config directories...${NC}"
    rm -rf /etc/wireguard

    echo -e "${PURPLE}Done! WireGuard has been completely removed from this system.${NC}"
else
    echo -e "${GREEN}Removal aborted. Your server was not modified.${NC}"
fi
