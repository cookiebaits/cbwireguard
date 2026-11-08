#!/bin/bash
# ==============================================================================
# 🍪 Cookie's Easy WireGuard Manager
#    (Simple AllowedIPs | True Server-Side Split Tunnel | Payment & Speed Tuned)
# ==============================================================================
set -euo pipefail

GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
WHITE='\033[1;37m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

GIT_REPO='https://raw.githubusercontent.com/cookiebaits/cbwireguard/main'
INSTALL_DIR="/root/easy_wireguard"
SETTINGS_FILE="${INSTALL_DIR}/settings.conf"
BYPASS_DOMAINS_FILE="${INSTALL_DIR}/bypass_domains.txt"
SPLIT_MODE_FILE="${INSTALL_DIR}/split_mode.txt"
DNSMASQ_WG_CONF="/etc/dnsmasq.d/99-wg-server-split.conf"
DNSMASQ_PORT=53530
REDSOCKS_PORT=12345
WARP_SOCKS_PORT=40000

if [[ "$EUID" -ne 0 ]]; then
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
DEFAULT_DNS="1.1.1.1, 8.8.8.8"
DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
EOF
        chmod 600 "$SETTINGS_FILE"
    else
        sed -i 's/^DEFAULT_MTU=1360/DEFAULT_MTU=1420/' "$SETTINGS_FILE" 2>/dev/null || true
        # Always clean any old fragmented multi-CIDR AllowedIPs back to simple full-tunnel
        if grep -q "0.0.0.0/2" "$SETTINGS_FILE" 2>/dev/null || [[ $(grep "^DEFAULT_ALLOWED_IPS=" "$SETTINGS_FILE" 2>/dev/null | wc -c || echo 0) -gt 60 ]]; then
            sed -i 's|^DEFAULT_ALLOWED_IPS=.*|DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"|' "$SETTINGS_FILE" 2>/dev/null || true
        fi
    fi

    [[ ! -f "$BYPASS_DOMAINS_FILE" ]] && touch "$BYPASS_DOMAINS_FILE"
    [[ ! -f "$SPLIT_MODE_FILE" ]] && echo "BYPASS" > "$SPLIT_MODE_FILE"
}

init_environment

if [[ -f "$SETTINGS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
fi

# ------------------------------------------------------------------------------
# Helper Functions: Progress Bar, Clear Stripping & OpenSSL Config Encryption
# ------------------------------------------------------------------------------
show_progress_bar() {
    local percent="$1"
    local step_text="$2"
    local bar_width=28
    local num_filled=$(( (percent * bar_width) / 100 ))
    local num_empty=$(( bar_width - num_filled ))
    local bar_str=""
    local i

    for ((i=0; i<num_filled; i++)); do bar_str+="█"; done
    for ((i=0; i<num_empty; i++)); do bar_str+="░"; done

    printf "\r  ${CYAN}[%3d%%]${NC} [${GREEN}%s${NC}] ${WHITE}%-54s${NC}\033[K" "$percent" "$bar_str" "$step_text"
    if [[ "$percent" -ge 100 ]]; then
        echo ""
    fi
}

strip_clear_from_script() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sed -i -E 's/^[[:space:]]*(clear|tput[[:space:]]+reset)[[:space:]]*$/: # clear disabled/g' "$file" 2>/dev/null || true
    fi
}

safe_ipt_del() {
    local cmd="$1"
    shift
    local tries=0
    while [[ $tries -lt 10 ]]; do
        if ! "$cmd" -w 2 "$@" >/dev/null 2>&1; then
            break
        fi
        tries=$((tries + 1))
    done
}

decrypt_conf_file() {
    local enc_file="$1"
    local pass="$2"
    local out=""
    out=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "pass:${pass}" -in "$enc_file" 2>/dev/null || true)
    if [[ "$out" == *"[Interface]"* ]]; then
        echo "$out"
        return 0
    fi
    out=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${pass}" -in "$enc_file" 2>/dev/null || true)
    if [[ "$out" == *"[Interface]"* ]]; then
        echo "$out"
        return 0
    fi
    return 1
}

encrypt_conf_file() {
    local content="$1"
    local enc_file="$2"
    local pass="$3"
    echo -n "$content" | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:${pass}" -out "$enc_file" 2>/dev/null || \
    echo -n "$content" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:${pass}" -out "$enc_file" 2>/dev/null
    chmod 600 "$enc_file" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 1. Server-Side Egress Helper for Datacenter-Blocked Split Domains (e.g. LinkedIn)
#    Uses passive localhost SOCKS5 (127.0.0.1:40000) + redsocks (127.0.0.1:12345)
#    ONLY for wg_split_v4 TCP traffic. Never touches host routing or eth0!
# ------------------------------------------------------------------------------
ensure_split_egress_bridge() {
    local dom_count
    dom_count=$(awk '!/^(#|[[:space:]]*$)/ {c++} END {print c+0}' "$BYPASS_DOMAINS_FILE" 2>/dev/null || echo 0)
    if [[ "$dom_count" -eq 0 ]]; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    # 1. Ensure redsocks is installed for transparent TCP -> SOCKS5 bridging
    if ! command -v redsocks &>/dev/null && command -v apt-get &>/dev/null; then
        apt-get update -o Acquire::Languages=none -qq >/dev/null 2>&1 || true
        apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" redsocks >/dev/null 2>&1 || true
    fi

    # 2. Ensure warp-cli is installed and running in passive SOCKS5 proxy mode (127.0.0.1:40000)
    if ! command -v warp-cli &>/dev/null && command -v apt-get &>/dev/null; then
        local arch="amd64"
        command -v dpkg &>/dev/null && arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        local codename="jammy"
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
        fi
        case "$codename" in
            noble|jammy|focal|bionic|bookworm|bullseye|buster) ;;
            *) codename="jammy" ;;
        esac
        mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
        curl -fsSL --connect-timeout 5 --max-time 10 https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
        echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" > /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
        apt-get update -o Acquire::Timeout="8" -o Dir::Etc::sourcelist="sources.list.d/cloudflare-client.list" -o Dir::Etc::sourceparts="-" -qq >/dev/null 2>&1 || true
        apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" cloudflare-warp >/dev/null 2>&1 || true
    fi

    if command -v warp-cli &>/dev/null; then
        systemctl enable --now warp-svc >/dev/null 2>&1 || true
        sleep 0.5
        warp-cli --accept-tos registration new >/dev/null 2>&1 || warp-cli --accept-tos register >/dev/null 2>&1 || echo "y" | warp-cli register >/dev/null 2>&1 || true
        warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || true
        warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || warp-cli --accept-tos set-proxy-port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true
        warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
    fi

    if command -v redsocks &>/dev/null; then
        cat << EOF > /etc/redsocks.conf
base {
    log_debug = off;
    log_info = off;
    log = "syslog:daemon";
    daemon = on;
    user = redsocks;
    group = redsocks;
    redirector = iptables;
}
redsocks {
    local_ip = 0.0.0.0;
    local_port = ${REDSOCKS_PORT};
    ip = 127.0.0.1;
    port = ${WARP_SOCKS_PORT};
    type = socks5;
}
EOF
        systemctl enable redsocks >/dev/null 2>&1 || true
        timeout 5 systemctl restart redsocks >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# 2. Server Forwarding, Zero-Hop TTL, QUIC Fallback & Payment Engine
