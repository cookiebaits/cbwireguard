#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_UUID_FILE="/usr/local/etc/xray/client_uuid.enc"

SETTINGS_FILE="/root/easy_wireguard/settings.conf"
if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

get_master_pass() {
    if [[ -z "${MASTER_PASS:-}" ]]; then
        echo -en "${GREEN}Enter Master Password for Encryption: ${NC}"
        read -rs MASTER_PASS
        echo
        export MASTER_PASS
    fi
}

install_xray() {
    echo -e "${GREEN}Installing/Updating Xray via official script...${NC}"
    # Use official script to ensure latest version and correct binary placement
    curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh | bash
    curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-dat-release.sh | bash
}

generate_config() {
    local uuid wg_port
    uuid=$(cat /proc/sys/kernel/random/uuid)
    wg_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | awk '{print $3}' || echo "51820")

    echo -e "${GREEN}Generating definitive Xray configuration...${NC}"
    mkdir -p /usr/local/etc/xray

    # Using V4 compatible JSON structure which Xray 5.x supports seamlessly
    cat <<EOF > "$XRAY_CONFIG"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 8888,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $wg_port,
        "network": "udp",
        "followRedirect": false
      },
      "tag": "stealth-udp-in"
    },
    {
      "port": ${XRAY_VLESS_PORT:-8880},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "$uuid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/video"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "port": 12345,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true,
        "userLevel": 0
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy",
          "mark": 255
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "tag": "tproxy-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "geosite:netflix",
          "geosite:disney",
          "geosite:hulu",
          "geosite:hbo",
          "domain:max.com"
        ]
      },
      {
        "type": "field",
        "inboundTag": ["tproxy-in", "stealth-udp-in"],
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF
    chmod 600 "$XRAY_CONFIG"

    get_master_pass
    echo "$uuid" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:$MASTER_PASS" -out "$XRAY_UUID_FILE"
    chmod 600 "$XRAY_UUID_FILE"
}

