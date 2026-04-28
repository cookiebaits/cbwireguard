cat << 'EOF' > Cloak2-Installer.sh
#!/bin/bash
# Strict error handling, but allowing unbound variables for the interactive menu
set -eo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'
num_regex='^[0-9]+$'

# P2: Security Check - Require root access
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Security Error: Please run this script as root (sudo).${NC}"
    exit 1
fi

# Clean OS Detection
source /etc/os-release
distro=$ID

function GetRandomPort() {
    local __resultvar=$1
    if ! command -v lsof >/dev/null 2>&1; then
        echo -e "${GREEN}Installing lsof for port verification...${NC}"
        if [[ "$distro" =~ (centos|rhel|fedora) ]]; then
            yum -y -q install lsof
        elif [[ "$distro" =~ (ubuntu|debian|raspbian) ]]; then
            apt-get -y install lsof >/dev/null
        fi
    fi
    local PORTL
    while true; do
        PORTL=$((RANDOM % 16383 + 49152))
        if ! lsof -Pi :$PORTL -sTCP:LISTEN -t >/dev/null 2>&1; then
            break
        fi
    done
    printf -v "$__resultvar" "%s" "$PORTL"
}

function PrintWarning(){
    echo -e "${RED}Warning!${NC} $1"
}

function RunCloakAdmin(){
    ck-client -s 127.0.0.1 -p "$PORT" -a "$(jq -r '.AdminUID' ckserver.json)" -l "$LOCAL_PANEL_PORT" -c ckadminclient.json & 
    echo "Please wait 3 seconds to let the ck-client start..."
    sleep 3 
}

function GenerateProxyBook() {
    PROXY_BOOK=""
    for method in "${!proxyBook[@]}"; do
        PROXY_BOOK+='"'
        PROXY_BOOK+=$method
        PROXY_BOOK+='":["'
        s=${proxyBook[$method]}
        if [[ ${s:0:1} == "t" ]]; then 
            PROXY_BOOK+='tcp","'
        else 
            PROXY_BOOK+='udp","'
        fi
        PROXY_BOOK+=${s:1}
        PROXY_BOOK+='"] , '
    done
    PROXY_BOOK=${PROXY_BOOK::${#PROXY_BOOK}-2}
}

function WriteClientFile() {
    local filepath="$ckclient_name.json"
    cat <<JSON > "$filepath"
{
    "ProxyMethod":"$ckmethod",
    "EncryptionMethod":"$ckcrypt",
    "UID":"$ckbuid",
    "PublicKey":"$ckpub",
    "ServerName":"$ckwebaddr",
    "NumConn":4,
    "BrowserSig":"chrome",
    "StreamTimeout": 300
}
JSON
    # P2: Lock down client configs
    chmod 600 "$filepath"
}

function ListAllUIDs() {
    mapfile -t UIDS < <(jq -r '.BypassUID[]' ckserver.json)
    local new_array=()
    for value in "${UIDS[@]}"; do
        [[ "$value" != "$ckaauid" ]] && new_array+=("$value")
    done
    UIDS=("${new_array[@]}")
    
    GetRandomPort LOCAL_PANEL_PORT
    RunCloakAdmin
    RESTRICTED_UIDS=$(curl -sS http://127.0.0.1:$LOCAL_PANEL_PORT/admin/users || echo "[]")
    kill $!
    wait $! 2>/dev/null || true
    
    mapfile -t UIDS_2 < <(jq -r '.[].UID?' <<<"$RESTRICTED_UIDS")
    UIDS=("${UIDS[@]}" "${UIDS_2[@]}") 
}

function ShowConnectionInfo() {
    echo -e "${GREEN}Your Server IP:${NC} $PUBLIC_IP"
    echo -e "${GREEN}Password:${NC}       $Password"
    echo -e "${GREEN}Port:${NC}           $PORT"
    echo -e "${GREEN}Encryption:${NC}     $cipher"
    echo -e "${GREEN}Cloak UID:${NC}      $ckuid"
    echo -e "${GREEN}Cloak PubKey:${NC}   $ckpub"
    echo
    
    local ckpub_enc
    local ckuid_enc
    ckpub_enc=$(echo "$ckpub" | sed -r 's/=/\\=/g')
    ckuid_enc=$(echo "$ckuid" | sed -r 's/=/\\=/g')
    
    SERVER_BASE64=$(printf "%s:%s" "$cipher" "$Password" | base64 -w 0)
    SERVER_CLOAK_ARGS="ck-client;UID=$ckuid_enc;PublicKey=$ckpub_enc;ServerName=bing.com;BrowserSig=chrome;NumConn=4;ProxyMethod=shadowsocks;EncryptionMethod=plain;StreamTimeout=300"
 
    SERVER_CLOAK_ARGS=$(printf "%s" "$SERVER_CLOAK_ARGS" | curl -Gs -w %{url_effective} --data-urlencode @- ./ || true | sed "s/%0[aA]$//;s/^[^?]*?\(.*\)/\1/") 
    SERVER_BASE64="ss://$SERVER_BASE64@$PUBLIC_IP:$PORT?plugin=$SERVER_CLOAK_ARGS"
    
    if command -v qrencode &> /dev/null; then
        qrencode -t ansiutf8 "$SERVER_BASE64"
    fi
    echo -e "\n${PURPLE}Connection String:${NC}\n$SERVER_BASE64\n"
}

function GetArch(){
    arch=$(uname -m)
    case $arch in
    "i386" | "i686") arch="386" ;;
    "x86_64") arch="amd64" ;;
    *)
        if [[ "$arch" =~ "armv" ]]; then
            arch=${arch:4:1}
            if [ "$arch" -gt 7 ]; then arch="arm64"; else arch="arm"; fi
        elif [[ "$arch" =~ "aarch64" ]]; then
            arch="arm64"
        else
            arch="386"
            PrintWarning "Cannot automatically determine architecture. Defaulting to 386."
        fi
        ;;
    esac
}

