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
        "api-global.netflix.com", "customerevents.netflix.com", "ichnaea.netflix.com", "dvd.netflix.com", "fast.com"
    ],
    "hulu.com": ["hulu.com", "huluim.com", "hulustream.com", "huluad.com"],
    "primevideo.com": ["primevideo.com", "amazonvideo.com", "aiv-cdn.net", "aiv-delivery.net", "media-amazon.com", "amazon.com", "prime.com"],
    "max.com": ["max.com", "hbomax.com", "hbomaxcdn.com", "hbo.com"],
    "twitch.tv": ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net"],
    "spotify.com": ["spotify.com", "scdn.co", "spoti.fi"],
    "youtube.com": [
        "youtube.com", "youtu.be", "ytimg.com", "googlevideo.com", "youtube-nocookie.com", "yt.be"
    ],
    "discord.com": [
        "discord.com", "discordapp.com", "discord.gg", "discordapp.net", "discord.media",
        "discordstatus.com", "gateway.discord.gg", "cdn.discordapp.com", "media.discordapp.net",
        "status.discord.com"
    ],
    "instagram.com": ["instagram.com", "cdninstagram.com", "ig.me"],
    "linkedin.com": [
        "linkedin.com", "licdn.com", "media.licdn.com", "static.licdn.com",
        "dms.licdn.com", "voyager.linkedin.com", "lnkd.in", "platform.linkedin.com"
    ],
    "tiktok.com": ["tiktok.com", "byteoversea.com", "ibytedtos.com", "musical.ly"],
    "chatgpt.com": ["chatgpt.com", "openai.com", "auth0.com", "challenges.cloudflare.com", "chat.openai.com", "oaistatic.com", "oaiusercontent.com"],
    "openai.com": ["chatgpt.com", "openai.com", "auth0.com", "challenges.cloudflare.com", "api.openai.com", "oaistatic.com", "oaiusercontent.com"],
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

add_preset_services() {
    echo -e "\n${PURPLE}Select Services to Split-Tunnel (Multi-Select Allowed, e.g. 'abc' or 'a, b, c'):${NC}"
    echo -e "  ${GREEN}Popular Streamer & Social Tools:${NC}"
    echo "    [A] YouTube       (youtube.com, youtu.be, googlevideo.com)"
    echo "    [B] Twitch        (twitch.tv, ttvnw.net, jtvnw.net)"
    echo "    [C] Discord       (discord.com, discordapp.com, discord.gg)"
    echo "    [D] Instagram     (instagram.com, cdninstagram.com, ig.me)"
    echo "    [E] LinkedIn      (linkedin.com, licdn.com, lnkd.in)"
    echo "    [F] TikTok        (tiktok.com, byteoversea.com, musical.ly)"
    echo -e "  ${GREEN}Popular Streaming Services:${NC}"
    echo "    [G] Netflix       (netflix.com, nflxvideo.net, fast.com)"
    echo "    [H] Hulu          (hulu.com, hulustream.com, huluim.com)"
    echo "    [I] Disney+       (disneyplus.com, bamgrid.com, dssott.com)"
    echo "    [J] Prime Video   (primevideo.com, amazonvideo.com, aiv-cdn.net)"
    echo "    [K] Max / HBO     (max.com, hbomax.com, hbomaxcdn.com)"
    echo "    [L] Spotify       (spotify.com, scdn.co, spoti.fi)"
    echo "    [ALL] Select all streaming & streamer tools above"
    echo -en "${GREEN}Enter selection [e.g. 'abc' or 'A C G']: ${NC}"
    read -r preset_input_raw

    local preset_input
    preset_input=$(echo "$preset_input_raw" | tr -d ' ,;/\t\r\n' | tr '[:lower:]' '[:upper:]')
    local preset_list=()

    if [[ "$preset_input" == *"ALL"* ]]; then
        preset_input="ABCDEFGHIJKL"
    fi

    local i=0
    for (( i=0; i<${#preset_input}; i++ )); do
        local opt_char="${preset_input:$i:1}"
        case "$opt_char" in
            A) preset_list+=("youtube.com") ;;
            B) preset_list+=("twitch.tv") ;;
            C) preset_list+=("discord.com") ;;
            D) preset_list+=("instagram.com") ;;
            E) preset_list+=("linkedin.com") ;;
            F) preset_list+=("tiktok.com") ;;
            G) preset_list+=("netflix.com") ;;
            H) preset_list+=("hulu.com") ;;
            I) preset_list+=("disneyplus.com") ;;
            J) preset_list+=("primevideo.com") ;;
            K) preset_list+=("max.com") ;;
            L) preset_list+=("spotify.com") ;;
        esac
    done

    if [[ ${#preset_list[@]} -gt 0 ]]; then
        local added=0
        for pd in "${preset_list[@]}"; do
            if ! grep -Fxq "$pd" "$BYPASS_FILE" 2>/dev/null; then
                echo "$pd" >> "$BYPASS_FILE"
                echo -e "${GREEN}Added ${pd} to bypass list.${NC}"
                added=$((added + 1))
            fi
        done
        if [[ $added -gt 0 ]]; then
            update_routes
        else
            echo -e "${PURPLE}All selected services were already in the bypass list.${NC}"
        fi
    else
        echo -e "${RED}No valid services selected.${NC}"
    fi
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│               Domain Bypass Actions                │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Add domain to bypass                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Select Streaming/Streamer Tools (Multi: A,B,C)${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[3] Remove domain from bypass                     ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[4] List bypass domains                           ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[5] Refresh/Apply routes                          ${PURPLE}│${NC}"
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
            2) add_preset_services ;;
            3) remove_domain ;;
            4)
                if [[ -f "$BYPASS_FILE" && -s "$BYPASS_FILE" ]]; then
                    cat "$BYPASS_FILE"
                else
                    echo "No domains in list."
                fi
                ;;
            5) update_routes ;;
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
