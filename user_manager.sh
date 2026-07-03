#!/bin/bash

# Cookie's Easy WireGuard Manager - Client Manager
# View, Edit, Remove clients securely

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_NIC="wg0"
CONF_FILE="/etc/wireguard/${WG_NIC}.conf"
CLIENTS_DIR="/etc/wireguard/clients"

function print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      $1      ${NC}"
    echo -e "${CYAN}================================================${NC}"
}

function list_clients() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo -e "${RED}WireGuard configuration not found!${NC}"
        return 0
    fi
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "$CONF_FILE")
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo -e "${ORANGE}You have no existing clients!${NC}"
        return 0
    fi
    echo ""
    grep -E "^### Client" "$CONF_FILE" | cut -d ' ' -f 3 | nl -s ') '
    echo ""
    return "$NUMBER_OF_CLIENTS"
}

function check_client() {
    print_header "Check Client Configuration"
    list_clients
    NUMBER_OF_CLIENTS=$?
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        read -rp "Select a client to check [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
    done

    CLIENT_NAME=$(grep -E "^### Client" "$CONF_FILE" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
    ENC_FILE="${CLIENTS_DIR}/${CLIENT_NAME}.conf.enc"

    if [[ ! -f "$ENC_FILE" ]]; then
        echo -e "${RED}Encrypted configuration for ${CLIENT_NAME} not found!${NC}"
        # Fallback to check if plain text exists (legacy)
        if [[ -f "/root/${WG_NIC}-client-${CLIENT_NAME}.conf" ]]; then
             echo -e "${ORANGE}Found unencrypted legacy config at /root/${WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
             cat "/root/${WG_NIC}-client-${CLIENT_NAME}.conf"
             if command -v qrencode &>/dev/null; then
                qrencode -t ansiutf8 -l L <"/root/${WG_NIC}-client-${CLIENT_NAME}.conf"
             fi
        fi
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    echo -e "\n${ORANGE}Configuration is encrypted. Please enter the password used when creating this client:${NC}"

    TEMP_FILE=$(mktemp)
    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -in "$ENC_FILE" -out "$TEMP_FILE" 2>/dev/null; then
        echo -e "\n${GREEN}Configuration decrypted successfully!${NC}"
        echo -e "${CYAN}--- Configuration for $CLIENT_NAME ---${NC}"
        cat "$TEMP_FILE"

        if command -v qrencode &>/dev/null; then
            echo -e "\n${CYAN}--- QR Code ---${NC}"
            qrencode -t ansiutf8 -l L <"$TEMP_FILE"
        fi

        # Securely remove the temporary plain-text file
        shred -u "$TEMP_FILE" 2>/dev/null || rm -f "$TEMP_FILE"
    else
        echo -e "\n${RED}Incorrect password or corrupted file!${NC}"
    fi

    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function edit_client() {
    print_header "Edit Client Settings"
    echo -e "${ORANGE}Note: Editing will require the client password and will generate a new encrypted config.${NC}"
    list_clients
    NUMBER_OF_CLIENTS=$?
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        read -rp "Select a client to edit [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
    done

    CLIENT_NAME=$(grep -E "^### Client" "$CONF_FILE" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
    ENC_FILE="${CLIENTS_DIR}/${CLIENT_NAME}.conf.enc"

    if [[ ! -f "$ENC_FILE" ]]; then
        echo -e "${RED}Encrypted configuration for ${CLIENT_NAME} not found! Cannot edit.${NC}"
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    echo -e "\n${ORANGE}Please enter the password to decrypt the config for editing:${NC}"
    TEMP_FILE=$(mktemp)
    if openssl enc -d -aes-256-cbc -salt -pbkdf2 -in "$ENC_FILE" -out "$TEMP_FILE" 2>/dev/null; then
        echo -e "${GREEN}Decrypted! Opening in nano...${NC}"
        sleep 1
        nano "$TEMP_FILE"

        echo -e "\n${ORANGE}Please enter a password to re-encrypt the configuration (can be the same or new):${NC}"
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "$TEMP_FILE" -out "$ENC_FILE"

        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}Configuration updated and securely encrypted!${NC}"
        else
            echo -e "${RED}Failed to re-encrypt. Your changes may not be saved securely.${NC}"
        fi

        shred -u "$TEMP_FILE" 2>/dev/null || rm -f "$TEMP_FILE"
    else
        echo -e "\n${RED}Incorrect password!${NC}"
    fi

    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function remove_client() {
    print_header "Remove Client"
    list_clients
    NUMBER_OF_CLIENTS=$?
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
        read -rp "Select a client to remove [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
    done

    CLIENT_NAME=$(grep -E "^### Client" "$CONF_FILE" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

    echo -e "\n${RED}WARNING: You are about to remove $CLIENT_NAME!${NC}"
    read -rp "Are you sure? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Removal cancelled."
        return
    fi

    # remove [Peer] block matching $CLIENT_NAME
    sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "$CONF_FILE"

    # remove encrypted file and legacy plain text if it exists
    rm -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf.enc"
    rm -f "/root/${WG_NIC}-client-${CLIENT_NAME}.conf"

    # restart wireguard to apply changes
    wg syncconf "$WG_NIC" <(wg-quick strip "$WG_NIC")

    echo -e "${GREEN}Client ${CLIENT_NAME} removed successfully.${NC}"
    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function manage_users() {
    mkdir -p "$CLIENTS_DIR"
    while true; do
        clear
        print_header "Client Configuration Manager"
        echo "   1) Check Client (View Config / QR)"
        echo "   2) Edit Client Settings"
        echo "   3) Remove Client"
        echo "   4) Exit to Main Menu"
        echo ""

        read -rp "Select an option [1-4]: " OPTION
        case "$OPTION" in
            1) check_client ;;
            2) edit_client ;;
            3) remove_client ;;
            4) break ;;
        esac
    done
}

# Allow running as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
    manage_users
fi
