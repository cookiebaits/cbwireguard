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

curl -O https://raw.githubusercontent.com/cookiebaits/cbwireguard/main/easy_wireguard.sh

chmod +x easy_wireguard.sh

./easy_wireguard.sh

```bash
sudo -i

## ⚙️ Step 2: Setting up the Server (Option 1)
The script will ask you to define your ports:

WireGuard VPN Port: Enter a custom port (1024-65535) or leave it blank to let the script generate a secure, randomized high port.

SSH Port: Enter your custom SSH port (or leave blank for the default 22) so the firewall doesn't lock you out.

Note: The script will automatically install dependencies, generate locked-down encryption keys, optimize your IP forwarding, and boot the server. (Internal IP scope: 10.18.0.x/24).

## 📱 Step 3: Adding a New Client (Option 2)
Create a new peer instantly:

Enter a device name (alphanumeric characters only).

Choose if you want the output rendered as a QR code or printed as raw text.

The script will generate the .conf file and inject the user into the active server without restarting the interface. If you chose QR output, scan the terminal with the WireGuard mobile app.

## 🔍 Step 4: Managing Clients (Options 3 & 4)
[3] Show Client QR: Enter the exact name of a previously created device. The script will instantly render a high-fidelity (ansiutf8) QR code in your terminal.

[4] List Configured Clients: Prints a clean list of every active peer currently configured on your server so you don't have to guess their names.

## 💾 Step 5: Backup & Restore Manager (Option 5)
Selecting this opens the dedicated Backup Sub-Menu:

Create: Archives your current /etc/wireguard configurations into a locked (chmod 600) .tar.gz file stamped with the date, time, and hostname.

Restore: Scans the directory for existing backups and allows you to select which one to restore. It safely handles extraction in an isolated memory space.

List: Shows all backups currently sitting in your directory and their file sizes.

Delete: Securely destroys old, unencrypted backup archives to keep your server secure.

## 🗑️ Step 6: Removing the Server (Option 6)
If you need to start fresh or remove the VPN, this option executes a total system wipe.

Safely stops the systemd service.

Reverts the sysctl IP forwarding changes to close system vulnerabilities.

Purges WireGuard and cleans up unused dependencies.