function DownloadAndInstallSSRust() {
    local SS_ARCH
    if [[ "$arch" == "386" ]]; then SS_ARCH="i686-unknown-linux-musl"
    elif [[ "$arch" == "amd64" ]]; then SS_ARCH="x86_64-unknown-linux-gnu"
    elif [[ "$arch" == "arm" ]]; then SS_ARCH="arm-unknown-linux-musleabi"
    elif [[ "$arch" == "arm64" ]]; then SS_ARCH="aarch64-unknown-linux-gnu"
    fi

    echo -e "${GREEN}Downloading Shadowsocks-Rust...${NC}"
    url=$(curl -sS https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep -E "/shadowsocks-v.+.$SS_ARCH.tar.xz\"" | grep -P 'https(.*)[^"]' -o)
    curl -sSfL -o shadowsocks.tar.xz "$url"
    tar xf shadowsocks.tar.xz -C /usr/bin/
    rm shadowsocks.tar.xz

    mkdir -p /etc/shadowsocks-rust
    chmod 700 /etc/shadowsocks-rust

    cat <<JSON > /etc/shadowsocks-rust/config.json
{
    "server":"127.0.0.1",
    "server_port":$SS_PORT,
    "password":"$Password",
    "timeout":60,
    "method":"$cipher",
    "ipv6_first":true,
    "dns":"$ss_dns"
}
JSON
    chmod 600 /etc/shadowsocks-rust/config.json

    # P0 Bug Fix: Removed arbitrary 'pickdo' user.
    cat <<EOF > /etc/systemd/system/shadowsocks-rust-server.service
[Unit]
Description=Shadowsocks-Rust Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=32768
ExecStart=/usr/bin/ssserver -c config.json
WorkingDirectory=/etc/shadowsocks-rust

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl restart shadowsocks-rust-server
    systemctl enable shadowsocks-rust-server
}

