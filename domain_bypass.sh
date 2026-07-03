#!/bin/bash

# Cookie's Easy WireGuard Manager - Domain Bypass (Split Tunneling)
# Uses python to resolve domains, calculate inverse CIDR for AllowedIPs, and update WireGuard config.

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

WG_NIC="wg0"
CONF_FILE="/etc/wireguard/${WG_NIC}.conf"
SETTINGS_DIR="/root/easy_wireguard"
DOMAIN_LIST="${SETTINGS_DIR}/bypassed_domains.txt"
SETTINGS_CONF="${SETTINGS_DIR}/settings.conf"

mkdir -p "$SETTINGS_DIR"
touch "$DOMAIN_LIST"

function print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      $1      ${NC}"
    echo -e "${CYAN}================================================${NC}"
}

function calculate_allowed_ips() {
    echo -e "${CYAN}Calculating AllowedIPs based on bypassed domains...${NC}"
    
    # Python script to generate AllowedIPs excluding the bypassed domains
    TEMP_SCRIPT=$(mktemp)
    cat << 'EOF' > "$TEMP_SCRIPT"
import ipaddress
import socket
import sys

def get_ips_for_domain(domain):
    try:
        return [ip[4][0] for ip in socket.getaddrinfo(domain, None)]
    except:
        return []

exclude_ips = set()
for domain in sys.argv[1:]:
    domain = domain.strip()
    if domain:
        for ip in get_ips_for_domain(domain):
            exclude_ips.add(ip)

networks_v4 = [ipaddress.IPv4Network('0.0.0.0/0')]
networks_v6 = [ipaddress.IPv6Network('::/0')]

for ip_str in exclude_ips:
    try:
        ip = ipaddress.ip_network(f"{ip_str}/32" if ':' not in ip_str else f"{ip_str}/128")
        if ip.version == 4:
            new_nets = []
            for net in networks_v4:
                if ip.subnet_of(net):
                    new_nets.extend(list(net.address_exclude(ip)))
                else:
                    new_nets.append(net)
            networks_v4 = new_nets
        else:
            new_nets = []
            for net in networks_v6:
                if ip.subnet_of(net):
                    new_nets.extend(list(net.address_exclude(ip)))
                else:
                    new_nets.append(net)
            networks_v6 = new_nets
    except Exception as e:
        pass

allowed_v4 = [str(n) for n in networks_v4]
allowed_v6 = [str(n) for n in networks_v6]

print(",".join(allowed_v4 + allowed_v6))
EOF
    
    DOMAINS=$(cat "$DOMAIN_LIST" | tr '\n' ' ')
    if [[ -z $(echo "$DOMAINS" | tr -d ' ') ]]; then
        NEW_ALLOWED_IPS="0.0.0.0/0,::/0"
    else
        NEW_ALLOWED_IPS=$(python3 "$TEMP_SCRIPT" $DOMAINS)
        if [[ -z "$NEW_ALLOWED_IPS" ]]; then
            NEW_ALLOWED_IPS="0.0.0.0/0,::/0"
        fi
    fi
    
    rm -f "$TEMP_SCRIPT"
    
    # Save the base AllowedIPs setting
    echo "$NEW_ALLOWED_IPS" > "${SETTINGS_DIR}/current_allowed_ips.txt"
    
    # Note: This logic computes the IPs but we don't automatically rewrite all client configs 
    # since they are encrypted. We just store it so newly generated clients use it.
    # To apply to existing, users must edit them manually via the Client Manager.
    
    echo -e "${GREEN}AllowedIPs calculated successfully.${NC}"
    echo -e "New clients will use this split-tunneling configuration."
    echo -e "${ORANGE}Note: Existing clients must be regenerated or edited manually to apply changes.${NC}"
}

function view_domains() {
    print_header "Bypassed Domains"
    if [[ ! -s "$DOMAIN_LIST" ]]; then
        echo -e "${ORANGE}No domains are currently bypassed.${NC}"
    else
        cat -n "$DOMAIN_LIST"
    fi
    echo ""
    read -n1 -r -p "Press any key to continue..."
}

