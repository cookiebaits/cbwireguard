#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

# Define colors
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/bllizard22/easy-wireguard-server/main'
INSTALL_DIR="/root/easy_wireguard" # Secure location for VPN scripts

# P2: Security Check - WireGuard configuration requires root access.
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# P0: Function Priority - Initialize secure environment
init_environment() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
    # Restrict read/write/execute access to the root user only
    chmod 700 "$INSTALL_DIR" 
}

# P1 & P3: Lightweight Fetch & Execute - Only downloads what is needed, forcing the latest version.
fetch_and_run() {
    local script_name="$1"
    local script_path="${INSTALL_DIR}/${script_name}"

    echo -e "${GREEN}Fetching latest version of ${script_name}...${NC}"

    # curl flags: -s (silent), -S (show error), -f (fail on HTTP errors like 404), -L (follow redirects)
    if curl -sSfL "${GIT_REPO}/${script_name}" -o "$script_path"; then
        chmod 700 "$script_path"
        # Execute the newly downloaded script
        "$script_path"
    else
        echo -e "${RED}Error: Failed to pull the latest ${script_name}. Check your connection.${NC}"
        exit 1
    fi
}

# P0: Function Priority - UI Display
display_menu() {
    echo -en "${GREEN}Choose the action:
[1] Setup WireGuard server
[2] Restore configuration backup
[3] Add new client (peer)
[4] Show client (peer) QR
[5] Create configuration backup
${RED}[6] Remove WireGuard server from this system${GREEN}

[1/2/3/4/5/6]: ${NC}"
}

# Core Logic Flow
main() {
    init_environment
    display_menu
    read -r OPTION

    # Secure input handling using a case statement instead of nested ifs
    case "$OPTION" in
        1) fetch_and_run "setup_server.sh" ;;
        2) fetch_and_run "restore_backup.sh" ;;
        3) fetch_and_run "add_client.sh" ;;
        4) fetch_and_run "show_qr.sh" ;;
        5) fetch_and_run "create_backup.sh" ;;
        6)
            fetch_and_run "remove_server.sh"
            echo -e "${GREEN}Cleaning up environment...${NC}"
            rm -rf "$INSTALL_DIR"
            ;;
        *)
            echo -e "${PURPLE}Exit: The system was not modified.${NC}"
            exit 0
            ;;
    esac
}

# Execute main function
main
