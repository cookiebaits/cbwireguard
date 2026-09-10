#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

if [[ "$EUID" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

echo -e "${GREEN}Starting Geo-IP & Anti-VPN Filter Integration Tests...${NC}"

SCRIPT="./geo_vpn_filter.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo -e "${RED}Test failed: geo_vpn_filter.sh not found.${NC}"
    exit 1
fi

# 1. Test Status Command before applying
echo -n "Testing status command... "
if bash "$SCRIPT" --status >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Status command failed.${NC}"
    exit 1
fi

# 2. Test Applying Firewall Rules
echo -n "Testing applying Geo-IP & Anti-VPN rules... "
if bash "$SCRIPT" --apply >/dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Failed to apply firewall rules.${NC}"
    exit 1
fi

# 3. Validate kernel ipsets or iptables chains exist
echo -n "Validating kernel firewall structures... "
if ipset list wg_allowed_geo >/dev/null 2>&1 || (iptables -L WG_BLOCKED_VPNS -n >/dev/null 2>&1 && iptables -L WG_ALLOWED_GEO -n >/dev/null 2>&1); then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Neither ipsets nor iptables chains were loaded.${NC}"
    exit 1
fi

# 4. Validate iptables rules in INPUT chain
echo -n "Validating iptables rules in INPUT chain... "
if iptables -L INPUT -n | grep -E -q "wg_blocked_vpns|WG_BLOCKED_VPNS" && iptables -L INPUT -n | grep -E -q "wg_allowed_geo|WG_ALLOWED_GEO"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: iptables rules missing in INPUT chain.${NC}"
    exit 1
fi

# 5. Test Whitelisting Custom IP
TEST_WHITE_IP="192.0.2.1"
echo -n "Testing custom IP whitelisting ($TEST_WHITE_IP)... "
bash "$SCRIPT" --allow-ip "$TEST_WHITE_IP" >/dev/null 2>&1
if ipset test wg_allowed_geo "$TEST_WHITE_IP" >/dev/null 2>&1 || iptables -L WG_ALLOWED_GEO -n | grep -q "$TEST_WHITE_IP"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Custom IP $TEST_WHITE_IP was not added to allowed set/chain.${NC}"
    exit 1
fi

# 6. Test Blacklisting Custom IP
TEST_BLACK_IP="192.0.2.2"
echo -n "Testing custom IP blacklisting ($TEST_BLACK_IP)... "
bash "$SCRIPT" --block-ip "$TEST_BLACK_IP" >/dev/null 2>&1
if ipset test wg_blocked_vpns "$TEST_BLACK_IP" >/dev/null 2>&1 || iptables -L WG_BLOCKED_VPNS -n | grep -q "$TEST_BLACK_IP"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Custom IP $TEST_BLACK_IP was not added to blocked set/chain.${NC}"
    exit 1
fi

# 7. Test Removing Rules
echo -n "Testing rule removal... "
bash "$SCRIPT" --remove >/dev/null 2>&1
if ! iptables -L INPUT -n | grep -E -q "wg_blocked_vpns|WG_BLOCKED_VPNS"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: iptables rules were not removed.${NC}"
    exit 1
fi

echo -e "${GREEN}All Geo-IP & Anti-VPN Filter tests passed successfully!${NC}"
exit 0
