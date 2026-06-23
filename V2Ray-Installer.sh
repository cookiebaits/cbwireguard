#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"
V2RAY_UUID_FILE="/usr/local/etc/v2ray/client_uuid.enc"

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

install_v2ray() {
    echo -e "${GREEN}Installing V2Ray (V2Fly) via official script...${NC}"
    curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh | bash
    curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh | bash
}

generate_config() {
    local uuid wg_port
    uuid=$(cat /proc/sys/kernel/random/uuid)
    wg_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | awk '{print $3}' || echo "51820")

    echo -e "${GREEN}Generating V2Ray configuration for TProxy...${NC}"
    mkdir -p /usr/local/etc/v2ray

    cat <<EOF > "$V2RAY_CONFIG"
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 8888,
      "protocol": "vmess",
      "tag": "vmess-in",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "alterId": 0,
            "security": "auto"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/video"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "tag": "tproxy-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 9050
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "tag": "streaming"
    },
    {
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": $wg_port,
        "network": "udp"
      },
      "tag": "wg-out"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "vmess-in"
        ],
        "outboundTag": "wg-out"
      },
      {
        "type": "field",
        "outboundTag": "streaming",
        "domain": [
          "domain:btstatic.com",
          "domain:netflix.com",
          "domain:netflix.net",
          "domain:nflxext.com",
          "domain:nflximg.com",
          "domain:nflximg.net",
          "domain:nflxsearch.net",
          "domain:nflxso.net",
          "domain:nflxvideo.net",
          "domain:fast.com",
          "domain:fast.ca",
          "domain:netflixinvestor.com",
          "domain:byspotify.com",
          "domain:pscdn.co",
          "domain:scdn.co",
          "domain:spoti.fi",
          "domain:spotify-everywhere.com",
          "domain:spotify.com",
          "domain:spotify.design",
          "domain:spotifycdn.com",
          "domain:spotifycdn.net",
          "domain:spotifycharts.com",
          "domain:sspotifycodes.com",
          "domain:spotifyforbrands.com",
          "domain:spotifyjobs.com",
          "domain:disneyplus.com",
          "domain:disney-plus.net",
          "domain:disneymedia.com",
          "domain:bamgrid.com",
          "domain:dssott.com",
          "domain:disneystreaming.com",
          "domain:hbomax.com",
          "domain:hbonow.com",
          "domain:hbogo.com",
          "domain:hbomaxcdn.com",
          "domain:max.com",
          "domain:hbo.com",
          "domain:warnermediacdn.com",
          "domain:hulu.com",
          "domain:huluim.com",
          "domain:hulustream.com"
        ]
      }
    ]
  }
}
EOF
    chmod 644 "$V2RAY_CONFIG"

    get_master_pass
    echo "$uuid" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:$MASTER_PASS" -out "$V2RAY_UUID_FILE"
    chmod 600 "$V2RAY_UUID_FILE"
}

