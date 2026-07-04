import re

with open("setup_server.sh", "r") as f:
    content = f.read()

# Make sure we stop all services first
content = content.replace(
    "echo -e \"${GREEN}Cleaning up any existing WireGuard instances...${NC}\"\nif systemctl is-active --quiet wg-quick@wg0.service; then\n    systemctl stop wg-quick@wg0.service\n    systemctl disable wg-quick@wg0.service\nfi",
    "echo -e \"${GREEN}Cleaning up any existing WireGuard instances...${NC}\"\nfor svc in $(systemctl list-units --type=service --state=active | grep -o \"wg-quick@.*\.service\"); do\n    systemctl stop \"$svc\"\n    systemctl disable \"$svc\"\ndone\nif systemctl is-active --quiet wg-quick@wg0.service; then\n    systemctl stop wg-quick@wg0.service\n    systemctl disable wg-quick@wg0.service\nfi"
)

# Remove all configurations
content = content.replace(
    "rm -rf /etc/wireguard",
    "rm -rf /etc/wireguard\nrm -rf /root/easy_wireguard/clients 2>/dev/null || true"
)

with open("setup_server.sh", "w") as f:
    f.write(content)
