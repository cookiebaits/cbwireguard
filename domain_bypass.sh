#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

BYPASS_FILE="/etc/wireguard/bypass_domains.txt"
SETTINGS_FILE="/root/easy_wireguard/settings.conf"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

init_bypass() {
    if [[ ! -f "$BYPASS_FILE" ]]; then
        touch "$BYPASS_FILE"
        chmod 600 "$BYPASS_FILE"
    fi
}

get_default_gateway() {
    ip route show default | awk '/default/ {print $3}' | head -n 1
}

update_routes() {
    local gateway
    gateway=$(get_default_gateway)
    if [[ -z "$gateway" ]]; then
        echo -e "${RED}Error: Default gateway not found.${NC}"
        return 1
    fi

    echo -e "${GREEN}Updating routing table...${NC}"
    while IFS= read -r domain; do
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue
        echo -e "Resolving ${PURPLE}${domain}${NC}..."
        ips=$(dig +short "$domain" | grep -E '^[0-9.]+$' || true)
        for ip in $ips; do
            echo -e "Adding route for ${PURPLE}${ip}${NC} via ${gateway}..."
            ip route add "$ip" via "$gateway" 2>/dev/null || true
        done
    done < "$BYPASS_FILE"
}

add_domain() {
    echo -en "${GREEN}Enter domain to bypass (e.g., netflix.com): ${NC}"
    read -r domain
    if [[ -n "$domain" ]]; then
        if grep -Fxq "$domain" "$BYPASS_FILE"; then
            echo -e "${PURPLE}Domain already in bypass list.${NC}"
        else
            echo "$domain" >> "$BYPASS_FILE"
            echo -e "${GREEN}Added ${domain} to bypass list.${NC}"
            update_routes
        fi
    fi
}

remove_domain() {
    echo -e "${GREEN}Bypass List:${NC}"
    mapfile -t domains < "$BYPASS_FILE"
    for i in "${!domains[@]}"; do
        echo "[$i] ${domains[$i]}"
    done
    echo -en "${GREEN}Enter index to remove (or Enter to cancel): ${NC}"
    read -r index
    if [[ -n "$index" && "$index" =~ ^[0-9]+$ && "$index" -lt "${#domains[@]}" ]]; then
        domain="${domains[$index]}"
        sed -i "$((index + 1))d" "$BYPASS_FILE"
        echo -e "${RED}Removed ${domain} from bypass list.${NC}"
        echo -e "${PURPLE}Note: Existing routes remain until reboot or manual removal.${NC}"
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
    printf "${PURPLE}│${NC} %s%*s${PURPLE}│\n${NC}" "$str" $padding ""
}

main_menu() {
    init_bypass
    while true; do
        echo
        print_header "Domain Bypass Manager (Split Tunneling)"
        echo -e "\n${PURPLE}╭$(printf '─%.0s' $(seq 1 54))╮${NC}"
        print_menu_item "1" "Add domain to bypass"
        print_menu_item "2" "Remove domain from bypass"
        print_menu_item "3" "List bypass domains"
        print_menu_item "4" "Refresh/Apply routes"
        print_menu_item "0" "Back to Main Menu"
        echo -e "${PURPLE}╰$(printf '─%.0s' $(seq 1 54))╯${NC}"
        echo -en "${GREEN}▶ Option: ${NC}"
        read -r opt
        case "$opt" in
            1) add_domain ;;
            2) remove_domain ;;
            3) cat "$BYPASS_FILE" ;;
            4) update_routes ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

main_menu
