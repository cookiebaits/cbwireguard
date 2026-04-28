#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard" 

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

init_environment() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
    chmod 700 "$INSTALL_DIR" 
}

fetch_and_run() {
    local script_name="$1"
    local script_path="${INSTALL_DIR}/${script_name}"

    echo -e "\n${GREEN}Fetching latest version of ${script_name}...${NC}"

    if curl -sSfL "${GIT_REPO}/${script_name}" -o "$script_path"; then
        chmod 700 "$script_path"
        "$script_path"
    else
        echo -e "${RED}Error: Failed to pull ${script_name} from ${GIT_REPO}.${NC}"
        exit 1
    fi
}

display_menu() {
    echo -en "\n${GREEN}Choose the action:
[1] Setup WireGuard server
[2] Add new client (peer)
[3] Show client (peer) QR
[4] List configured clients
[5] Backup & Restore Manager
${RED}[6] Remove WireGuard server from this system${GREEN}

[1/2/3/4/5/6]: ${NC}"
}

main() {
    init_environment
    # Loop the main menu so it returns after completing a task
    while true; do
        display_menu
        read -r OPTION

        case "$OPTION" in
            1) fetch_and_run "setup_server.sh" ;;
            2) fetch_and_run "add_client.sh" ;;
            3) fetch_and_run "show_qr.sh" ;;
            4) fetch_and_run "list_clients.sh" ;;
            5) fetch_and_run "backup_manager.sh" ;;
            6)
                fetch_and_run "remove_server.sh"
                echo -e "${GREEN}Cleaning up environment...${NC}"
                rm -rf "$INSTALL_DIR"
                break
                ;;
            *)
                echo -e "${PURPLE}Exit: The system was not modified.${NC}"
                exit 0
                ;;
        esac
    done
}

main
