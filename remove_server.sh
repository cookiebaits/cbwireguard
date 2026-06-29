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

echo -e "${RED}================================================================${NC}"
echo -e "${RED}WARNING: This will completely REMOVE WireGuard from this system!${NC}"
echo -e "${RED}All configurations, keys, and client access will be destroyed.${NC}"
echo -e "${RED}================================================================${NC}"
echo -en "${PURPLE}Are you absolutely sure you want to proceed? [y/N]: ${NC}"
read -r FLAG

# Default to "No" for safety. Only proceed if user explicitly types y or Y.
if [[ "$FLAG" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Starting removal process...${NC}"

    # 1. Safely shut down the service to prevent network hanging
    if systemctl is-active --quiet wg-quick@wg0.service; then
        echo -e "${GREEN}Stopping WireGuard service...${NC}"
        systemctl stop wg-quick@wg0.service
        systemctl disable wg-quick@wg0.service
    fi

    # 2. Revert the IP forwarding vulnerability
    echo -e "${GREEN}Reverting IP forwarding settings...${NC}"
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    # Suppress output of sysctl to keep the terminal clean
    sysctl -p &> /dev/null

    # 3. Completely wipe the packages
    echo -e "${GREEN}Uninstalling WireGuard...${NC}"
    # Purge destroys the app configurations; autoremove cleans up unused dependencies
    apt-get purge -y wireguard wireguard-tools
    apt-get autoremove -y

    # 4. Destroy the sensitive keys and configuration directory
    echo -e "${GREEN}Deleting WireGuard keys and config directories...${NC}"
    rm -rf /etc/wireguard

    echo -e "${PURPLE}Done! WireGuard has been completely removed from this system.${NC}"
else
    echo -e "${GREEN}Removal aborted. Your server was not modified.${NC}"
fi
