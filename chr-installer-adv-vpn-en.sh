#!/bin/bash
set -e

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# ============================================
# KEY AND PASSWORD GENERATION
# ============================================
generate_password() {
    local length=$1
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_wireguard_key() {
    # Generate WireGuard keys via base64
    # Private key - 32 random bytes in base64
    head -c 32 /dev/urandom | base64
}

# ============================================
# INPUT SANITIZATION
# ============================================
sanitize_input() {
    local input="$1"
    # Remove dangerous characters: ; " ' ` $ \ / and newlines
    echo "$input" | tr -d ';"'\''`$\\/\n\r' | head -c 64
}

# ============================================
# CONFIGURATION
# ============================================
CHR_VERSION="7.16.1"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
CHR_ZIP="chr-${CHR_VERSION}.img.zip"
CHR_IMG="chr-${CHR_VERSION}.img"
WORK_DIR="/tmp/chr-install"
MOUNT_POINT="/mnt/chr"

# CHR Settings (password auto-generated if not specified)
ADMIN_PASSWORD=""
DNS_SERVERS="8.8.8.8,8.8.4.4"
ROUTER_NAME="MikroTik-VPN"
TIMEZONE="Europe/Moscow"

# VPN Settings
VPN_POOL="10.10.10.0/24"
VPN_POOL_START="10.10.10.2"
VPN_POOL_END="10.10.10.254"
VPN_LOCAL_IP="10.10.10.1"
VPN_USER="vpnuser"
VPN_USER_PASSWORD=""
IPSEC_SECRET=""
WG_SERVER_PORT="51820"
WG_SERVER_PRIVATE_KEY=""
WG_NETWORK="10.10.20.0/24"
OVPN_PORT="1194"
OVPN_TCP_PORT="1195"
SSTP_PORT="8443"

# Flags
FORCE_DOWNLOAD=false
AUTO_YES=false
AUTO_REBOOT=false

# ============================================
# ARGUMENT PARSING
# ============================================
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "CHR installation script as VPN server with all protocols:"
    echo "  - PPTP (port 1723)"
    echo "  - L2TP/IPsec (port 1701, UDP 500/4500)"
    echo "  - SSTP (port 8443)"
    echo "  - OpenVPN (port 1194 UDP/TCP, 1195 TCP)"
    echo "  - WireGuard (port 51820)"
    echo ""
    echo "Options:"
    echo "  --force          Force re-download the image"
    echo "  --yes, -y        No confirmations (automatic mode)"
    echo "  --reboot         Automatic reboot (requires --yes)"
    echo "  --version VER    CHR version (default: $CHR_VERSION)"
    echo "  --password PASS  Admin password (auto-generated)"
    echo "  --name NAME      Router name (default: $ROUTER_NAME)"
    echo "  --timezone TZ    Timezone (default: $TIMEZONE)"
    echo "  --dns SERVERS    DNS servers (default: $DNS_SERVERS)"
    echo "  --vpn-user USER  VPN user (default: $VPN_USER)"
    echo "  --vpn-pass PASS  VPN password (auto-generated)"
    echo "  --vpn-pool CIDR  VPN address pool (default: $VPN_POOL)"
    echo "  --ipsec-secret S IPsec Pre-Shared Key (auto-generated)"
    echo "  --wg-port PORT   WireGuard port (default: $WG_SERVER_PORT)"
    echo "  -h, --help       Show help"
    echo ""
    echo "Examples:"
    echo "  $0 --yes --reboot                    # Auto-install VPN server"
    echo "  $0 --vpn-user myuser --vpn-pass secret123"
    echo "  $0 --ipsec-secret MyIPsecKey123"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DOWNLOAD=true
            shift
            ;;
        --yes|-y)
            AUTO_YES=true
            shift
            ;;
        --reboot)
            AUTO_REBOOT=true
            shift
            ;;
        --version)
            CHR_VERSION="$2"
            CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
            CHR_ZIP="chr-${CHR_VERSION}.img.zip"
            CHR_IMG="chr-${CHR_VERSION}.img"
            shift 2
            ;;
        --password)
            ADMIN_PASSWORD=$(sanitize_input "$2")
            shift 2
            ;;
        --name)
            ROUTER_NAME=$(sanitize_input "$2")
            shift 2
            ;;
        --timezone)
            TIMEZONE=$(sanitize_input "$2")
            shift 2
            ;;
        --dns)
            DNS_SERVERS=$(sanitize_input "$2")
            shift 2
            ;;
        --vpn-user)
            VPN_USER=$(sanitize_input "$2")
            shift 2
            ;;
        --vpn-pass)
            VPN_USER_PASSWORD=$(sanitize_input "$2")
            shift 2
            ;;
        --vpn-pool)
            VPN_POOL=$(sanitize_input "$2")
            shift 2
            ;;
        --ipsec-secret)
            IPSEC_SECRET=$(sanitize_input "$2")
            shift 2
            ;;
        --wg-port)
            WG_SERVER_PORT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# ============================================
# KEY GENERATION (if not specified)
# ============================================
log_info "Generating keys and passwords..."

if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(generate_password 16)
    log_info "Generated admin password: $ADMIN_PASSWORD"
fi

if [[ -z "$VPN_USER_PASSWORD" ]]; then
    VPN_USER_PASSWORD=$(generate_password 16)
    log_info "Generated VPN password: $VPN_USER_PASSWORD"
fi

if [[ -z "$IPSEC_SECRET" ]]; then
    IPSEC_SECRET=$(generate_password 12)
    log_info "Generated IPsec PSK: $IPSEC_SECRET"
fi

# WireGuard server key
WG_SERVER_PRIVATE_KEY=$(generate_wireguard_key)

log_info "Generated WireGuard server key"

# ============================================
# ROOT CHECK
# ============================================
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# ============================================
# DEPENDENCY CHECK
# ============================================
log_info "Checking dependencies..."

REQUIRED_TOOLS="wget unzip fdisk dd mount umount file md5sum xxd"
MISSING_TOOLS=""

for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [[ -n "$MISSING_TOOLS" ]]; then
    log_warn "Missing tools:$MISSING_TOOLS"
    log_info "Attempting to install..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wget unzip fdisk coreutils mount xxd
    elif command -v yum &> /dev/null; then
        yum install -y wget unzip util-linux coreutils vim-common
    elif command -v dnf &> /dev/null; then
        dnf install -y wget unzip util-linux coreutils vim-common
    else
        log_error "Please install manually:$MISSING_TOOLS"
        exit 1
    fi
fi

log_info "All dependencies are satisfied"

# ============================================
# WORKING DIRECTORY PREPARATION
# ============================================
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log_info "Working directory: $WORK_DIR"
log_debug "Free space: $(df -h "$WORK_DIR" | tail -1 | awk '{print $4}')"

# ============================================
# IMAGE DOWNLOAD
# ============================================
if [[ "$FORCE_DOWNLOAD" == true ]] || [[ ! -f "$CHR_IMG" ]]; then
    rm -f "$CHR_ZIP" "$CHR_IMG" "${CHR_IMG}.modified"
    
    log_info "Downloading CHR ${CHR_VERSION}..."
    wget --progress=bar:force -O "$CHR_ZIP" "$CHR_URL"
    
    ACTUAL_SIZE=$(stat -c%s "$CHR_ZIP")
    log_debug "Downloaded file size: $ACTUAL_SIZE bytes"
    
    if [[ $ACTUAL_SIZE -lt 30000000 ]]; then
        log_error "File too small, download incomplete"
        exit 1
    fi
    
    FILE_TYPE=$(file "$CHR_ZIP")
    log_debug "File type: $FILE_TYPE"
    
    if echo "$FILE_TYPE" | grep -q "Zip archive"; then
        log_info "Extracting ZIP..."
        unzip -o "$CHR_ZIP"
    elif echo "$FILE_TYPE" | grep -q "gzip"; then
        log_info "Extracting GZIP..."
        gunzip -c "$CHR_ZIP" > "$CHR_IMG"
    else
        log_error "Unknown format: $FILE_TYPE"
        exit 1
    fi
    
    rm -f "$CHR_ZIP"
else
    log_info "Using existing image: $CHR_IMG"
fi

# ============================================
# IMAGE VALIDATION
# ============================================
log_info "Validating image..."

if [[ ! -f "$CHR_IMG" ]]; then
    log_error "Image not found!"
    ls -la "$WORK_DIR"
    exit 1
fi

IMG_SIZE=$(stat -c%s "$CHR_IMG")
log_debug "Image size: $IMG_SIZE bytes ($(( IMG_SIZE / 1024 / 1024 )) MB)"

MBR_SIG=$(xxd -s 510 -l 2 -p "$CHR_IMG")
if [[ "$MBR_SIG" != "55aa" ]]; then
    log_error "Invalid MBR signature: $MBR_SIG (expected 55aa)"
    exit 1
fi
log_debug "MBR signature: OK (55aa)"

ORIGINAL_MD5=$(md5sum "$CHR_IMG" | awk '{print $1}')
log_info "Original image MD5: $ORIGINAL_MD5"

log_info "Image validation passed ✓"

# ============================================
# NETWORK PARAMETERS DETECTION
# ============================================
log_info "Detecting network parameters..."

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
ADDRESS=$(ip addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
SERVER_IP="${ADDRESS%/*}"

if [[ -z "$INTERFACE" || -z "$ADDRESS" || -z "$GATEWAY" ]]; then
    log_error "Failed to detect network parameters"
    log_error "INTERFACE=$INTERFACE ADDRESS=$ADDRESS GATEWAY=$GATEWAY"
    exit 1
fi

log_info "Interface: $INTERFACE | Address: $ADDRESS | Gateway: $GATEWAY"

# ============================================
# DISK DETECTION
# ============================================
log_info "Detecting target disk..."

echo ""
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "(NAME|disk)"
echo ""

DISK_DEVICE=$(lsblk -ndo NAME,TYPE | grep disk | head -n1 | awk '{print "/dev/"$1}')

if [[ -z "$DISK_DEVICE" ]]; then
    log_error "Disk not found"
    exit 1
fi

DISK_SIZE=$(lsblk -ndo SIZE "$DISK_DEVICE")
log_warn "Target disk: $DISK_DEVICE ($DISK_SIZE)"

# ============================================
# CREATE AUTORUN WITH VPN CONFIGURATION
# ============================================
log_info "Creating autorun.scr with VPN server configuration..."

CHR_IMG_MOD="${CHR_IMG}.modified"
cp "$CHR_IMG" "$CHR_IMG_MOD"

mkdir -p "$MOUNT_POINT"

OFFSET_SECTORS=$(fdisk -l "$CHR_IMG_MOD" 2>/dev/null | grep "${CHR_IMG_MOD}2" | awk '{print $2}')
if [[ -z "$OFFSET_SECTORS" ]]; then
    OFFSET_BYTES=33571840
else
    OFFSET_BYTES=$((OFFSET_SECTORS * 512))
fi

log_debug "Mounting with offset: $OFFSET_BYTES"

mount -o loop,offset="$OFFSET_BYTES" "$CHR_IMG_MOD" "$MOUNT_POINT"

if [[ ! -d "$MOUNT_POINT/rw" ]]; then
    log_warn "Directory /rw does not exist, creating..."
    mkdir -p "$MOUNT_POINT/rw"
fi

# Create extended autorun with VPN configuration
cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
# ============================================
# BASIC CONFIGURATION - NETWORK
# ============================================
/ip dns set servers=${DNS_SERVERS}
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=[/interface ethernet find where name=ether1]
/ip route add gateway=${GATEWAY}

# ============================================
# USER AND SYSTEM
# ============================================
/user set 0 name=admin password=${ADMIN_PASSWORD}
/system identity set name=${ROUTER_NAME}
/system clock set time-zone-name=${TIMEZONE}
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org

# ============================================
# SERVICES - DISABLE INSECURE
# ============================================
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set ssh disabled=no port=22
/ip service set winbox disabled=no

# ============================================
# VPN - ADDRESS POOL
# ============================================
/ip pool add name=vpn-pool ranges=${VPN_POOL_START}-${VPN_POOL_END}

# ============================================
# VPN - PPP PROFILE
# ============================================
/ppp profile add name=vpn-profile local-address=${VPN_LOCAL_IP} remote-address=vpn-pool dns-server=${DNS_SERVERS} use-encryption=yes

# ============================================
# VPN - OPENVPN PUSH ROUTES
# ============================================
# Default route through VPN (all traffic)
/ppp profile set vpn-profile push-routes="0.0.0.0/0 ${VPN_LOCAL_IP}"

# ============================================
# VPN - USER
# ============================================
/ppp secret add name=${VPN_USER} password=${VPN_USER_PASSWORD} profile=vpn-profile service=any

# ============================================
# VPN - PPTP SERVER
# ============================================
/interface pptp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2

# ============================================
# VPN - L2TP/IPSEC SERVER
# ============================================
/interface l2tp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2 use-ipsec=yes ipsec-secret=${IPSEC_SECRET}

# ============================================
# VPN - SSTP SERVER
# ============================================
# Create self-signed certificate for SSTP
/certificate add name=sstp-ca common-name=sstp-ca days-valid=3650 key-size=2048 key-usage=key-cert-sign,crl-sign
/certificate sign sstp-ca
/certificate add name=sstp-server common-name=${SERVER_IP} days-valid=3650 key-size=2048 key-usage=digital-signature,key-encipherment,tls-server
/certificate sign sstp-server ca=sstp-ca
/certificate set sstp-server trusted=yes
/interface sstp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2 certificate=sstp-server port=${SSTP_PORT}

# ============================================
# VPN - OPENVPN SERVER
# ============================================
# Create certificate for OpenVPN
/certificate add name=ovpn-ca common-name=ovpn-ca days-valid=3650 key-size=2048 key-usage=key-cert-sign,crl-sign
/certificate sign ovpn-ca
/certificate add name=ovpn-server common-name=ovpn-server days-valid=3650 key-size=2048 key-usage=digital-signature,key-encipherment,tls-server
/certificate sign ovpn-server ca=ovpn-ca
/certificate set ovpn-server trusted=yes
/certificate add name=ovpn-client common-name=ovpn-client days-valid=3650 key-size=2048 key-usage=tls-client
/certificate sign ovpn-client ca=ovpn-ca
/interface ovpn-server server set enabled=yes default-profile=vpn-profile certificate=ovpn-server auth=sha256 cipher=aes256-cbc port=${OVPN_PORT} require-client-certificate=no

# ============================================
# VPN - WIREGUARD SERVER
# ============================================
/interface wireguard add name=wg0 listen-port=${WG_SERVER_PORT} private-key="${WG_SERVER_PRIVATE_KEY}"
/ip address add address=${WG_NETWORK%.*}.1/24 interface=wg0
# Peer is added manually after receiving client's public key:
# /interface wireguard peers add interface=wg0 public-key="CLIENT_PUBLIC_KEY" allowed-address=10.10.20.2/32

# ============================================
# NAT - MASQUERADE FOR VPN
# ============================================
/ip firewall nat add chain=srcnat src-address=${VPN_POOL} action=masquerade comment="NAT for VPN clients"
/ip firewall nat add chain=srcnat src-address=${WG_NETWORK} action=masquerade comment="NAT for WireGuard clients"

# ============================================
# NAT - REDIRECT OPENVPN TCP ALT PORT
# ============================================
/ip firewall nat add chain=dstnat protocol=tcp dst-port=${OVPN_TCP_PORT} action=redirect to-ports=${OVPN_PORT} comment="Redirect OpenVPN TCP alt port to main"

# ============================================
# FIREWALL - BASIC RULES (first for performance)
# ============================================
/ip firewall filter
add chain=input connection-state=established,related action=accept comment="Accept established connections"
add chain=input connection-state=invalid action=drop comment="Drop invalid connections"

# ============================================
# FIREWALL - SSH BRUTE-FORCE PROTECTION
# ============================================
add chain=input protocol=tcp dst-port=22 src-address-list=ssh_blacklist action=drop comment="Drop SSH brute force"
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage3 action=add-src-to-address-list address-list=ssh_blacklist address-list-timeout=1w
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage2 action=add-src-to-address-list address-list=ssh_stage3 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage1 action=add-src-to-address-list address-list=ssh_stage2 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new action=add-src-to-address-list address-list=ssh_stage1 address-list-timeout=1m

# ============================================
# FIREWALL - WINBOX BRUTE-FORCE PROTECTION
# ============================================
add chain=input protocol=tcp dst-port=8291 src-address-list=winbox_blacklist action=drop comment="Drop WinBox brute force"
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage3 action=add-src-to-address-list address-list=winbox_blacklist address-list-timeout=1w
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage2 action=add-src-to-address-list address-list=winbox_stage3 address-list-timeout=1m
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage1 action=add-src-to-address-list address-list=winbox_stage2 address-list-timeout=1m
add chain=input protocol=tcp dst-port=8291 connection-state=new action=add-src-to-address-list address-list=winbox_stage1 address-list-timeout=1m

# ============================================
# FIREWALL - DNS AMPLIFICATION PROTECTION
# ============================================
/ip dns set allow-remote-requests=no
/ip firewall filter
add chain=input protocol=udp dst-port=53 action=drop comment="Drop external DNS queries (anti-amplification)"
add chain=input protocol=tcp dst-port=53 action=drop comment="Drop external DNS TCP queries"

# ============================================
# FIREWALL - ALLOWED SERVICES
# ============================================
add chain=input protocol=icmp action=accept comment="Accept ICMP (ping)"
add chain=input protocol=tcp dst-port=22 action=accept comment="Accept SSH"
add chain=input protocol=tcp dst-port=8291 action=accept comment="Accept WinBox"

# ============================================
# FIREWALL - VPN PORTS
# ============================================
add chain=input protocol=tcp dst-port=1723 action=accept comment="Accept PPTP"
add chain=input protocol=gre action=accept comment="Accept GRE (PPTP)"
add chain=input protocol=udp dst-port=500 action=accept comment="Accept IKE (L2TP/IPsec)"
add chain=input protocol=udp dst-port=4500 action=accept comment="Accept NAT-T (L2TP/IPsec)"
add chain=input protocol=udp dst-port=1701 action=accept comment="Accept L2TP"
add chain=input protocol=ipsec-esp action=accept comment="Accept IPsec ESP"
add chain=input protocol=ipsec-ah action=accept comment="Accept IPsec AH"
add chain=input protocol=tcp dst-port=${SSTP_PORT} action=accept comment="Accept SSTP"
add chain=input protocol=tcp dst-port=${OVPN_PORT} action=accept comment="Accept OpenVPN TCP"
add chain=input protocol=udp dst-port=${OVPN_PORT} action=accept comment="Accept OpenVPN UDP"
add chain=input protocol=tcp dst-port=${OVPN_TCP_PORT} action=accept comment="Accept OpenVPN TCP alt port"
add chain=input protocol=udp dst-port=${WG_SERVER_PORT} action=accept comment="Accept WireGuard"

# Final rule
add chain=input action=drop comment="Drop all other input"

# ============================================
# FIREWALL - FORWARD FOR VPN
# ============================================
add chain=forward connection-state=established,related action=accept comment="Accept established forward"
add chain=forward connection-state=invalid action=drop comment="Drop invalid forward"
add chain=forward src-address=${VPN_POOL} action=accept comment="Accept forward from VPN"
add chain=forward src-address=${WG_NETWORK} action=accept comment="Accept forward from WireGuard"
add chain=forward action=drop comment="Drop all other forward"

# ============================================
# AUTO-BACKUP CONFIGURATION
# ============================================
/system script add name=backup-script source="/system backup save name=auto-backup"
/system scheduler add name=daily-backup interval=1d on-event=backup-script start-time=03:00:00

# ============================================
# LOGGING
# ============================================
/system logging add topics=firewall action=memory
/system logging add topics=error action=memory
/system logging add topics=warning action=memory
/system logging add topics=pptp action=memory
/system logging add topics=l2tp action=memory
/system logging add topics=sstp action=memory
/system logging add topics=ovpn action=memory

# ============================================
# NAT - MASQUERADE FOR ALL OUTGOING TRAFFIC
# ============================================
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade comment="NAT for all outgoing traffic"

# ============================================
# SECURITY - REMOVE AUTORUN AFTER EXECUTION
# ============================================
/file remove [find name~"autorun"]
EOF

sync

log_debug "autorun.scr created"

if [[ ! -s "$MOUNT_POINT/rw/autorun.scr" ]]; then
    log_error "autorun.scr is empty or not created!"
    umount "$MOUNT_POINT"
    exit 1
fi

sync
umount "$MOUNT_POINT"
sync

# Check MD5 after modification
MODIFIED_MD5=$(md5sum "$CHR_IMG_MOD" | awk '{print $1}')
log_debug "MD5 after modification: $MODIFIED_MD5"

# Check MBR after modification
MBR_SIG_MOD=$(xxd -s 510 -l 2 -p "$CHR_IMG_MOD")
if [[ "$MBR_SIG_MOD" != "55aa" ]]; then
    log_error "MBR corrupted after modification! Signature: $MBR_SIG_MOD"
    exit 1
fi

log_debug "MBR after modification: OK"
FINAL_IMG="$CHR_IMG_MOD"
log_info "VPN configuration prepared ✓"

# ============================================
# FINAL CONFIRMATION
# ============================================
echo ""
echo "============================================"
echo -e "${YELLOW}        POINT OF NO RETURN!${NC}"
echo "============================================"
echo ""
echo "Image:    $FINAL_IMG"
echo "Disk:     $DISK_DEVICE ($DISK_SIZE)"
echo "IP:       $ADDRESS"
echo "Gateway:  $GATEWAY"
echo "Name:     $ROUTER_NAME"
echo "Timezone: $TIMEZONE"
echo ""
echo -e "${GREEN}VPN Servers:${NC}"
echo "  ✓ PPTP       (port 1723)"
echo "  ✓ L2TP/IPsec (port 1701, UDP 500/4500)"
echo "  ✓ SSTP       (port $SSTP_PORT)"
echo "  ✓ OpenVPN    (port $OVPN_PORT UDP/TCP, $OVPN_TCP_PORT TCP)"
echo "  ✓ WireGuard  (port $WG_SERVER_PORT)"
echo ""
echo -e "${CYAN}VPN Credentials:${NC}"
echo "  Username:   $VPN_USER"
echo "  Password:   $VPN_USER_PASSWORD"
echo "  IPsec PSK:  $IPSEC_SECRET"
echo "  VPN Pool:   $VPN_POOL"
echo ""
echo -e "${CYAN}WireGuard:${NC}"
echo "  Server:     ${SERVER_IP}:${WG_SERVER_PORT}"
echo "  Network:    $WG_NETWORK"
echo "  Server PrivKey: $WG_SERVER_PRIVATE_KEY"
echo "  (Add peer manually after receiving client's public key)"
echo ""
echo -e "${RED}ALL DATA ON $DISK_DEVICE WILL BE DESTROYED!${NC}"
echo ""

if [[ "$AUTO_YES" == true ]]; then
    log_warn "Automatic mode (--yes), continuing without confirmation..."
else
    read -p "Type 'YES' to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "Cancelled"
        exit 0
    fi
fi

# ============================================
# WRITE TO DISK
# ============================================
log_info "Writing image to $DISK_DEVICE..."

log_info "Switching filesystem to read-only..."
sync
echo 1 > /proc/sys/kernel/sysrq
echo u > /proc/sysrq-trigger
sleep 2

dd if="$FINAL_IMG" of="$DISK_DEVICE" bs=4M oflag=direct status=progress

log_info "Write completed"

# ============================================
# COMPLETION
# ============================================
echo ""
log_info "=========================================="
log_info "VPN Server installation completed!"
log_info "=========================================="
echo ""
echo "CHR will be available at: ${SERVER_IP}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}        SAVE THIS INFORMATION!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo "Server:        ${SERVER_IP}"
echo "Admin password: ${ADMIN_PASSWORD}"
echo ""
echo "PPTP/L2TP/SSTP/OpenVPN:"
echo "  Username:    ${VPN_USER}"
echo "  Password:    ${VPN_USER_PASSWORD}"
echo "  IPsec PSK:   ${IPSEC_SECRET}"
echo ""
echo "WireGuard:"
echo "  Endpoint:    ${SERVER_IP}:${WG_SERVER_PORT}"
echo "  Server Key:  ${WG_SERVER_PRIVATE_KEY}"
echo "  Network:     ${WG_NETWORK}"
echo "  Get server public key: /interface wireguard print"
echo "  Add peer: /interface wireguard peers add interface=wg0 public-key=CLIENT_KEY allowed-address=10.10.20.2/32"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

if [[ "$AUTO_YES" == true && "$AUTO_REBOOT" == true ]]; then
    log_info "Automatic reboot in 5 seconds..."
    sleep 5
    echo 1 > /proc/sys/kernel/sysrq
    echo s > /proc/sysrq-trigger
    sleep 1
    echo u > /proc/sysrq-trigger
    sleep 1
    echo b > /proc/sysrq-trigger
elif [[ "$AUTO_YES" == true ]]; then
    log_info "Reboot manually: reboot"
else
    read -p "Reboot now? (y/n): " do_reboot
    if [[ "$do_reboot" == "y" ]]; then
        log_info "Rebooting..."
        sleep 2
        echo 1 > /proc/sys/kernel/sysrq
        echo s > /proc/sysrq-trigger
        sleep 1
        echo u > /proc/sysrq-trigger
        sleep 1
        echo b > /proc/sysrq-trigger
    else
        log_info "Reboot manually: reboot"
    fi
fi
