#!/bin/bash

# Cookie's Easy WireGuard Manager - Remove Server

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

function print_header() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}      $1      ${NC}"
    echo -e "${CYAN}================================================${NC}"
}

function isRoot() {
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
}

function checkOS() {
    source /etc/os-release
    OS="${ID}"
    if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
        OS=debian
    elif [[ ${OS} == "ubuntu" ]]; then
        OS=ubuntu
    elif [[ ${OS} == "fedora" ]]; then
        OS=fedora
    elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
        OS=centos
    elif [[ -e /etc/oracle-release ]]; then
        OS=oracle
    elif [[ -e /etc/arch-release ]]; then
        OS=arch
    elif [[ -e /etc/alpine-release ]]; then
        OS=alpine
    else
        echo "Unsupported OS."
        exit 1
    fi
}

function uninstall_wireguard() {
    print_header "Uninstall WireGuard"
    echo -e "\n${RED}WARNING: This will completely remove WireGuard and DELETE all configuration files!${NC}"
    echo -e "${ORANGE}It is highly recommended to use the Backup Manager first if you want to save your configs.${NC}"

    read -rp "Are you absolutely sure you want to remove WireGuard? [y/N]: " -e REMOVE
    if [[ ! "$REMOVE" =~ ^[Yy]$ ]]; then
        echo -e "\nRemoval aborted."
        read -n1 -r -p "Press any key to continue..."
        return
    fi

    SERVER_WG_NIC="wg0"
    if [[ -e /etc/wireguard/params ]]; then
        source /etc/wireguard/params
    fi

    echo -e "\n${CYAN}Stopping and disabling services...${NC}"
    if [[ ${OS} == 'alpine' ]]; then
        rc-service "wg-quick.${SERVER_WG_NIC}" stop 2>/dev/null
        rc-update del "wg-quick.${SERVER_WG_NIC}" 2>/dev/null
        unlink "/etc/init.d/wg-quick.${SERVER_WG_NIC}" 2>/dev/null
        rc-update del sysctl 2>/dev/null
    else
        systemctl stop "wg-quick@${SERVER_WG_NIC}" 2>/dev/null
        systemctl disable "wg-quick@${SERVER_WG_NIC}" 2>/dev/null
    fi

    echo -e "${CYAN}Removing packages...${NC}"
    if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
        apt-get remove -y wireguard wireguard-tools qrencode
    elif [[ ${OS} == 'fedora' ]]; then
        dnf remove -y --noautoremove wireguard-tools qrencode
    elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
        yum remove -y --noautoremove wireguard-tools kmod-wireguard qrencode
    elif [[ ${OS} == 'oracle' ]]; then
        yum remove -y --noautoremove wireguard-tools qrencode
    elif [[ ${OS} == 'arch' ]]; then
        pacman -Rs --noconfirm wireguard-tools qrencode
    elif [[ ${OS} == 'alpine' ]]; then
        apk del wireguard-tools libqrencode libqrencode-tools
    fi

    echo -e "${CYAN}Cleaning up files...${NC}"
    rm -rf /etc/wireguard
    rm -f /etc/sysctl.d/wg.conf
    rm -rf /root/easy_wireguard

    if [[ ${OS} != 'alpine' ]]; then
        sysctl --system >/dev/null 2>&1
    fi

    echo -e "\n${GREEN}WireGuard has been successfully uninstalled.${NC}"
    echo ""
    read -n1 -r -p "Press any key to continue..."
}

isRoot
checkOS

# Allow running as a standalone script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    uninstall_wireguard
fi
