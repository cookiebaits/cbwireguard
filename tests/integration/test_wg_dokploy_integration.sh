#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Starting WireGuard + Dokploy Integration Test...${NC}"

# 1. Environment Setup Validation
echo -n "Checking if port 443/udp is active (e.g., bound by Traefik or WireGuard)... "
if ss -lnpu | grep -q ":443 "; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Port 443/udp is not bound by any service.${NC}"
    exit 1
fi

echo -n "Checking firewall rules for UDP 443... "
if iptables -L -n | grep -q "dpt:443" || ufw status | grep -q "443/udp"; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: No clear firewall rule allowing UDP 443 found.${NC}"
    exit 1
fi

# 2. End-to-End Connectivity Test
echo -e "${GREEN}Setting up test client...${NC}"
# We assume the WG server is already running and configured by setup_server.sh on wg0
if ! ip link show wg0 >/dev/null 2>&1; then
    echo -e "${RED}FAIL: wg0 interface does not exist. Please run setup_server.sh first.${NC}"
    exit 1
fi

SERVER_PUBKEY=$(wg show wg0 public-key)
# Connect locally to port 443 where Traefik is presumably listening
ENDPOINT="127.0.0.1:443"

CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
CLIENT_IP="10.18.0.254"

# Add client to server
wg set wg0 peer "$CLIENT_PUBKEY" allowed-ips "$CLIENT_IP/32"

# Setup client interface (wg-test)
ip link add dev wg-test type wireguard
wg set wg-test private-key <(echo "$CLIENT_PRIVKEY") peer "$SERVER_PUBKEY" allowed-ips 0.0.0.0/0 endpoint "$ENDPOINT"
ip address add "$CLIENT_IP/24" dev wg-test
ip link set up dev wg-test

echo -n "Testing ping to inner tunnel gateway (10.18.0.1)... "
if ping -c 3 -W 2 -I wg-test 10.18.0.1 > /dev/null 2>&1; then
    echo -e "${GREEN}PASS${NC}"
else
    echo -e "${RED}FAIL: Ping to 10.18.0.1 failed.${NC}"
    # check handshake transfer
    RX=$(wg show wg-test transfer | awk '{print $2}')
    TX=$(wg show wg-test transfer | awk '{print $3}')
    echo -e "${RED}Handshake Data - TX: ${TX} B, RX: ${RX} B${NC}"
    if [[ "$RX" == "0" ]]; then
        echo -e "${RED}Error: 0 B received. The WireGuard handshake failed to establish. Check Dokploy/Traefik routing and socat bridge.${NC}"
    fi
    # Cleanup
    ip link del dev wg-test
    wg set wg0 peer "$CLIENT_PUBKEY" remove
    exit 1
fi

# Handshake assert
RX=$(wg show wg-test transfer | awk '{print $2}')
TX=$(wg show wg-test transfer | awk '{print $3}')
echo -n "Validating Handshake (TX > 0, RX > 0)... "
if [[ "$TX" -gt 0 && "$RX" -gt 0 ]]; then
    echo -e "${GREEN}PASS (TX: $TX, RX: $RX)${NC}"
else
    echo -e "${RED}FAIL (TX: $TX, RX: $RX)${NC}"
    ip link del dev wg-test
    wg set wg0 peer "$CLIENT_PUBKEY" remove
    exit 1
fi

# Cleanup
echo -e "${GREEN}Cleaning up test client...${NC}"
ip link del dev wg-test
wg set wg0 peer "$CLIENT_PUBKEY" remove

echo -e "${GREEN}All tests passed successfully!${NC}"
exit 0
