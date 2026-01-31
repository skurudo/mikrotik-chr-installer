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
wget -qO- https://raw.githubusercontent.com/YOUR_REPO/mikrotik-chr-installer/main/chr-installer.sh | bash
```

### Manual Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/YOUR_REPO/mikrotik-chr-installer/main/chr-installer.sh

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

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📮 Support

If you encounter any issues or have questions, please open an issue on GitHub.

---

**Disclaimer**: This script is provided as-is. Always ensure you have backups and console access before running on production systems. MikroTik and RouterOS are trademarks of MikroTik SIA.
