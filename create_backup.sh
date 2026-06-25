#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# P2: Security Check - Require root access to read private keys
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# Ensure WireGuard directory actually exists before trying to back it up
if [[ ! -d "/etc/wireguard" ]]; then
    echo -e "${RED}Error: /etc/wireguard directory not found. Is the server installed?${NC}"
    exit 1
fi

echo -e "${GREEN}Preparing backup of WireGuard configurations...${NC}"

# Generate filename variables (added Hours-Mins-Secs to prevent overwriting same-day backups)
CURRENT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
HOST_NAME=$(hostname -s)
BACKUP_FILE="easy-wireguard-server-${CURRENT_DATE}-${HOST_NAME}-backup.tar.gz"

# Create the backup archive
# We use '-C /etc wireguard' so it archives the folder neatly without the absolute '/etc/' path
if tar -czf "$BACKUP_FILE" -C /etc wireguard &> /dev/null; then
    # P2: CRITICAL SECURITY - Lock down the backup file so only root can read it
    chmod 600 "$BACKUP_FILE"
    
    echo -e "${PURPLE}Backup successfully created!${NC}"
    echo -e "${GREEN}Saved to: ${PWD}/${BACKUP_FILE}${NC}"
    echo -e "${RED}WARNING: This archive contains unencrypted private keys. Keep it secure!${NC}"
else
    echo -e "${RED}Error: Backup creation failed.${NC}"
    exit 1
fi
