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
DEFAULT_MTU=1420
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

print_header() {
    local title="$1"
    local width=54
    local padding=$(( (width - ${#title}) / 2 ))
    echo -e "${PURPLE}╭$(printf '─%.0s' $(seq 1 $width))╮${NC}"
    printf "${PURPLE}│${GREEN}%*s%s%*s${PURPLE}│\n${NC}" $padding "" "$title" $((width - padding - ${#title})) ""
    echo -e "${PURPLE}╰$(printf '─%.0s' $(seq 1 $width))╯${NC}"
}

print_menu_item() {
    local key="$1"
    local desc="$2"
    local color="${3:-$GREEN}"
    local width=52
    local str="${color}[${key}]${NC} ${desc}"
    local plain_str="[${key}] ${desc}"
    local padding=$(( width - ${#plain_str} + 1 ))
    printf "${PURPLE}│${NC} %b%*s${PURPLE}│\n${NC}" "$str" $padding ""
}

display_menu() {
    echo -e "\n${PURPLE}╭$(printf '─%.0s' $(seq 1 54))╮${NC}"
    print_menu_item "1" "Setup WireGuard server"
    print_menu_item "2" "Add new client (peer)"
    print_menu_item "3" "Show client (peer) QR"
    print_menu_item "4" "Configure clients (Check/Edit/Remove)"
    print_menu_item "5" "Backup & Restore Manager"
    print_menu_item "s" "Settings (MTU, DNS, AllowedIPs)"
    print_menu_item "r" "Remove WireGuard server from this system" "$RED"
    print_menu_item "q" "Exit"
    echo -e "${PURPLE}╰$(printf '─%.0s' $(seq 1 54))╯${NC}"
    echo -en "${GREEN}▶ Option: ${NC}"
}

settings_menu() {
    while true; do
        echo
        print_header "Settings"
        echo -e "\n${PURPLE}╭$(printf '─%.0s' $(seq 1 54))╮${NC}"
        print_menu_item "1" "Default MTU: ${DEFAULT_MTU:-1420}"
        print_menu_item "2" "Default DNS: ${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}"
        print_menu_item "3" "Default Allowed IPs: ${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1"}"
        print_menu_item "b" "Back to Main Menu"
        echo -e "${PURPLE}╰$(printf '─%.0s' $(seq 1 54))╯${NC}"
        echo -en "${GREEN}▶ Select option: ${NC}"
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
            b) break ;;
        esac
    done
}

main() {
    # Loop the main menu so it returns after completing a task
    while true; do
        clear
        print_header "🍪 Cookie's Easy WireGuard Manager"
        display_menu
        read -r OPTION

        case "$OPTION" in
            1) fetch_and_run "setup_server.sh" ;;
            2) fetch_and_run "add_client.sh" ;;
            3)
                echo -en "${GREEN}Enter device name to show QR: ${NC}"
                read -r dname
                # We can reuse user_manager.sh logic or just call a small snippet
                # For now, let's keep it simple and maybe restore show_qr.sh if needed
                # or just use user_manager.sh with a flag.
                # Actually, user_manager.sh has show_user.
                # Let's just point to a new script that does exactly this or use a flag.
                MASTER_PASS="" fetch_and_run "user_manager.sh" --show "$dname" || true
                ;;
            4) fetch_and_run "user_manager.sh" ;;
            5) fetch_and_run "backup_manager.sh" ;;
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
