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
    BACKUP_FILES=(easy-wireguard-server-*-backup.tar.gz.enc)
    shopt -u nullglob
}

create_backup() {
    if [[ -d "/etc/amnezia/amneziawg" ]]; then
        BACKUP_TARGET="amnezia/amneziawg"
    elif [[ -d "/etc/wireguard" ]]; then
        BACKUP_TARGET="wireguard"
    else
        echo -e "${RED}Error: VPN configuration directory not found. Is the server installed?${NC}"
        return
    fi

    CURRENT_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    HOST_NAME=$(hostname -s)
    BACKUP_FILE="easy-${BACKUP_TARGET}-server-${CURRENT_DATE}-${HOST_NAME}-backup.tar.gz.enc"

    echo -en "${GREEN}Enter encryption password for backup: ${NC}"
    read -rs BACKUP_PASS
    echo

    echo -e "\n${GREEN}Creating encrypted backup...${NC}"
    if tar -cz -C /etc "$BACKUP_TARGET" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:$BACKUP_PASS" -out "$BACKUP_FILE"; then
        chmod 600 "$BACKUP_FILE"
        echo -e "${PURPLE}Backup successfully created and encrypted: ${BACKUP_FILE}${NC}"
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
            echo -en "${GREEN}Enter decryption password for backup: ${NC}"
            read -rs BACKUP_PASS
            echo

            echo -e "${GREEN}Restoring $TARGET...${NC}"

            TEMP_DIR=$(mktemp -d)
            chmod 700 "$TEMP_DIR"

            if openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 -pass "pass:$BACKUP_PASS" -in "$TARGET" | tar -xz -C "$TEMP_DIR"; then
                if [[ -d "$TEMP_DIR/amnezia/amneziawg" || -d "$TEMP_DIR/etc/amnezia/amneziawg" || -d "$TEMP_DIR/amneziawg" ]]; then
                    mkdir -p /etc/amnezia/amneziawg
                    if [[ -d "$TEMP_DIR/amnezia/amneziawg" ]]; then
                        cp -a "$TEMP_DIR/amnezia/amneziawg/"* /etc/amnezia/amneziawg/
                    elif [[ -d "$TEMP_DIR/etc/amnezia/amneziawg" ]]; then
                        cp -a "$TEMP_DIR/etc/amnezia/amneziawg/"* /etc/amnezia/amneziawg/
                    elif [[ -d "$TEMP_DIR/amneziawg" ]]; then
                        cp -a "$TEMP_DIR/amneziawg/"* /etc/amnezia/amneziawg/
                    fi
                    chmod 700 /etc/amnezia/amneziawg
                    find /etc/amnezia/amneziawg -type f -exec chmod 600 {} +
                    [[ -d "/etc/amnezia/amneziawg/clients" ]] && chmod 700 /etc/amnezia/amneziawg/clients
                    echo -e "${GREEN}Restarting AmneziaWG service...${NC}"
                    systemctl restart awg-quick@awg0.service || true
                else
                    mkdir -p /etc/wireguard
                    if [[ -d "$TEMP_DIR/wireguard" ]]; then
                        cp -a "$TEMP_DIR/wireguard/"* /etc/wireguard/
                    elif [[ -d "$TEMP_DIR/etc/wireguard" ]]; then
                        cp -a "$TEMP_DIR/etc/wireguard/"* /etc/wireguard/
                    fi
                    chmod 700 /etc/wireguard
                    find /etc/wireguard -type f -exec chmod 600 {} +
                    [[ -d "/etc/wireguard/clients" ]] && chmod 700 /etc/wireguard/clients
                    echo -e "${GREEN}Restarting WireGuard service...${NC}"
                    systemctl restart wg-quick@wg0.service || true
                fi

                rm -rf "$TEMP_DIR"
                echo -e "${PURPLE}Backup successfully restored!${NC}"
            else
                echo -e "${RED}Error: Restoration failed. Incorrect password?${NC}"
                rm -rf "$TEMP_DIR"
            fi
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
    echo -e "\n${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} ${GREEN}Backup & Restore Manager${NC}                                   ${PURPLE}║${NC}"
    echo -e "${PURPLE}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${PURPLE}║${NC} [1] Create a new backup                                    ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} [2] Restore an existing backup                             ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} [3] List existing backup files                             ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} ${RED}[4] Delete a backup file${NC}                                   ${PURPLE}║${NC}"
    echo -e "${PURPLE}║${NC} [0] Return to Main Menu                                    ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
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
