#!/bin/bash
# Strict mode for maximum stability and security
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

CACHE_DIR="/etc/wireguard/geo_cache"
US_CA_CACHE="${CACHE_DIR}/us_ca_geo.zone"
VPN_CACHE="${CACHE_DIR}/vpn_datacenter.zone"
CUSTOM_ALLOW="${CACHE_DIR}/custom_allow.list"
CUSTOM_BLOCK="${CACHE_DIR}/custom_block.list"

SET_ALLOWED="wg_allowed_geo"
SET_BLOCKED="wg_blocked_vpns"

CHAIN_ALLOWED="WG_ALLOWED_GEO"
CHAIN_BLOCKED="WG_BLOCKED_VPNS"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

check_ipset_support() {
    if command -v ipset &>/dev/null; then
        if ipset create wg_test_set hash:net -exist 2>/dev/null; then
            ipset destroy wg_test_set 2>/dev/null || true
            echo "true"
            return 0
        fi
    fi
    echo "false"
    return 0
}

USE_IPSET=$(check_ipset_support)

init_env() {
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
    touch "$CUSTOM_ALLOW" "$CUSTOM_BLOCK"
    chmod 600 "$CUSTOM_ALLOW" "$CUSTOM_BLOCK"

    if command -v ipset &>/dev/null && [[ "$USE_IPSET" == "true" ]]; then
        ipset create "$SET_ALLOWED" hash:net maxelem 200000 -exist 2>/dev/null || ipset create "$SET_ALLOWED" hash:net -exist 2>/dev/null || true
        ipset create "$SET_BLOCKED" hash:net maxelem 200000 -exist 2>/dev/null || ipset create "$SET_BLOCKED" hash:net -exist 2>/dev/null || true
    fi
}

