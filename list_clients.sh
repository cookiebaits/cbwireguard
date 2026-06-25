#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

echo -e "${GREEN}Currently Configured Clients:${NC}"
echo -e "${PURPLE}-----------------------------------${NC}"

# Check if the directory has .conf files
if ls /etc/wireguard/clients/*.conf 1> /dev/null 2>&1; then
    # Loop through and print just the base names of the files
    for conf_file in /etc/wireguard/clients/*.conf; do
        basename "$conf_file" .conf
    done
else
    echo -e "${RED}No clients have been configured yet.${NC}"
fi
echo -e "${PURPLE}-----------------------------------${NC}"
