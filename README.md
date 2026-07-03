# 🍪 Cookie's Easy WireGuard Manager

A powerful, secure, and user-friendly WireGuard VPN manager for Ubuntu 20.04+. Features automated server setup, encrypted client management, domain-based split tunneling, and integrated V2Ray (V2Fly) for advanced stealth and streaming enhancement.

## 🚀 Key Features

- **One-Click Installation:** Automated deployment of a hardened WireGuard server.
- **V2Ray Integration:** Seamlessly integrated V2Ray (V2Fly) for Deep Packet Inspection (DPI) bypass and streaming optimization (Netflix, Disney+, Max, etc.).
- **Transparent Proxying:** Server-side V2Ray TProxy intercepts WireGuard traffic for automatic streaming geoblock bypass without client-side V2Ray software.
- **Encrypted Client Management:** Client configurations are stored with AES-256 encryption.
- **Domain-Based Split Tunneling:** Easily route specific domains outside the VPN tunnel.
- **Secure Backups:** Encrypted backup and restoration of your entire VPN configuration.
- **Hardened Security:** Automatic kernel hardening (Sysctl), BBR congestion control, and UFW firewall configuration.

## 🛠️ Quick Start

Run the following command as root to launch the manager:

```bash
wget https://raw.githubusercontent.com/cookiebaits/cbwireguard/main/easy_wireguard.sh -O easy_wireguard.sh && chmod +x easy_wireguard.sh && ./easy_wireguard.sh
```

## 📖 Usage Guide

### 1️⃣ Setup WireGuard Server (Option 1)
Select your desired VPN port (stealthy ports like 443, 53, or 123 are recommended) and let the script handle the rest. You will also be prompted to install V2Ray for added stealth and streaming capabilities.

### 2️⃣ Add New Client (Option 2)
Enter a name for the device. The script will generate a configuration and display a QR code for easy mobile setup.

### 3️⃣ Configure Clients (Option 4)
Manage existing clients:
- **List:** View all configured peers.
- **Check:** Display configuration text and QR codes.
- **Edit:** Manually adjust client settings (MTU, DNS).
- **Remove:** Safely delete a peer from the server.

### 4️⃣ Backup & Restore (Option 5)
Keep your configurations safe. Backups are AES-256 encrypted with a password you provide.

### 5️⃣ Domain-Based Split Tunneling (Option 6)
Add domains (e.g., `netflix.com`) to a bypass list to route their traffic through your standard internet connection instead of the VPN.

### 6️⃣ V2Ray Stealth & Streaming (Option 7)
Enable V2Ray to add an extra layer of obfuscation to your traffic. V2Ray is pre-configured to route major streaming services through a specified proxy, ensuring you can access content from anywhere.

---

## 🔒 Security Information
- **No Activity Logging:** All scripts are configured to avoid logging user traffic.
- **Encryption:** All sensitive configurations and backups are encrypted using OpenSSL with PBKDF2.
- **Privileged Access:** Root access is required for network and service modifications.

## 📄 License
This project is licensed under the MIT License.
