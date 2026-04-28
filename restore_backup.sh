#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

# P2: Security Check - Require root access to write to /etc/wireguard
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

echo -e "${GREEN}Looking for the most recent backup file...${NC}"

# Find the newest backup file in the current directory, ignoring errors if none exist
BACKUP_FILE=$(ls -t easy-wireguard-server-*-backup.tar.gz 2>/dev/null | head -n 1 || true)

if [[ -z "$BACKUP_FILE" ]]; then
    echo -e "${RED}Error: No backup files found in this directory.${NC}"
    exit 1
fi

echo -en "${PURPLE}Found backup: ${BACKUP_FILE}. Restore this file? [y/N]: ${NC}"
read -r FLAG

if [[ "$FLAG" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Preparing secure restoration environment...${NC}"

    # Create a secure, isolated temporary directory
    TEMP_DIR=$(mktemp -d)
    chmod 700 "$TEMP_DIR"

    # Extract the archive securely into the temp directory
    tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"

    # Ensure the destination directory exists
    mkdir -p /etc/wireguard

    # Handle both new (relative) and old (absolute) backup path structures safely
    echo -e "${GREEN}Restoring configuration files...${NC}"
    if [[ -d "$TEMP_DIR/wireguard" ]]; then
        cp -a "$TEMP_DIR/wireguard/"* /etc/wireguard/
    elif [[ -d "$TEMP_DIR/etc/wireguard" ]]; then
        cp -a "$TEMP_DIR/etc/wireguard/"* /etc/wireguard/
    else
        echo -e "${RED}Error: Archive does not contain a recognizable WireGuard backup format.${NC}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # P2: CRITICAL SECURITY - Re-enforce strict permissions on the restored files
    echo -e "${GREEN}Locking down file permissions...${NC}"
    chmod 700 /etc/wireguard
    # Set all files inside to read-write for root only
    find /etc/wireguard -type f -exec chmod 600 {} +
    # Ensure the clients folder exists and is secure
    if [[ -d "/etc/wireguard/clients" ]]; then
        chmod 700 /etc/wireguard/clients
    fi

    # Clean up the temporary folder immediately
    rm -rf "$TEMP_DIR"

    # P3: Restart the service cleanly via systemd rather than wg-quick
    # (Restoring a backup often changes the server private key, so a full restart is mandatory here)
    echo -e "${GREEN}Restarting WireGuard service to apply changes...${NC}"
    systemctl restart wg-quick@wg0.service

    echo -e "${PURPLE}Backup successfully restored!${NC}"
else
    echo -e "${GREEN}Restoration aborted.${NC}"
fi
