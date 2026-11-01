#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager (Enhanced Installer & Safe Port Management)
# ==============================================================================
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard" 
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
WG_PARAMS_FILE="/etc/wireguard/params"

# ------------------------------------------------------------------------------
# 1. Environment & Privilege Initialization
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo bash $0).${NC}"
    exit 1
fi

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

# ------------------------------------------------------------------------------
# 2. Port Safety & Compatibility Checks
# ------------------------------------------------------------------------------
isSensitivePort() {
    local port="$1"
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017)
    for sp in "${sensitive_ports[@]}"; do
        if [[ "$port" -eq "$sp" ]]; then
            return 0
        fi
    done
    return 1
}

isPortInUse() {
    local port="$1"
    local proto="${2:-udp}"
    if command -v ss &>/dev/null; then
        if [[ "$proto" == "udp" ]]; then
            ss -uln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
        else
            ss -tln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
        fi
    elif command -v netstat &>/dev/null; then
        if [[ "$proto" == "udp" ]]; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
        else
            netstat -tln 2>/dev/null | grep -qE "(:|\])${port}\s" && return 0
        fi
    fi
    return 1
}

checkVirt() {
    local VIRT=""
    if command -v virt-what &>/dev/null; then
        VIRT=$(virt-what)
    else
        VIRT=$(systemd-detect-virt 2>/dev/null || true)
    fi
    if [[ "${VIRT}" == "openvz" ]]; then
        echo -e "${RED}[ERROR] OpenVZ is not supported by WireGuard kernel modules.${NC}"
        exit 1
    fi
    if [[ "${VIRT}" == "lxc" ]]; then
        echo -e "${YELLOW}[WARNING] LXC container detected. WireGuard requires the kernel module enabled on the host.${NC}"
    fi
}

cleanupOldWireguard() {
    echo -e "\n${CYAN}[*] Checking for conflicting WireGuard interfaces & legacy rules...${NC}"

    systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@*" >/dev/null 2>&1 || true

    if command -v wg-quick >/dev/null 2>&1; then
        wg-quick down wg0 >/dev/null 2>&1 || true
        wg-quick down wg1 >/dev/null 2>&1 || true
    fi

    ip link delete dev wg0 >/dev/null 2>&1 || true
    ip link delete dev wg1 >/dev/null 2>&1 || true

    # Clean only WireGuard-specific firewall entries (preserving SSH, web, and custom chains)
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i wg1 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg1 -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s 10.18.0.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null || true

    echo -e "${GREEN}[✔] Pre-installation checks complete. Sensitive services protected.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Interactive Installation & Port Selection
# ------------------------------------------------------------------------------
install_wireguard_wizard() {
    checkVirt
    cleanupOldWireguard

    echo -e "\n${PURPLE}=================================================================${NC}"
    echo -e "          ${GREEN}${BOLD}🍪 WireGuard Server Setup: Port & Network Options${NC}"
    echo -e "${PURPLE}=================================================================${NC}"

    # Auto-detect public IP
    local DETECTED_IP=""
    local services=("https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com")
    for svc in "${services[@]}"; do
        DETECTED_IP=$(curl -4 -sSf --max-time 2 "$svc" 2>/dev/null || true)
        if [[ -n "$DETECTED_IP" && "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
    done
    if [[ -z "$DETECTED_IP" ]]; then
        DETECTED_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1 || echo "127.0.0.1")
    fi

    read -rp "IPv4 public address for server: " -e -i "${DETECTED_IP}" SERVER_PUB_IP

    # Auto-detect default network interface
    local DETECTED_NIC
    DETECTED_NIC=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || true)
    [[ -z "$DETECTED_NIC" ]] && DETECTED_NIC="eth0"
    read -rp "Public network interface: " -e -i "${DETECTED_NIC}" SERVER_PUB_NIC

    read -rp "WireGuard interface name: " -e -i "wg0" SERVER_WG_NIC
    read -rp "Server WireGuard internal IPv4: " -e -i "10.18.0.1" SERVER_WG_IPV4

    # Interactive Port Configuration
    echo -e "\n${CYAN}${BOLD}Select WireGuard UDP Port:${NC}"
    echo -e "   1) ${GREEN}51820${NC} (Official WireGuard Standard Port)"
    echo -e "   2) ${GREEN}4500${NC}  (IPsec NAT-Traversal UDP | Common Tunnel Port)"
    echo -e "   3) ${GREEN}3478${NC}  (STUN / WebRTC Media UDP)"
    echo -e "   4) ${GREEN}41194${NC} (Disguised High UDP Port)"
    echo -e "   5) Random High Port (49152-65535)"
    echo -e "   6) Custom Port"

    local SELECTED_PORT=""
    while true; do
        read -rp "Select Port option [1-6, default 1 (51820)]: " PORT_CHOICE
        PORT_CHOICE=${PORT_CHOICE:-1}

        # Handle direct numerical inputs
        if [[ "$PORT_CHOICE" =~ ^[0-9]+$ ]] && [[ "$PORT_CHOICE" -ge 1024 && "$PORT_CHOICE" -le 65535 ]]; then
            if isSensitivePort "$PORT_CHOICE"; then
                echo -e "${RED}[!] Port ${PORT_CHOICE} is a reserved service port (conflicts with Web/SSH/Mail). Choose another.${NC}"
                continue
            fi
            if isPortInUse "$PORT_CHOICE" "udp"; then
                echo -e "${YELLOW}[!] Warning: Port ${PORT_CHOICE}/udp is already bound on this host. Choose another.${NC}"
                continue
            fi
            SELECTED_PORT="$PORT_CHOICE"
            break
        fi

        case "$PORT_CHOICE" in
            1) SELECTED_PORT=51820 ; break ;;
            2) SELECTED_PORT=4500 ; break ;;
            3) SELECTED_PORT=3478 ; break ;;
            4) SELECTED_PORT=41194 ; break ;;
            5)
                SELECTED_PORT=$(( (RANDOM % 16383) + 49152 ))
                echo -e "${GREEN}[✔] Generated Random Port: ${SELECTED_PORT}/udp${NC}"
                break
                ;;
            6)
                while true; do
                    read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "51820" CUSTOM_PORT
                    if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_PORT" -lt 1024 || "$CUSTOM_PORT" -gt 65535 ]]; then
                        echo -e "${RED}[!] Invalid port number.${NC}"
                        continue
                    fi
                    if isSensitivePort "$CUSTOM_PORT"; then
                        echo -e "${RED}[!] Port ${CUSTOM_PORT} conflicts with a sensitive system port. Choose another.${NC}"
                        continue
                    fi
                    if isPortInUse "$CUSTOM_PORT" "udp"; then
                        echo -e "${YELLOW}[!] Warning: Port ${CUSTOM_PORT}/udp is in use. Choose another.${NC}"
                        continue
                    fi
                    SELECTED_PORT="$CUSTOM_PORT"
                    break
                done
                break
                ;;
            *)
                echo -e "${RED}[!] Invalid selection.${NC}"
                ;;
        esac
    done

    echo -e "${GREEN}[✔] Port selected: ${SELECTED_PORT}/udp${NC}\n"

    # Persist parameters for the core setup script
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    cat << EOF > "$WG_PARAMS_FILE"
SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_PORT=${SELECTED_PORT}
EOF
    chmod 600 "$WG_PARAMS_FILE"

    echo -e "${GREEN}Executing server installation script...${NC}"
    fetch_and_run "setup_server.sh"
}

