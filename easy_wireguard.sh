#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager
# ==============================================================================
# Strict mode for maximum stability and security
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

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
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
# 1. Sensitive Port Protection & Port-In-Use Verification
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

# ------------------------------------------------------------------------------
# 2. Comprehensive Old WireGuard & Port Cleanup (Sensitive Ports Protected)
# ------------------------------------------------------------------------------
cleanupOldWireguard() {
    echo -e "\n${CYAN}[*] Cleaning up any existing WireGuard instances and ports...${NC}"

    # 1. Collect all ports and interface names from existing configs & live wg interfaces
    local OLD_PORTS=()
    local OLD_IFACES=("wg0" "wg1")

    if [[ -d /etc/wireguard ]]; then
        for conf in /etc/wireguard/*.conf; do
            [[ ! -f "$conf" ]] && continue
            local iface_name
            iface_name=$(basename "$conf" .conf)
            OLD_IFACES+=("$iface_name")

            local extracted_ports
            extracted_ports=$(grep -iE "^\s*ListenPort\s*=" "$conf" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || true)
            for p in $extracted_ports; do
                [[ "$p" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$p")
            done
        done
    fi

    if command -v wg &>/dev/null; then
        local live_ifaces
        live_ifaces=$(wg show interfaces 2>/dev/null || true)
        for liface in $live_ifaces; do
            OLD_IFACES+=("$liface")
            local lport
            lport=$(wg show "$liface" listen-port 2>/dev/null | tr -d ' \t\r\n' || true)
            [[ "$lport" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$lport")
        done
    fi

    # Also check ip link for any lingering wg* interfaces
    local link_ifaces
    link_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wg[0-9]+' || true)
    for kiface in $link_ifaces; do
        OLD_IFACES+=("$kiface")
    done

    # Deduplicate arrays
    local UNIQUE_IFACES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && UNIQUE_IFACES+=("$line")
    done < <(printf "%s\n" "${OLD_IFACES[@]}" | sort -u)

    local UNIQUE_PORTS=()
    if [[ ${#OLD_PORTS[@]} -gt 0 ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && UNIQUE_PORTS+=("$line")
        done < <(printf "%s\n" "${OLD_PORTS[@]}" | sort -u)
    fi

    # 2. Stop and disable all systemd wg-quick services
    systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@*" >/dev/null 2>&1 || true

    # 3. Bring down and delete all discovered WireGuard interfaces & rules
    for iface in "${UNIQUE_IFACES[@]}"; do
        systemctl stop "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        systemctl disable "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        if command -v wg-quick &>/dev/null; then
            wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        ip link set "$iface" down >/dev/null 2>&1 || true
        ip link delete dev "$iface" >/dev/null 2>&1 || true

        # Clean all iptables/ip6tables FORWARD/INPUT/OUTPUT rules tied to this interface
        while iptables -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -o "$iface" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -o "$iface" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i "$iface" -j REJECT 2>/dev/null; do :; done
        while ip6tables -D OUTPUT -o "$iface" -j REJECT 2>/dev/null; do :; done
    done

    # 4. Clean up all discovered WireGuard UDP ports (strictly skipping sensitive ports)
    for port in "${UNIQUE_PORTS[@]}"; do
        if isSensitivePort "$port"; then
            echo -e "${YELLOW}[!] Skipping sensitive port ${port} during cleanup.${NC}"
            continue
        fi
        echo -e "${CYAN} -> Cleaning firewall rules for old WireGuard port ${port}/udp...${NC}"
        while iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done

        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    done

    # 5. Clean WireGuard NAT & Mangle rules without touching Docker/Web chains
    local wg_subnets=("10.18.0.0/24" "10.19.0.0/24" "10.8.0.0/24" "10.0.0.0/24" "10.66.66.0/24")
    local def_nic
    def_nic=$(ip -4 route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

    for sub in "${wg_subnets[@]}"; do
        while iptables -D FORWARD -s "$sub" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -d "$sub" -j ACCEPT 2>/dev/null; do :; done
        while iptables -t nat -D POSTROUTING -s "$sub" -j MASQUERADE 2>/dev/null; do :; done
        while iptables -t nat -D POSTROUTING -s "$sub" -o "$def_nic" -j MASQUERADE 2>/dev/null; do :; done
        while iptables -t nat -D POSTROUTING -s "$sub" ! -o wg0 -j MASQUERADE 2>/dev/null; do :; done
    done

    while iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -o "$def_nic" -j TTL --ttl-set 64 2>/dev/null; do :; done
    while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64 2>/dev/null; do :; done

    # 6. Remove stale WireGuard configs so installation starts completely fresh
    rm -f /etc/wireguard/wg*.conf /etc/wireguard/params 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    echo -e "${GREEN}[✔] Cleaned all old WireGuard instances & ports. Sensitive ports (80, 443, 22, etc.) untouched.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Pre-fetch Required Companion Scripts (Fixes Status 127 Missing Script Error)
# ------------------------------------------------------------------------------
prefetch_companion_scripts() {
    local scripts=("setup_server.sh" "add_client.sh" "user_manager.sh" "backup_manager.sh" "domain_bypass.sh" "geo_vpn_filter.sh" "remove_server.sh")
    echo -e "\n${CYAN}[*] Syncing companion scripts into ${INSTALL_DIR} (prevents missing PostUp script errors)...${NC}"
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    for s in "${scripts[@]}"; do
        if [[ -f "./${s}" ]]; then
            cp -f "./${s}" "${INSTALL_DIR}/${s}"
            chmod 700 "${INSTALL_DIR}/${s}"
        elif [[ ! -f "${INSTALL_DIR}/${s}" ]]; then
            if curl -sSfL "${GIT_REPO}/${s}" -o "${INSTALL_DIR}/${s}" 2>/dev/null; then
                chmod 700 "${INSTALL_DIR}/${s}"
            else
                # Create a safe no-op fallback if geo_vpn_filter.sh is called by wg0.conf PostUp before being configured
                if [[ "$s" == "geo_vpn_filter.sh" ]]; then
                    cat << 'EOF' > "${INSTALL_DIR}/geo_vpn_filter.sh"
#!/bin/bash
exit 0
EOF
                    chmod 700 "${INSTALL_DIR}/geo_vpn_filter.sh"
                fi
            fi
        else
            chmod 700 "${INSTALL_DIR}/${s}"
        fi
    done
}

# ------------------------------------------------------------------------------
# 4. Patch & Run Setup Server (Single Port Prompt AFTER Dependencies)
# ------------------------------------------------------------------------------
run_setup_server() {
    cleanupOldWireguard
    prefetch_companion_scripts

    local target_script="${INSTALL_DIR}/setup_server.sh"
    if [[ -f "./setup_server.sh" ]]; then
        cp -f "./setup_server.sh" "$target_script"
    else
        echo -e "\n${GREEN}Fetching latest version of setup_server.sh...${NC}"
        if ! curl -sSfL "${GIT_REPO}/setup_server.sh" -o "$target_script"; then
            echo -e "${RED}Error: Failed to pull setup_server.sh from ${GIT_REPO}.${NC}"
            exit 1
        fi
    fi
    chmod 700 "$target_script"

    # Build the safe interactive port selector snippet to inject into setup_server.sh
    local port_selector_file="${INSTALL_DIR}/.port_selector.sh"
    cat << 'PORT_EOF' > "$port_selector_file"
select_safe_wg_port() {
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 8080 8443 3306 5432 6379 27017)
    is_sens() {
        local p="$1"
        for sp in "${sensitive_ports[@]}"; do [[ "$p" -eq "$sp" ]] && return 0; done
        return 1
    }
    is_used() {
        local p="$1"
        if command -v ss &>/dev/null; then
            ss -uln 2>/dev/null | grep -qE "(:|\])${p}\s" && return 0
        elif command -v netstat &>/dev/null; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${p}\s" && return 0
        fi
        return 1
    }

    echo -e "\n\033[0;36m\033[1mSelect WireGuard UDP Port:\033[0m"
    echo -e "   1) \033[0;32m4500\033[0m  (IPsec NAT-Traversal UDP | Stealth Encrypted Tunneling) \033[0;35m[RECOMMENDED]\033[0m"
    echo -e "   2) \033[0;32m3478\033[0m  (STUN / WebRTC Media UDP | VoIP Bypass)"
    echo -e "   3) \033[0;32m500\033[0m   (IKEv2 / IPsec Signaling UDP)"
    echo -e "   4) \033[0;32m853\033[0m   (DNS-over-QUIC UDP)"
    echo -e "   5) \033[0;32m51820\033[0m (Official WireGuard Standard Port)"
    echo -e "   6) \033[0;32m41194\033[0m (Disguised High Tunnel UDP)"
    echo -e "   7) Random High-Entropy Stealth Port (49152-65535)"
    echo -e "   8) Custom Port (Or type any port directly, e.g. 8008)"

    while true; do
        read -rp "Select Port option [1-8, or type port directly, default 1 (4500)]: " PORT_OPT
        PORT_OPT=${PORT_OPT:-1}

        if [[ "$PORT_OPT" =~ ^[0-9]+$ ]] && [[ "$PORT_OPT" -ge 1024 && "$PORT_OPT" -le 65535 ]]; then
            if is_sens "$PORT_OPT"; then
                echo -e "\033[0;31m[!] Port ${PORT_OPT} is a sensitive service port (80/443/22/etc.). Please choose a safe port.\033[0m"
                continue
            fi
            if is_used "$PORT_OPT"; then
                echo -e "\033[1;33m[!] Warning: Port ${PORT_OPT}/udp is currently in use on this host. Choose another.\033[0m"
                continue
            fi
            SELECTED_WG_PORT="$PORT_OPT"
            break
        fi

        case "$PORT_OPT" in
            1) SELECTED_WG_PORT=4500 ; break ;;
            2) SELECTED_WG_PORT=3478 ; break ;;
            3) SELECTED_WG_PORT=500 ; break ;;
            4) SELECTED_WG_PORT=853 ; break ;;
            5) SELECTED_WG_PORT=51820 ; break ;;
            6) SELECTED_WG_PORT=41194 ; break ;;
            7)
                SELECTED_WG_PORT=$(( (RANDOM % 16383) + 49152 ))
                echo -e "\033[0;32m[✔] Generated Random Stealth High Port: ${SELECTED_WG_PORT}/udp\033[0m"
                break
                ;;
            8)
                while true; do
                    read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "8008" CUSTOM_P
                    if ! [[ "$CUSTOM_P" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_P" -lt 1024 || "$CUSTOM_P" -gt 65535 ]]; then
                        echo -e "\033[0;31m[!] Invalid port. Enter a port between 1024 and 65535.\033[0m"
                        continue
                    fi
                    if is_sens "$CUSTOM_P"; then
                        echo -e "\033[0;31m[!] Port ${CUSTOM_P} conflicts with sensitive services (80/443/22/etc.). Choose another.\033[0m"
                        continue
                    fi
                    if is_used "$CUSTOM_P"; then
                        echo -e "\033[1;33m[!] Warning: Port ${CUSTOM_P}/udp is currently in use. Choose another.\033[0m"
                        continue
                    fi
                    SELECTED_WG_PORT="$CUSTOM_P"
                    break
                done
                break
                ;;
            *)
                echo -e "\033[0;31m[!] Invalid option. Enter 1-8 or a port number (1024-65535).\033[0m"
                ;;
        esac
    done
    echo -e "\033[0;32m[✔] WireGuard Port Confirmed: ${SELECTED_WG_PORT}/udp\033[0m\n"
    PORT="$SELECTED_WG_PORT"
    SERVER_PORT="$SELECTED_WG_PORT"
    WG_PORT="$SELECTED_WG_PORT"
}
PORT_EOF

    # Patch setup_server.sh so:
    # 1. Any early port prompt is removed/replaced by a single port prompt AFTER "Installing WireGuard and required dependencies..."
    # 2. PostUp geo_vpn_filter.sh call is guarded so it never causes exit code 127 if absent
    if command -v python3 &>/dev/null; then
        python3 - "$target_script" "$port_selector_file" << 'PY_EOF'
import sys, re

script_path = sys.argv[1]
selector_path = sys.argv[2]

with open(script_path, 'r') as f:
    content = f.read()

with open(selector_path, 'r') as f:
    selector_code = f.read()

# 1. Guard geo_vpn_filter.sh in PostUp so wg-quick never fails with exit status 127
content = re.sub(
    r'PostUp\s*=\s*(/root/easy_wireguard/geo_vpn_filter\.sh\s+--apply)(?!\s*\|\|)',
    r'PostUp = test -x /root/easy_wireguard/geo_vpn_filter.sh && \1 || true',
    content
)

# 2. Neutralize any existing interactive port read prompts in setup_server.sh so it doesn't ask twice
lines = content.splitlines()
new_lines = []
skip_until_esac = False

for i, line in enumerate(lines):
    # If setup_server.sh has its own port prompt (e.g. read ... PORT), comment out that prompt block
    if re.search(r'read\s+.*(PORT|SERVER_PORT|WG_PORT)', line) and 'select_safe_wg_port' not in content:
        new_lines.append('# ' + line + ' # replaced by select_safe_wg_port')
        continue
    new_lines.append(line)

content = '\n'.join(new_lines) + '\n'

# 3. Inject selector function at top (after shebang) and invoke it right after dependency installation finishes
if 'select_safe_wg_port' not in content:
    content = re.sub(r'^(#!/bin/bash[^\n]*\n)', r'\1\n' + selector_code + '\n', content, count=1)

    # Look for the "Installing WireGuard and required dependencies..." block and place select_safe_wg_port after apt-get/yum/apk install
    dep_match = re.search(r'(Installing WireGuard and required dependencies[\s\S]*?(?:apt-get|apt|yum|dnf|pacman|apk)\s+install[^\n]+\n(?:\s*fi\n)?)', content)
    if dep_match:
        insert_pos = dep_match.end()
        content = content[:insert_pos] + '\nselect_safe_wg_port\n' + content[insert_pos:]
    else:
        # Fallback: place right before wg genkey or /etc/wireguard/wg0.conf creation
        key_match = re.search(r'(wg\s+genkey|cat\s+<<\s*EOF\s*>\s*["\']?/etc/wireguard/wg0\.conf)', content)
        if key_match:
            insert_pos = key_match.start()
            content = content[:insert_pos] + '\nselect_safe_wg_port\n' + content[insert_pos:]

with open(script_path, 'w') as f:
    f.write(content)
PY_EOF
    fi

    rm -f "$port_selector_file"
    "$target_script"
}

# ------------------------------------------------------------------------------
# 5. Modular Sub-script Fetcher & Settings Management
# ------------------------------------------------------------------------------
fetch_and_run() {
    local script_name="$1"
    local script_path="./${script_name}"

    if [[ -f "$script_path" ]]; then
        echo -e "\n${GREEN}Running local version of ${script_name}...${NC}"
        chmod +x "$script_path"
        cp -f "$script_path" "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
        chmod 700 "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
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

main() {
    # Loop the main menu so it returns after completing a task
    while true; do
        clear
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r OPTION

        case "$OPTION" in
            1) run_setup_server ;;
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
                cleanupOldWireguard
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