import re

with open("remove_server.sh", "r") as f:
    content = f.read()

# Make sure we stop all services first
content = content.replace(
    "    if systemctl is-active --quiet wg-quick@wg0.service; then\n        echo -e \"${GREEN}Stopping WireGuard service...${NC}\"\n        systemctl stop wg-quick@wg0.service\n        systemctl disable wg-quick@wg0.service\n    fi",
    "    echo -e \"${GREEN}Stopping WireGuard services...${NC}\"\n    for svc in $(systemctl list-units --type=service --state=active | grep -o \"wg-quick@.*\\.service\"); do\n        systemctl stop \"$svc\"\n        systemctl disable \"$svc\"\n    done\n    if systemctl is-active --quiet wg-quick@wg0.service; then\n        systemctl stop wg-quick@wg0.service\n        systemctl disable wg-quick@wg0.service\n    fi"
)

# Completely wipe packages
content = content.replace(
    "    apt-get purge -y wireguard wireguard-tools\n    apt-get autoremove -y",
    "    apt-get purge -y wireguard wireguard-tools wireguard-dkms wireguard-go qrencode 2>/dev/null || true\n    apt-get autoremove -y 2>/dev/null || true"
)

with open("remove_server.sh", "w") as f:
    f.write(content)
