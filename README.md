# 🍪 Cookie's Easy WireGuard Server

> A heavily optimized, hyper-secure, and lightning-fast deployment script to configure and manage a WireGuard VPN server on Ubuntu.

This wrapper dynamically pulls the latest scripts from GitHub, ensuring your server is always running the most up-to-date and secure code. Guaranteed to work on **Ubuntu 20.04 and newer**.

---

## 📑 Table of Contents
- [Key Feature Upgrades](#-key-feature-upgrades)
- [Installation (Step 1)](#%EF%B8%8F-installation-step-1)
- [Setting up the Server (Option 1)](#%E2%9A%99%EF%B8%8F-setting-up-the-server-option-1)
- [Adding a New Client (Option 2)](#-adding-a-new-client-option-2)
- [Managing Clients (Options 3 & 4)](#-managing-clients-options-3--4)
- [Backup & Restore Manager (Option 5)](#-backup--restore-manager-option-5)
- [Removing the Server (Option 6)](#%EF%B8%8F-removing-the-server-option-6)

---

## 🚀 Key Feature Upgrades

- **Maximized Throughput:** Injects Kernel-level BBR (Bottleneck Bandwidth and RTT) and FQ queueing, paired with an optimized MTU (1360) to eliminate packet fragmentation and maximize upload/download speeds.
- **Zero-Downtime Hot Reloading:** Adding a new peer instantly injects them into the live server. Existing users are never disconnected when the configuration updates.
- **Military-Grade Security:** Enforces strict execution rules (`set -euo pipefail`), root-only directory locks (`chmod 700`), and secure unprivileged port generation.
- **Smart IP Tracking:** Intelligently scans the server to dynamically assign IP addresses, preventing crashes from corrupted or empty lines.
- **Unified Backup Manager:** Securely create, list, restore, and destroy server backups from a single interactive menu.

---

## 🛠️ Installation (Step 1)

WireGuard requires root access to modify system network interfaces. Enter `sudo` mode in your terminal:

```bash
sudo -i
