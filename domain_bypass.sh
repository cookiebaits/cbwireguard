#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

BYPASS_FILE="/etc/wireguard/bypass_domains.txt"

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
        ips=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)
        
        if [[ -z "$ips" ]]; then
            echo -e "${RED}Warning: Could not resolve ${domain}, skipping.${NC}"
            continue
        fi

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

add_streaming_services() {
    local services=(
        "netflix.com" "nflxvideo.net" "nflxext.com" "nflximg.net" "nflxso.net"
        "hulu.com" "huluim.com" "hulustream.com" 
        "disneyplus.com" "bamgrid.com" "disney-plus.net" "dssott.com" "disney.com"
        "hbomax.com" "max.com" "hbonow.com" "hbo.com"
        "primevideo.com" "amazonvideo.com" "media-amazon.com"
        "bbc.co.uk" "bbci.co.uk"
    )
    echo -e "${GREEN}Adding popular streaming services and their CDNs to bypass list...${NC}"
    for domain in "${services[@]}"; do
        if ! grep -Fxq "$domain" "$BYPASS_FILE"; then
            echo "$domain" >> "$BYPASS_FILE"
            echo -e "${PURPLE}Added: ${domain}${NC}"
        fi
    done
    update_routes
}

main_menu() {
    init_bypass
    while true; do
        echo -e "\n${PURPLE}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${PURPLE}║${NC} ${GREEN}Domain Bypass Manager (Split Tunneling)${NC}                    ${PURPLE}║${NC}"
        echo -e "${PURPLE}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${PURPLE}║${NC} [1] Add domain to bypass                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} [2] Remove domain from bypass                              ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} [3] List bypass domains                                    ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} [4] Refresh/Apply routes                                   ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} [5] Add streaming services to bypass list                  ${PURPLE}║${NC}"
        echo -e "${PURPLE}║${NC} [0] Back to Main Menu                                      ${PURPLE}║${NC}"
        echo -e "${PURPLE}╚════════════════════════════════════════════════════════════╝${NC}"
        echo -en "${GREEN}Option: ${NC}"
        read -r opt
        case "$opt" in
            1) add_domain ;;
            2) remove_domain ;;
            3) cat "$BYPASS_FILE" ;;
            4) update_routes ;;
            5) add_streaming_services ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

main_menu
