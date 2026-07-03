#!/bin/bash

# Cookie's Easy WireGuard Manager - Main Menu Wrapper

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

function print_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${GREEN}      🍪 Cookie's Easy WireGuard Manager      ${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

function ensure_executable() {
    for script in wireguard-install.sh user_manager.sh backup_manager.sh domain_bypass.sh remove_server.sh; do
        if [[ -f "$script" && ! -x "$script" ]]; then
            chmod +x "$script"
        fi
    done
}

function main_menu() {
    isRoot
    ensure_executable

    while true; do
        print_header
        
        if [[ -e /etc/wireguard/params ]]; then
            echo -e "Status: ${GREEN}Installed & Running${NC}"
            echo ""
            echo "   1) Add New Client"
            echo "   2) Client Manager (Check/Edit/Remove)"
            echo "   3) Backup & Restore Manager"
            echo "   4) Settings & Domain Bypass"
            echo "   5) Remove WireGuard Server"
            echo "   0) Exit"
            echo ""
            
            read -rp "Select an option [0-5]: " OPTION
            case "$OPTION" in
                1) 
                    # Use bash instead of sourcing to avoid re-running the install script's main menu
                    bash -c 'source ./wireguard-install.sh && newClient'
                    read -n1 -r -p "Press any key to continue..."
                    ;;
                2) ./user_manager.sh ;;
                3) ./backup_manager.sh ;;
                4) ./domain_bypass.sh ;;
                5) ./remove_server.sh ;;
                0) exit 0 ;;
            esac
        else
            echo -e "Status: ${ORANGE}Not Installed${NC}"
            echo ""
            echo "   1) Install WireGuard Server"
            echo "   0) Exit"
            echo ""
            
            read -rp "Select an option [0-1]: " OPTION
            case "$OPTION" in
                1) ./wireguard-install.sh ;;
                0) exit 0 ;;
            esac
        fi
    done
}

function isRoot() {
    if [ "${EUID}" -ne 0 ]; then
        echo -e "${RED}Error: You need to run this script as root.${NC}"
        exit 1
    fi
}

main_menu
