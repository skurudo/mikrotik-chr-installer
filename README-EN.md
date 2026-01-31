# MikroTik CHR Installer

Automated MikroTik Cloud Hosted Router (CHR) installation script for Linux VPS/VDS servers.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Русский](https://img.shields.io/badge/lang-Русский-blue.svg)](README.md)

## 📋 Overview

This script automates the complete installation of MikroTik Cloud Hosted Router (CHR) on any Linux-based VPS or VDS server. It handles everything from downloading the CHR image to configuring network settings and performing the installation — all with a single command.

### Key Features

- 🚀 **One-command installation** — fully automated process
- 🌐 **Auto-detection of network settings** — IP address, gateway, interface
- 📦 **Automatic dependency installation** — works on Debian/Ubuntu, CentOS, RHEL, Fedora
- 🔧 **Pre-configured autorun** — CHR boots with network already configured
- ✅ **Image validation** — MBR signature and integrity checks
- 🔄 **Flexible options** — customizable version, password, and installation modes

## 🎯 Use Cases

### 1. Quick VPS Migration to MikroTik

Replace your Linux VPS with a full MikroTik router in minutes. Perfect for:
- Setting up a VPN server (WireGuard, L2TP, PPTP, OpenVPN)
- Creating a secure gateway for your infrastructure
- Building a remote network management point

### 2. Network Lab Environment

Quickly deploy MikroTik instances for:
- Testing RouterOS configurations before production
- Learning MikroTik administration
- Certification exam preparation (MTCNA, MTCRE, etc.)

### 3. Site-to-Site VPN Hub

Transform a cheap VPS into a central VPN hub connecting multiple sites:
- Cloud-based router for distributed networks
- Backup connectivity point
- Geographic routing optimization

### 4. Traffic Management & Monitoring

Deploy CHR for:
- Bandwidth management and QoS
- Traffic analysis with built-in tools
- Firewall and security gateway

## 📦 Requirements

- Linux-based VPS/VDS server (Debian, Ubuntu, CentOS, RHEL, Fedora)
- Root access
- Minimum 128 MB RAM (256 MB+ recommended)
- At least 128 MB disk space
- Active internet connection

## 🚀 Quick Start

### One-Line Installation

```bash
wget -qO- https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer.sh | bash
```

### Manual Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer.sh

# Make it executable
chmod +x chr-installer.sh

# Run the installer
sudo ./chr-installer.sh
```

## 📖 Usage Examples

### Basic Installation (Interactive)

```bash
sudo ./chr-installer.sh
```

The script will:
1. Download the latest CHR image
2. Detect your network configuration
3. Ask for confirmation before writing to disk
4. Prompt for reboot after installation

### Fully Automated Installation

```bash
sudo ./chr-installer.sh --yes --reboot
```

No user interaction required — perfect for automation and scripts.

### Custom Version and Password

```bash
sudo ./chr-installer.sh --version 7.14.3 --password MySecurePass123
```

### Clean Installation (No Auto-Configuration)

```bash
sudo ./chr-installer.sh --clean
```

CHR will boot with default settings. Useful when you want to configure everything manually.

### Automation Script Example

```bash
#!/bin/bash
# Deploy MikroTik CHR on multiple servers

SERVERS="192.168.1.10 192.168.1.11 192.168.1.12"
PASSWORD="StrongPassword123"

for server in $SERVERS; do
    ssh root@$server "curl -sL https://example.com/chr-installer.sh | bash -s -- --yes --reboot --password $PASSWORD"
done
```

## ⚙️ Command Line Options

| Option | Description |
|--------|-------------|
| `--clean` | Clean installation without autorun.scr (manual configuration required) |
| `--force` | Force re-download of the CHR image |
| `--no-verify` | Skip write verification |
| `--yes`, `-y` | Automatic mode, no confirmations |
| `--reboot` | Auto-reboot after installation (requires `--yes`) |
| `--version VER` | Specify CHR version (default: 7.16.1) |
| `--password PASS` | Set admin password (default: PASSWORD) |
| `-h`, `--help` | Show help message |

## 🔧 What the Script Does

1. **Checks dependencies** — installs required tools if missing
2. **Downloads CHR image** — from official MikroTik servers
3. **Validates the image** — checks MBR signature and file integrity
4. **Detects network settings** — IP address, gateway, interface
5. **Creates autorun.scr** — configures CHR to boot with your network settings
6. **Writes to disk** — uses `dd` with direct I/O for reliability
7. **Reboots** — into your new MikroTik CHR

## 🌐 Post-Installation Access

After installation and reboot, access your CHR via:

- **WinBox**: Connect to your server's IP address
- **SSH**: `ssh admin@YOUR_SERVER_IP`
- **WebFig**: `http://YOUR_SERVER_IP`

Default credentials:
- **Username**: `admin`
- **Password**: as specified with `--password` (default: `PASSWORD`)

## ⚠️ Important Notes

- **All data on the target disk will be erased!**
- The script requires root privileges
- Ensure you have console/KVM access in case of issues
- Test in a non-production environment first
- Default CHR license is free (limited to 1 Mbps upload)

## 🔒 Security Recommendations

1. **Change the default password** immediately if you used the default
2. **Disable unused services** after first login
3. **Configure firewall rules** to protect management access
4. **Update to latest RouterOS** version regularly

## 📝 Default CHR Configuration

The autorun script configures:

```routeros
/ip dns set servers=8.8.8.8,8.8.4.4
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=no
/ip service set ssh disabled=no
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=no
/ip address add address=YOUR_IP interface=ether1
/ip route add gateway=YOUR_GATEWAY
```

## 🛠️ Customizing autorun.scr

You can edit the script and add your own configuration to `autorun.scr`. This allows CHR to boot with a fully prepared setup — firewall, VPN, users, etc.

### Where to Edit

Find the autorun creation block in `chr-installer.sh` (around line 297):

```bash
cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
# Your configuration here
EOF
```

### Custom Configuration Examples

#### Basic VPS Firewall

```routeros
# SSH brute force protection
/ip firewall filter
add chain=input protocol=tcp dst-port=22 src-address-list=ssh_blacklist action=drop comment="Drop SSH brute force"
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage3 action=add-src-to-address-list address-list=ssh_blacklist address-list-timeout=1w
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage2 action=add-src-to-address-list address-list=ssh_stage3 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage1 action=add-src-to-address-list address-list=ssh_stage2 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new action=add-src-to-address-list address-list=ssh_stage1 address-list-timeout=1m

# Basic rules
add chain=input connection-state=established,related action=accept comment="Accept established"
add chain=input connection-state=invalid action=drop comment="Drop invalid"
add chain=input protocol=icmp action=accept comment="Accept ICMP"
add chain=input protocol=tcp dst-port=22 action=accept comment="Accept SSH"
add chain=input protocol=tcp dst-port=8291 action=accept comment="Accept WinBox"
add chain=input action=drop comment="Drop all other"
```

#### IP-Based Access Restriction

```routeros
# Allow management only from specific IPs
/ip firewall address-list
add list=management address=YOUR_HOME_IP comment="Home IP"
add list=management address=YOUR_OFFICE_IP comment="Office IP"

/ip firewall filter
add chain=input src-address-list=management action=accept comment="Allow management IPs"
add chain=input protocol=tcp dst-port=22,8291,80,443 action=drop comment="Block management from others"
```

#### WireGuard VPN Setup

```routeros
/interface wireguard
add name=wg0 listen-port=51820 private-key="YOUR_PRIVATE_KEY"

/interface wireguard peers
add interface=wg0 public-key="PEER_PUBLIC_KEY" allowed-address=10.0.0.2/32

/ip address
add address=10.0.0.1/24 interface=wg0

/ip firewall filter
add chain=input protocol=udp dst-port=51820 action=accept comment="Accept WireGuard"
```

#### Automatic Configuration Backup

```routeros
# Create backup script
/system script
add name=backup-script source="/system backup save name=auto-backup"

# Scheduler runs the script daily at 03:00
/system scheduler
add name=daily-backup interval=1d on-event=backup-script start-time=03:00:00
```

#### NTP and Timezone Configuration

```routeros
/system clock set time-zone-name=America/New_York
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org
```

### Full Custom autorun.scr Example

```bash
cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
# === Basic Setup ===
/ip dns set servers=${DNS_SERVERS}
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=[/interface ethernet find where name=ether1]
/ip route add gateway=${GATEWAY}
/user set 0 name=admin password=${ADMIN_PASSWORD}

# === Services ===
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=no
/ip service set ssh disabled=no port=22
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=no

# === Firewall ===
/ip firewall filter
add chain=input connection-state=established,related action=accept
add chain=input connection-state=invalid action=drop
add chain=input protocol=icmp action=accept
add chain=input protocol=tcp dst-port=22 action=accept
add chain=input protocol=tcp dst-port=8291 action=accept
add chain=input action=drop

# === System ===
/system clock set time-zone-name=America/New_York
/system identity set name=MikroTik-CHR
EOF
```

## 🐛 Troubleshooting

### CHR doesn't boot
- Check console output via VNC/KVM
- Verify the disk was written correctly
- Try `--clean` mode and configure manually

### Network not working after boot
- Verify IP and gateway settings in CHR
- Check if the interface name is `ether1`
- Review firewall rules on the hosting provider

### Can't connect via SSH/WinBox
- Wait 1-2 minutes for CHR to fully boot
- Verify the IP address is correct
- Check hosting provider's firewall/security groups

## 📦 Installation Variants

Several scripts are available for different scenarios:

### Minimal Installation

| Script | Language | Description |
|--------|----------|-------------|
| `chr-installer.sh` | RU | Basic installer with network auto-config |
| `chr-installer-en.sh` | EN | Basic installer with network auto-config |

### With Basic Security Configuration

| Script | Language | Description |
|--------|----------|-------------|
| `chr-installer-base-ru.sh` | RU | + Firewall, brute-force protection, NTP, auto-backup |
| `chr-installer-base-en.sh` | EN | + Firewall, brute-force protection, NTP, auto-backup |

**Includes:**
- SSH/WinBox brute-force protection
- DNS amplification attack protection
- Disable insecure services
- NTP and timezone configuration
- Daily auto-backup

### VPN Server (All Protocols)

| Script | Language | Description |
|--------|----------|-------------|
| `chr-installer-adv-vpn-ru.sh` | RU | Full-featured VPN server |
| `chr-installer-adv-vpn-en.sh` | EN | Full-featured VPN server |

**Includes all protocols:**
- PPTP (port 1723)
- L2TP/IPsec (port 1701, UDP 500/4500) — auto-generated 12-char PSK
- SSTP (port 443) — auto-generated self-signed certificate
- OpenVPN (port 1194 UDP/TCP, 1195 TCP) — auto-generated certificate
- WireGuard (port 51820) — auto-generated server key

**Additional VPN parameters:**
```bash
--vpn-user USER      # VPN username (default: vpnuser)
--vpn-pass PASS      # VPN password (auto-generated)
--ipsec-secret KEY   # IPsec PSK (auto-generated)
--wg-port PORT       # WireGuard port (default: 51820)
```

### 🚀 One-Line Quick Installation

#### Basic setup with security (EN):
```bash
bash <(curl -sL https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer-base-en.sh) --yes --reboot
```

#### Basic setup with security (RU):
```bash
bash <(curl -sL https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer-base-ru.sh) --yes --reboot
```

#### VPN server with all protocols (EN):
```bash
bash <(curl -sL https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer-adv-vpn-en.sh) --yes --reboot
```

#### VPN server with all protocols (RU):
```bash
bash <(curl -sL https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer-adv-vpn-ru.sh) --yes --reboot
```

#### VPN server with custom parameters:
```bash
bash <(curl -sL https://raw.githubusercontent.com/skurudo/mikrotik-chr-installer/main/chr-installer-adv-vpn-en.sh) \
  --password MyAdminPass \
  --vpn-user myuser \
  --vpn-pass MyVPNPass123 \
  --ipsec-secret MyIPsecKey \
  --yes --reboot
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📮 Support

If you encounter any issues or have questions, please open an issue on GitHub.

---

**Disclaimer**: This script is provided as-is. Always ensure you have backups and console access before running on production systems. MikroTik and RouterOS are trademarks of MikroTik SIA.