setup_tproxy_rules() {
    echo -e "${GREEN}Configuring TProxy routing and iptables...${NC}"

    # Load required modules
    modprobe xt_TPROXY xt_mark xt_multiport iptable_mangle 2>/dev/null || true

    # Loosening rp_filter for TProxy compatibility (TProxy delivers packets
    # with non-local source addresses; strict rp_filter would drop them).
    # Persist in /etc/sysctl.conf so it survives reboot.
    local sysctl_file="/etc/sysctl.conf"
    sed -i '/^net\.ipv4\.conf\.\(all\|default\|wg0\)\.rp_filter[[:space:]]*=/d' "$sysctl_file"
    {
        echo "net.ipv4.conf.all.rp_filter = 2"
        echo "net.ipv4.conf.default.rp_filter = 2"
    } >> "$sysctl_file"
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
    for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$i" 2>/dev/null || true; done

    # TProxy Routing Table
    if ! ip rule list | grep -q "fwmark 0x1 lookup 100"; then
        ip rule add fwmark 1 table 100
    fi
    if ! ip route show table 100 | grep -q "local default"; then
        ip route add local default dev lo table 100
    fi

    local wg_subnet
    wg_subnet=$(grep "^Address" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d/ -f1 | sed 's/\.[0-9]\+$/.0\/24/' || echo "10.18.0.0/24")

    # MSS clamping: FORWARD covers regular forwarded TCP, OUTPUT covers
    # TProxy reply packets that Xray injects from local sockets to wg0.
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    iptables -t mangle -C OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    iptables -t mangle -N DIVERT 2>/dev/null || true
    iptables -t mangle -F DIVERT
    iptables -t mangle -A DIVERT -j MARK --set-mark 1
    iptables -t mangle -A DIVERT -j ACCEPT

    if iptables -m socket --help >/dev/null 2>&1; then
        iptables -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || \
        iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
    fi

    iptables -t mangle -N XRAY 2>/dev/null || true
    iptables -t mangle -F XRAY
    iptables -t mangle -A XRAY -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A XRAY -d "$wg_subnet" -j RETURN

    # Exclude server's public IP to prevent loops
    local public_ip
    public_ip=$(curl -s -m 5 https://api.ipify.org || echo "")
    if [[ -n "$public_ip" ]]; then
        iptables -t mangle -A XRAY -d "$public_ip" -j RETURN
    fi

    iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A XRAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    # Redirection from wg0
    iptables -t mangle -C PREROUTING -i wg0 -p tcp -m mark ! --mark 255 -j XRAY 2>/dev/null || \
    iptables -t mangle -I PREROUTING 1 -i wg0 -p tcp -m mark ! --mark 255 -j XRAY

    iptables -t mangle -C PREROUTING -i wg0 -p udp -m mark ! --mark 255 -j XRAY 2>/dev/null || \
    iptables -t mangle -I PREROUTING 1 -i wg0 -p udp -m mark ! --mark 255 -j XRAY

    # Persist in wg0.conf (idempotent: strip any previous XRAY block first)
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        sed -i "/# XRAY_START/,/# XRAY_END/d" /etc/wireguard/wg0.conf
        # Remove any trailing blank lines so the block appends cleanly
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/wireguard/wg0.conf

        # Build the optional public-IP exclusion line conditionally
        local public_ip_postup=""
        local public_ip_predown=""
        if [[ -n "$public_ip" ]]; then
            public_ip_postup="PostUp = iptables -t mangle -A XRAY -d ${public_ip} -j RETURN"
            public_ip_predown="PreDown = iptables -t mangle -D XRAY -d ${public_ip} -j RETURN || true"
        fi

        cat <<EOF >> /etc/wireguard/wg0.conf

# XRAY_START
PostUp = modprobe xt_TPROXY xt_mark xt_multiport iptable_mangle 2>/dev/null || true
PostUp = ip rule add fwmark 1 table 100 2>/dev/null || true
PostUp = ip route add local default dev lo table 100 2>/dev/null || true
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2 || true
PostUp = sysctl -w net.ipv4.conf.default.rp_filter=2 || true
PostUp = sysctl -w net.ipv4.conf.wg0.rp_filter=2 || true
PostUp = sh -c 'for i in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "\$i" 2>/dev/null || true; done'
PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -A OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostUp = iptables -t mangle -N DIVERT 2>/dev/null || true
PostUp = iptables -t mangle -F DIVERT
PostUp = iptables -t mangle -A DIVERT -j MARK --set-mark 1
PostUp = iptables -t mangle -A DIVERT -j ACCEPT
PostUp = iptables -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || iptables -t mangle -A PREROUTING -p tcp -m socket -j DIVERT
PostUp = iptables -t mangle -N XRAY 2>/dev/null || true
PostUp = iptables -t mangle -F XRAY
PostUp = iptables -t mangle -A XRAY -d 127.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A XRAY -d ${wg_subnet} -j RETURN
${public_ip_postup}
PostUp = iptables -t mangle -A XRAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A XRAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -C PREROUTING -i wg0 -p tcp -m mark ! --mark 255 -j XRAY 2>/dev/null || iptables -t mangle -I PREROUTING 1 -i wg0 -p tcp -m mark ! --mark 255 -j XRAY
PostUp = iptables -t mangle -C PREROUTING -i wg0 -p udp -m mark ! --mark 255 -j XRAY 2>/dev/null || iptables -t mangle -I PREROUTING 1 -i wg0 -p udp -m mark ! --mark 255 -j XRAY

PreDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
PreDown = iptables -t mangle -D OUTPUT -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
PreDown = iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT || true
PreDown = iptables -t mangle -D PREROUTING -i wg0 -p tcp -m mark ! --mark 255 -j XRAY || true
PreDown = iptables -t mangle -D PREROUTING -i wg0 -p udp -m mark ! --mark 255 -j XRAY || true
${public_ip_predown}
PreDown = iptables -t mangle -F XRAY || true
PreDown = iptables -t mangle -X XRAY || true
PreDown = iptables -t mangle -F DIVERT || true
PreDown = iptables -t mangle -X DIVERT || true
PreDown = ip rule del fwmark 1 table 100 || true
PreDown = ip route del local default dev lo table 100 || true
# XRAY_END
EOF
    fi
}

setup_firewall() {
    if command -v ufw >/dev/null; then
        echo -e "${GREEN}Configuring UFW for Xray...${NC}"
        ufw allow 8888/udp
        ufw allow "${XRAY_VLESS_PORT:-8880}/tcp"
        ufw allow 12345
    fi
}

test_integration() {
    echo -e "\n${GREEN}Running Robust Integration Tests...${NC}"
    local errors=0

    echo "Waiting 15 seconds for Xray and network state to stabilize..."
    sleep 15

    # 1. Service check
    if systemctl is-active --quiet xray; then
        echo -e "[PASS] Xray service is active."
    else
        echo -e "${RED}[FAIL] Xray service is NOT active.${NC}"
        errors=$((errors + 1))
    fi

    # 2. Port check
    if ss -Hlntu | grep -q ":8888"; then
        echo -e "[PASS] Xray Stealth UDP Port (8888) is listening."
    else
        echo -e "${RED}[FAIL] Xray Stealth UDP Port (8888) is NOT listening.${NC}"
        errors=$((errors + 1))
    fi

    if ss -Hlntu | grep -q ":${XRAY_VLESS_PORT:-8880}"; then
        echo -e "[PASS] Xray VLESS Port (${XRAY_VLESS_PORT:-8880}) is listening."
    else
        echo -e "${RED}[FAIL] Xray VLESS Port (${XRAY_VLESS_PORT:-8880}) is NOT listening.${NC}"
        errors=$((errors + 1))
    fi

    if ss -Hlntu | grep -q ":12345"; then
        echo -e "[PASS] Xray TProxy Port (12345) is listening."
    else
        echo -e "${RED}[FAIL] Xray TProxy Port (12345) is NOT listening.${NC}"
        errors=$((errors + 1))
    fi

    # 3. Iptables check
    if iptables -t mangle -L XRAY -n >/dev/null 2>&1; then
        echo -e "[PASS] Iptables XRAY mangle chain is present."
        if iptables -t mangle -S XRAY | grep -q "TPROXY --on-port 12345"; then
            echo -e "[PASS] TProxy redirection rule is present in XRAY chain."
        else
            echo -e "${RED}[FAIL] TProxy redirection rule is MISSING.${NC}"
            errors=$((errors + 1))
        fi
    else
        echo -e "${RED}[FAIL] Iptables XRAY mangle chain is MISSING.${NC}"
        errors=$((errors + 1))
    fi

    # 4. WireGuard Interface & Data Check
    if ip link show wg0 >/dev/null 2>&1; then
        echo -e "[PASS] WireGuard interface (wg0) is UP."
        local transfer
        transfer=$(wg show wg0 transfer | awk '{print $2}' | paste -sd+ - | bc || echo "0")
        if [[ "$transfer" -gt 0 ]]; then
             echo -e "[INFO] WireGuard transfer data detected ($transfer bytes)."
        else
             echo -e "${PURPLE}[NOTE] No WireGuard transfer data detected yet.${NC}"
        fi
    else
        echo -e "${RED}[FAIL] WireGuard interface (wg0) is DOWN.${NC}"
        errors=$((errors + 1))
    fi

    # Always display logs
    echo -e "${PURPLE}\n--- Xray Service Status ---${NC}"
    systemctl status xray --no-pager || true
    echo -e "${PURPLE}--- Last 20 lines of Journal ---${NC}"
    journalctl -u xray -n 20 --no-pager || true
    echo -e "${PURPLE}----------------------------${NC}"

    if [[ $errors -ne 0 ]]; then
        echo -e "${RED}\nIntegration Error: Some checks failed. Please review the logs above.${NC}"
        echo -en "${GREEN}\nPress Enter to return to menu...${NC}"
        read -r || true
        return 1
    else
        echo -e "${GREEN}\nIntegration Success: Xray and WireGuard are fully integrated!${NC}"
        echo -en "${GREEN}\nPress Enter to continue and add users...${NC}"
        read -r || true
        return 0
    fi
}

start_xray() {
    echo -e "${GREEN}Hardening Xray service and starting...${NC}"

    # Overwrite the service file to be certain
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
Group=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # Clean up old drop-ins
    rm -rf /etc/systemd/system/xray.service.d

    echo -e "${GREEN}Verifying Xray configuration...${NC}"
    if ! /usr/local/bin/xray run -test -c "$XRAY_CONFIG"; then
        echo -e "${RED}Error: Xray configuration test failed!${NC}"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
}

uninstall_xray() {
    echo -e "${RED}Uninstalling Xray and clearing routing...${NC}"
    systemctl stop xray || true
    systemctl disable xray || true
    rm -f /etc/systemd/system/xray.service
    rm -rf /etc/systemd/system/xray.service.d

    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) --remove
    rm -rf /usr/local/etc/xray

    # Restoring kernel parameters
    sysctl -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true

    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        sed -i "/# XRAY_START/,/# XRAY_END/d" /etc/wireguard/wg0.conf
    fi

    if command -v ufw >/dev/null; then
        ufw delete allow 8888/udp || true
        ufw delete allow "${XRAY_VLESS_PORT:-8880}/tcp" || true
        ufw delete allow 12345 || true
    fi
}

