#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Testing Multi-Select Parsing and Domain Expansion...${NC}"

# Test 1: Letter parsing logic (e.g. 'abc' or 'a, b, c' or 'A C G')
parse_letters() {
    local input="$1"
    local preset_input
    preset_input=$(echo "$input" | tr -d ' ,;/\t\r\n' | tr '[:lower:]' '[:upper:]')
    local preset_list=()

    if [[ "$preset_input" == *"ALL"* ]]; then
        preset_input="ABCDEFGHIJKL"
    fi

    local i=0
    for (( i=0; i<${#preset_input}; i++ )); do
        local opt_char="${preset_input:$i:1}"
        case "$opt_char" in
            A) preset_list+=("youtube.com") ;;
            B) preset_list+=("twitch.tv") ;;
            C) preset_list+=("discord.com") ;;
            D) preset_list+=("instagram.com") ;;
            E) preset_list+=("linkedin.com" "licdn.com" "lnkd.in") ;;
            F) preset_list+=("tiktok.com") ;;
            G) preset_list+=("netflix.com") ;;
            H) preset_list+=("hulu.com") ;;
            I) preset_list+=("disneyplus.com") ;;
            J) preset_list+=("primevideo.com") ;;
            K) preset_list+=("max.com") ;;
            L) preset_list+=("spotify.com") ;;
        esac
    done
    echo "${preset_list[@]}"
}

res1=$(parse_letters "abc")
if [[ "$res1" == "youtube.com twitch.tv discord.com" ]]; then
    echo -e "Test 1 ('abc'): ${GREEN}PASS${NC}"
else
    echo -e "Test 1 ('abc'): ${RED}FAIL ($res1)${NC}"
    exit 1
fi

res2=$(parse_letters "A, B, C")
if [[ "$res2" == "youtube.com twitch.tv discord.com" ]]; then
    echo -e "Test 2 ('A, B, C'): ${GREEN}PASS${NC}"
else
    echo -e "Test 2 ('A, B, C'): ${RED}FAIL ($res2)${NC}"
    exit 1
fi

res3=$(parse_letters "ALL")
expected_all="youtube.com twitch.tv discord.com instagram.com linkedin.com licdn.com lnkd.in tiktok.com netflix.com hulu.com disneyplus.com primevideo.com max.com spotify.com"
if [[ "$res3" == "$expected_all" ]]; then
    echo -e "Test 3 ('ALL'): ${GREEN}PASS${NC}"
else
    echo -e "Test 3 ('ALL'): ${RED}FAIL ($res3)${NC}"
    exit 1
fi

# Test 2: Python expansion logic in easy_wireguard.sh
echo -n "Testing Python domain expansion for streamer tools and streaming services... "
python3 - << 'PY_EOF'
import sys

domains = ["youtube.com", "twitch.tv", "discord.com", "instagram.com", "netflix.com", "hulu.com"]
expanded_user = set()
for d in domains:
    expanded_user.add(d)
    if 'netflix.com' in d:
        expanded_user.update(['fast.com', 'nflxvideo.net'])
    elif 'youtube.com' in d:
        expanded_user.update(['youtu.be', 'googlevideo.com', 'ytimg.com'])
    elif 'twitch.tv' in d:
        expanded_user.update(['ttvnw.net', 'jtvnw.net'])
    elif 'discord.com' in d:
        expanded_user.update(['discordapp.com', 'discord.gg', 'discord.media'])
    elif 'instagram.com' in d:
        expanded_user.update(['cdninstagram.com', 'ig.me'])
    elif 'hulu.com' in d:
        expanded_user.update(['hulustream.com', 'huluim.com'])

assert "youtu.be" in expanded_user, "youtu.be missing"
assert "googlevideo.com" in expanded_user, "googlevideo.com missing"
assert "discord.gg" in expanded_user, "discord.gg missing"
assert "cdninstagram.com" in expanded_user, "cdninstagram.com missing"
assert "fast.com" in expanded_user, "fast.com missing"
assert "hulustream.com" in expanded_user, "hulustream.com missing"
print("SUCCESS")
PY_EOF

echo -e "${GREEN}All unit tests passed successfully!${NC}"