# ------------------------------------------------------------------------------
ensure_server_forwarding_active() {
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe iptable_nat >/dev/null 2>&1 || true
    modprobe iptable_mangle >/dev/null 2>&1 || true
    modprobe xt_mark >/dev/null 2>&1 || true
    modprobe ipt_TTL >/dev/null 2>&1 || true
    modprobe nf_conntrack >/dev/null 2>&1 || true

    local sysctl_file="/etc/sysctl.d/99-wireguard-forward.conf"
    cat << 'SYSCTL_EOF' > "$sysctl_file"
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 2048000
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535
SYSCTL_EOF

    if lsmod 2>/dev/null | grep -q bbr || grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> "$sysctl_file"
    fi

    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_max=262144 >/dev/null 2>&1 || true
    sysctl --system -q >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1 || true

    local def_nic
    def_nic=$(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

    if command -v ethtool &>/dev/null && [[ -n "$def_nic" ]]; then
        ethtool -K "$def_nic" tx on rx on sg on tso on gso on gro on >/dev/null 2>&1 || true
    fi

    if [[ -f /etc/wireguard/wg0.conf ]]; then
        # Strip any hardcoded --ttl-set 64 from wg0.conf (which breaks Windows TTL=128 on LinkedIn & payment sites)
        if grep -q "ttl-set 64" /etc/wireguard/wg0.conf 2>/dev/null; then
            sed -i 's/-A POSTROUTING -o [^ ]* -j TTL --ttl-set 64/-I PREROUTING 1 -i wg0 -j TTL --ttl-inc 1/g' /etc/wireguard/wg0.conf 2>/dev/null || true
            sed -i 's/-D POSTROUTING -o [^ ]* -j TTL --ttl-set 64/-D PREROUTING -i wg0 -j TTL --ttl-inc 1/g' /etc/wireguard/wg0.conf 2>/dev/null || true
        fi

        local wg_port
        wg_port=$(grep -iE "^[[:space:]]*ListenPort[[:space:]]*=" /etc/wireguard/wg0.conf 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || true)
        if [[ -n "$wg_port" && "$wg_port" =~ ^[0-9]+$ ]]; then
            iptables -C INPUT -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null || true
        fi

        # Remove any live --ttl-set 64 rules in POSTROUTING
        safe_ipt_del iptables -t mangle -D POSTROUTING -o "$def_nic" -j TTL --ttl-set 64
        safe_ipt_del iptables -t mangle -D POSTROUTING -j TTL --ttl-set 64

        # Zero-Hop TTL Preservation: Windows stays 128, Mac/iOS/Android stays 64
        iptables -t mangle -C PREROUTING -i wg0 -j TTL --ttl-inc 1 2>/dev/null || \
            iptables -t mangle -I PREROUTING 1 -i wg0 -j TTL --ttl-inc 1 2>/dev/null || true

        # Reject UDP 443 (QUIC) on wg0 so browsers instantly use TCP 443 with TCPMSS clamping
        iptables -C FORWARD -i wg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || \
            iptables -I FORWARD 1 -i wg0 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true

        iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 2 -i wg0 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -o wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 3 -o wg0 -j ACCEPT 2>/dev/null || true

        iptables -t mangle -C FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD 1 -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD 2 -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

        if [[ -n "$def_nic" ]]; then
            iptables -t nat -C POSTROUTING -o "$def_nic" -j MASQUERADE 2>/dev/null || \
                iptables -t nat -I POSTROUTING 1 -o "$def_nic" -j MASQUERADE 2>/dev/null || true
        fi
    fi
}

apply_server_side_split_and_payment_engine() {
    echo -e "\n${CYAN}${BOLD}[*] Applying Server-Side Split Tunneling & Payment Gateway Optimization...${NC}"

    ensure_server_forwarding_active

    show_progress_bar 15 "Checking dnsmasq, ipset, and DNS utilities..."
    for tool_pkg in "dnsmasq:dnsmasq" "ipset:ipset" "dig:dnsutils" "python3:python3"; do
        local bin="${tool_pkg%%:*}"
        local pkg="${tool_pkg##*:}"
        if ! command -v "$bin" &>/dev/null && command -v apt-get &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -o Acquire::Languages=none -qq >/dev/null 2>&1 || true
            apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$pkg" >/dev/null 2>&1 || true
        fi
    done

    if command -v ipset &>/dev/null; then
        ipset create wg_payment_v4 hash:net family inet 2>/dev/null || true
        ipset create wg_split_v4 hash:net family inet 2>/dev/null || true
        ipset flush wg_split_v4 2>/dev/null || true
    fi

    local wg0_ip="10.8.0.1"
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        local cfg_ip
        cfg_ip=$(grep -iE "^[[:space:]]*Address[[:space:]]*=" /etc/wireguard/wg0.conf 2>/dev/null | head -n1 | awk -F'=' '{print $2}' | cut -d',' -f1 | cut -d'/' -f1 | tr -d ' \t\r\n' || true)
        [[ -n "$cfg_ip" ]] && wg0_ip="$cfg_ip"
    fi
    local live_wg_ip
    live_wg_ip=$(ip -4 -o addr show dev wg0 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1 || true)
    [[ -n "$live_wg_ip" ]] && wg0_ip="$live_wg_ip"

    mkdir -p /etc/wireguard
    [[ ! -f "$BYPASS_DOMAINS_FILE" ]] && touch "$BYPASS_DOMAINS_FILE"
    cp -f "$BYPASS_DOMAINS_FILE" /etc/wireguard/split_domains.txt 2>/dev/null || true

    show_progress_bar 40 "Building payment & split-tunnel DNS + IPSet rules on server..."

    local has_dnsmasq_ipset=0
    local has_filter_aaaa=0
    if command -v dnsmasq &>/dev/null; then
        dnsmasq -v 2>/dev/null | grep -qi "ipset" && has_dnsmasq_ipset=1
        dnsmasq --help 2>&1 | grep -q "filter-AAAA" && has_filter_aaaa=1
    fi

    python3 - "$BYPASS_DOMAINS_FILE" "$SETTINGS_FILE" "$DNSMASQ_WG_CONF" "$DNSMASQ_PORT" "$wg0_ip" "$has_dnsmasq_ipset" "$has_filter_aaaa" << 'PY_SERVER_SPLIT_EOF'
import sys, os, re, socket, subprocess, ipaddress

domains_file = sys.argv[1]
settings_file = sys.argv[2]
dnsmasq_conf = sys.argv[3]
dnsmasq_port = sys.argv[4]
wg0_ip = sys.argv[5]
has_ipset = int(sys.argv[6]) == 1
has_filter_aaaa = int(sys.argv[7]) == 1

PAYMENT_DOMAINS = [
    "paypal.com", "www.paypal.com", "c.paypal.com", "b.stats.paypal.com", "t.paypal.com",
    "s.paypal.com", "m.paypal.com", "api.paypal.com", "api-m.paypal.com", "checkout.paypal.com",
    "identity.paypal.com", "paypalobjects.com", "www.paypalobjects.com", "objects.paypal.com",
    "c.paypalobjects.com", "paypal.me", "braintreegateway.com", "braintree-api.com",
    "assets.braintreegateway.com", "js.braintreegateway.com",
    "cardinalcommerce.com", "songbird.cardinalcommerce.com", "centinelapi.cardinalcommerce.com",
    "geo.cardinalcommerce.com", "1.songbird.cardinalcommerce.com", "secure.cardinalcommerce.com",
    "stripe.com", "api.stripe.com", "js.stripe.com", "m.stripe.com", "m.stripe.network",
    "q.stripe.com", "r.stripe.com", "hooks.stripe.com", "checkout.stripe.com",
    "online-metrix.net", "h.online-metrix.net", "threatmetrix.com", "iesnare.com",
    "mpsnare.iesnare.com", "iovation.com", "kount.com", "kaptcha.com", "ssl.kaptcha.com",
    "sift.com", "siftscience.com", "forter.com", "riskified.com", "signifyd.com", "seon.io",
    "challenges.cloudflare.com", "turnstile.com", "hcaptcha.com", "newassets.hcaptcha.com",
    "recaptcha.net", "www.recaptcha.net", "gstatic.com", "www.gstatic.com", "arkoselabs.com",
    "client-api.arkoselabs.com", "funcaptcha.com",
    "amazon.com", "www.amazon.com", "completion.amazon.com", "fls-na.amazon.com",
    "aax.amazon-adsystem.com", "images-amazon.com", "ssl-images-amazon.com",
    "shopify.com", "checkout.shopify.com", "shop.app", "pay.shopify.com",
    "klarna.com", "js.klarna.com", "affirm.com", "cdn1.affirm.com",
    "ebay.com", "www.ebay.com", "pay.ebay.com", "pay.google.com", "apple.com",
    "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "americanexpress.com"
]

user_domains = []
if os.path.isfile(domains_file):
    with open(domains_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            d = line.strip().lower()
            if d and not d.startswith('#'):
                d = re.sub(r'^https?://', '', d).split('/')[0].strip()
                if d and d not in user_domains:
                    user_domains.append(d)

expanded_user = set()
has_linkedin = False
for d in user_domains:
    expanded_user.add(d)
    if not d.startswith('www.') and d.count('.') == 1:
        expanded_user.add('www.' + d)
    if 'linkedin.com' in d or 'licdn.com' in d:
        has_linkedin = True
        expanded_user.update([
            'linkedin.com', 'www.linkedin.com', 'licdn.com', 'media.licdn.com',
            'static.licdn.com', 'dms.licdn.com', 'voyager.linkedin.com', 'lnkd.in',
            'platform.linkedin.com', 'snap.licdn.com', 'px.ads.linkedin.com'
        ])
    elif 'netflix.com' in d:
        expanded_user.update(['nflxext.com', 'nflxso.net', 'nflxvideo.net', 'nflximg.net', 'fast.com'])
    elif 'disneyplus.com' in d:
        expanded_user.update(['disney-plus.net', 'dssott.com', 'bamgrid.com'])
    elif 'hulu.com' in d:
        expanded_user.update(['hulustream.com', 'huluim.com'])
    elif 'openai.com' in d or 'chatgpt.com' in d:
        expanded_user.update(['openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com'])
    elif 'discord.com' in d or 'discord.gg' in d or 'discordapp.com' in d:
        expanded_user.update([
            'discord.com', 'discordapp.com', 'discord.gg', 'discordapp.net',
            'discord.media', 'discordstatus.com', 'gateway.discord.gg',
            'cdn.discordapp.com', 'media.discordapp.net', 'status.discord.com'
        ])

upstream_dns = ["1.1.1.1", "8.8.8.8"]
if os.path.isfile(settings_file):
    with open(settings_file, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('DEFAULT_DNS='):
                val = line.split('=', 1)[1].strip().strip('"\'')
                parsed = []
                for part in val.split(','):
                    ip_str = part.strip()
                    try:
                        ip_obj = ipaddress.ip_address(ip_str)
                        if ip_obj.version == 4:
                            parsed.append(ip_str)
                    except ValueError:
                        pass
                if parsed:
                    upstream_dns = parsed

os.makedirs(os.path.dirname(dnsmasq_conf), exist_ok=True)
conf_lines = [
    "# Cookie Easy WireGuard - Server-Side Split Tunnel & Payment Engine",
    f"port={dnsmasq_port}",
    f"listen-address=127.0.0.1,{wg0_ip}",
    "bind-dynamic",
    "no-resolv",
    "no-poll",
    "no-edns0",
    "bogus-priv",
    "cache-size=10000",
    "dns-forward-max=1000",
    # Disable browser DoH bypass so Chrome/Edge/Firefox always use wg0 DNS
    "server=/use-application-dns.net/",
    "server=/_dns.resolver.arpa/",
]

# Always filter AAAA on wg0 because wg0 is IPv4-only (prevents IPv6 hangs on LinkedIn & checkouts)
if has_filter_aaaa:
    conf_lines.append("filter-AAAA")

for u_ip in upstream_dns:
    conf_lines.append(f"server={u_ip}")

for pdom in sorted(set(PAYMENT_DOMAINS)):
    conf_lines.append(f"server=/{pdom}/1.1.1.1")
    conf_lines.append(f"server=/{pdom}/8.8.8.8")
    if has_ipset:
        conf_lines.append(f"ipset=/.{pdom}/wg_payment_v4")

for sdom in sorted(expanded_user):
    conf_lines.append(f"server=/{sdom}/1.1.1.1")
    conf_lines.append(f"server=/{sdom}/8.8.8.8")
    if has_ipset:
        conf_lines.append(f"ipset=/.{sdom}/wg_split_v4")

with open(dnsmasq_conf, 'w', encoding='utf-8') as f:
    f.write('\n'.join(conf_lines) + '\n')

# Pre-populate PayPal & Payment CIDRs
PAYMENT_CIDRS = [
    "64.4.240.0/21", "66.211.168.0/21", "173.0.80.0/20", "173.224.160.0/19",
    "185.177.52.0/22", "192.148.20.0/23", "198.54.120.0/22", "216.113.160.0/19"
]
for cidr in PAYMENT_CIDRS:
    subprocess.run(['ipset', 'add', 'wg_payment_v4', cidr, '-exist'], stderr=subprocess.DEVNULL)

# If linkedin.com is in split domains, pre-populate all official LinkedIn AS12447 & Azure FrontDoor CIDRs
if has_linkedin:
    LINKEDIN_CIDRS = [
        "108.174.0.0/16", "144.2.0.0/19", "185.63.144.0/22", "199.101.160.0/22",
        "216.52.16.0/20", "216.52.20.0/22", "216.52.24.0/22", "65.156.227.0/24",
        "8.247.168.0/24", "13.107.42.0/24", "150.171.22.0/24"
    ]
    for lcidr in LINKEDIN_CIDRS:
        subprocess.run(['ipset', 'add', 'wg_split_v4', lcidr, '-exist'], stderr=subprocess.DEVNULL)

def resolve_into_ipset(domain_list, set_name):
    resolved_count = 0
    for dom in domain_list:
        ips = set()
        try:
            for res in socket.getaddrinfo(dom, None, socket.AF_INET):
                ip_obj = ipaddress.IPv4Address(res[4][0])
                if ip_obj.is_global and not ip_obj.is_private:
                    ips.add(str(ip_obj))
        except Exception:
            pass
        for resolver in ['1.1.1.1', '8.8.8.8']:
            try:
                out = subprocess.check_output(
                    ['dig', '+time=1', '+tries=1', '+short', f'@{resolver}', dom, 'A'],
                    stderr=subprocess.DEVNULL, text=True, timeout=2
                )
                for tok in out.splitlines():
                    try:
                        ip_obj = ipaddress.IPv4Address(tok.strip())
                        if ip_obj.is_global and not ip_obj.is_private:
                            ips.add(str(ip_obj))
                    except ValueError:
                        pass
            except Exception:
                pass
        for ip_s in ips:
            subprocess.run(['ipset', 'add', set_name, f"{ip_s}/24", '-exist'], stderr=subprocess.DEVNULL)
            resolved_count += 1
    return resolved_count

core_pay_list = [
    "paypal.com", "www.paypal.com", "c.paypal.com", "b.stats.paypal.com", "api-m.paypal.com",
    "paypalobjects.com", "cardinalcommerce.com", "songbird.cardinalcommerce.com",
    "centinelapi.cardinalcommerce.com", "stripe.com", "api.stripe.com", "js.stripe.com",
    "m.stripe.network", "braintreegateway.com", "h.online-metrix.net", "amazon.com", "www.amazon.com"
]
pay_ips_added = resolve_into_ipset(core_pay_list, 'wg_payment_v4')
split_ips_added = resolve_into_ipset(sorted(expanded_user), 'wg_split_v4')

with open('/tmp/.wg_split_summary', 'w', encoding='utf-8') as sf:
    sf.write(f"  \033[0;32m├─ Payment Shield:\033[0m    {len(PAYMENT_DOMAINS)} payment/3DS/fraud domains whitelisted ({pay_ips_added} live subnets)\n")
    sf.write(f"  \033[0;32m├─ Split Domains:\033[0m     {len(user_domains)} custom domain(s) active on server ({split_ips_added} live subnets in wg_split_v4)\n")
PY_SERVER_SPLIT_EOF

    show_progress_bar 70 "Starting server-side DNS resolver & split-tunnel egress bridge..."

    # Ensure split egress bridge (redsocks -> 127.0.0.1:40000) is ready if custom split domains are configured
    ensure_split_egress_bridge

    rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf /etc/dnsmasq.d/00-wg-location-stealth.conf 2>/dev/null || true

    local dnsmasq_ok=0
    if command -v dnsmasq &>/dev/null; then
        if ! dnsmasq --test -C "$DNSMASQ_WG_CONF" >/dev/null 2>&1; then
            sed -i '/^ipset=/d' "$DNSMASQ_WG_CONF" 2>/dev/null || true
        fi
        if ! dnsmasq --test -C "$DNSMASQ_WG_CONF" >/dev/null 2>&1; then
            sed -i '/^filter-AAAA/d' "$DNSMASQ_WG_CONF" 2>/dev/null || true
        fi
        systemctl enable dnsmasq >/dev/null 2>&1 || true
        timeout 5 systemctl restart dnsmasq >/dev/null 2>&1 || true

        if command -v dig &>/dev/null && dig +time=1 +tries=1 @127.0.0.1 -p "$DNSMASQ_PORT" cloudflare.com A >/dev/null 2>&1; then
            dnsmasq_ok=1
        fi
    fi

    # Clean previous PREROUTING NAT redirect rules
    safe_ipt_del iptables -t nat -D PREROUTING -i wg0 -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
    safe_ipt_del iptables -t nat -D PREROUTING -i wg0 -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
    safe_ipt_del iptables -t nat -D PREROUTING -i wg0 -p tcp -m set --match-set wg_payment_v4 dst -j RETURN
    safe_ipt_del iptables -t nat -D PREROUTING -i wg0 -p tcp -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports "$REDSOCKS_PORT"

    if [[ "$dnsmasq_ok" -eq 1 ]]; then
        iptables -C INPUT -i wg0 -p udp --dport "$DNSMASQ_PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -i wg0 -p udp --dport "$DNSMASQ_PORT" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -i wg0 -p tcp --dport "$DNSMASQ_PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 2 -i wg0 -p tcp --dport "$DNSMASQ_PORT" -j ACCEPT 2>/dev/null || true

        iptables -t nat -I PREROUTING 1 -i wg0 -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null || true
        iptables -t nat -I PREROUTING 2 -i wg0 -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT" 2>/dev/null || true
    fi

    local bridge_active=0
    if isPortInUse "$WARP_SOCKS_PORT" "tcp" && isPortInUse "$REDSOCKS_PORT" "tcp"; then
        bridge_active=1
    fi

    if command -v ipset &>/dev/null; then
        # Priority FORWARD allow rules (above any geo/anti-VPN filter)
        safe_ipt_del iptables -D FORWARD -i wg0 -m set --match-set wg_payment_v4 dst -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o wg0 -m set --match-set wg_payment_v4 src -j ACCEPT
        safe_ipt_del iptables -D FORWARD -i wg0 -m set --match-set wg_split_v4 dst -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o wg0 -m set --match-set wg_split_v4 src -j ACCEPT

        iptables -I FORWARD 2 -i wg0 -m set --match-set wg_payment_v4 dst -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 3 -o wg0 -m set --match-set wg_payment_v4 src -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 4 -i wg0 -m set --match-set wg_split_v4 dst -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 5 -o wg0 -m set --match-set wg_split_v4 src -j ACCEPT 2>/dev/null || true

        # If the split egress bridge (redsocks -> 127.0.0.1:40000) is active:
        # 1. Payment domains (wg_payment_v4) RETURN immediately so they ALWAYS use native static VPS IP (eth0)
        # 2. Split domains (wg_split_v4, e.g. linkedin.com) redirect to redsocks so they bypass datacenter ASN blocks!
        if [[ "$bridge_active" -eq 1 ]]; then
            iptables -C INPUT -i wg0 -p tcp --dport "$REDSOCKS_PORT" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT 1 -i wg0 -p tcp --dport "$REDSOCKS_PORT" -j ACCEPT 2>/dev/null || true
            iptables -t nat -A PREROUTING -i wg0 -p tcp -m set --match-set wg_payment_v4 dst -j RETURN 2>/dev/null || true
            iptables -t nat -A PREROUTING -i wg0 -p tcp -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports "$REDSOCKS_PORT" 2>/dev/null || true
        fi
    fi

    show_progress_bar 100 "Server-side split tunneling & payment engine active!"
    if [[ -f /tmp/.wg_split_summary ]]; then
        cat /tmp/.wg_split_summary
        rm -f /tmp/.wg_split_summary
    fi
    if [[ "$bridge_active" -eq 1 ]]; then
        echo -e "  ${GREEN}└─ Server Split Egress:${NC} Active (Split domains bypass VPS datacenter ASN; Client AllowedIPs stays simple!)"
    else
        echo -e "  ${GREEN}└─ Server DNS & TTL:${NC}    Zero-Hop OS TTL + QUIC Fallback + Payment DNS active on port ${DNSMASQ_PORT}"
    fi
}

# ------------------------------------------------------------------------------
# 3. Sensitive Port Protection & Port-In-Use Verification
# ------------------------------------------------------------------------------
isSensitivePort() {
    local port="$1"
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 1935 8080 8443 3306 5432 6379 27017)
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
            ss -uln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        else
            ss -tln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        fi
    elif command -v netstat &>/dev/null; then
        if [[ "$proto" == "udp" ]]; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        else
            netstat -tln 2>/dev/null | grep -qE "(:|\])${port}[[:space:]]" && return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 4. Pre-Install Cleanup, Hijack Purge & Deep Uninstaller (Guarded Single Run)
# ------------------------------------------------------------------------------
cleanupOldWireguard() {
    local mode="${1:-preinstall}"

    if [[ "$mode" == "preinstall" && -f /tmp/.wg_cleanup_done ]]; then
        return 0
    fi
    touch /tmp/.wg_cleanup_done

    echo -e "\n${CYAN}${BOLD}[*] Cleaning up existing WireGuard instances, routing hijacks, ports, and cache...${NC}"

    show_progress_bar 15 "Scanning configs & kernel for WireGuard interfaces/ports..."
    local OLD_PORTS=()
    local OLD_IFACES=("wg0" "wg1")

    if [[ -d /etc/wireguard ]]; then
        for conf in /etc/wireguard/*.conf; do
            [[ ! -f "$conf" ]] && continue
            local iface_name
            iface_name=$(basename "$conf" .conf)
            OLD_IFACES+=("$iface_name")

            local extracted_ports
            extracted_ports=$(grep -iE "^[[:space:]]*ListenPort[[:space:]]*=" "$conf" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' \t\r\n' || true)
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

    if command -v wg &>/dev/null; then
        local live_ifaces
        live_ifaces=$(timeout 3 wg show interfaces 2>/dev/null || true)
        for liface in $live_ifaces; do
            OLD_IFACES+=("$liface")
            local lport
            lport=$(timeout 2 wg show "$liface" listen-port 2>/dev/null | tr -d ' \t\r\n' || true)
            [[ "$lport" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$lport")
        done
    fi

    local link_ifaces
    link_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wg[0-9a-zA-Z_-]*' || true)
    for kiface in $link_ifaces; do
        OLD_IFACES+=("$kiface")
    done

    local conf_files=()
    while IFS= read -r -d '' cf; do
        conf_files+=("$cf")
    done < <(find /etc/wireguard "$INSTALL_DIR" /root /home -maxdepth 2 -type f -name "*.conf" -print0 2>/dev/null || true)

    for cf in "${conf_files[@]}"; do
        while IFS= read -r ep_line; do
            local ep_port="${ep_line##*:}"
            ep_port=$(echo "$ep_port" | tr -d ' \t\r\n')
            [[ "$ep_port" =~ ^[0-9]+$ ]] && OLD_PORTS+=("$ep_port")
        done < <(grep -E "^[[:space:]]*Endpoint[[:space:]]*=" "$cf" 2>/dev/null || true)
    done

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

    show_progress_bar 35 "Stopping WireGuard services and resetting settings.conf..."
    timeout 10 systemctl stop "wg-quick@*" >/dev/null 2>&1 || true
    timeout 10 systemctl disable "wg-quick@*" >/dev/null 2>&1 || true
    timeout 5 systemctl stop cbwireguard-web >/dev/null 2>&1 || true
    timeout 5 systemctl disable cbwireguard-web >/dev/null 2>&1 || true

    while ip rule del fwmark 0x51820 table 51820 2>/dev/null; do :; done
    ip route flush table 51820 2>/dev/null || true
    while ip rule del fwmark 0x200 table 200 2>/dev/null; do :; done
    ip route flush table 200 2>/dev/null || true

    rm -f /etc/dnsmasq.d/00-stealth-privacy.conf /etc/dnsmasq.d/wg_split.conf /etc/dnsmasq.d/00-wg-location-stealth.conf "$DNSMASQ_WG_CONF" 2>/dev/null || true
    if [[ -f /etc/systemd/resolved.conf.d/no-stub.conf ]]; then
        rm -f /etc/systemd/resolved.conf.d/no-stub.conf 2>/dev/null || true
        timeout 5 systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi

    # Reset DEFAULT_ALLOWED_IPS in settings.conf so no 65-CIDR list is ever inherited
    if [[ -f "$SETTINGS_FILE" ]]; then
        sed -i 's|^DEFAULT_ALLOWED_IPS=.*|DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"|' "$SETTINGS_FILE" 2>/dev/null || true
        sed -i 's|^DEFAULT_MTU=.*|DEFAULT_MTU=1420|' "$SETTINGS_FILE" 2>/dev/null || true
    fi

    local wg_units
    wg_units=$(timeout 5 systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '(^wg-quick|wireguard|cbwireguard)' || true)
    for unit in $wg_units; do
        timeout 5 systemctl stop "$unit" >/dev/null 2>&1 || true
        timeout 5 systemctl disable "$unit" >/dev/null 2>&1 || true
    done

    show_progress_bar 55 "Removing virtual WireGuard interfaces (${UNIQUE_IFACES[*]})..."
    for iface in "${UNIQUE_IFACES[@]}"; do
        timeout 5 systemctl stop "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        timeout 5 systemctl disable "wg-quick@${iface}.service" >/dev/null 2>&1 || true
        if command -v wg-quick &>/dev/null; then
            timeout 5 wg-quick down "$iface" >/dev/null 2>&1 || true
        fi
        ip link set "$iface" down >/dev/null 2>&1 || true
        ip link delete dev "$iface" >/dev/null 2>&1 || true

        safe_ipt_del iptables -D FORWARD -i "$iface" -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable
        safe_ipt_del iptables -D FORWARD -i "$iface" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o "$iface" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        safe_ipt_del iptables -D INPUT -i "$iface" -j ACCEPT
        safe_ipt_del iptables -D INPUT -i "$iface" -p udp --dport "$DNSMASQ_PORT" -j ACCEPT
        safe_ipt_del iptables -D INPUT -i "$iface" -p tcp --dport "$DNSMASQ_PORT" -j ACCEPT
        safe_ipt_del iptables -D INPUT -i "$iface" -p tcp --dport "$REDSOCKS_PORT" -j ACCEPT
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports 53
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p tcp --dport 53 -j REDIRECT --to-ports 53
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p tcp --dport 53 -j REDIRECT --to-ports "$DNSMASQ_PORT"
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p tcp -m set --match-set wg_payment_v4 dst -j RETURN
        safe_ipt_del iptables -t nat -D PREROUTING -i "$iface" -p tcp -m set --match-set wg_split_v4 dst -j REDIRECT --to-ports "$REDSOCKS_PORT"
        safe_ipt_del ip6tables -D FORWARD -i "$iface" -j ACCEPT
        safe_ipt_del ip6tables -D FORWARD -o "$iface" -j ACCEPT
        safe_ipt_del ip6tables -D FORWARD -i "$iface" -j REJECT
        safe_ipt_del ip6tables -D OUTPUT -o "$iface" -j REJECT
    done

    show_progress_bar 75 "Cleaning old WireGuard UDP ports (sensitive ports protected)..."
    local cleaned_ports_list=()
    for port in "${UNIQUE_PORTS[@]}"; do
        if isSensitivePort "$port"; then
            continue
        fi
        cleaned_ports_list+=("${port}/udp")
        safe_ipt_del iptables -D INPUT -p udp --dport "$port" -j ACCEPT
        safe_ipt_del iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
        safe_ipt_del ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT
        safe_ipt_del ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT

        if command -v ufw &>/dev/null && timeout 3 ufw status 2>/dev/null | grep -q "Status: active"; then
            timeout 5 ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
            timeout 5 ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            timeout 5 firewall-cmd --remove-port="${port}/udp" --permanent >/dev/null 2>&1 || true
            timeout 5 firewall-cmd --remove-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
            timeout 5 firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    done

    show_progress_bar 88 "Flushing leftover PREROUTING, NAT, Mangle, and IPSet rules..."
    local wg_subnets=("10.18.0.0/24" "10.19.0.0/24" "10.8.0.0/24" "10.0.0.0/24" "10.66.66.0/24" "10.7.0.0/24" "10.10.0.0/24")
    local def_nic
    def_nic=$(ip -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n1 || echo "eth0")

    if command -v ethtool &>/dev/null && [[ -n "$def_nic" ]]; then
        ethtool -K "$def_nic" tx on rx on sg on tso on gso on gro on >/dev/null 2>&1 || true
    fi

    iptables -t mangle -F PREROUTING 2>/dev/null || true
    iptables -t mangle -F FORWARD 2>/dev/null || true
    iptables -t mangle -F POSTROUTING 2>/dev/null || true

    for sub in "${wg_subnets[@]}"; do
        safe_ipt_del iptables -D FORWARD -s "$sub" -j ACCEPT
        safe_ipt_del iptables -D FORWARD -d "$sub" -j ACCEPT
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" -j MASQUERADE
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" -o "$def_nic" -j MASQUERADE
        safe_ipt_del iptables -t nat -D POSTROUTING -s "$sub" ! -o wg0 -j MASQUERADE
    done

    safe_ipt_del iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    if command -v ipset &>/dev/null; then
        local wg_ipsets
        wg_ipsets=$(ipset list -n 2>/dev/null | grep -iE '^(wg_|geo_|vpn_)' || true)
        for setname in $wg_ipsets; do
            safe_ipt_del iptables -D INPUT -m set --match-set "$setname" src -j DROP
            safe_ipt_del iptables -D FORWARD -m set --match-set "$setname" src -j DROP
            safe_ipt_del iptables -D FORWARD -i wg0 -m set --match-set "$setname" dst -j ACCEPT
            safe_ipt_del iptables -D FORWARD -o wg0 -m set --match-set "$setname" src -j ACCEPT
            safe_ipt_del iptables -t nat -D POSTROUTING -m set --match-set "$setname" dst -o "$def_nic" -j MASQUERADE
            ipset flush "$setname" 2>/dev/null || true
            ipset destroy "$setname" 2>/dev/null || true
        done
    fi

    show_progress_bar 96 "Purging old cached WireGuard scripts, client configs & sockets..."
    rm -f "${INSTALL_DIR}"/*.sh "${INSTALL_DIR}"/.*.sh "${INSTALL_DIR}"/*.conf "${INSTALL_DIR}"/*.conf.enc 2>/dev/null || true
    rm -rf /etc/wireguard/clients /run/wireguard /var/run/wireguard /tmp/*wireguard* /tmp/*wg* /var/tmp/*wireguard* /var/tmp/*wg* 2>/dev/null || true
    rm -f /var/cache/apt/archives/*wireguard* /etc/wireguard/*.conf /etc/wireguard/*.conf.enc /etc/wireguard/params /etc/wireguard/manager.env /etc/wireguard/.*.swp 2>/dev/null || true
    rm -f /etc/sysctl.d/99-wireguard-speed-stealth.conf /etc/sysctl.d/99-wireguard-stealth.conf /etc/sysctl.d/99-wireguard-bbr.conf 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    show_progress_bar 100 "Cleanup & hijack purge complete!"

    if [[ "$mode" == "preinstall" ]]; then
        echo -e "  ${GREEN}├─ Interfaces Cleaned:${NC} ${UNIQUE_IFACES[*]}"
        if [[ ${#cleaned_ports_list[@]} -gt 0 ]]; then
            echo -e "  ${GREEN}├─ Old Ports Freed:${NC}    ${cleaned_ports_list[*]}"
        else
            echo -e "  ${GREEN}├─ Old Ports Freed:${NC}    None active"
        fi
        echo -e "  ${GREEN}└─ Cache & AllowedIPs:${NC} Reset to simple AllowedIPs; sensitive ports (80, 443, 22, 1935) untouched."
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

    show_progress_bar 10 "Running uninstaller script (auto-confirming prompts)..."
    local rem_script=""
    if [[ -f "./remove_server.sh" ]]; then
        rem_script="./remove_server.sh"
    elif [[ -f "${INSTALL_DIR}/remove_server.sh" ]]; then
        rem_script="${INSTALL_DIR}/remove_server.sh"
    elif curl -sSfL --connect-timeout 4 --max-time 10 "${GIT_REPO}/remove_server.sh" -o "${INSTALL_DIR}/remove_server.sh" 2>/dev/null; then
        rem_script="${INSTALL_DIR}/remove_server.sh"
    fi

    if [[ -n "$rem_script" && -f "$rem_script" ]]; then
        strip_clear_from_script "$rem_script"
        chmod 700 "$rem_script" 2>/dev/null || true
        yes "y" 2>/dev/null | timeout 15 "$rem_script" >/dev/null 2>&1 || true
    fi

    cleanupOldWireguard "deep"

    show_progress_bar 50 "Unloading WireGuard kernel module..."
    if lsmod 2>/dev/null | grep -q "^wireguard"; then
        timeout 5 modprobe -r wireguard 2>/dev/null || true
    fi

    show_progress_bar 70 "Scanning /root, /home, /etc, and /tmp for WireGuard client configs..."
    local removed_files_count=0
    local client_search_dirs=("/root" "/home" "/tmp" "/var/tmp" "/etc/wireguard" "/opt")
    for sdir in "${client_search_dirs[@]}"; do
        [[ ! -d "$sdir" ]] && continue
        while IFS= read -r -d '' f; do
            local bname
            bname=$(basename "$f")
            [[ "$bname" == "resolv.conf" || "$bname" == "sysctl.conf" || "$bname" == "host.conf" || "$bname" == "nsswitch.conf" ]] && continue
            if grep -qE "(\[Interface\]|\[Peer\]|PrivateKey[[:space:]]*=|AllowedIPs[[:space:]]*=|wg-quick)" "$f" 2>/dev/null || [[ "$bname" == *.conf.enc ]]; then
                rm -f "$f" 2>/dev/null || true
                removed_files_count=$((removed_files_count + 1))
            fi
        done < <(find "$sdir" -maxdepth 3 -type f \( -name "*.conf" -o -name "*.conf.enc" -o -name "*.key" \) -print0 2>/dev/null || true)
    done

    show_progress_bar 85 "Removing WireGuard sysctl, dnsmasq, and systemd drop-in files..."
    local sys_dirs=("/etc/sysctl.d" "/etc/dnsmasq.d" "/etc/systemd/system" "/etc/cron.d" "/etc/cron.daily" "/etc/cron.hourly")
    for sysd in "${sys_dirs[@]}"; do
        [[ ! -d "$sysd" ]] && continue
        while IFS= read -r -d '' sysf; do
            if echo "$sysf" | grep -qiE "(wireguard|wg0|wg1|wg-quick|wg_split|99-wg-server-split|cbwireguard|stealth)" || grep -qiE "(wireguard|wg-quick|wg0|wg_split)" "$sysf" 2>/dev/null; then
                rm -f "$sysf" 2>/dev/null || true
                removed_files_count=$((removed_files_count + 1))
            fi
        done < <(find "$sysd" -maxdepth 2 \( -type f -o -type l \) -print0 2>/dev/null || true)
    done

    show_progress_bar 95 "Purging WireGuard directories, backups, and saving clean firewall state..."
    rm -rf /etc/wireguard /opt/cbwireguard "$INSTALL_DIR" /root/wireguard_backup* /home/*/easy_wireguard /var/cache/apt/archives/*wireguard* 2>/dev/null || true

    if command -v dnsmasq &>/dev/null && systemctl is-active --quiet dnsmasq 2>/dev/null; then
        timeout 5 systemctl restart dnsmasq >/dev/null 2>&1 || true
    fi
    netfilter-persistent save >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true

    init_environment
    show_progress_bar 100 "Deep removal complete! (${removed_files_count} config/system files purged)"

    echo -e "\n${GREEN}${BOLD}[✔] Deep removal finished! All WireGuard services, cached files, folders, and ports were removed.${NC}"
    echo -e "${GREEN}${BOLD}[✔] Sensitive ports (80, 443, 22, 1935, etc.) and host services remain completely untouched.${NC}"
}

# ------------------------------------------------------------------------------
# 5. Post-Install Config Display (Enforces Simple AllowedIPs on All Configs)
# ------------------------------------------------------------------------------
display_post_install_configs() {
    local target_simple_ips="0.0.0.0/0"
    if [[ -f /tmp/.wg_last_client_allowed_ips ]]; then
        target_simple_ips=$(cat /tmp/.wg_last_client_allowed_ips 2>/dev/null || echo "0.0.0.0/0")
    elif [[ -n "${DEFAULT_ALLOWED_IPS:-}" && ${#DEFAULT_ALLOWED_IPS} -lt 40 ]]; then
        target_simple_ips="$DEFAULT_ALLOWED_IPS"
    fi

    local found_plain=()
    local found_enc=()
    local search_paths=("/etc/wireguard/clients" "$INSTALL_DIR" "/root" "/etc/wireguard")
    if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
        search_paths+=("/home/${SUDO_USER}")
    fi

    for spath in "${search_paths[@]}"; do
        [[ ! -d "$spath" ]] && continue
        while IFS= read -r -d '' cfg; do
            local base
            base=$(basename "$cfg")
            [[ "$base" == "wg0.conf" || "$base" == "wg1.conf" || "$base" == "settings.conf" || "$base" == "resolv.conf" || "$base" == "sysctl.conf" ]] && continue
            if grep -q "\[Interface\]" "$cfg" 2>/dev/null && grep -q "Endpoint" "$cfg" 2>/dev/null; then
                # Sanitize AllowedIPs if it contains a fragmented CIDR list
                sed -i "s|^[[:space:]]*AllowedIPs[[:space:]]*=.*|AllowedIPs = ${target_simple_ips}|g" "$cfg" 2>/dev/null || true
                found_plain+=("$cfg")
            fi
        done < <(find "$spath" -maxdepth 2 -type f -name "*.conf" -print0 2>/dev/null || true)

        while IFS= read -r -d '' ecfg; do
            found_enc+=("$ecfg")
        done < <(find "$spath" -maxdepth 2 -type f -name "*.conf.enc" -print0 2>/dev/null || true)
    done

    local unique_plain=()
    local seen_names="|"
    for c in "${found_plain[@]}"; do
        local bname
        bname=$(basename "$c")
        if [[ "$seen_names" != *"|${bname}|"* ]]; then
            seen_names+="${bname}|"
            unique_plain+=("$c")
        fi
    done

    local unique_enc=()
    local seen_enc="|"
    for ec in "${found_enc[@]}"; do
        local ebname
        ebname=$(basename "$ec")
        if [[ "$seen_enc" != *"|${ebname}|"* ]]; then
            seen_enc+="${ebname}|"
            unique_enc+=("$ec")
        fi
    done

    if [[ ${#unique_plain[@]} -eq 0 && ${#unique_enc[@]} -eq 0 ]]; then
        echo -e "\n${CYAN}[*] Generating initial client configuration...${NC}"
        fetch_and_run "add_client.sh"
        return 0
    fi

    for cfg_file in "${unique_plain[@]}"; do
        local cname
        cname=$(basename "$cfg_file")
        echo -e "\n${PURPLE}=================================================================${NC}"
        echo -e "${GREEN}${BOLD}📋 COPY & PASTE WIREGUARD CLIENT CONFIGURATION (${cname}):${NC}"
        echo -e "${YELLOW}Path: ${cfg_file}${NC}"
        echo -e "${PURPLE}-----------------------------------------------------------------${NC}"
        cat "$cfg_file"
        echo -e "${PURPLE}-----------------------------------------------------------------${NC}\n"

        if command -v qrencode &>/dev/null; then
            echo -e "${CYAN}${BOLD}📱 SCAN QR CODE FOR MOBILE / TABLET CLIENT (${cname}):${NC}\n"
            qrencode -t ansiutf8 < "$cfg_file" || true
            echo ""
        fi
    done

    if [[ ${#unique_plain[@]} -eq 0 && ${#unique_enc[@]} -gt 0 ]]; then
        for enc_file in "${unique_enc[@]}"; do
            local ecname
            ecname=$(basename "$enc_file" .enc)
            local dec_pass=""
            if [[ -f /tmp/.wg_last_client_pass ]]; then
                dec_pass=$(cat /tmp/.wg_last_client_pass 2>/dev/null || true)
            fi
            if [[ -z "$dec_pass" ]]; then
                echo -e "\n${CYAN}🔒 Encrypted client configuration detected: ${BOLD}${ecname}${NC}"
                read -s -rp "Enter decryption password for ${ecname} to display config & QR (or press Enter to skip): " dec_pass
                echo ""
            fi
            if [[ -n "$dec_pass" ]]; then
                local dec_text=""
                if dec_text=$(decrypt_conf_file "$enc_file" "$dec_pass"); then
                    # Ensure encrypted config also has simple AllowedIPs (never a 65-CIDR list)
                    if echo "$dec_text" | grep -q "0.0.0.0/2"; then
                        dec_text=$(echo "$dec_text" | sed "s|^[[:space:]]*AllowedIPs[[:space:]]*=.*|AllowedIPs = ${target_simple_ips}|g")
                        encrypt_conf_file "$dec_text" "$enc_file" "$dec_pass"
                    fi
                    echo -e "\n${PURPLE}=================================================================${NC}"
                    echo -e "${GREEN}${BOLD}📋 COPY & PASTE WIREGUARD CLIENT CONFIGURATION (${ecname}):${NC}"
                    echo -e "${PURPLE}-----------------------------------------------------------------${NC}"
                    echo "$dec_text"
                    echo -e "${PURPLE}-----------------------------------------------------------------${NC}\n"
                    if command -v qrencode &>/dev/null; then
                        echo -e "${CYAN}${BOLD}📱 SCAN QR CODE FOR MOBILE / TABLET CLIENT (${ecname}):${NC}\n"
                        echo "$dec_text" | qrencode -t ansiutf8 || true
                        echo ""
                    fi
                else
                    echo -e "${RED}[!] Incorrect password for ${ecname}.${NC}"
                fi
            fi
        done
    fi
    rm -f /tmp/.wg_last_client_pass 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 6. Companion Scripts Sync, Double Password Confirmation & Travel/Home Mode
# ------------------------------------------------------------------------------
prefetch_companion_scripts() {
    local scripts=("setup_server.sh" "add_client.sh" "user_manager.sh" "backup_manager.sh" "domain_bypass.sh" "remove_server.sh")
    local total=${#scripts[@]}
    local count=0

    echo -e "\n${CYAN}${BOLD}[*] Fetching fresh companion scripts into ${INSTALL_DIR}...${NC}"
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    cat << 'EOF' > "${INSTALL_DIR}/geo_vpn_filter.sh"
#!/bin/bash
exit 0
EOF
    chmod 700 "${INSTALL_DIR}/geo_vpn_filter.sh"

    for s in "${scripts[@]}"; do
        count=$((count + 1))
        local pct=$(( (count * 100) / total ))
        show_progress_bar "$pct" "Syncing ${s} (${count}/${total})..."

        if [[ -f "./${s}" ]]; then
            cp -f "./${s}" "${INSTALL_DIR}/${s}"
        else
            curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/${s}" -o "${INSTALL_DIR}/${s}" 2>/dev/null || true
        fi

        local target_sub="${INSTALL_DIR}/${s}"
        if [[ -f "$target_sub" ]]; then
            strip_clear_from_script "$target_sub"
            chmod 700 "$target_sub"

            if command -v python3 &>/dev/null; then
                python3 - "$target_sub" "$s" << 'PY_CLIENT_PATCH_EOF'
import sys, re

sub_path = sys.argv[1]
script_name = sys.argv[2]
with open(sub_path, 'r', encoding='utf-8', errors='replace') as f:
    code = f.read()

# 1. Enforce password double confirmation AND immediately prompt for Travel Mode vs Home Mode
#    Placing Travel Mode / Home Mode right inside the password confirmation block guarantees
#    it runs right before the client config is generated and sets simple AllowedIPs!
target_pattern = r'(read\s+-(?:s\s+)?rp\s+["\'][^"\']*password[^"\']*["\']\s+([a-zA-Z_][a-zA-Z0-9_]*))'
match = re.search(target_pattern, code, re.IGNORECASE)

if match and 'confirm' not in code.lower():
    original_line = match.group(1)
    var_name = match.group(2)
    
    confirm_block = f'''
# --- Enforced Password Double Confirmation & Travel/Home LAN Mode ---
while true; do
    {original_line}
    echo ""
    if [[ ${{# {var_name} }} -lt 4 ]]; then
        echo -e "\\033[0;31m[!] Password must be at least 4 characters long.\\033[0m"
        continue
    fi
    read -s -rp "Confirm encryption password: " {var_name}_confirm
    echo ""
    if [[ "${{ {var_name} }}" != "${{ {var_name}_confirm }}" ]]; then
        echo -e "\\033[0;31m[!] Passwords do not match. Please try again.\\033[0m"
        continue
    fi
    echo -e "\\033[0;32m[✔] Password confirmed successfully.\\033[0m"
    echo -n "${{ {var_name} }}" > /tmp/.wg_last_client_pass
    chmod 600 /tmp/.wg_last_client_pass 2>/dev/null || true
    break
done

if [[ "{script_name}" == "add_client.sh" || "{script_name}" == "setup_server.sh" ]]; then
    echo -e "\\n\\033[0;36m\\033[1mSelect Local Network (LAN) Traffic Mode for this Client:\\033[0m"
    echo -e "   1) \\033[0;32mTravel Mode (LAN Blocking Enabled)\\033[0m  - Simple AllowedIPs = 0.0.0.0/0 (Blocks public Wi-Fi/hotel LAN)"
    echo -e "   2) \\033[0;32mHome Mode (LAN Blocking Disabled)\\033[0m   - Simple AllowedIPs = 0.0.0.0/1, 128.0.0.0/1 (Allows home LAN)"
    read -rp "Select mode [1-2, default 1 (Travel Mode - LAN Blocking Enabled)]: " TRAVEL_LAN_OPT
    TRAVEL_LAN_OPT=${{TRAVEL_LAN_OPT:-1}}
    if [[ "$TRAVEL_LAN_OPT" == "2" ]]; then
        DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
        ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
        echo "0.0.0.0/1, 128.0.0.0/1" > /tmp/.wg_last_client_allowed_ips
        sed -i 's|^DEFAULT_ALLOWED_IPS=.*|DEFAULT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"|' /root/easy_wireguard/settings.conf 2>/dev/null || true
        echo -e "\\033[0;32m[✔] Home Mode selected (AllowedIPs = 0.0.0.0/1, 128.0.0.0/1).\\033[0m\\n"
    else
        DEFAULT_ALLOWED_IPS="0.0.0.0/0"
        ALLOWED_IPS="0.0.0.0/0"
        echo "0.0.0.0/0" > /tmp/.wg_last_client_allowed_ips
        sed -i 's|^DEFAULT_ALLOWED_IPS=.*|DEFAULT_ALLOWED_IPS="0.0.0.0/0"|' /root/easy_wireguard/settings.conf 2>/dev/null || true
        echo -e "\\033[0;32m[✔] Travel Mode selected (AllowedIPs = 0.0.0.0/0).\\033[0m\\n"
    fi
fi
# --------------------------------------------------------------------
'''
    code = code.replace(original_line, confirm_block, 1)

if 'qrencode' in code and 'COPY & PASTE WIREGUARD CLIENT CONFIGURATION' not in code:
    code = re.sub(
        r'(qrencode\s+-t\s+ansiutf8\s*<\s*["\']?(\$[A-Za-z0-9_{}]+)["\']?)',
        r'echo -e "\n\\033[0;32m📋 COPY & PASTE WIREGUARD CLIENT CONFIGURATION:\\033[0m\n----------------------------------------"; cat "\2"; echo -e "----------------------------------------\n"; \1',
        code
    )

with open(sub_path, 'w', encoding='utf-8') as f:
    f.write(code)
PY_CLIENT_PATCH_EOF
            fi
        fi
    done
}

# ------------------------------------------------------------------------------
# 7. Safe Setup Server Patcher (Port, DNS, Server-Side Split Setup Prompt)
# ------------------------------------------------------------------------------
run_setup_server() {
    rm -f /tmp/.wg_cleanup_done
    cleanupOldWireguard "preinstall"
    prefetch_companion_scripts

    local target_script="${INSTALL_DIR}/setup_server.sh"
    if [[ ! -f "$target_script" ]]; then
        echo -e "\n${GREEN}Fetching latest version of setup_server.sh...${NC}"
        if ! curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/setup_server.sh" -o "$target_script"; then
            echo -e "${RED}Error: Failed to pull setup_server.sh from ${GIT_REPO}.${NC}"
            return 1
        fi
    fi
    strip_clear_from_script "$target_script"
    chmod 700 "$target_script"

    local port_selector_file="${INSTALL_DIR}/.port_selector.sh"
    cat << 'PORT_EOF' > "$port_selector_file"
input_VPN_PORT="${input_VPN_PORT:-51820}"
VPN_PORT="${VPN_PORT:-51820}"
PORT="${PORT:-51820}"
SERVER_PORT="${SERVER_PORT:-51820}"
WG_PORT="${WG_PORT:-51820}"

select_safe_wg_port() {
    local sensitive_ports=(20 21 22 23 25 53 67 68 80 110 143 443 1935 8080 8443 3306 5432 6379 27017)
    is_sens() {
        local p="$1"
        for sp in "${sensitive_ports[@]}"; do [[ "$p" -eq "$sp" ]] && return 0; done
        return 1
    }
    is_used() {
        local p="$1"
        if command -v ss &>/dev/null; then
            ss -uln 2>/dev/null | grep -qE "(:|\])${p}[[:space:]]" && return 0
        elif command -v netstat &>/dev/null; then
            netstat -uln 2>/dev/null | grep -qE "(:|\])${p}[[:space:]]" && return 0
        fi
        return 1
    }

    echo -e "\n\033[0;36m\033[1mSelect WireGuard UDP Port:\033[0m"
    echo -e "   1) \033[0;32m51820\033[0m (Official WireGuard Standard Port - Zero Router ALG Drops) \033[0;35m[RECOMMENDED]\033[0m"
    echo -e "   2) \033[0;32m1194\033[0m  (OpenVPN Standard UDP | High ISP Compatibility)"
    echo -e "   3) \033[0;32m41194\033[0m (High Tunnel UDP | Evades Low-Port Scans)"
    echo -e "   4) \033[0;32m3478\033[0m  (STUN / WebRTC Media UDP)"
    echo -e "   5) \033[0;32m4500\033[0m  (IPsec NAT-T UDP)"
    echo -e "   6) \033[0;32m853\033[0m   (DNS-over-QUIC UDP)"
    echo -e "   7) Random High Port (49152-65535)"
    echo -e "   8) Custom Port (Or type any port directly, e.g. 8008)"

    while true; do
        read -rp "Select Port option [1-8, or type port directly, default 1 (51820)]: " PORT_OPT
        PORT_OPT=${PORT_OPT:-1}

        if [[ "$PORT_OPT" =~ ^[0-9]+$ ]] && [[ "$PORT_OPT" -ge 1024 && "$PORT_OPT" -le 65535 ]]; then
            if is_sens "$PORT_OPT"; then
                echo -e "\033[0;31m[!] Port ${PORT_OPT} is a sensitive service port (80/443/22/1935/etc.). Please choose a safe port.\033[0m"
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
            1) SELECTED_WG_PORT=51820 ; break ;;
            2) SELECTED_WG_PORT=1194 ; break ;;
            3) SELECTED_WG_PORT=41194 ; break ;;
            4) SELECTED_WG_PORT=3478 ; break ;;
            5) SELECTED_WG_PORT=4500 ; break ;;
            6) SELECTED_WG_PORT=853 ; break ;;
            7)
                SELECTED_WG_PORT=$(( (RANDOM % 16383) + 49152 ))
                echo -e "\033[0;32m[✔] Generated Random High Port: ${SELECTED_WG_PORT}/udp\033[0m"
                break
                ;;
            8)
                while true; do
                    read -rp "Enter Custom WireGuard Port [1024-65535]: " -e -i "51820" CUSTOM_P
                    if ! [[ "$CUSTOM_P" =~ ^[0-9]+$ ]] || [[ "$CUSTOM_P" -lt 1024 || "$CUSTOM_P" -gt 65535 ]]; then
                        echo -e "\033[0;31m[!] Invalid port. Enter a port between 1024 and 65535.\033[0m"
                        continue
                    fi
                    if is_sens "$CUSTOM_P"; then
                        echo -e "\033[0;31m[!] Port ${CUSTOM_P} conflicts with sensitive services (80/443/22/1935/etc.). Choose another.\033[0m"
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
    input_VPN_PORT="$SELECTED_WG_PORT"
    VPN_PORT="$SELECTED_WG_PORT"
    PORT="$SELECTED_WG_PORT"
    SERVER_PORT="$SELECTED_WG_PORT"
    WG_PORT="$SELECTED_WG_PORT"

    select_safe_dns_resolver
    select_setup_split_domains
}

select_safe_dns_resolver() {
    echo -e "\033[0;36m\033[1mSelect DNS Resolver for Clients (Standard Port 53 & Payment-Safe Anycast):\033[0m"
    echo -e "   1) \033[0;32mCloudflare + Google Anycast\033[0m (1.1.1.1, 8.8.8.8 | Fastest & 100% Payment/Shopping Compatible) \033[0;35m[RECOMMENDED]\033[0m"
    echo -e "   2) \033[0;32mAdGuard + Quad9 Default\033[0m     (94.140.14.49, 9.9.9.9, 94.140.14.59 | Ad-Block + Server Payment Bypass)"
    echo -e "   3) \033[0;32mCloudflare Pure Anycast\033[0m     (1.1.1.1, 1.0.0.1 | Port 53 - Ultra Low Latency)"
    echo -e "   4) \033[0;32mQuad9 Swiss Shield\033[0m          (9.9.9.9, 149.112.112.112 | Port 53 - Threat Intelligence)"
    echo -e "   5) \033[0;32mGoogle Public DNS\033[0m           (8.8.8.8, 8.8.4.4 | Port 53 - High Availability Anycast)"
    echo -e "   6) \033[0;32mMullvad Privacy\033[0m             (194.242.2.2, 194.242.2.3 | Port 53 - Strict Zero-Logs)"
    echo -e "   7) \033[0;32mControl D Uncensored\033[0m        (76.76.2.0, 76.76.10.0 | Port 53 - Anti-Throttle)"
    echo -e "   8) \033[0;32mOpenDNS / Cisco\033[0m             (208.67.222.222, 208.67.220.220 | Port 53 - Reliability)"
    echo -e "   9) Custom DNS Resolvers"

    read -rp "Select DNS Resolver [1-9, default 1]: " DNS_OPT
    DNS_OPT=${DNS_OPT:-1}

    case "$DNS_OPT" in
        2) CLIENT_DNS="94.140.14.49, 9.9.9.9, 94.140.14.59" ;;
        3) CLIENT_DNS="1.1.1.1, 1.0.0.1" ;;
        4) CLIENT_DNS="9.9.9.9, 149.112.112.112" ;;
        5) CLIENT_DNS="8.8.8.8, 8.8.4.4" ;;
        6) CLIENT_DNS="194.242.2.2, 194.242.2.3" ;;
        7) CLIENT_DNS="76.76.2.0, 76.76.10.0" ;;
        8) CLIENT_DNS="208.67.222.222, 208.67.220.220" ;;
        9)
            read -rp "Enter Primary DNS: " -e -i "1.1.1.1" C_DNS1
            read -rp "Enter Secondary DNS: " -e -i "8.8.8.8" C_DNS2
            CLIENT_DNS="${C_DNS1}, ${C_DNS2}"
            ;;
        1|*) CLIENT_DNS="1.1.1.1, 8.8.8.8" ;;
    esac

    echo -e "\033[0;32m[✔] Selected DNS Resolvers: ${CLIENT_DNS}\033[0m\n"
    CLIENT_DNS_1=$(echo "$CLIENT_DNS" | cut -d',' -f1 | tr -d ' ')
    CLIENT_DNS_2=$(echo "$CLIENT_DNS" | cut -d',' -f2 | tr -d ' ')
    DEFAULT_DNS="$CLIENT_DNS"

    if [[ -f "/root/easy_wireguard/settings.conf" ]]; then
        if grep -q "^DEFAULT_DNS=" "/root/easy_wireguard/settings.conf" 2>/dev/null; then
            sed -i "s|^DEFAULT_DNS=.*|DEFAULT_DNS=\"${CLIENT_DNS}\"|" "/root/easy_wireguard/settings.conf"
        else
            echo "DEFAULT_DNS=\"${CLIENT_DNS}\"" >> "/root/easy_wireguard/settings.conf"
        fi
    fi
}

select_setup_split_domains() {
    echo -e "\033[0;36m\033[1mServer-Side Split Tunneling (Keeps Client AllowedIPs Simple!):\033[0m"
    echo -e "   • Payment & Shopping sites (PayPal, Stripe, 3D-Secure, Amazon, Banks) are auto-protected."
    echo -e "   • Enter any extra domains to split-tunnel on the server (e.g. linkedin.com, netflix.com)"
    read -rp "Domains to split-tunnel [comma/space separated, or press Enter for none]: " SETUP_SPLIT_DOMS
    if [[ -n "${SETUP_SPLIT_DOMS:-}" ]]; then
        mkdir -p /root/easy_wireguard
        touch /root/easy_wireguard/bypass_domains.txt
        for raw_d in ${SETUP_SPLIT_DOMS//,/ }; do
            local clean_d
            clean_d=$(echo "$raw_d" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r\n')
            if [[ -n "$clean_d" && "$clean_d" == *.* ]]; then
                grep -q -i "^${clean_d}$" /root/easy_wireguard/bypass_domains.txt 2>/dev/null || echo "$clean_d" >> /root/easy_wireguard/bypass_domains.txt
                echo -e "\033[0;32m[✔] Queued '${clean_d}' for Server-Side Split Tunneling (Client AllowedIPs remains simple).\033[0m"
            fi
        done
        echo ""
    fi
}
PORT_EOF

    if command -v python3 &>/dev/null; then
        python3 - "$target_script" "$port_selector_file" << 'PY_EOF'
import sys, re

script_path = sys.argv[1]
selector_path = sys.argv[2]

with open(script_path, 'r', encoding='utf-8', errors='replace') as f:
    content = f.read()

with open(selector_path, 'r', encoding='utf-8', errors='replace') as f:
    selector_code = f.read()

content = re.sub(
    r'(?m)^[ \t]*(clear|tput[ \t]+reset)[ \t]*$',
    lambda _: ': # clear disabled',
    content
)

# Replace hardcoded --ttl-set 64 in setup_server.sh with Zero-Hop --ttl-inc 1
content = re.sub(
    r'-A\s+POSTROUTING\s+-o\s+\S+\s+-j\s+TTL\s+--ttl-set\s+64',
    '-I PREROUTING 1 -i wg0 -j TTL --ttl-inc 1',
    content
)
content = re.sub(
    r'-D\s+POSTROUTING\s+-o\s+\S+\s+-j\s+TTL\s+--ttl-set\s+64',
    '-D PREROUTING -i wg0 -j TTL --ttl-inc 1',
    content
)

# Neutralize secondary cleanup block inside setup_server.sh so it only runs once
content = re.sub(
    r'(?m)^([ \t]*(?:function\s+)?cleanupOldWireguard[ \t]*\(\)[ \t]*\{)',
    r'\1 return 0;',
    content
)
content = re.sub(
    r'(?m)^([ \t]*cleanupOldWireguard[ \t]*$)',
    r': # cleanupOldWireguard skipped',
    content
)

lines = content.splitlines()
cleaned_setup_lines = []
skip_inline_cleanup = False
for line in lines:
    if 'Cleaning up any existing WireGuard instances' in line:
        skip_inline_cleanup = True
        cleaned_setup_lines.append(': # inline cleanup skipped (already completed by manager)')
        continue
    if skip_inline_cleanup:
        if 'Installing WireGuard and required dependencies' in line:
            skip_inline_cleanup = False
            cleaned_setup_lines.append(line)
        else:
            cleaned_setup_lines.append('# ' + line)
        continue
    cleaned_setup_lines.append(line)
content = '\n'.join(cleaned_setup_lines) + '\n'

content = re.sub(
    r'PostUp\s*=\s*(/root/easy_wireguard/geo_vpn_filter\.sh\s+--apply)(?!\s*\|\|)',
    lambda m: f'PostUp = test -x /root/easy_wireguard/geo_vpn_filter.sh && {m.group(1)} || true',
    content
)

if 'select_safe_wg_port()' not in content:
    lines = content.splitlines()
    out_lines = []
    injected_header = False
    replaced_port_prompt = False
    in_port_case = False

    read_port_idx = -1
    for idx, line in enumerate(lines):
        if re.search(r'^\s*read\b.*\b(input_VPN_PORT|VPN_PORT|PORT|SERVER_PORT)\b', line):
            read_port_idx = idx
            break

    for idx, line in enumerate(lines):
        if not injected_header:
            out_lines.append(line)
            if re.match(r'^\s*set\s+-euo\s+pipefail', line) or (idx == 0 and line.startswith('#!') and 'set -euo pipefail' not in content):
                out_lines.append('')
                out_lines.extend(selector_code.splitlines())
                out_lines.append('')
                injected_header = True
            continue

        if read_port_idx != -1 and (read_port_idx - 18) <= idx < read_port_idx:
            if re.search(r'(^\s*echo\b.*(\[[1-9]\]|port|Port|Select option)|^\s*printf\b.*port)', line):
                out_lines.append('# ' + line + ' # replaced by select_safe_wg_port')
                continue

        if idx == read_port_idx:
            out_lines.append('select_safe_wg_port')
            replaced_port_prompt = True
            continue

        if replaced_port_prompt and not in_port_case and read_port_idx < idx <= read_port_idx + 6:
            if re.search(r'^\s*case\s+["\']?\$\{?(input_VPN_PORT|VPN_PORT|PORT)\}?["\']?\s+in', line):
                in_port_case = True
                out_lines.append('# ' + line)
                continue

        if in_port_case:
            out_lines.append('# ' + line)
            if re.match(r'^\s*esac\b', line):
                in_port_case = False
                out_lines.append('VPN_PORT="$SELECTED_WG_PORT"')
                out_lines.append('input_VPN_PORT="$SELECTED_WG_PORT"')
            continue

        out_lines.append(line)

    final_text = '\n'.join(out_lines) + '\n'
    if not replaced_port_prompt:
        dep_match = re.search(r'(Installing WireGuard and required dependencies[\s\S]*?(?:apt-get|apt|yum|dnf|pacman|apk)\s+install[^\n]+\n(?:\s*fi\n)?)', final_text)
        if dep_match:
            pos = dep_match.end()
            final_text = final_text[:pos] + '\nselect_safe_wg_port\n' + final_text[pos:]

    content = final_text

with open(script_path, 'w', encoding='utf-8') as f:
    f.write(content)
PY_EOF
    fi

    rm -f "$port_selector_file"
    WG_SKIP_CLEANUP=1 "$target_script"

    # Activate Server-Side Split Tunneling & Payment Optimization Engine automatically
    apply_server_side_split_and_payment_engine
    display_post_install_configs
}

# ------------------------------------------------------------------------------
# 8. Server-Side Domain Split Tunneling Menu
# ------------------------------------------------------------------------------
domain_split_tunnel_menu() {
    while true; do
        [[ ! -f "$BYPASS_DOMAINS_FILE" ]] && touch "$BYPASS_DOMAINS_FILE"

        local dom_count
        dom_count=$(awk '!/^(#|[[:space:]]*$)/ {c++} END {print c+0}' "$BYPASS_DOMAINS_FILE" 2>/dev/null || echo 0)

        echo -e "\n${PURPLE}┌──────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│       ${GREEN}${BOLD}🌐 Server-Side Split Tunneling & Payment Manager${NC}       ${PURPLE}│${NC}"
        echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│${NC} ${BOLD}Client AllowedIPs:${NC} ${GREEN}SIMPLE${NC} (0.0.0.0/0 or 0.0.0.0/1, 128.0.0.0/1)${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} ${BOLD}Payment Shield:${NC}    ${GREEN}ACTIVE${NC} (PayPal, Stripe, 3DS, Amazon, Banks)${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} ${BOLD}Split Domains:${NC}     ${YELLOW}${dom_count} domain(s) handled on server${NC}              ${PURPLE}│${NC}"
        echo -e "${PURPLE}├──────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${PURPLE}│${NC} [1] Add Domain(s) (e.g. linkedin.com, netflix.com)           ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [2] Remove a Domain                                          ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [3] Add Preset Category (LinkedIn/Social, Shopping, AI)      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [4] View Active Split Domains & Live Server IPSet Status     ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [5] Force Refresh Server-Side Split & Payment Rules Now      ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [6] Clear Custom Split Domains (Keep Payment Shield Active)  ${PURPLE}│${NC}"
        echo -e "${PURPLE}│${NC} [b] Back to Main Menu                                        ${PURPLE}│${NC}"
        echo -e "${PURPLE}└──────────────────────────────────────────────────────────────┘${NC}"
        echo -en "${GREEN}Select option: ${NC}"
        read -r SPLIT_OPT

        case "$SPLIT_OPT" in
            1)
                echo -en "${GREEN}Enter domain(s) to split-tunnel on server (comma or space separated): ${NC}"
                read -r INPUT_DOMS
                local added=0
                for raw_d in ${INPUT_DOMS//,/ }; do
                    local clean_d
                    clean_d=$(echo "$raw_d" | sed -e 's|^https*://||' -e 's|/.*$||' | tr '[:upper:]' '[:lower:]' | tr -d ' \t\r\n')
                    if [[ -n "$clean_d" && "$clean_d" == *.* ]]; then
                        if ! grep -q -i "^${clean_d}$" "$BYPASS_DOMAINS_FILE" 2>/dev/null; then
                            echo "$clean_d" >> "$BYPASS_DOMAINS_FILE"
                            echo -e "${GREEN}[✔] Added: ${clean_d}${NC}"
                            added=$((added + 1))
                        else
                            echo -e "${YELLOW}[!] ${clean_d} is already in the list.${NC}"
                        fi
                    fi
                done
                if [[ $added -gt 0 ]]; then
                    apply_server_side_split_and_payment_engine
                fi
                ;;
            2)
                if [[ "$dom_count" -eq 0 ]]; then
                    echo -e "${YELLOW}No custom domains currently configured.${NC}"
                else
                    echo -e "\n${CYAN}Configured Custom Split Domains:${NC}"
                    awk '!/^(#|[[:space:]]*$)/ {printf "  %2d) %s\n", ++i, $0}' "$BYPASS_DOMAINS_FILE"
                    echo -en "${GREEN}Enter number to remove [1-${dom_count}]: ${NC}"
                    read -r DEL_IDX
                    if [[ "$DEL_IDX" =~ ^[0-9]+$ ]] && [[ "$DEL_IDX" -ge 1 && "$DEL_IDX" -le "$dom_count" ]]; then
                        local target_d
                        target_d=$(awk '!/^(#|[[:space:]]*$)/ {if (++i == idx) print $0}' idx="$DEL_IDX" "$BYPASS_DOMAINS_FILE")
                        grep -v -F -x "$target_d" "$BYPASS_DOMAINS_FILE" > "${BYPASS_DOMAINS_FILE}.tmp" || true
                        mv "${BYPASS_DOMAINS_FILE}.tmp" "$BYPASS_DOMAINS_FILE"
                        echo -e "${GREEN}[✔] Removed '${target_d}'.${NC}"
                        apply_server_side_split_and_payment_engine
                    else
                        echo -e "${RED}Invalid selection.${NC}"
                    fi
                fi
                ;;
            3)
                echo -e "\n${CYAN}Select Server-Side Preset Category:${NC}"
                echo "  1) LinkedIn & Professional Networks (linkedin.com, licdn.com, lnkd.in + AS12447 CIDRs)"
                echo "  2) Online Shopping, Payments & 3D-Secure (PayPal, Stripe, Amazon, Shopify, Klarna, Banks)"
                echo "  3) Streaming Services (Netflix, Hulu, Disney+, Prime Video, Max, Spotify)"
                echo "  4) Discord & Chat (discord.com, discord.gg, discordapp.com, discordstatus.com)"
                echo "  5) AI Services (ChatGPT, OpenAI, Claude, Gemini, Perplexity)"
                echo -en "${GREEN}Select preset [1-5]: ${NC}"
                read -r PRESET_CHOICE
                local preset_list=()
                case "$PRESET_CHOICE" in
                    1) preset_list=("linkedin.com" "licdn.com" "lnkd.in") ;;
                    2) preset_list=("paypal.com" "paypalobjects.com" "cardinalcommerce.com" "braintreegateway.com" "stripe.com" "online-metrix.net" "amazon.com" "shopify.com" "klarna.com" "affirm.com" "ebay.com" "chase.com" "bankofamerica.com" "wellsfargo.com") ;;
                    3) preset_list=("netflix.com" "hulu.com" "disneyplus.com" "primevideo.com" "max.com" "spotify.com") ;;
                    4) preset_list=("discord.com" "discord.gg" "discordapp.com" "discordstatus.com") ;;
                    5) preset_list=("openai.com" "chatgpt.com" "claude.ai" "anthropic.com" "gemini.google.com" "perplexity.ai") ;;
                    *) echo -e "${RED}Invalid preset.${NC}" ;;
                esac
                if [[ ${#preset_list[@]} -gt 0 ]]; then
                    for pd in "${preset_list[@]}"; do
                        grep -q -i "^${pd}$" "$BYPASS_DOMAINS_FILE" 2>/dev/null || echo "$pd" >> "$BYPASS_DOMAINS_FILE"
                    done
                    apply_server_side_split_and_payment_engine
                fi
                ;;
            4)
                echo -e "\n${CYAN}--- Server-Side Split Tunnel & Payment Engine Status ---${NC}"
                if [[ "$dom_count" -eq 0 ]]; then
                    echo -e "  ${YELLOW}Custom Domains:${NC} None added yet (Built-in Payment Shield is active)"
                else
                    echo -e "  ${BOLD}Configured Custom Domains:${NC}"
                    awk '!/^(#|[[:space:]]*$)/ {printf "    %2d) %s\n", ++i, $0}' "$BYPASS_DOMAINS_FILE"
                fi
                if command -v ipset &>/dev/null; then
                    local pay_cnt split_cnt
                    pay_cnt=$(ipset list wg_payment_v4 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
                    split_cnt=$(ipset list wg_split_v4 2>/dev/null | awk '/Number of entries:/ {print $4}' || echo 0)
                    echo -e "  ${GREEN}Payment IPSet (wg_payment_v4):${NC} ${pay_cnt:-0} active subnet(s)"
                    echo -e "  ${GREEN}Split IPSet   (wg_split_v4):${NC}   ${split_cnt:-0} active subnet(s)"
                fi
                echo -en "\n${GREEN}Press Enter to continue...${NC}"
                read -r
                ;;
            5)
                apply_server_side_split_and_payment_engine
                ;;
            6)
                > "$BYPASS_DOMAINS_FILE"
                apply_server_side_split_and_payment_engine
                echo -e "${GREEN}[✔] Cleared custom split domains. Built-in Payment & Shopping Shield remains active.${NC}"
                ;;
            b|B)
                break
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 9. Modular Sub-script Fetcher & Settings Management
# ------------------------------------------------------------------------------
fetch_and_run() {
    local script_name="$1"
    local script_path="./${script_name}"

    if [[ -f "$script_path" ]]; then
        echo -e "\n${GREEN}Running local version of ${script_name}...${NC}"
        strip_clear_from_script "$script_path"
        chmod +x "$script_path"
        cp -f "$script_path" "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
        chmod 700 "${INSTALL_DIR}/${script_name}" 2>/dev/null || true
        "$script_path"
    else
        script_path="${INSTALL_DIR}/${script_name}"
        echo -e "\n${GREEN}Fetching latest version of ${script_name}...${NC}"

        if curl -sSfL --connect-timeout 5 --max-time 15 "${GIT_REPO}/${script_name}" -o "$script_path"; then
            strip_clear_from_script "$script_path"
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
        echo ""
        print_banner
        local display_ips="${DEFAULT_ALLOWED_IPS:-0.0.0.0/1, 128.0.0.0/1}"
        if [[ ${#display_ips} -gt 25 ]]; then
            display_ips="${display_ips:0:22}..."
        fi
        echo -e "${PURPLE}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│                      Settings                      │${NC}"
        echo -e "${PURPLE}├────────────────────────────────────────────────────┤${NC}"
        printf "${PURPLE}│ ${GREEN}[1] Default MTU: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_MTU:-1420}"
        printf "${PURPLE}│ ${GREEN}[2] Default DNS: ${NC}%-33s ${PURPLE}│${NC}\n" "${DEFAULT_DNS:-"1.1.1.1, 8.8.8.8"}"
        printf "${PURPLE}│ ${GREEN}[3] Default Allowed IPs: ${NC}%-25s ${PURPLE}│${NC}\n" "$display_ips"
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
                apply_server_side_split_and_payment_engine
                ;;
            3)
                echo -en "${GREEN}Enter new Default Allowed IPs: ${NC}"
                read -r NEW_IPS
                update_setting "DEFAULT_ALLOWED_IPS" "\"$NEW_IPS\""
                DEFAULT_ALLOWED_IPS="$NEW_IPS"
                ;;
            b|B) break ;;
        esac
    done
}

print_banner() {
    echo -e "\n${PURPLE}======================================================${NC}"
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
    echo -e "${PURPLE}│ ${NC}[5] Domain-Based Split Tunneling (Server-Side)    ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[6] Real-Time Logging (Errors)                    ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[7] Geo-IP & Anti-VPN Shield (US/CA Only)         ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[s] Settings (MTU, DNS, AllowedIPs)               ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${RED}[r] Remove WireGuard server from this system      ${PURPLE}│${NC}"
    echo -e "${PURPLE}│ ${NC}[q] Exit                                          ${PURPLE}│${NC}"
    echo -e "${PURPLE}└────────────────────────────────────────────────────┘${NC}"
}

main() {
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        apply_server_side_split_and_payment_engine >/dev/null 2>&1 || true
    fi

    while true; do
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
                display_post_install_configs
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            3) fetch_and_run "user_manager.sh" ;;
            4) fetch_and_run "backup_manager.sh" ;;
            5) domain_split_tunnel_menu ;;
            6) 
                echo -e "\n${GREEN}Starting Real-Time Logging for WireGuard errors (last 12 hours)...${NC}"
                echo -e "${PURPLE}Press Ctrl+C to stop logging and return to menu.${NC}\n"
                journalctl -u wg-quick@wg0.service --since "12 hours ago" -p err -f || true
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            7)
                rm -f "${INSTALL_DIR}/geo_vpn_filter.sh"
                fetch_and_run "geo_vpn_filter.sh"
                apply_server_side_split_and_payment_engine >/dev/null 2>&1 || true
                ;;
            s|S) settings_menu ;;
            r|R)
                deep_remove_wireguard
                echo -en "\n${GREEN}Press Enter to return to Main Menu...${NC}"
                read -r
                ;;
            q|Q)
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