function add_domain() {
    print_header "Add Domain to Bypass"
    echo -e "Enter the domain you want to bypass the VPN (e.g., netflix.com)"
    read -rp "Domain: " NEW_DOMAIN
    
    if [[ -n "$NEW_DOMAIN" ]]; then
        echo "$NEW_DOMAIN" >> "$DOMAIN_LIST"
        echo -e "${GREEN}Added $NEW_DOMAIN to bypass list.${NC}"
        calculate_allowed_ips
    fi
    read -n1 -r -p "Press any key to continue..."
}

function remove_domain() {
    print_header "Remove Domain from Bypass"
    if [[ ! -s "$DOMAIN_LIST" ]]; then
        echo -e "${ORANGE}No domains are currently bypassed.${NC}"
        read -n1 -r -p "Press any key to continue..."
        return
    fi
    
    cat -n "$DOMAIN_LIST"
    echo ""
    read -rp "Enter the number of the domain to remove (0 to cancel): " DOMAIN_NUM
    
    if [[ "$DOMAIN_NUM" =~ ^[0-9]+$ && "$DOMAIN_NUM" -gt 0 ]]; then
        TOTAL_DOMAINS=$(wc -l < "$DOMAIN_LIST")
        if [[ "$DOMAIN_NUM" -le "$TOTAL_DOMAINS" ]]; then
            sed -i "${DOMAIN_NUM}d" "$DOMAIN_LIST"
            echo -e "${GREEN}Domain removed.${NC}"
            calculate_allowed_ips
        else
            echo -e "${RED}Invalid number.${NC}"
        fi
    fi
    read -n1 -r -p "Press any key to continue..."
}

function settings_menu() {
    # Initialize basic settings if they don't exist
    if [[ ! -f "$SETTINGS_CONF" ]]; then
        echo "MTU=1280" > "$SETTINGS_CONF"
        echo "DNS1=1.1.1.1" >> "$SETTINGS_CONF"
        echo "DNS2=1.0.0.1" >> "$SETTINGS_CONF"
    fi

    while true; do
        clear
        print_header "Settings & Split Tunneling"
        
        source "$SETTINGS_CONF"
        
        echo -e "Current Default MTU: ${CYAN}${MTU}${NC}"
        echo -e "Current Default DNS: ${CYAN}${DNS1}, ${DNS2}${NC}"
        echo ""
        echo "   1) Change Default MTU"
        echo "   2) Change Default DNS"
        echo "   3) View Bypassed Domains"
        echo "   4) Add Domain to Bypass"
        echo "   5) Remove Domain from Bypass"
        echo "   6) Force Recalculate AllowedIPs"
        echo "   7) Exit to Main Menu"
        echo ""
        
        read -rp "Select an option [1-7]: " OPTION
        case "$OPTION" in
            1)
                read -rp "Enter new MTU (e.g., 1280, 1420): " NEW_MTU
                if [[ "$NEW_MTU" =~ ^[0-9]+$ ]]; then
                    sed -i "s/^MTU=.*/MTU=${NEW_MTU}/" "$SETTINGS_CONF"
                    echo -e "${GREEN}MTU updated.${NC}"
                    sleep 1
                fi
                ;;
            2)
                read -rp "Enter Primary DNS: " NEW_DNS1
                read -rp "Enter Secondary DNS: " NEW_DNS2
                if [[ -n "$NEW_DNS1" ]]; then
                    sed -i "s/^DNS1=.*/DNS1=${NEW_DNS1}/" "$SETTINGS_CONF"
                fi
                if [[ -n "$NEW_DNS2" ]]; then
                    sed -i "s/^DNS2=.*/DNS2=${NEW_DNS2}/" "$SETTINGS_CONF"
                fi
                echo -e "${GREEN}DNS updated.${NC}"
                sleep 1
                ;;
            3) view_domains ;;
            4) add_domain ;;
            5) remove_domain ;;
            6) calculate_allowed_ips; read -n1 -r -p "Press any key to continue..." ;;
            7) break ;;
        esac
    done
}

# Allow running as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
    settings_menu
fi