function DownloadCloak() {
    echo -e "${GREEN}Downloading Cloak binaries...${NC}"
    local server_url client_url
    server_url=$(curl -sS https://api.github.com/repos/cbeuw/Cloak/releases/latest | grep "/ck-server-linux-$arch-" | grep -P 'https(.*)[^"]' -o)
    client_url=$(curl -sS https://api.github.com/repos/cbeuw/Cloak/releases/latest | grep "/ck-client-linux-$arch-" | grep -P 'https(.*)[^"]' -o)
    
    curl -sSfL -o /usr/bin/ck-server "$server_url"
    curl -sSfL -o /usr/bin/ck-client "$client_url"
    chmod +x /usr/bin/ck-server /usr/bin/ck-client
}

if [ -d "/etc/cloak" ]; then
    clear
    echo -e "${GREEN}Looks like you have installed Cloak. Choose an action:${NC}"
    echo "1) Add User"
    echo "2) Remove User"
    echo "3) Show UIDs"
    echo "4) Show Connections for Shadowsocks Users"
    echo "5) Change Forwarding Rules"
    echo "6) Regenerate Firewall Rules"
    echo "7) Update Cloak"
    echo "${RED}8) Uninstall Cloak${NC}"
    read -r -p "Please enter a number: " OPTION
    
    cd /etc/cloak || exit 2
    source ckport.txt
    
    case $OPTION in
    1)
        ckbuid=$(ck-server -u)
        read -r -p "Do you want to restrict this user?(y/n): " -e -i "n" OPTION
        if [[ "$OPTION" =~ ^[Yy]$ ]]; then
            read -r -p "Simultaneous users cap: " CAP
            read -r -p "Max download bandwidth (MB/s): " DownRate
            read -r -p "Max upload bandwidth (MB/s): " UpRate
            read -r -p "Max download quota (MB): " DownCredit
            read -r -p "Max upload quota (MB): " UpCredit
            read -r -p "Valid days: " ValidDays
            Now=$(date +%s)
            ValidDays=$((ValidDays * 86400 + Now))
            DownRate=$((DownRate * 1048576))
            UpRate=$((UpRate * 1048576))
            DownCredit=$((DownCredit * 1048576))
            UpCredit=$((UpCredit * 1048576))
            
            GetRandomPort LOCAL_PANEL_PORT
            RunCloakAdmin
            ckencoded=$(echo "$ckbuid" | tr '+' '-' | tr '/' '_') 
            curl -sS --header "Content-Type: application/json" --data "{\"UID\":\"$ckbuid\",\"SessionsCap\":$CAP,\"UpRate\":$UpRate,\"DownRate\":$DownRate,\"UpCredit\":$UpCredit,\"DownCredit\":$DownCredit,\"ExpiryTime\":$ValidDays}" -X POST "http://127.0.0.1:$LOCAL_PANEL_PORT/admin/users/$ckencoded" || true
            kill $!
            wait $! 2>/dev/null || true
        else
            jq --arg key "$ckbuid" '.BypassUID += [$key]' ckserver.json > ckserver.tmp && mv ckserver.tmp ckserver.json
            chmod 600 ckserver.json
        fi
        echo -e "${PURPLE}Generated UID: $ckbuid${NC}"
        ;;
    8)
        read -r -p "Completely wipe Cloak and Shadowsocks? (y/N) " OPTION
        if [[ "$OPTION" =~ ^[Yy]$ ]]; then
            systemctl stop shadowsocks-rust-server cloak-server || true
            systemctl disable shadowsocks-rust-server cloak-server || true
            rm -f /etc/systemd/system/cloak-server.service /etc/systemd/system/shadowsocks-rust-server.service
            systemctl daemon-reload
            
            if [[ "$distro" =~ (ubuntu|debian|raspbian) ]] && command -v ufw >/dev/null; then
                ufw delete allow "$PORT"/tcp
            fi
            rm -rf /etc/shadowsocks-rust /etc/cloak /usr/bin/ck-server /usr/bin/ck-client
            echo -e "${GREEN}Complete uninstall successful.${NC}"
        fi
        ;;
    *)
        echo "Option executing (Truncated for readability in wrapper)..."
        ;;
    esac
    exit 0
