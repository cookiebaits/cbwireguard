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

# Helper function to safely populate an array with existing backup files
get_backups() {
    shopt -s nullglob
    BACKUP_FILES=(easy-wireguard-server-*-backup.tar.gz)
    shopt -u nullglob
}

create_backup() {
    if [[ ! -d "/etc/wireguard" ]]; then
        echo -e "${RED}Error: /etc/wireguard directory not found. Is the server installed?${NC}"
        return
    fi
    
    CURRENT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    HOST_NAME=$(hostname -s)
    BACKUP_FILE="easy-wireguard-server-${CURRENT_DATE}-${HOST_NAME}-backup.tar.gz"

    echo -e "\n${GREEN}Creating backup...${NC}"
    if tar -czf "$BACKUP_FILE" -C /etc wireguard &> /dev/null; then
        chmod 600 "$BACKUP_FILE"
        echo -e "${PURPLE}Backup successfully created: ${BACKUP_FILE}${NC}"
        echo -e "${RED}WARNING: This archive contains unencrypted private keys. Delete it when finished!${NC}"
    else
        echo -e "${RED}Error: Backup creation failed.${NC}"
    fi
}

list_backups() {
    get_backups
    if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
        echo -e "\n${RED}No backup files found in the current directory.${NC}"
        return 1 # Return false so other functions know to stop
    fi
    
    echo -e "\n${GREEN}Available Backup Archives:${NC}"
    for i in "${!BACKUP_FILES[@]}"; do
        size=$(du -h "${BACKUP_FILES[$i]}" | cut -f1)
        echo -e "${PURPLE}[$i]${NC} ${BACKUP_FILES[$i]} (${size})"
    done
    return 0 # Return true
}

restore_backup() {
    if ! list_backups; then return; fi
    
    echo -en "\n${GREEN}Enter the number of the backup to restore (or press Enter to cancel): ${NC}"
    read -r index
    if [[ -z "$index" ]]; then return; fi
    
    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 0 ] && [ "$index" -lt "${#BACKUP_FILES[@]}" ]; then
        TARGET="${BACKUP_FILES[$index]}"
        
        echo -en "${RED}WARNING: This will OVERWRITE your current live configuration with '$TARGET'. Proceed? [y/N]: ${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Restoring $TARGET...${NC}"
            
            TEMP_DIR=$(mktemp -d)
            chmod 700 "$TEMP_DIR"
            tar -xzf "$TARGET" -C "$TEMP_DIR"
            
            mkdir -p /etc/wireguard
            if [[ -d "$TEMP_DIR/wireguard" ]]; then
                cp -a "$TEMP_DIR/wireguard/"* /etc/wireguard/
            elif [[ -d "$TEMP_DIR/etc/wireguard" ]]; then
                cp -a "$TEMP_DIR/etc/wireguard/"* /etc/wireguard/
            fi
            
            # Secure everything
            chmod 700 /etc/wireguard
            find /etc/wireguard -type f -exec chmod 600 {} +
            [[ -d "/etc/wireguard/clients" ]] && chmod 700 /etc/wireguard/clients
            rm -rf "$TEMP_DIR"
            
            echo -e "${GREEN}Restarting WireGuard service...${NC}"
            systemctl restart wg-quick@wg0.service
            echo -e "${PURPLE}Backup successfully restored!${NC}"
        else
            echo -e "${GREEN}Restoration aborted.${NC}"
        fi
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

delete_backup() {
    if ! list_backups; then return; fi
    
    echo -en "\n${RED}Enter the number of the backup to DELETE (or press Enter to cancel): ${NC}"
    read -r index
    if [[ -z "$index" ]]; then return; fi
    
    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 0 ] && [ "$index" -lt "${#BACKUP_FILES[@]}" ]; then
        TARGET="${BACKUP_FILES[$index]}"
        
        echo -en "${RED}Are you absolutely sure you want to PERMANENTLY DESTROY '$TARGET'? [y/N]: ${NC}"
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$TARGET"
            echo -e "${PURPLE}Successfully deleted: $TARGET${NC}"
        else
            echo -e "${GREEN}Deletion aborted.${NC}"
        fi
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

# The Sub-Menu Loop
while true; do
    echo -e "\n${GREEN}--- Backup & Restore Manager ---${NC}"
    echo "[1] Create a new backup"
    echo "[2] Restore an existing backup"
    echo "[3] List existing backup files"
    echo "${RED}[4] Delete a backup file${NC}"
    echo "[0] Return to Main Menu"
    echo -en "${GREEN}Select an option [0-4]: ${NC}"
    read -r OPTION

    case "$OPTION" in
        1) create_backup ;;
        2) restore_backup ;;
        3) list_backups || true ;; # || true prevents the script from crashing if the list is empty
        4) delete_backup ;;
        0) break ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
done