get_wireguard_ports() {
    local ports=()
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        local listen_port ext_port
        listen_port=$(grep -i "^ListenPort" /etc/wireguard/wg0.conf | awk -F'=' '{print $2}' | tr -d ' ' || true)
        ext_port=$(grep -i "^# ExternalPort" /etc/wireguard/wg0.conf | awk -F'=' '{print $2}' | tr -d ' ' || true)

        if [[ -n "$listen_port" ]]; then ports+=("$listen_port"); fi
        if [[ -n "$ext_port" && "$ext_port" != "$listen_port" ]]; then ports+=("$ext_port"); fi
    fi

    if [[ ${#ports[@]} -eq 0 ]]; then
        ports=(443 51820)
    fi

    echo "${ports[@]}"
}

generate_baseline_caches() {
    if [[ ! -s "$US_CA_CACHE" ]]; then
        echo -e "${GREEN}Generating baseline USA & Canada IP database...${NC}"
        cat <<'EOF' > "$US_CA_CACHE"
# Baseline US & CA IP Ranges
3.0.0.0/9
4.0.0.0/8
8.0.0.0/8
12.0.0.0/8
15.0.0.0/8
16.0.0.0/8
17.0.0.0/8
20.0.0.0/8
24.0.0.0/8
23.16.0.0/12
24.48.0.0/12
24.64.0.0/11
24.96.0.0/11
24.114.0.0/15
24.137.0.0/16
24.141.0.0/16
24.156.0.0/14
24.222.0.0/15
24.244.0.0/15
50.64.0.0/11
64.0.0.0/10
65.0.0.0/8
66.0.0.0/8
67.0.0.0/8
68.0.0.0/8
69.0.0.0/8
70.0.0.0/8
71.0.0.0/8
72.0.0.0/8
73.0.0.0/8
74.0.0.0/8
75.0.0.0/8
76.0.0.0/8
96.0.0.0/8
97.0.0.0/8
98.0.0.0/8
99.0.0.0/8
100.64.0.0/10
104.0.0.0/8
107.0.0.0/8
108.0.0.0/8
142.112.0.0/12
142.166.0.0/15
172.56.0.0/12
173.0.0.0/8
174.0.0.0/8
184.0.0.0/8
192.206.0.0/15
198.52.0.0/15
198.84.0.0/14
198.90.0.0/15
198.96.0.0/13
199.212.0.0/14
204.101.0.0/16
205.200.0.0/13
206.0.0.0/8
207.0.0.0/8
208.0.0.0/8
209.0.0.0/8
216.0.0.0/8
EOF
    fi

    if [[ ! -s "$VPN_CACHE" ]]; then
        echo -e "${GREEN}Generating baseline VPN & Datacenter IP blocklist...${NC}"
        cat <<'EOF' > "$VPN_CACHE"
# Baseline VPN, Datacenter, Cloud, & Proxy Subnets (NordVPN, M247, AWS, GCP, DigitalOcean, Hetzner, etc.)
3.5.0.0/16
13.32.0.0/12
18.128.0.0/9
34.192.0.0/10
35.152.0.0/13
45.56.0.0/15
45.79.0.0/16
52.0.0.0/10
54.64.0.0/11
64.227.0.0/16
66.249.64.0/19
89.187.160.0/19
104.131.0.0/16
104.236.0.0/16
104.248.0.0/16
138.68.0.0/16
138.197.0.0/16
142.93.0.0/16
143.198.0.0/16
146.190.0.0/16
157.230.0.0/16
159.65.0.0/16
159.89.0.0/16
161.35.0.0/16
164.90.0.0/16
165.22.0.0/16
167.99.0.0/16
167.172.0.0/16
178.62.0.0/16
178.128.0.0/16
188.166.0.0/16
185.220.100.0/22
185.220.101.0/24
192.241.128.0/17
198.199.64.0/18
198.211.96.0/19
206.189.0.0/16
207.154.0.0/16
209.97.128.0/17
EOF
    fi
}

update_ip_databases() {
    echo -e "${GREEN}Fetching latest USA & Canada IP ranges...${NC}"
    local tmp_us_ca
    tmp_us_ca=$(mktemp)
    trap 'rm -f "$tmp_us_ca"' EXIT

    if curl -sSfL "https://www.ipdeny.com/ipblocks/data/countries/us.zone" >> "$tmp_us_ca" 2>/dev/null && \
       curl -sSfL "https://www.ipdeny.com/ipblocks/data/countries/ca.zone" >> "$tmp_us_ca" 2>/dev/null; then
        if [[ -s "$tmp_us_ca" ]]; then
            cp "$tmp_us_ca" "$US_CA_CACHE"
            echo -e "${GREEN}Successfully updated USA & Canada IP database!${NC}"
        fi
    else
        echo -e "${ORANGE}Warning: Failed to fetch online Geo-IP updates. Using local cache.${NC}"
    fi

    echo -e "${GREEN}Fetching latest VPN, Datacenter, & Proxy blocklists...${NC}"
    local tmp_vpn
    tmp_vpn=$(mktemp)
    trap 'rm -f "$tmp_vpn"' EXIT

    if curl -sSfL "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/datacenter.netset" >> "$tmp_vpn" 2>/dev/null || \
       curl -sSfL "https://raw.githubusercontent.com/stampede-app/ip-range-blocks/main/datacenter_vpn_proxy.txt" >> "$tmp_vpn" 2>/dev/null; then
        if [[ -s "$tmp_vpn" ]]; then
            grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$tmp_vpn" > "$VPN_CACHE" || true
            echo -e "${GREEN}Successfully updated VPN/Datacenter blocklists!${NC}"
        fi
    else
        echo -e "${ORANGE}Warning: Failed to fetch online VPN blocklists. Using local cache.${NC}"
    fi

    trap - EXIT
}

load_ipsets_or_chains() {
    init_env
    generate_baseline_caches

    if [[ "$USE_IPSET" == "true" ]]; then
        echo -e "${GREEN}Loading USA & Canada allowed IP set into kernel (ipset)...${NC}"
        local restore_file
        restore_file=$(mktemp)
        trap 'rm -f "$restore_file"' EXIT

        {
            echo "create $SET_ALLOWED hash:net maxelem 200000 -exist"
            echo "flush $SET_ALLOWED"
            grep -h -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$US_CA_CACHE" "$CUSTOM_ALLOW" 2>/dev/null | sed 's/^/add '"$SET_ALLOWED"' /'
        } > "$restore_file"

        ipset restore < "$restore_file"

        echo -e "${GREEN}Loading VPN & Datacenter blocked IP set into kernel (ipset)...${NC}"
        {
            echo "create $SET_BLOCKED hash:net maxelem 200000 -exist"
            echo "flush $SET_BLOCKED"
            grep -h -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$VPN_CACHE" "$CUSTOM_BLOCK" 2>/dev/null | sed 's/^/add '"$SET_BLOCKED"' /'
        } > "$restore_file"

        ipset restore < "$restore_file"
        trap - EXIT
    else
        echo -e "${GREEN}Loading Geo-IP & Anti-VPN rules into iptables chains...${NC}"
        iptables -N "$CHAIN_BLOCKED" 2>/dev/null || iptables -F "$CHAIN_BLOCKED"
        iptables -N "$CHAIN_ALLOWED" 2>/dev/null || iptables -F "$CHAIN_ALLOWED"

        # Populate blocked chain
        while read -r cidr; do
            [[ -z "$cidr" || "$cidr" =~ ^# ]] && continue
            iptables -A "$CHAIN_BLOCKED" -s "$cidr" -j DROP
        done < <(grep -h -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$VPN_CACHE" "$CUSTOM_BLOCK" 2>/dev/null || true)
        iptables -A "$CHAIN_BLOCKED" -j RETURN

        # Populate allowed chain
        while read -r cidr; do
            [[ -z "$cidr" || "$cidr" =~ ^# ]] && continue
            iptables -A "$CHAIN_ALLOWED" -s "$cidr" -j RETURN
        done < <(grep -h -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' "$US_CA_CACHE" "$CUSTOM_ALLOW" 2>/dev/null || true)
        iptables -A "$CHAIN_ALLOWED" -j DROP
    fi
}

apply_firewall_rules() {
    load_ipsets_or_chains

    local ports
    ports=$(get_wireguard_ports)

    echo -e "${GREEN}Applying Geo-IP (US/CA Only) and Anti-VPN firewall rules...${NC}"
    for port in $ports; do
        if [[ "$USE_IPSET" == "true" ]]; then
            iptables -C INPUT -p udp --dport "$port" -m set --match-set "$SET_BLOCKED" src -j DROP 2>/dev/null || \
            iptables -I INPUT 1 -p udp --dport "$port" -m set --match-set "$SET_BLOCKED" src -j DROP

            iptables -C INPUT -p udp --dport "$port" -m set ! --match-set "$SET_ALLOWED" src -j DROP 2>/dev/null || \
            iptables -I INPUT 2 -p udp --dport "$port" -m set ! --match-set "$SET_ALLOWED" src -j DROP
        else
            iptables -C INPUT -p udp --dport "$port" -j "$CHAIN_BLOCKED" 2>/dev/null || \
            iptables -I INPUT 1 -p udp --dport "$port" -j "$CHAIN_BLOCKED"

            iptables -C INPUT -p udp --dport "$port" -j "$CHAIN_ALLOWED" 2>/dev/null || \
            iptables -I INPUT 2 -p udp --dport "$port" -j "$CHAIN_ALLOWED"
        fi

        echo -e "${PURPLE}- Protected UDP Port ${port}: Allowed origins = US/CA only | VPN/Datacenter = BLOCKED${NC}"
    done
}

remove_firewall_rules() {
    local ports
    ports=$(get_wireguard_ports)

    echo -e "${ORANGE}Removing Geo-IP and Anti-VPN firewall rules...${NC}"
    for port in $ports; do
        if [[ "$USE_IPSET" == "true" ]]; then
            while iptables -D INPUT -p udp --dport "$port" -m set --match-set "$SET_BLOCKED" src -j DROP 2>/dev/null; do :; done
            while iptables -D INPUT -p udp --dport "$port" -m set ! --match-set "$SET_ALLOWED" src -j DROP 2>/dev/null; do :; done
        else
            while iptables -D INPUT -p udp --dport "$port" -j "$CHAIN_BLOCKED" 2>/dev/null; do :; done
            while iptables -D INPUT -p udp --dport "$port" -j "$CHAIN_ALLOWED" 2>/dev/null; do :; done
        fi
        echo -e "${ORANGE}- Unprotected UDP Port ${port}${NC}"
    done

    if iptables -L "$CHAIN_BLOCKED" -n &>/dev/null; then
        iptables -F "$CHAIN_BLOCKED" 2>/dev/null || true
        iptables -X "$CHAIN_BLOCKED" 2>/dev/null || true
    fi

    if iptables -L "$CHAIN_ALLOWED" -n &>/dev/null; then
        iptables -F "$CHAIN_ALLOWED" 2>/dev/null || true
        iptables -X "$CHAIN_ALLOWED" 2>/dev/null || true
    fi
}

show_status() {
    init_env
    local ports
    ports=$(get_wireguard_ports)

    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}        🛡️ Geo-IP & Anti-VPN Shield Status${NC}"
    echo -e "${PURPLE}======================================================${NC}"

    local allowed_count blocked_count
    if [[ "$USE_IPSET" == "true" ]]; then
        allowed_count=$(ipset list "$SET_ALLOWED" 2>/dev/null | grep -E -c '^[0-9]{1,3}\.' || echo 0)
        blocked_count=$(ipset list "$SET_BLOCKED" 2>/dev/null | grep -E -c '^[0-9]{1,3}\.' || echo 0)
        echo -e "${GREEN}Engine: ${PURPLE}Kernel ipset (O(1) Hash Accelerator)${NC}"
    else
        allowed_count=$(grep -h -E -c '^[0-9]{1,3}\.' "$US_CA_CACHE" "$CUSTOM_ALLOW" 2>/dev/null || echo 0)
        blocked_count=$(grep -h -E -c '^[0-9]{1,3}\.' "$VPN_CACHE" "$CUSTOM_BLOCK" 2>/dev/null || echo 0)
        echo -e "${GREEN}Engine: ${PURPLE}iptables Netfilter Chains${NC}"
    fi

    echo -e "${GREEN}Allowed US/CA Subnets: ${PURPLE}${allowed_count}${NC}"
    echo -e "${GREEN}Blocked VPN/Datacenter Subnets: ${PURPLE}${blocked_count}${NC}"
    echo -e "\n${GREEN}Protected WireGuard UDP Ports:${NC}"

    for port in $ports; do
        local active=false
        if [[ "$USE_IPSET" == "true" ]]; then
            if iptables -C INPUT -p udp --dport "$port" -m set --match-set "$SET_BLOCKED" src -j DROP 2>/dev/null && \
               iptables -C INPUT -p udp --dport "$port" -m set ! --match-set "$SET_ALLOWED" src -j DROP 2>/dev/null; then
                active=true
            fi
        else
            if iptables -C INPUT -p udp --dport "$port" -j "$CHAIN_BLOCKED" 2>/dev/null && \
               iptables -C INPUT -p udp --dport "$port" -j "$CHAIN_ALLOWED" 2>/dev/null; then
                active=true
            fi
        fi

        if [[ "$active" == "true" ]]; then
            echo -e " - Port ${port}: ${GREEN}ACTIVE (US/CA Only, VPN Blocked)${NC}"
        else
            echo -e " - Port ${port}: ${RED}INACTIVE / UNPROTECTED${NC}"
        fi
    done
    echo -e "${PURPLE}======================================================${NC}"
}

add_custom_ip() {
    local type="$1"
    local ip="$2"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo -e "${RED}Error: Invalid IPv4 address or CIDR format: ${ip}${NC}"
        return 1
    fi

    init_env
    if [[ "$type" == "allow" ]]; then
        echo "$ip" >> "$CUSTOM_ALLOW"
        if [[ "$USE_IPSET" == "true" ]]; then
            ipset add "$SET_ALLOWED" "$ip" -exist 2>/dev/null || true
        else
            iptables -I "$CHAIN_ALLOWED" 1 -s "$ip" -j RETURN 2>/dev/null || true
        fi
        echo -e "${GREEN}Added ${ip} to custom ALLOW list.${NC}"
    else
        echo "$ip" >> "$CUSTOM_BLOCK"
        if [[ "$USE_IPSET" == "true" ]]; then
            ipset add "$SET_BLOCKED" "$ip" -exist 2>/dev/null || true
        else
            iptables -I "$CHAIN_BLOCKED" 1 -s "$ip" -j DROP 2>/dev/null || true
        fi
        echo -e "${GREEN}Added ${ip} to custom BLOCK list.${NC}"
    fi
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│        🛡️ Geo-IP & Anti-VPN Shield Settings        │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Check Protection Status                        ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Enable Shield (US/CA Only + Block VPNs)        ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[3] Disable Shield (Allow Global Connections)       ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[4] Update IP Databases (Fetch Latest Rules)     ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[5] Manually Whitelist IP/CIDR                     ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[6] Manually Blacklist IP/CIDR                     ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[b] Back to Main Menu                              ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

menu() {
    while true; do
        clear
        echo -e "${PURPLE}======================================================${NC}"
        echo -e "${GREEN}       🍪 Cookie's WireGuard Security Shield${NC}"
        echo -e "${PURPLE}======================================================${NC}"
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r opt

        case "$opt" in
            1)
                show_status
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            2)
                apply_firewall_rules
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            3)
                remove_firewall_rules
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            4)
                update_ip_databases
                apply_firewall_rules
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            5)
                echo -en "${GREEN}Enter IP or CIDR to whitelist (e.g. 1.2.3.4 or 1.2.3.0/24): ${NC}"
                read -r user_ip
                add_custom_ip "allow" "$user_ip"
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            6)
                echo -en "${GREEN}Enter IP or CIDR to blacklist (e.g. 5.6.7.8 or 5.6.7.0/24): ${NC}"
                read -r user_ip
                add_custom_ip "block" "$user_ip"
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            b) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

# Main entry point
case "${1:-}" in
    --apply)
        apply_firewall_rules
        ;;
    --remove)
        remove_firewall_rules
        ;;
    --update)
        update_ip_databases
        apply_firewall_rules
        ;;
    --status)
        show_status
        ;;
    --allow-ip)
        if [[ -n "${2:-}" ]]; then
            add_custom_ip "allow" "$2"
        else
            echo -e "${RED}Error: --allow-ip requires an IP argument.${NC}"
            exit 1
        fi
        ;;
    --block-ip)
        if [[ -n "${2:-}" ]]; then
            add_custom_ip "block" "$2"
        else
            echo -e "${RED}Error: --block-ip requires an IP argument.${NC}"
            exit 1
        fi
        ;;
    --menu)
        menu
        ;;
    *)
        menu
        ;;
esac