# ------------------------------------------------------------------------------
# 4. Modular Sub-script Fetcher & Settings Management
# ------------------------------------------------------------------------------
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

settings_menu() {
    while true; do
        clear
        print_banner
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│                      Settings                      │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        printf "${PURPLE}│ ${GREEN}[1] Default MTU: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_MTU:-1420}"
        printf "${PURPLE}│ ${GREEN}[2] Default DNS: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_DNS:-"94.140.14.49, 9.9.9.9, 94.140.14.59"}"
        printf "${PURPLE}│ ${GREEN}[3] Default Allowed IPs: ${NC}%-25s ${PURPLE}│${NC}\n" "${DEFAULT_ALLOWED_IPS:-"0.0.0.0/1, 128.0.0.0/1"}"
        echo -e "${PURPLE}│ ${GREEN}[b] Back to Main Menu                             ${PURPLE}│${NC}"
        echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
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
            b) break ;;
        esac
    done
}

print_banner() {
    echo -e "${PURPLE}======================================================${NC}"
    echo -e "${GREEN}       🍪 Cookie's Easy WireGuard Manager${NC}"
    echo -e "${PURPLE}======================================================${NC}"
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│                  Main Menu Actions                 │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Setup WireGuard server                        ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Add new client (peer)                         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[3] Configure clients (Check/Edit/Remove)         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[4] Backup & Restore Manager                      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[5] Domain-Based Split Tunneling                  ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[6] Real-Time Logging (Errors)                    ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[7] Geo-IP & Anti-VPN Shield (US/CA Only)         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[s] Settings (MTU, DNS, AllowedIPs)               ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[r] Remove WireGuard server from this system      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[q] Exit                                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

# ------------------------------------------------------------------------------
# 5. Execution Loop
# ------------------------------------------------------------------------------
main() {
    while true; do
        clear
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r OPTION

        case "$OPTION" in
            1) install_wireguard_wizard ;;
            2) fetch_and_run "add_client.sh" ;;
            3) fetch_and_run "user_manager.sh" ;;
            4) fetch_and_run "backup_manager.sh" ;;
            5) fetch_and_run "domain_bypass.sh" ;;
            6) 
                echo -e "\n${GREEN}Starting Real-Time Logging for WireGuard errors (last 12 hours)...${NC}"
                echo -e "${PURPLE}Press Ctrl+C to stop logging and return to menu.${NC}\n"
                journalctl -u wg-quick@wg0.service --since "12 hours ago" -p err -f || true
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            7) fetch_and_run "geo_vpn_filter.sh" ;;
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
                sleep 1
                ;;
        esac
    done
}

main