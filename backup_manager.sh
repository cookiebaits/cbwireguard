#!/bin/bash

# Cookie's Easy WireGuard Manager - Backup & Restore
# AES-256 encrypted backups

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

function print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      $1      ${NC}"
    echo -e "${CYAN}================================================${NC}"
}

function backup_config() {
    print_header "WireGuard Backup"
    if [[ ! -d "/etc/wireguard" ]]; then
        echo -e "${RED}WireGuard configuration directory not found!${NC}"
        return
    fi
    
    BACKUP_FILE="/root/wireguard_backup_$(date +%Y%m%d_%H%M%S).tar.gz.enc"
    
    echo -e "${ORANGE}You will be prompted to enter a password to encrypt the backup.${NC}"
    echo -e "${ORANGE}DO NOT LOSE THIS PASSWORD. You will need it to restore.${NC}"
    echo ""
    
    tar -czf - /etc/wireguard 2>/dev/null | openssl enc -aes-256-cbc -salt -pbkdf2 -out "$BACKUP_FILE"
    
    if [[ $? -eq 0 && -f "$BACKUP_FILE" ]]; then
        echo -e "\n${GREEN}Backup completed successfully!${NC}"
        echo -e "Saved to: ${CYAN}$BACKUP_FILE${NC}"
    else
        echo -e "\n${RED}Backup failed!${NC}"
    fi
    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function restore_config() {
    print_header "WireGuard Restore"
    
    BACKUPS=($(ls /root/wireguard_backup_*.tar.gz.enc 2>/dev/null))
    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        echo -e "${RED}No encrypted backups found in /root/!${NC}"
        echo ""
        read -n1 -r -p "Press any key to continue..."
        return
    fi
    
    echo "Available Backups:"
    for i in "${!BACKUPS[@]}"; do
        echo "   $((i+1))) $(basename "${BACKUPS[$i]}")"
    done
    echo "   0) Cancel"
    echo ""
    
    until [[ ${BACKUP_OPTION} =~ ^[0-9]+$ ]] && [ "${BACKUP_OPTION}" -ge 0 ] && [ "${BACKUP_OPTION}" -le ${#BACKUPS[@]} ]; do
        read -rp "Select a backup to restore: " BACKUP_OPTION
    done
    
    if [[ "$BACKUP_OPTION" -eq 0 ]]; then
        return
    fi
    
    SELECTED_BACKUP="${BACKUPS[$((BACKUP_OPTION-1))]}"
    
    echo -e "\n${ORANGE}WARNING: This will overwrite your current WireGuard configuration!${NC}"
    read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        return
    fi
    
    echo -e "\n${ORANGE}Please enter the password used to encrypt this backup:${NC}"
    
    # Restore the backup to a temporary directory first to verify password
    mkdir -p /tmp/wg_restore_test
    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -in "$SELECTED_BACKUP" | tar -xzf - -C /tmp/wg_restore_test 2>/dev/null; then
        echo -e "${GREEN}Password verified successfully. Restoring configuration...${NC}"
        
        # Stop WireGuard if running
        if systemctl is-active --quiet "wg-quick@wg0"; then
            systemctl stop "wg-quick@wg0"
        fi
        
        # Backup the current config just in case
        if [[ -d "/etc/wireguard" ]]; then
            mv /etc/wireguard /etc/wireguard.old.$(date +%s)
        fi
        
        # Move the restored config into place
        mv /tmp/wg_restore_test/etc/wireguard /etc/
        rm -rf /tmp/wg_restore_test
        
        # Fix permissions
        chmod 600 -R /etc/wireguard/
        
        # Start WireGuard
        systemctl start "wg-quick@wg0"
        
        echo -e "\n${GREEN}Restore completed successfully!${NC}"
    else
        echo -e "\n${RED}Incorrect password or corrupted backup! Restore failed.${NC}"
        rm -rf /tmp/wg_restore_test
    fi
    
    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function manage_backups() {
    while true; do
        clear
        print_header "Backup & Restore Manager"
        echo "   1) Create Encrypted Backup"
        echo "   2) Restore Encrypted Backup"
        echo "   3) Exit to Main Menu"
        echo ""
        
        read -rp "Select an option [1-3]: " OPTION
        case "$OPTION" in
            1) backup_config ;;
            2) restore_config ;;
            3) break ;;
        esac
    done
}

# Allow running as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
    manage_backups
fi
