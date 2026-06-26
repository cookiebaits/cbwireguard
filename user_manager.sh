#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

CLIENT_DIR="/etc/wireguard/clients"
SETTINGS_FILE="/root/easy_wireguard/settings.conf"

if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# P3: Master password for config encryption
# For simplicity in this automated script, we'll use a hidden file or prompt
# Ideally, the user should provide this once per session.
get_master_pass() {
    if [[ -z "${MASTER_PASS:-}" ]]; then
        echo -en "${GREEN}Enter Decryption password: ${NC}"
        read -rs MASTER_PASS
        echo
        export MASTER_PASS
    fi
}

encrypt_file() {
    local file="$1"
    get_master_pass
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:$MASTER_PASS" -in "$file" -out "${file}.enc"
    rm -f "$file"
}

decrypt_file_to_stdout() {
    local file="$1"
    get_master_pass
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass "pass:$MASTER_PASS" -in "$file" 2>/dev/null || echo "FAILED"
}

list_users() {
    echo -e "${GREEN}Configured Users:${NC}"
    shopt -s nullglob
    local users=("${CLIENT_DIR}"/*.conf.enc)
    shopt -u nullglob
    
    if [[ ${#users[@]} -eq 0 ]]; then
        echo -e "${RED}No encrypted users found.${NC}"
        return 1
    fi
    
    for i in "${!users[@]}"; do
        basename "${users[$i]}" .conf.enc
    done
}

show_user() {
    list_users || return
    echo -en "${GREEN}Enter username to view: ${NC}"
    read -r username
    local file="${CLIENT_DIR}/${username}.conf.enc"
    
    if [[ -f "$file" ]]; then
        local content
        content=$(decrypt_file_to_stdout "$file")
        if [[ "$content" == "FAILED" ]]; then
            echo -e "${RED}Error: Decryption failed. Incorrect master password?${NC}"
        else
            echo -e "${PURPLE}--- Configuration for $username ---${NC}"
            echo "$content"
            echo -e "${PURPLE}-----------------------------------${NC}"
            if command -v qrencode &> /dev/null; then
                echo -e "${GREEN}QR Code:${NC}"
                echo "$content" | qrencode -t ansiutf8
            fi
        fi
    else
        echo -e "${RED}User not found.${NC}"
    fi
}

delete_user() {
    list_users || return
    echo -en "${RED}Enter username to DELETE: ${NC}"
    read -r username
    local file="${CLIENT_DIR}/${username}.conf.enc"
    
    if [[ -f "$file" ]]; then
        local content
        content=$(decrypt_file_to_stdout "$file")
        if [[ "$content" == "FAILED" ]]; then
            echo -e "${RED}Error: Decryption failed.${NC}"
            return
        fi
        
        local privkey pubkey
        privkey=$(echo "$content" | grep "^PrivateKey" | awk '{print $3}')
        pubkey=$(echo "$privkey" | wg pubkey)
        
        if [[ -n "$pubkey" ]]; then
            echo -e "${GREEN}Removing peer from live WireGuard...${NC}"
            wg set wg0 peer "$pubkey" remove
        fi
        
        echo -e "${GREEN}Removing from wg0.conf...${NC}"
        sed -i "/# USER_START: $username/,/# USER_END: $username/d" /etc/wireguard/wg0.conf
        
        rm -f "$file"
        echo -e "${PURPLE}User $username deleted.${NC}"
    else
        echo -e "${RED}User not found.${NC}"
    fi
}

edit_user() {
    list_users || return
    echo -en "${GREEN}Enter username to EDIT: ${NC}"
    read -r username
    local file="${CLIENT_DIR}/${username}.conf.enc"
    
    if [[ -f "$file" ]]; then
        local content
        content=$(decrypt_file_to_stdout "$file")
        if [[ "$content" == "FAILED" ]]; then
            echo -e "${RED}Error: Decryption failed.${NC}"
            return
        fi
        
        local temp_file
        temp_file=$(mktemp)
        echo "$content" > "$temp_file"
        
        echo -e "${GREEN}Editing configuration for $username...${NC}"
        echo -e "${PURPLE}You can change MTU, DNS, etc. manually.${NC}"
        ${EDITOR:-nano} "$temp_file"
        
        encrypt_file "$temp_file"
        mv "${temp_file}.enc" "$file"
        echo -e "${PURPLE}Configuration updated and re-encrypted.${NC}"
        echo -e "${RED}Note: Manual edits to IP/Keys in the client file do not sync automatically to the server wg0.conf in this version.${NC}"
    else
        echo -e "${RED}User not found.${NC}"
    fi
}

show_user_by_name() {
    local username="$1"
    local file="${CLIENT_DIR}/${username}.conf.enc"
    
    if [[ -f "$file" ]]; then
        local content
        content=$(decrypt_file_to_stdout "$file")
        if [[ "$content" == "FAILED" ]]; then
            echo -e "${RED}Error: Decryption failed. Incorrect master password?${NC}"
        else
            echo -e "${PURPLE}--- Configuration for $username ---${NC}"
            echo "$content"
            echo -e "${PURPLE}-----------------------------------${NC}"
            if command -v qrencode &> /dev/null; then
                echo -e "${GREEN}QR Code:${NC}"
                echo "$content" | qrencode -t ansiutf8
            fi
        fi
    else
        echo -e "${RED}User not found.${NC}"
    fi
}

# Main Menu logic or CLI arg
if [[ "${1:-}" == "--show" && -n "${2:-}" ]]; then
    show_user_by_name "$2"
    exit 0
fi

while true; do
    echo -e "\n${PURPLE}--- User Management (Configure Clients) ---${NC}"
    echo "[1] List users"
    echo "[2] Check configuration (Show QR/Text)"
    echo "[3] Edit configuration"
    echo "${RED}[4] Remove user (Delete)${NC}"
    echo "[0] Back to Main Menu"
    echo -en "${GREEN}Option: ${NC}"
    read -r opt
    case "$opt" in
        1) list_users || true ;;
        2) show_user ;;
        3) edit_user ;;
        4) delete_user ;;
        0) break ;;
        *) echo -e "${RED}Invalid option.${NC}" ;;
    esac
done
