#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard" 
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"

init_environment() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
    chmod 700 "$INSTALL_DIR"

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        cat <<EOF > "$SETTINGS_FILE"
DEFAULT_MTU=1280
DEFAULT_DNS="94.140.14.49, 9.9.9.9, 94.140.14.59"
DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
EOF
        chmod 600 "$SETTINGS_FILE"
    fi
}

init_environment

if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

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
    local script_path="./${script_name}"

    if [[ -f "$script_path" ]]; then
        echo -e "\n${GREEN}Running local version of ${script_name}...${NC}"
        chmod +x "$script_path"
        "$script_path"
    else
        script_path="${INSTALL_DIR}/${script_name}"
        echo -e "\n${GREEN}Fetching latest version of ${script_name}...${NC}"

        if curl -sSfL "${GIT_REPO}/${script_name}" -o "$script_path"; then
            chmod 700 "$script_path"
            "$script_path"
        else
            echo -e "${RED}Error: Failed to pull ${script_name} from ${GIT_REPO}.${NC}"
            exit 1
        fi
    fi
}

update_setting() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SETTINGS_FILE"
    else
        echo "${key}=${value}" >> "$SETTINGS_FILE"
    fi
}

display_menu() {
    echo -en "\n${GREEN}Choose the action:
[1] Setup WireGuard server
[2] Add new client (peer)
[3] Show client (peer) QR
[4] List configured clients
[5] Backup & Restore Manager
[6] Install/Manage Cloak (Stealth Plugin)
[s] Settings (MTU, DNS, AllowedIPs)
${RED}[r] Remove WireGuard server from this system${GREEN}
[q] Exit

Option: ${NC}"
}

settings_menu() {
    while true; do
        echo -e "\n${PURPLE}--- Settings ---${NC}"
        echo -e "${GREEN}[1] Default MTU: ${NC}${DEFAULT_MTU:-1280}"
        echo -e "${GREEN}[2] Default DNS: ${NC}${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}"
        echo -e "${GREEN}[3] Default Allowed IPs: ${NC}${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1"}"
        echo -e "${GREEN}[4] Domain-Based Split Tunneling${NC}"
        echo -e "${GREEN}[b] Back to Main Menu${NC}"
        echo -en "${PURPLE}Select option: ${NC}"
        read -r SET_OPT

        case "$SET_OPT" in
            1)
                echo -en "${GREEN}Enter new Default MTU: ${NC}"
                read -r NEW_MTU
                update_setting "DEFAULT_MTU" "$NEW_MTU"
                DEFAULT_MTU="$NEW_MTU"
                ;;
            2)
                echo -en "${GREEN}Enter new Default DNS (comma separated): ${NC}"
                read -r NEW_DNS
                update_setting "DEFAULT_DNS" "\"$NEW_DNS\""
                DEFAULT_DNS="$NEW_DNS"
                ;;
            3)
                echo -en "${GREEN}Enter new Default Allowed IPs: ${NC}"
                read -r NEW_IPS
                update_setting "DEFAULT_ALLOWED_IPS" "\"$NEW_IPS\""
                DEFAULT_ALLOWED_IPS="$NEW_IPS"
                ;;
            4) fetch_and_run "domain_bypass.sh" ;;
            b) break ;;
        esac
    done
}

main() {
    # Loop the main menu so it returns after completing a task
    while true; do
        clear
        echo -e "${PURPLE}======================================================${NC}"
        echo -e "${GREEN}       🍪 Cookie's Easy WireGuard Manager${NC}"
        echo -e "${PURPLE}======================================================${NC}"
        display_menu
        read -r OPTION

        case "$OPTION" in
            1) fetch_and_run "setup_server.sh" ;;
            2) fetch_and_run "add_client.sh" ;;
            3) fetch_and_run "show_qr.sh" ;;
            4) fetch_and_run "list_clients.sh" ;;
            5) fetch_and_run "backup_manager.sh" ;;
            6) fetch_and_run "Cloak2-Installer.sh" ;;
            s) settings_menu ;;
            r)
                fetch_and_run "remove_server.sh"
                echo -e "${GREEN}Cleaning up environment...${NC}"
                rm -rf "$INSTALL_DIR"
                break
                ;;
            q)
                echo -e "${PURPLE}Exit: The system was not modified.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                ;;
        esac
    done
}

main