show_status() {
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}Xray is active and integrated with WireGuard.${NC}"
        get_master_pass
        local uuid
        uuid=$(openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass "pass:$MASTER_PASS" -in "$XRAY_UUID_FILE" 2>/dev/null || echo "Decryption Failed")
        echo -e "${PURPLE}Connection Info (Stealth VLESS):${NC}"
        echo -e "Port: ${XRAY_VLESS_PORT:-8880}, UUID: $uuid, Protocol: VLESS, Transport: ws, Path: /video"
        echo -e "${PURPLE}WireGuard Integration:${NC}"
        echo -e "Stealth UDP Entry: 8888, TProxy Port: 12345"
    else
        echo -e "${RED}Xray is not running.${NC}"
    fi
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│            Xray Management (Stealth)              │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Install/Update Xray (Integrated)            ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Show Status & Connection Info                ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[3] Uninstall Xray & Restore Routing            ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[0] Back to Main Menu                            ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

main() {
    if [[ "${1:-}" == "--install" ]]; then
        install_xray
        generate_config
        setup_tproxy_rules
        setup_firewall
        start_xray
        test_integration
        show_status
        return
    fi

    while true; do
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r opt
        case "$opt" in
            1)
                install_xray
                generate_config
                setup_tproxy_rules
                setup_firewall
                start_xray
                test_integration
                show_status
                ;;
            2) show_status ;;
            3)
                read -r -p "Are you sure? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then uninstall_xray; fi
                ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
        if [[ "$opt" != "0" ]]; then
            echo; read -n 1 -s -r -p "Press any key to continue..."; clear
        fi
    done
}

main "$@"
