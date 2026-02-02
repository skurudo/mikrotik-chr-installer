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
# PASSWORD GENERATION AND SANITIZATION
# ============================================
generate_password() {
    local length=$1
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

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
ROUTER_NAME="MikroTik-CHR"
TIMEZONE="Europe/Moscow"

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
    echo "CHR installation script with basic security configuration:"
    echo "  - Firewall with SSH/WinBox brute-force protection"
    echo "  - DNS amplification attack protection"
    echo "  - Disable insecure services"
    echo "  - NTP and timezone configuration"
    echo "  - Daily automatic backup"
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
    echo "  -h, --help       Show help"
    echo ""
    echo "Examples:"
    echo "  $0 --yes --reboot                           # Auto-install with basic config"
    echo "  $0 --password MyPass123 --name VPN-Server   # Custom password and name"
    echo "  $0 --timezone America/New_York              # Different timezone"
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
# PASSWORD GENERATION (if not specified)
# ============================================
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(generate_password 16)
    log_info "Generated admin password: $ADMIN_PASSWORD"
fi

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
    
    # Check downloaded file size
    ACTUAL_SIZE=$(stat -c%s "$CHR_ZIP")
    log_debug "Downloaded file size: $ACTUAL_SIZE bytes"
    
    if [[ $ACTUAL_SIZE -lt 30000000 ]]; then
        log_error "File too small, download incomplete"
        exit 1
    fi
    
    # Check file type
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

# Check MBR signature
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
# CREATE AUTORUN WITH BASIC CONFIGURATION
# ============================================
log_info "Creating autorun.scr with basic security configuration..."

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

# Create autorun (no comments for RouterOS compatibility)
cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=ether1
/ip route add dst-address=${GATEWAY}/32 gateway=ether1
/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY}
/ip dns set servers=${DNS_SERVERS}
/user set 0 name=admin password=${ADMIN_PASSWORD}
/system identity set name=${ROUTER_NAME}
/system clock set time-zone-name=${TIMEZONE}
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set ssh disabled=no port=22
/ip service set winbox disabled=no
/ip firewall filter add chain=input connection-state=established,related action=accept
/ip firewall filter add chain=input connection-state=invalid action=drop
/ip firewall filter add chain=input protocol=tcp dst-port=22 src-address-list=ssh_blacklist action=drop
/ip firewall filter add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage3 action=add-src-to-address-list address-list=ssh_blacklist address-list-timeout=1w
/ip firewall filter add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage2 action=add-src-to-address-list address-list=ssh_stage3 address-list-timeout=1m
/ip firewall filter add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage1 action=add-src-to-address-list address-list=ssh_stage2 address-list-timeout=1m
/ip firewall filter add chain=input protocol=tcp dst-port=22 connection-state=new action=add-src-to-address-list address-list=ssh_stage1 address-list-timeout=1m
/ip firewall filter add chain=input protocol=tcp dst-port=8291 src-address-list=winbox_blacklist action=drop
/ip firewall filter add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage3 action=add-src-to-address-list address-list=winbox_blacklist address-list-timeout=1w
/ip firewall filter add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage2 action=add-src-to-address-list address-list=winbox_stage3 address-list-timeout=1m
/ip firewall filter add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage1 action=add-src-to-address-list address-list=winbox_stage2 address-list-timeout=1m
/ip firewall filter add chain=input protocol=tcp dst-port=8291 connection-state=new action=add-src-to-address-list address-list=winbox_stage1 address-list-timeout=1m
/ip dns set allow-remote-requests=no
/ip firewall filter add chain=input protocol=udp dst-port=53 action=drop
/ip firewall filter add chain=input protocol=tcp dst-port=53 action=drop
/ip firewall filter add chain=input protocol=icmp action=accept
/ip firewall filter add chain=input protocol=tcp dst-port=22 action=accept
/ip firewall filter add chain=input protocol=tcp dst-port=8291 action=accept
/ip firewall filter add chain=input action=drop
/system script add name=backup-script source="/system backup save name=auto-backup"
/system scheduler add name=daily-backup interval=1d on-event=backup-script start-time=03:00:00
/system logging add topics=firewall action=memory
/system logging add topics=error action=memory
/system logging add topics=warning action=memory
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
/file remove [find name~"autorun"]
EOF

sync

log_debug "autorun.scr created:"
cat "$MOUNT_POINT/rw/autorun.scr"

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
log_info "Basic configuration prepared ✓"

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
echo -e "${GREEN}Basic configuration includes:${NC}"
echo "  ✓ Firewall with brute-force protection (SSH, WinBox)"
echo "  ✓ DNS amplification attack protection"
echo "  ✓ Disable insecure services"
echo "  ✓ NTP configuration (pool.ntp.org)"
echo "  ✓ Daily auto-backup (03:00)"
echo "  ✓ Logging firewall/error/warning"
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
log_info "CHR installation with basic config completed!"
log_info "=========================================="
echo ""
echo "CHR will be available at: ${ADDRESS%/*}"
echo "Admin password: ${ADMIN_PASSWORD}"
echo ""
echo -e "${GREEN}Configured:${NC}"
echo "  • Router name: $ROUTER_NAME"
echo "  • Timezone: $TIMEZONE"
echo "  • Firewall with brute-force protection"
echo "  • DNS amplification protection"
echo "  • Auto-backup daily at 03:00"
echo ""

if [[ "$AUTO_YES" == true && "$AUTO_REBOOT" == true ]]; then
    log_info "Automatic reboot in 3 seconds..."
    sleep 3
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