setup_tproxy_routing() {
    echo -e "${GREEN}Configuring TProxy routing and iptables...${NC}"

    # TProxy Routing Table
    ip rule add fwmark 1 table 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    # Iptables Mangle Rules for TProxy
    local wg_subnet
    wg_subnet=$(grep "^Address" /etc/wireguard/wg0.conf | awk '{print $3}' | cut -d/ -f1 | sed 's/\.[0-9]\+$/.0\/24/' || echo "10.18.0.0/24")

    iptables -t mangle -N V2RAY 2>/dev/null || true
    iptables -t mangle -F V2RAY
    iptables -t mangle -A V2RAY -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A V2RAY -d "$wg_subnet" -j RETURN

    # Direct wg0 traffic to V2RAY chain
    iptables -t mangle -A PREROUTING -i wg0 -p tcp -j V2RAY
    iptables -t mangle -A PREROUTING -i wg0 -p udp -j V2RAY

    # TProxy to port 12345
    iptables -t mangle -A V2RAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
    iptables -t mangle -A V2RAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1

    # Persist in wg0.conf if exists
    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        if ! grep -q "V2RAY" /etc/wireguard/wg0.conf; then
            sed -i "/PostUp = iptables -t nat -A POSTROUTING/a PostUp = ip rule add fwmark 1 table 100 || true; ip route add local 0.0.0.0/0 dev lo table 100 || true; iptables -t mangle -N V2RAY || true; iptables -t mangle -F V2RAY; iptables -t mangle -A V2RAY -d 127.0.0.0/8 -j RETURN; iptables -t mangle -A V2RAY -d $wg_subnet -j RETURN; iptables -t mangle -A PREROUTING -i wg0 -p tcp -j V2RAY; iptables -t mangle -A PREROUTING -i wg0 -p udp -j V2RAY; iptables -t mangle -A V2RAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1; iptables -t mangle -A V2RAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1" /etc/wireguard/wg0.conf
            sed -i "/PreDown = iptables -t nat -D POSTROUTING/a PreDown = iptables -t mangle -D PREROUTING -i wg0 -p tcp -j V2RAY || true; iptables -t mangle -D PREROUTING -i wg0 -p udp -j V2RAY || true; iptables -t mangle -F V2RAY || true; iptables -t mangle -X V2RAY || true; ip rule del fwmark 1 table 100 || true; ip route del local 0.0.0.0/0 dev lo table 100 || true" /etc/wireguard/wg0.conf
        fi
    fi
}

setup_firewall() {
    if command -v ufw >/dev/null; then
        echo -e "${GREEN}Configuring UFW for V2Ray...${NC}"
        ufw allow 8888/tcp
    fi
}

start_v2ray() {
    echo -e "${GREEN}Starting V2Ray service...${NC}"
    systemctl enable v2ray
    systemctl restart v2ray
}

uninstall_v2ray() {
    echo -e "${RED}Uninstalling V2Ray and clearing routing...${NC}"
    systemctl stop v2ray || true
    systemctl disable v2ray || true

    bash <(curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove
    rm -rf /usr/local/etc/v2ray

    iptables -t mangle -D PREROUTING -i wg0 -p tcp -j V2RAY 2>/dev/null || true
    iptables -t mangle -D PREROUTING -i wg0 -p udp -j V2RAY 2>/dev/null || true
    iptables -t mangle -F V2RAY 2>/dev/null || true
    iptables -t mangle -X V2RAY 2>/dev/null || true

    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

    if [[ -f "/etc/wireguard/wg0.conf" ]]; then
        sed -i "/V2RAY/d" /etc/wireguard/wg0.conf
    fi

    if command -v ufw >/dev/null; then
        ufw delete allow 8888/tcp || true
    fi
}

show_status() {
    if systemctl is-active --quiet v2ray; then
        echo -e "${GREEN}V2Ray is active and integrated with WireGuard.${NC}"
        get_master_pass
        local uuid
        uuid=$(openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass "pass:$MASTER_PASS" -in "$V2RAY_UUID_FILE" 2>/dev/null || echo "Decryption Failed")
        echo -e "${PURPLE}Connection Info (Stealth VMess):${NC}"
        echo -e "Port: 8888, UUID: $uuid, Protocol: VMess, Transport: ws, Path: /video"
        echo -e "${PURPLE}WireGuard Integration:${NC}"
        echo -e "TProxy Port: 12345, Streaming: Netflix/Spotify/etc routed to 127.0.0.1:9050"
    else
        echo -e "${RED}V2Ray is not running.${NC}"
    fi
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│            V2Ray Management (Stealth)              │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Install/Update V2Ray (Integrated)            ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Show Status & Connection Info                ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[3] Uninstall V2Ray & Restore Routing            ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[0] Back to Main Menu                            ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

main() {
    while true; do
        print_menu
        echo -en "${GREEN}Option: ${NC}"
        read -r opt
        case "$opt" in
            1)
                install_v2ray
                generate_config
                setup_tproxy_routing
                setup_firewall
                start_v2ray
                show_status
                ;;
            2) show_status ;;
            3)
                read -r -p "Are you sure? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then uninstall_v2ray; fi
                ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
        if [[ "$opt" != "0" ]]; then
            echo; read -n 1 -s -r -p "Press any key to continue..."; clear
        fi
    done
}

main
