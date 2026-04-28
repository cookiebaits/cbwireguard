#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# P2: Security Check - Require root access to read private configurations
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

echo -en "${GREEN}Enter device name to show QR code: ${NC}"
read -r raw_device_name

# Sanitize input to prevent path traversal or broken filenames
DEVICE_NAME=$(echo "$raw_device_name" | tr -cd '[:alnum:]_-')

if [[ -z "$DEVICE_NAME" ]]; then
    echo -e "${RED}Error: Invalid device name.${NC}"
    exit 1
fi

CLIENT_CONF="/etc/wireguard/clients/${DEVICE_NAME}.conf"

# Ensure the configuration file actually exists before trying to read it
if [[ ! -f "$CLIENT_CONF" ]]; then
    echo -e "${RED}Error: Configuration file for '${DEVICE_NAME}' not found.${NC}"
    echo -e "${PURPLE}Checked path: ${CLIENT_CONF}${NC}"
    exit 1
fi

# P3: Optimization - Only run the apt installer if qrencode is entirely missing
if ! command -v qrencode &> /dev/null; then
    echo -e "${GREEN}Installing qrencode...${NC}"
    # Suppress apt output to keep the terminal clean
    apt-get update -y > /dev/null && apt-get install -y qrencode > /dev/null
fi

echo -e "\n${GREEN}Generating QR Code for ${DEVICE_NAME}...${NC}\n"

# Use ansiutf8 instead of utf8 for vastly superior rendering in modern SSH terminals
qrencode -t ansiutf8 < "$CLIENT_CONF"

echo -e "\n${PURPLE}^^^ Scan this QR-code with the WireGuard App ^^^${NC}\n"