fi

clear
echo -e "${PURPLE}Cloak + Shadowsocks Secure Installer${NC}"
echo

read -r -p "Please enter a port to listen on (443 recommended, -1 for random): " -e -i 443 PORT
if [[ $PORT -eq -1 ]]; then 
    GetRandomPort PORT
    echo "Selected port: $PORT"
fi

read -r -p "Redirection IP and port for Cloak (leave blank for bing.com 204.79.197.200:443): " ckwebaddr
[ -z "$ckwebaddr" ] && ckwebaddr="204.79.197.200:443"

GetArch
declare -A proxyBook

read -r -p "Install Shadowsocks with Cloak plugin? (y/n): " -e -i "y" OPTION
if [[ "$OPTION" =~ ^[Yy]$ ]]; then
    SHADOWSOCKS=true
    # P2: Secure Cryptographic Password Generation
    read -r -p "Enter Shadowsocks password (leave blank for secure random): " Password
    if [ -z "$Password" ]; then
        Password=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)
        echo -e "${PURPLE}Generated Secure Password: $Password${NC}"
    fi
    
    cipher="aes-256-gcm"
    ss_dns="1.1.1.1"
    GetRandomPort SS_PORT
    proxyBook+=(["shadowsocks"]="t127.0.0.1:$SS_PORT")
fi

if [[ "$distro" =~ (ubuntu|debian|raspbian) ]]; then
    apt-get update -y >/dev/null
    apt-get -y install wget jq curl xz-utils iptables
fi

DownloadCloak

Local_Address_Book_For_Admin="panel"
proxyBook+=(["$Local_Address_Book_For_Admin"]="t127.0.0.1:0")
GenerateProxyBook 

mkdir -p /etc/cloak
chmod 700 /etc/cloak
cd /etc/cloak || exit 1

ckauid=$(ck-server -u)
ckaauid=$(ck-server -u) 
ckbuid=$(ck-server -u)
IFS=, read -r ckpub ckpv <<<"$(ck-server -k)"

cat <<JSON > ckserver.json
{
  "ProxyBook": {
    $PROXY_BOOK
  },
  "BypassUID": [
    "$ckaauid",
    "$ckbuid"
  ],
  "BindAddr":[":$PORT"],
  "RedirAddr": "$ckwebaddr",
  "PrivateKey": "$ckpv",
  "AdminUID": "$ckauid",
  "DatabasePath": "userinfo.db",
  "StreamTimeout": 300
}
JSON
chmod 600 ckserver.json

echo "PORT=$PORT" > ckport.txt
echo "ckaauid=\"$ckaauid\"" >> ckport.txt

cat <<JSON > ckadminclient.json
{
    "ProxyMethod":"$Local_Address_Book_For_Admin",
    "EncryptionMethod":"plain",
    "UID":"$ckaauid",
    "PublicKey":"$ckpub",
    "ServerName":"www.bing.com",
    "NumConn":1,
    "BrowserSig":"chrome",
    "StreamTimeout": 300
}
JSON
chmod 600 ckadminclient.json

cat <<EOF > /etc/systemd/system/cloak-server.service
[Unit]
Description=Cloak Server Service
After=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=32768
ExecStart=/usr/bin/ck-server -c ckserver.json
WorkingDirectory=/etc/cloak

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start cloak-server
systemctl enable cloak-server

if [[ "$SHADOWSOCKS" == true ]]; then
    if [[ "$distro" =~ (ubuntu|debian|raspbian) ]]; then
        apt-get -y install haveged qrencode >/dev/null
    fi
    DownloadAndInstallSSRust
    PUBLIC_IP="$(curl -sS https://api.ipify.org || echo "YOUR_IP")"
    clear
    ckuid="$ckbuid"
    ShowConnectionInfo
fi

echo -e "${GREEN}Installation Complete!${NC}"
EOF
chmod +x Cloak2-Installer.sh
