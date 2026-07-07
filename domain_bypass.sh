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
        mkdir -p /etc/wireguard
        touch "$BYPASS_FILE"
        chmod 600 "$BYPASS_FILE"
    fi
}

update_routes() {
    echo -e "${GREEN}Calculating Split Tunneling AllowedIPs...${NC}"
    cat << 'PY_CALC_EOF' | python3
import ipaddress
import socket
import sys
import glob
import re

SERVICE_MAP = {
    "disneyplus.com": [
        "disneyplus.com", "bamgrid.com", "dssott.com", "disney-plus.net",
        "disneystreaming.com", "cdn.registerdisney.go.com",
        "global.edge.bamgrid.com", "api.disneyplus.com", "auth.disneyplus.com",
        "js-agent.newrelic.com", "bam.nr-data.net", "cws.conviva.com", "braze.com", "disney.com", "go.com",
        "my.disney.com", "cdn.registerdisney.go.com", "registerdisney.go.com", "disneyid.disney.com"
    ],
    "netflix.com": [
        "netflix.com", "netflix.net", "nflximg.net", "nflxext.com", "nflxso.net", "nflxvideo.net",
        "api-global.netflix.com", "customerevents.netflix.com", "ichnaea.netflix.com", "dvd.netflix.com"
    ],
    "hulu.com": ["hulu.com", "huluim.com", "hulustream.com", "huluad.com"],
    "primevideo.com": ["primevideo.com", "amazonvideo.com", "aiv-cdn.net", "aiv-delivery.net", "media-amazon.com", "amazon.com", "prime.com"],
    "max.com": ["max.com", "hbomax.com", "hbomaxcdn.com", "hbo.com"],
    "chatgpt.com": ["chatgpt.com", "openai.com", "auth0.com", "challenges.cloudflare.com", "chat.openai.com"],
    "openai.com": ["chatgpt.com", "openai.com", "auth0.com", "challenges.cloudflare.com", "api.openai.com"],
    "ticketmaster.com": ["ticketmaster.com", "livenation.com", "tmclient.ticketmaster.com"],
    "chase.com": ["chase.com", "chasecdn.com"],
    "bankofamerica.com": ["bankofamerica.com", "bofa.com", "bankofamerica.com.akadns.net"]
}

def resolve_domain(domain):
    try:
        _, _, ips = socket.gethostbyname_ex(domain)
        return ips
    except Exception:
        return []

def main():
    bypass_file = "/etc/wireguard/bypass_domains.txt"
    settings_file = "/root/easy_wireguard/settings.conf"

    try:
        with open(bypass_file, "r") as f:
            domains = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    except FileNotFoundError:
        domains = []

    expanded_domains = set()
    for d in domains:
        expanded_domains.add(d)
        for k, v in SERVICE_MAP.items():
            keyword = k.split('.')[0]
            # Match if the user added the exact service domain, a subdomain of it,
            # or just the service keyword (like 'netflix')
            if d == k or d.endswith("." + k) or d == keyword:
                expanded_domains.update(v)

    ips_to_exclude = set()
    prefixes = ["", "www.", "api.", "auth.", "login.", "cdn.", "global.edge.", "app."]
    for d in expanded_domains:
        for p in prefixes:
            if d.startswith(p) and p != "":
                host = d
            else:
                host = p + d
            resolved = resolve_domain(host)
            ips_to_exclude.update(resolved)

    networks = [ipaddress.IPv4Network("0.0.0.0/0")]

    for ip in ips_to_exclude:
        exclude_net = ipaddress.IPv4Network(f"{ip}/32")
        new_networks = []
        for net in networks:
            if exclude_net.subnet_of(net):
                new_networks.extend(list(net.address_exclude(exclude_net)))
            else:
                new_networks.append(net)
        networks = new_networks

    collapsed = list(ipaddress.collapse_addresses(networks))

    if not ips_to_exclude:
        final_str = "0.0.0.0/1, 128.0.0.0/1"
    else:
        final_str = ", ".join(str(n) for n in collapsed)

    try:
        with open(settings_file, "r") as f:
            lines = f.readlines()

        with open(settings_file, "w") as f:
            found = False
            for line in lines:
                if line.startswith("DEFAULT_ALLOWED_IPS="):
                    f.write('DEFAULT_ALLOWED_IPS="' + final_str + '"\n')
                    found = True
                else:
                    f.write(line)
            if not found:
                f.write('DEFAULT_ALLOWED_IPS="' + final_str + '"\n')
        print("Updated AllowedIPs with " + str(len(ips_to_exclude)) + " bypassed IPs.")
    except Exception as e:
        print("Error updating settings: " + str(e))

    # Process client configs separately
    client_configs = glob.glob("/etc/wireguard/clients/*.conf")
    for conf_path in client_configs:
        try:
            with open(conf_path, "r") as cf:
                c_lines = cf.readlines()
            with open(conf_path, "w") as cf:
                for line in c_lines:
                    if re.match(r"^AllowedIPs\s*=", line):
                        # Preserve IPv6 if it exists
                        parts = line.split("=")[1].split(",")
                        ipv6_parts = [p.strip() for p in parts if ":" in p]

                        new_allowed = final_str
                        if ipv6_parts:
                            new_allowed += ", " + ", ".join(ipv6_parts)

                        cf.write("AllowedIPs = " + new_allowed + "\n")
                    else:
                        cf.write(line)
        except Exception:
            pass

if __name__ == "__main__":
    main()
PY_CALC_EOF
    echo -e "${PURPLE}Note: Bypasses apply to newly added clients.${NC}"
    echo -e "${PURPLE}To apply to existing clients, re-add them or update their AllowedIPs.${NC}"
}

add_domain() {
    echo -en "${GREEN}Enter domain to bypass (e.g., netflix.com): ${NC}"
    read -r raw_domain
    domain=$(echo "$raw_domain" | tr -cd '[:alnum:]_.-')
    if [[ -n "$domain" ]]; then
        if grep -Fxq "$domain" "$BYPASS_FILE" 2>/dev/null; then
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
    if [[ ! -s "$BYPASS_FILE" ]]; then
        echo "No domains in list."
        return
    fi
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
        update_routes
    fi
}

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 Domain Bypass Manager (Split Tunneling)${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│               Domain Bypass Actions                │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Add domain to bypass                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Remove domain from bypass                     ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[3] List bypass domains                           ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[4] Refresh/Apply routes                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[0] Back to Main Menu                             ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

if [[ "${1:-}" == "--cli-update" ]]; then
    init_bypass
    update_routes
    exit 0
fi

main_menu() {
    init_bypass
    while true; do
        clear
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r opt
        case "$opt" in
            1) add_domain ;;
            2) remove_domain ;;
            3)
                if [[ -f "$BYPASS_FILE" && -s "$BYPASS_FILE" ]]; then
                    cat "$BYPASS_FILE"
                else
                    echo "No domains in list."
                fi
                ;;
            4) update_routes ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
        if [[ "$opt" != "0" ]]; then
            echo
            read -n 1 -s -r -p "Press any key to continue..."
        fi
    done
}

if [[ "${1:-}" != "--cli-update" ]]; then
    main_menu
fi
