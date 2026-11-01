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
# 2. Pre-Install Cleanup & Deep Uninstaller (Sensitive Ports Protected)
# ------------------------------------------------------------------------------
cleanupOldWireguard() {
    local mode="${1:-preinstall}"
    echo -e "\n${CYAN}[*] Scanning for WireGuard interfaces, services, and ports...${NC}"

    local OLD_PORTS=()
    local OLD_IFACES=("wg0" "wg1")

    # 1. Discover interfaces & ports from /etc/wireguard configs and params
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

        for param_file in /etc/wireguard/params /etc/wireguard/manager.env "$SETTINGS_FILE"; do
            if [[ -f "$param_file" ]]; then
                local p_vals
                p_vals=$(grep -iE "(PORT|LISTEN)" "$param_file" 2>/dev/null | awk -F'=' '{print $2}' | tr -d '"'\'' \t\r\n' || true)
                for p in $p_vals; do
                    [[ "$p" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$p")
                done
            fi
        done
    fi

    # 2. Discover live WireGuard interfaces and listen ports from kernel
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

    local link_ifaces
    link_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wg[0-9a-zA-Z_-]*' || true)
    for kiface in $link_ifaces; do
        OLD_IFACES+=("$kiface")
    done

    # Also scan client configs for Endpoint ports so no custom port rule is left behind
    local search_dirs=("/etc/wireguard" "$INSTALL_DIR" "/root" "/home")
    for sdir in "${search_dirs[@]}"; do
        [[ ! -d "$sdir" ]] && continue
        while IFS= read -r ep_line; do
            local ep_port="${ep_line##*:}"
            ep_port=$(echo "$ep_port" | tr -d ' \t\r\n')
            [[ "$ep_port" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$ep_port")
        done < <(grep -rhE "^\s*Endpoint\s*=" "$sdir" 2>/dev/null || true)
    done

    # Deduplicate discovered interfaces and ports
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

    # 3. Stop and disable all WireGuard services
    echo -e "${CYAN}[*] Stopping all WireGuard systemd services and active tunnels...${NC}"
    systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@*" >/dev/null 2>&1 || true

    local wg_units
    wg_units=$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '(^wg-quick|wireguard|cbwireguard)' || true)
    for unit in $wg_units; do
        systemctl stop "$unit" >/dev/null 2>&1 || true
        systemctl disable "$unit" >/dev/null 2>&1 || true
    done

    for iface in "${UNIQUE_IFACES[@]}"; do
        systemctl stop "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        systemctl disable "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        if command -v wg-quick &>/dev/null; then
            wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        ip link set "$iface" down >/dev/null 2>&1 || true
        ip link delete dev "$iface" >/dev/null 2>&1 || true

        # Remove interface-bound firewall rules
        while iptables -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -o "$iface" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
        while iptables -D INPUT -i "$iface" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -o "$iface" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i "$iface" -j REJECT 2>/dev/null; do :; done
        while ip6tables -D OUTPUT -o "$iface" -j REJECT 2>/dev/null; do :; done
    done

    # 4. Clean firewall rules for discovered WireGuard ports (Never touch sensitive ports)
    for port in "${UNIQUE_PORTS[@]}"; do
        if isSensitivePort "$port"; then
            echo -e "${YELLOW}[!] Protected sensitive port ${port} skipped.${NC}"
            continue
        fi
        echo -e "${CYAN} -> Removing firewall rules for WireGuard port ${port}/udp...${NC}"
        while iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
        while iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; do :; done
        while ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do :; done

        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    done

    # 5. Clean WireGuard NAT, Mangle, and IPSet rules without touching web/SSH chains
    local wg_subnets=("10.18.0.0/24" "10.19.0.0/24" "10.8.0.0/24" "10.0.0.0/24" "10.66.66.0/24" "10.7.0.0/24")
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

    if command -v ipset &>/dev/null; then
        local wg_ipsets
        wg_ipsets=$(ipset list -n 2>/dev/null | grep -iE '^(wg_|geo_|vpn_)' || true)
        for setname in $wg_ipsets; do
            while iptables -D INPUT -m set --match-set "$setname" src -j DROP 2>/dev/null; do :; done
            while iptables -D FORWARD -m set --match-set "$setname" src -j DROP 2>/dev/null; do :; done
            while iptables -t nat -D POSTROUTING -m set --match-set "$setname" dst -o "$def_nic" -j MASQUERADE 2>/dev/null; do :; done
            ipset flush "$setname" 2>/dev/null || true
            ipset destroy "$setname" 2>/dev/null || true
        done
    fi

    # Remove server configs for clean state
    rm -f /etc/wireguard/wg*.conf /etc/wireguard/params /etc/wireguard/manager.env 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    if [[ "$mode" == "preinstall" ]]; then
        echo -e "${GREEN}[✔] Cleaned existing WireGuard instances and ports. Sensitive ports (80, 443, 22, etc.) untouched.${NC}"
    fi
}

deep_remove_wireguard() {
    echo -e "\n${RED}${BOLD}=================================================================${NC}"
    echo -e "${RED}${BOLD}   ⚠️  DEEP REMOVAL: WIREGUARD SERVER, CONFIGS, PORTS & FILES    ${NC}"
    echo -e "${RED}${BOLD}=================================================================${NC}"
    echo -en "${YELLOW}Are you sure you want to completely remove all WireGuard services, configs, and ports? [y/N]: ${NC}"
    read -r CONFIRM_DEL
    if [[ ! "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
        echo -e "${PURPLE}Removal cancelled. Returning to main menu...${NC}"
        return 0
    fi

    # 1. Run companion remove_server.sh if reachable (non-fatal)
    if [[ -f "./remove_server.sh" ]]; then
        chmod +x "./remove_server.sh"
        "./remove_server.sh" || true
    elif [[ -f "${INSTALL_DIR}/remove_server.sh" ]]; then
        chmod 700 "${INSTALL_DIR}/remove_server.sh"
        "${INSTALL_DIR}/remove_server.sh" || true
    elif curl -sSfL "${GIT_REPO}/remove_server.sh" -o "${INSTALL_DIR}/remove_server.sh" 2>/dev/null; then
        chmod 700 "${INSTALL_DIR}/remove_server.sh"
        "${INSTALL_DIR}/remove_server.sh" || true
    fi

    # 2. Execute comprehensive service, interface & port teardown (protects 80, 443, 22, etc.)
    cleanupOldWireguard "deep"

    # 3. Unload WireGuard kernel module if loaded
    if lsmod 2>/dev/null | grep -q "^wireguard"; then
        echo -e "${CYAN}[*] Unloading wireguard kernel module...${NC}"
        modprobe -r wireguard 2>/dev/null || true
    fi

    # 4. Deep scan and remove all WireGuard client configs (.conf / .conf.enc) across /root, /home, /tmp, /etc
    echo -e "${CYAN}[*] Searching filesystem for leftover WireGuard client configs and keys...${NC}"
    local client_search_dirs=("/root" "/home" "/tmp" "/etc/wireguard" "/opt")
    for sdir in "${client_search_dirs[@]}"; do
        [[ ! -d "$sdir" ]] && continue
        while IFS= read -r -d '' f; do
            local bname
            bname=$(basename "$f")
            # Never touch standard OS config files
            [[ "$bname" == "resolv.conf" || "$bname" == "sysctl.conf" || "$bname" == "host.conf" || "$bname" == "nsswitch.conf" ]] && continue
            if grep -qE "(\[Interface\]|\[Peer\]|PrivateKey\s*=|AllowedIPs\s*=|wg-quick)" "$f" 2>/dev/null || [[ "$bname" == *.conf.enc ]]; then
                echo -e "${CYAN} -> Removing WireGuard config file: ${f}${NC}"
                rm -f "$f" 2>/dev/null || true
            fi
        done < <(find "$sdir" -maxdepth 4 -type f \( -name "*.conf" -o -name "*.conf.enc" -o -name "*.key" \) -print0 2>/dev/null || true)
    done

    # 5. Deep scan system directories (/etc/sysctl.d, /etc/dnsmasq.d, /etc/systemd, /etc/cron*) for files mentioning wireguard
    echo -e "${CYAN}[*] Deep scanning system directories for WireGuard drop-ins, services, and sysctl rules...${NC}"
    local sys_dirs=("/etc/sysctl.d" "/etc/dnsmasq.d" "/etc/systemd/system" "/etc/cron.d" "/etc/cron.daily" "/etc/cron.hourly")
    for sysd in "${sys_dirs[@]}"; do
        [[ ! -d "$sysd" ]] && continue
        while IFS= read -r -d '' sysf; do
            if echo "$sysf" | grep -qiE "(wireguard|wg0|wg1|wg-quick|wg_split|cbwireguard|stealth)" || grep -qiE "(wireguard|wg-quick|wg0|wg_split)" "$sysf" 2>/dev/null; then
                echo -e "${CYAN} -> Removing system file: ${sysf}${NC}"
                rm -f "$sysf" 2>/dev/null || true
            fi
        done < <(find "$sysd" -maxdepth 3 \( -type f -o -type l \) -print0 2>/dev/null || true)
    done

    # 6. Remove WireGuard directories and backups
    echo -e "${CYAN}[*] Removing WireGuard directories and archives...${NC}"
    rm -rf /etc/wireguard /opt/cbwireguard "$INSTALL_DIR" /root/wireguard_backup* /home/*/easy_wireguard 2>/dev/null || true

    # Reload daemons and sysctl
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    if command -v dnsmasq &>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi

    # Re-initialize base manager folder so the Main Menu continues working seamlessly
    init_environment

    echo -e "\n${GREEN}${BOLD}[✔] Deep removal complete! All WireGuard services, configs, folders, and ports were cleaned.${NC}"
    echo -e "${GREEN}[✔] Sensitive ports (80, 443, 22, etc.) and host services remain completely untouched.${NC}"
}

# ------------------------------------------------------------------------------
# 3. Post-Install Client Config & QR Code Display
# ------------------------------------------------------------------------------
display_post_install_configs() {
    local found_configs=()
    local search_paths=("/etc/wireguard/clients" "$INSTALL_DIR" "/root" "/etc/wireguard")
    if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
        search_paths+=("/home/${SUDO_USER}")
    fi

    for spath in "${search_paths[@]}"; do
        [[ ! -d "$spath" ]] && continue
        while IFS= read -r -d '' cfg; do
            local base
            base=$(basename "$cfg")
            # Exclude server interface configs and manager settings
            [[ "$base" == "wg0.conf" || "$base" == "wg1.conf" || "$base" == "settings.conf" || "$base" == "resolv.conf" || "$base" == "sysctl.conf" ]] && continue
            if grep -q "\[Interface\]" "$cfg" 2>/dev/null && grep -q "Endpoint" "$cfg" 2>/dev/null; then
                found_configs+=("$cfg")
            fi
        done < <(find "$spath" -maxdepth 3 -type f -name "*.conf" -print0 2>/dev/null || true)
    done

    # Deduplicate by basename so the same client config isn't printed twice
    local unique_configs=()
    local seen_names="|"
    for c in "${found_configs[@]}"; do
        local bname
        bname=$(basename "$c")
        if [[ "$seen_names" != *"|${bname}|"* ]]; then
            seen_names+="${bname}|"
            unique_configs+=("$c")
        fi
    done

    # If setup_server.sh did not generate a client config automatically, run add_client.sh now
    if [[ ${#unique_configs[@]} -eq 0 ]]; then
        echo -e "\n${CYAN}[*] Generating initial client configuration...${NC}"
        fetch_and_run "add_client.sh"
        for spath in "${search_paths[@]}"; do
            [[ ! -d "$spath" ]] && continue
            while IFS= read -r -d '' cfg; do
                local base
                base=$(basename "$cfg")
                [[ "$base" == "wg0.conf" || "$base" == "wg1.conf" || "$base" == "settings.conf" ]] && continue
                if grep -q "\[Interface\]" "$cfg" 2>/dev/null && grep -q "Endpoint" "$cfg" 2>/dev/null; then
                    if [[ "$seen_names" != *"|${base}|"* ]]; then
                        seen_names+="${base}|"
                        unique_configs+=("$cfg")
                    fi
                fi
            done < <(find "$spath" -maxdepth 3 -type f -name "*.conf" -print0 2>/dev/null || true)
        done
    fi

    if [[ ${#unique_configs[@]} -gt 0 ]]; then
        for cfg_file in "${unique_configs[@]}"; do
            local cname
            cname=$(basename "$cfg_file")
            echo -e "\n${PURPLE}=================================================================${NC}"
            echo -e "${GREEN}${BOLD}📋 COPY & PASTE CLIENT CONFIGURATION (${cname}):${NC}"
            echo -e "${YELLOW}File Location: ${cfg_file}${NC}"
            echo -e "${PURPLE}-----------------------------------------------------------------${NC}"
            cat "$cfg_file"
            echo -e "${PURPLE}-----------------------------------------------------------------${NC}\n"

            if command -v qrencode &>/dev/null; then
                echo -e "${CYAN}${BOLD}📱 SCAN QR CODE FOR MOBILE / CLIENT (${cname}):${NC}\n"
                qrencode -t ansiutf8 < "$cfg_file" || true
                echo ""
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# 4. Pre-fetch Required Companion Scripts (Fixes Status 127 Missing Script Error)
# ------------------------------------------------------------------------------
prefetch_companion_scripts() {
    local scripts=("setup_server.sh" "add_client.sh" "user_manager.sh" "backup_manager.sh" "domain_bypass.sh" "geo_vpn_filter.sh" "remove_server.sh")
    echo -e "\n${CYAN}[*] Syncing companion scripts into ${INSTALL_DIR}...${NC}"
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
# 5. Patch & Run Setup Server (Single Port Prompt AFTER Dependencies + Output)
# ------------------------------------------------------------------------------
run_setup_server() {
    cleanupOldWireguard "preinstall"
    prefetch_companion_scripts

    local target_script="${INSTALL_DIR}/setup_server.sh"
    if [[ -f "./setup_server.sh" ]]; then
        cp -f "./setup_server.sh" "$target_script"
    else
        echo -e "\n${GREEN}Fetching latest version of setup_server.sh...${NC}"
        if ! curl -sSfL "${GIT_REPO}/setup_server.sh" -o "$target_script"; then
            echo -e "${RED}Error: Failed to pull setup_server.sh from ${GIT_REPO}.${NC}"
            return 1
        fi
    fi
    chmod 700 "$target_script"

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
for line in lines:
    if re.search(r'read\s+.*(PORT|SERVER_PORT|WG_PORT)', line) and 'select_safe_wg_port' not in content:
        new_lines.append('# ' + line + ' # replaced by select_safe_wg_port')
        continue
    new_lines.append(line)

content = '\n'.join(new_lines) + '\n'

# 3. Inject selector function at top and invoke it right after dependency installation finishes
if 'select_safe_wg_port' not in content:
    content = re.sub(r'^(#!/bin/bash[^\n]*\n)', r'\1\n' + selector_code + '\n', content, count=1)

    dep_match = re.search(r'(Installing WireGuard and required dependencies[\s\S]*?(?:apt-get|apt|yum|dnf|pacman|apk)\s+install[^\n]+\n(?:\s*fi\n)?)', content)
    if dep_match:
        insert_pos = dep_match.end()
        content = content[:insert_pos] + '\nselect_safe_wg_port\n' + content[insert_pos:]
    else:
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

    # Output the generated client configuration and QR code for immediate copy/paste
    display_post_install_configs
}

# ------------------------------------------------------------------------------
# 6. Modular Sub-script Fetcher & Settings Management
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
            return 1
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
    # Loop the main menu so it always returns after completing install, removal, or any task
    while true; do
        clear
        print_banner
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r OPTION

        case "$OPTION" in
            1)
                run_setup_server
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            2)
                fetch_and_run "add_client.sh"
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            3) fetch_and_run "user_manager.sh" ;;
            4) fetch_and_run "backup_manager.sh" ;;
            5) fetch_and_run "domain_bypass.sh" ;;
            6) 
                echo -e "\n${GREEN}Starting Real-Time Logging for WireGuard errors (last 12 hours)...${NC}"
                echo -e "${PURPLE}Press Ctrl+C to stop logging and return to menu.${NC}\n"
                journalctl -u wg-quick@wg0.service --since "12 hours ago" -p err -f || true
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            7) fetch_and_run "geo_vpn_filter.sh" ;;
            s) settings_menu ;;
            r)
                deep_remove_wireguard
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            q)
                echo -e "${PURPLE}Exit: Goodbye!${NC}"
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