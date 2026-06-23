#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    distro=$ID
else
    distro="unknown"
fi

install_v2ray() {
    echo -e "${GREEN}Installing V2Ray (V2Fly) via official script...${NC}"
    # Using the official FHS install script from V2Fly
    curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh | bash

    # Ensure geoip and geosite are installed
    curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh | bash
}

generate_config() {
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)

    echo -e "${GREEN}Generating V2Ray configuration...${NC}"
    mkdir -p /usr/local/etc/v2ray

    cat <<EOF > /usr/local/etc/v2ray/config.json
{
  "log": {
    "loglevel": "none"
  },
  "inbounds": [
    {
      "port": 8888,
      "protocol": "vmess",
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
        "security": "none",
        "tcpSettings": {
          "header": {
            "type": "none"
          }
        }
      },
      "tag": "streaming"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
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
    chmod 644 /usr/local/etc/v2ray/config.json
    echo "$uuid" > /usr/local/etc/v2ray/client_uuid.txt
}

setup_firewall() {
    if command -v ufw >/dev/null; then
        echo -e "${GREEN}Configuring UFW to allow V2Ray port 8888...${NC}"
        ufw allow 8888/tcp
    fi
}

start_v2ray() {
    echo -e "${GREEN}Starting V2Ray service...${NC}"
    systemctl enable v2ray
    systemctl restart v2ray
}

uninstall_v2ray() {
    echo -e "${RED}Uninstalling V2Ray...${NC}"
    systemctl stop v2ray || true
    systemctl disable v2ray || true
    # Using the official uninstall command
    bash <(curl -Ls https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) --remove
    rm -rf /usr/local/etc/v2ray
    if command -v ufw >/dev/null; then
        ufw delete allow 8888/tcp || true
    fi
    echo -e "${GREEN}V2Ray uninstalled successfully.${NC}"
}

show_status() {
    if systemctl is-active --quiet v2ray; then
        echo -e "${GREEN}V2Ray is running.${NC}"
        local uuid
        uuid=$(cat /usr/local/etc/v2ray/client_uuid.txt 2>/dev/null || echo "Unknown")
        echo -e "${PURPLE}Connection Info:${NC}"
        echo -e "Port: 8888"
        echo -e "UUID: $uuid"
        echo -e "Protocol: VMess"
        echo -e "Transport: WebSocket (ws)"
        echo -e "Path: /video"
        echo -e "Security: auto"
    else
        echo -e "${RED}V2Ray is not running.${NC}"
    fi
}

print_menu() {
    echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${PURPLE}│            V2Ray Management (Stealth)              │${NC}"
    echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
    echo -e "${PURPLE}│ ${NC}[1] Install/Update V2Ray                         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[2] Show Connection Info                         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[3] Uninstall V2Ray                              ${PURPLE}│${NC}"
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
                setup_firewall
                start_v2ray
                show_status
                ;;
            2)
                show_status
                ;;
            3)
                read -r -p "Are you sure you want to uninstall V2Ray? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_v2ray
                fi
                ;;
            0) break ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
        if [[ "$opt" != "0" ]]; then
            echo
            read -n 1 -s -r -p "Press any key to continue..."
            clear
        fi
    done
}

main
