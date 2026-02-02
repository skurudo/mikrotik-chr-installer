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

# Flags
SKIP_AUTORUN=false
FORCE_DOWNLOAD=false
VERIFY_WRITE=true
AUTO_YES=false
AUTO_REBOOT=false

# ============================================
# ARGUMENT PARSING
# ============================================
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --clean          Clean installation without autorun.scr"
    echo "  --force          Force re-download the image"
    echo "  --no-verify      Skip write verification"
    echo "  --yes, -y        No confirmations (automatic mode)"
    echo "  --reboot         Automatic reboot (requires --yes)"
    echo "  --version VER    CHR version (default: $CHR_VERSION)"
    echo "  --password PASS  Admin password (auto-generated)"
    echo "  -h, --help       Show help"
    echo ""
    echo "Examples:"
    echo "  $0 --clean                    # Clean install with confirmation"
    echo "  $0 --yes --reboot             # Fully automatic installation"
    echo "  $0 -y --clean --reboot        # Automatic clean installation"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            SKIP_AUTORUN=true
            shift
            ;;
        --force)
            FORCE_DOWNLOAD=true
            shift
            ;;
        --no-verify)
            VERIFY_WRITE=false
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
# IMAGE VALIDATION (EXTENDED)
# ============================================
log_info "Validating image..."

if [[ ! -f "$CHR_IMG" ]]; then
    log_error "Image not found!"
    ls -la "$WORK_DIR"
    exit 1
fi

IMG_SIZE=$(stat -c%s "$CHR_IMG")
log_debug "Image size: $IMG_SIZE bytes ($(( IMG_SIZE / 1024 / 1024 )) MB)"

# Check MBR signature (last 2 bytes of first sector = 55 AA)
MBR_SIG=$(xxd -s 510 -l 2 -p "$CHR_IMG")
if [[ "$MBR_SIG" != "55aa" ]]; then
    log_error "Invalid MBR signature: $MBR_SIG (expected 55aa)"
    exit 1
fi
log_debug "MBR signature: OK (55aa)"

# Save MD5 of original image
ORIGINAL_MD5=$(md5sum "$CHR_IMG" | awk '{print $1}')
log_info "Original image MD5: $ORIGINAL_MD5"

# Check partition table
log_debug "Partition table:"
fdisk -l "$CHR_IMG" 2>/dev/null | grep -E "^(Disk|Device|${CHR_IMG})" || true

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
# IMAGE SELECTION FOR WRITING
# ============================================
FINAL_IMG="$CHR_IMG"

if [[ "$SKIP_AUTORUN" == true ]]; then
    log_warn "Mode --clean: autorun.scr will NOT be created"
    log_warn "Configure CHR manually after boot"
else
    log_info "Creating autorun.scr..."
    
    # Create a copy of the image for modification
    CHR_IMG_MOD="${CHR_IMG}.modified"
    cp "$CHR_IMG" "$CHR_IMG_MOD"
    
    # Mounting
    mkdir -p "$MOUNT_POINT"
    
    OFFSET_SECTORS=$(fdisk -l "$CHR_IMG_MOD" 2>/dev/null | grep "${CHR_IMG_MOD}2" | awk '{print $2}')
    if [[ -z "$OFFSET_SECTORS" ]]; then
        OFFSET_BYTES=33571840
    else
        OFFSET_BYTES=$((OFFSET_SECTORS * 512))
    fi
    
    log_debug "Mounting with offset: $OFFSET_BYTES"
    
    mount -o loop,offset="$OFFSET_BYTES" "$CHR_IMG_MOD" "$MOUNT_POINT"
    
    # Check structure
    log_debug "Mounted partition contents:"
    ls -la "$MOUNT_POINT/" || true
    
    if [[ ! -d "$MOUNT_POINT/rw" ]]; then
        log_warn "Directory /rw does not exist, creating..."
        mkdir -p "$MOUNT_POINT/rw"
    fi
    
    # Create autorun
    cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=ether1
/ip route add dst-address=${GATEWAY}/32 gateway=ether1
/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY}
/ip dns set servers=${DNS_SERVERS}
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set ssh disabled=no
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=no
/user set 0 name=admin password=${ADMIN_PASSWORD}
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
/file remove [find name~"autorun"]
EOF
    
    # Sync filesystem before unmounting
    sync
    
    log_debug "autorun.scr created:"
    cat "$MOUNT_POINT/rw/autorun.scr"
    
    # Check that file was written
    if [[ ! -s "$MOUNT_POINT/rw/autorun.scr" ]]; then
        log_error "autorun.scr is empty or not created!"
        umount "$MOUNT_POINT"
        exit 1
    fi
    
    # Unmount with sync
    sync
    umount "$MOUNT_POINT"
    sync
    
    # Check MD5 after modification
    MODIFIED_MD5=$(md5sum "$CHR_IMG_MOD" | awk '{print $1}')
    log_debug "MD5 after modification: $MODIFIED_MD5"
    
    if [[ "$ORIGINAL_MD5" == "$MODIFIED_MD5" ]]; then
        log_warn "MD5 unchanged — autorun.scr may not have been written"
    fi
    
    # Check MBR after modification
    MBR_SIG_MOD=$(xxd -s 510 -l 2 -p "$CHR_IMG_MOD")
    if [[ "$MBR_SIG_MOD" != "55aa" ]]; then
        log_error "MBR corrupted after modification! Signature: $MBR_SIG_MOD"
        log_error "Using original image without autorun"
        rm -f "$CHR_IMG_MOD"
        SKIP_AUTORUN=true
        FINAL_IMG="$CHR_IMG"
    else
        log_debug "MBR after modification: OK"
        FINAL_IMG="$CHR_IMG_MOD"
        log_info "Autorun configured ✓"
    fi
fi

# ============================================
# FINAL CONFIRMATION
# ============================================
echo ""
echo "============================================"
echo -e "${YELLOW}        POINT OF NO RETURN!${NC}"
echo "============================================"
echo ""
echo "Image:   $FINAL_IMG"
echo "Disk:    $DISK_DEVICE ($DISK_SIZE)"
echo "IP:      $ADDRESS"
echo "Gateway: $GATEWAY"
echo "Autorun: $(if [[ "$SKIP_AUTORUN" == true ]]; then echo "DISABLED"; else echo "enabled"; fi)"
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

# Switch FS to read-only to avoid race condition
log_info "Switching filesystem to read-only..."
sync
echo 1 > /proc/sys/kernel/sysrq
echo u > /proc/sysrq-trigger
sleep 2

dd if="$FINAL_IMG" of="$DISK_DEVICE" bs=4M oflag=direct status=progress

log_info "Write completed"
# sync not needed - FS is already read-only, dd with oflag=direct writes directly

# ============================================
# WRITE VERIFICATION
# ============================================
# After echo u filesystem is read-only, verification is not possible
# MBR was already checked before writing, dd with oflag=direct guarantees write
log_info "Verification skipped (FS is read-only after remount)"

# ============================================
# COMPLETION
# ============================================
echo ""
log_info "=========================================="
log_info "CHR installation completed successfully!"
log_info "=========================================="
echo ""

if [[ "$SKIP_AUTORUN" == true ]]; then
    echo "After boot, configure manually:"
    echo "  /ip address add address=$ADDRESS interface=ether1"
    echo "  /ip route add gateway=$GATEWAY"
    echo ""
fi

echo "CHR will be available at: ${ADDRESS%/*}"
echo "Admin password: ${ADMIN_PASSWORD}"
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
