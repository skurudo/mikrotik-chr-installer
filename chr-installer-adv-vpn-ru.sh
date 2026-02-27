#!/bin/bash
set -e

# Цвета для вывода
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
# ГЕНЕРАЦИЯ КЛЮЧЕЙ И ПАРОЛЕЙ
# ============================================
generate_password() {
    local length=$1
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_wireguard_key() {
    # Генерация WireGuard ключей через base64
    # Приватный ключ - 32 байта случайных данных в base64
    head -c 32 /dev/urandom | base64
}

# ============================================
# САНИТИЗАЦИЯ ВХОДНЫХ ДАННЫХ
# ============================================
sanitize_input() {
    local input="$1"
    # Удаляем опасные символы: ; " ' ` $ \ / и переносы строк
    echo "$input" | tr -d ';"'\''`$\\/\n\r' | head -c 64
}

# ============================================
# КОНФИГУРАЦИЯ
# ============================================
CHR_VERSION="7.16.1"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
CHR_ZIP="chr-${CHR_VERSION}.img.zip"
CHR_IMG="chr-${CHR_VERSION}.img"
WORK_DIR="/tmp/chr-install"
MOUNT_POINT="/mnt/chr"

# Настройки CHR (пароль генерируется автоматически если не указан)
ADMIN_PASSWORD=""
DNS_SERVERS="8.8.8.8,8.8.4.4"
ROUTER_NAME="MikroTik-VPN"
TIMEZONE="Europe/Moscow"

# VPN настройки
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

# Флаги
FORCE_DOWNLOAD=false
AUTO_YES=false
AUTO_REBOOT=false

# ============================================
# ПАРСИНГ АРГУМЕНТОВ
# ============================================
usage() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Скрипт установки CHR как VPN-сервера со всеми протоколами:"
    echo "  - PPTP (порт 1723)"
    echo "  - L2TP/IPsec (порт 1701, UDP 500/4500)"
    echo "  - SSTP (порт 8443)"
    echo "  - OpenVPN (порт 1194 UDP/TCP, 1195 TCP)"
    echo "  - WireGuard (порт 51820)"
    echo ""
    echo "Опции:"
    echo "  --force          Принудительно скачать образ заново"
    echo "  --yes, -y        Без подтверждений (автоматический режим)"
    echo "  --reboot         Автоматическая перезагрузка (требует --yes)"
    echo "  --version VER    Версия CHR (по умолчанию: $CHR_VERSION)"
    echo "  --password PASS  Пароль admin (генерируется автоматически)"
    echo "  --name NAME      Имя роутера (по умолчанию: $ROUTER_NAME)"
    echo "  --timezone TZ    Часовой пояс (по умолчанию: $TIMEZONE)"
    echo "  --dns SERVERS    DNS серверы (по умолчанию: $DNS_SERVERS)"
    echo "  --vpn-user USER  VPN пользователь (по умолчанию: $VPN_USER)"
    echo "  --vpn-pass PASS  Пароль VPN (генерируется автоматически)"
    echo "  --vpn-pool CIDR  VPN пул адресов (по умолчанию: $VPN_POOL)"
    echo "  --ipsec-secret S IPsec Pre-Shared Key (генерируется автоматически)"
    echo "  --wg-port PORT   WireGuard порт (по умолчанию: $WG_SERVER_PORT)"
    echo "  -h, --help       Показать справку"
    echo ""
    echo "Примеры:"
    echo "  $0 --yes --reboot                    # Автоустановка VPN сервера"
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
            log_error "Неизвестная опция: $1"
            usage
            ;;
    esac
done

# ============================================
# ГЕНЕРАЦИЯ КЛЮЧЕЙ (если не заданы)
# ============================================
log_info "Генерация ключей и паролей..."

if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(generate_password 16)
    log_info "Сгенерирован пароль admin: $ADMIN_PASSWORD"
fi

if [[ -z "$VPN_USER_PASSWORD" ]]; then
    VPN_USER_PASSWORD=$(generate_password 16)
    log_info "Сгенерирован пароль VPN: $VPN_USER_PASSWORD"
fi

if [[ -z "$IPSEC_SECRET" ]]; then
    IPSEC_SECRET=$(generate_password 12)
    log_info "Сгенерирован IPsec PSK: $IPSEC_SECRET"
fi

# WireGuard ключ сервера
WG_SERVER_PRIVATE_KEY=$(generate_wireguard_key)

log_info "Сгенерирован WireGuard ключ сервера"

# ============================================
# ПРОВЕРКА ROOT
# ============================================
if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен запускаться от root"
    exit 1
fi

# ============================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ
# ============================================
log_info "Проверка зависимостей..."

REQUIRED_TOOLS="wget unzip fdisk dd mount umount file md5sum xxd"
MISSING_TOOLS=""

for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [[ -n "$MISSING_TOOLS" ]]; then
    log_warn "Отсутствуют утилиты:$MISSING_TOOLS"
    log_info "Попытка установки..."
    
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wget unzip fdisk coreutils mount xxd
    elif command -v yum &> /dev/null; then
        yum install -y wget unzip util-linux coreutils vim-common
    elif command -v dnf &> /dev/null; then
        dnf install -y wget unzip util-linux coreutils vim-common
    else
        log_error "Установи вручную:$MISSING_TOOLS"
        exit 1
    fi
fi

log_info "Все зависимости в порядке"

# ============================================
# ПОДГОТОВКА РАБОЧЕЙ ДИРЕКТОРИИ
# ============================================
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

log_info "Рабочая директория: $WORK_DIR"
log_debug "Свободное место: $(df -h "$WORK_DIR" | tail -1 | awk '{print $4}')"

# ============================================
# СКАЧИВАНИЕ ОБРАЗА
# ============================================
if [[ "$FORCE_DOWNLOAD" == true ]] || [[ ! -f "$CHR_IMG" ]]; then
    rm -f "$CHR_ZIP" "$CHR_IMG" "${CHR_IMG}.modified"
    
    log_info "Скачивание CHR ${CHR_VERSION}..."
    wget --progress=bar:force -O "$CHR_ZIP" "$CHR_URL"
    
    ACTUAL_SIZE=$(stat -c%s "$CHR_ZIP")
    log_debug "Размер скачанного файла: $ACTUAL_SIZE байт"
    
    if [[ $ACTUAL_SIZE -lt 30000000 ]]; then
        log_error "Файл слишком маленький, скачивание неполное"
        exit 1
    fi
    
    FILE_TYPE=$(file "$CHR_ZIP")
    log_debug "Тип файла: $FILE_TYPE"
    
    if echo "$FILE_TYPE" | grep -q "Zip archive"; then
        log_info "Распаковка ZIP..."
        unzip -o "$CHR_ZIP"
    elif echo "$FILE_TYPE" | grep -q "gzip"; then
        log_info "Распаковка GZIP..."
        gunzip -c "$CHR_ZIP" > "$CHR_IMG"
    else
        log_error "Неизвестный формат: $FILE_TYPE"
        exit 1
    fi
    
    rm -f "$CHR_ZIP"
else
    log_info "Используется существующий образ: $CHR_IMG"
fi

# ============================================
# ВАЛИДАЦИЯ ОБРАЗА
# ============================================
log_info "Валидация образа..."

if [[ ! -f "$CHR_IMG" ]]; then
    log_error "Образ не найден!"
    ls -la "$WORK_DIR"
    exit 1
fi

IMG_SIZE=$(stat -c%s "$CHR_IMG")
log_debug "Размер образа: $IMG_SIZE байт ($(( IMG_SIZE / 1024 / 1024 )) MB)"

MBR_SIG=$(xxd -s 510 -l 2 -p "$CHR_IMG")
if [[ "$MBR_SIG" != "55aa" ]]; then
    log_error "Неверная MBR сигнатура: $MBR_SIG (ожидается 55aa)"
    exit 1
fi
log_debug "MBR сигнатура: OK (55aa)"

ORIGINAL_MD5=$(md5sum "$CHR_IMG" | awk '{print $1}')
log_info "MD5 оригинального образа: $ORIGINAL_MD5"

log_info "Образ прошёл валидацию ✓"

# ============================================
# ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ПАРАМЕТРОВ
# ============================================
log_info "Определение сетевых параметров..."

INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
ADDRESS=$(ip addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n1)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)
SERVER_IP="${ADDRESS%/*}"
NETMASK="${ADDRESS#*/}"

if [[ -z "$INTERFACE" || -z "$ADDRESS" || -z "$GATEWAY" ]]; then
    log_error "Не удалось определить сетевые параметры"
    log_error "INTERFACE=$INTERFACE ADDRESS=$ADDRESS GATEWAY=$GATEWAY"
    exit 1
fi

# Функция проверки - находится ли gateway в той же подсети
check_same_subnet() {
    local ip="$1"
    local gw="$2"
    local mask="$3"
    
    # Конвертируем IP в число
    IFS='.' read -r i1 i2 i3 i4 <<< "$ip"
    IFS='.' read -r g1 g2 g3 g4 <<< "$gw"
    
    # Вычисляем маску
    local full_mask=$(( 0xFFFFFFFF << (32 - mask) & 0xFFFFFFFF ))
    local m1=$(( (full_mask >> 24) & 255 ))
    local m2=$(( (full_mask >> 16) & 255 ))
    local m3=$(( (full_mask >> 8) & 255 ))
    local m4=$(( full_mask & 255 ))
    
    # Сравниваем сетевые части
    if [[ $((i1 & m1)) -eq $((g1 & m1)) ]] && \
       [[ $((i2 & m2)) -eq $((g2 & m2)) ]] && \
       [[ $((i3 & m3)) -eq $((g3 & m3)) ]] && \
       [[ $((i4 & m4)) -eq $((g4 & m4)) ]]; then
        return 0  # В одной подсети
    else
        return 1  # В разных подсетях
    fi
}

# Проверяем, находится ли gateway в той же подсети
if check_same_subnet "$SERVER_IP" "$GATEWAY" "$NETMASK"; then
    GATEWAY_IN_SUBNET=true
    log_info "Gateway в той же подсети - используем простой маршрут"
else
    GATEWAY_IN_SUBNET=false
    log_info "Gateway в другой подсети - используем recursive routing (scope)"
fi

log_info "Интерфейс: $INTERFACE | Адрес: $ADDRESS | Шлюз: $GATEWAY"

# ============================================
# ОПРЕДЕЛЕНИЕ ДИСКА
# ============================================
log_info "Определение целевого диска..."

echo ""
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "(NAME|disk)"
echo ""

# Определяем диск по корневому разделу (исключает fd0, sr0 и т.д.)
DISK_DEVICE=""
ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null)
if [[ -n "$ROOT_PART" ]]; then
    DISK_DEVICE=$(lsblk -ndo PKNAME "$ROOT_PART" 2>/dev/null)
    [[ -n "$DISK_DEVICE" ]] && DISK_DEVICE="/dev/$DISK_DEVICE"
fi
# Fallback: первый реальный диск (исключаем floppy, cdrom, loop)
if [[ -z "$DISK_DEVICE" ]]; then
    DISK_DEVICE=$(lsblk -ndo NAME,TYPE | awk '$2=="disk" && $1!~/^(fd|sr|loop)/ {print "/dev/"$1; exit}')
fi

if [[ -z "$DISK_DEVICE" ]]; then
    log_error "Диск не найден"
    exit 1
fi

DISK_SIZE=$(lsblk -ndo SIZE "$DISK_DEVICE")
log_warn "Целевой диск: $DISK_DEVICE ($DISK_SIZE)"

# ============================================
# СОЗДАНИЕ AUTORUN С VPN НАСТРОЙКОЙ
# ============================================
log_info "Создание autorun.scr с настройкой VPN серверов..."

CHR_IMG_MOD="${CHR_IMG}.modified"
cp "$CHR_IMG" "$CHR_IMG_MOD"

mkdir -p "$MOUNT_POINT"

OFFSET_SECTORS=$(fdisk -l "$CHR_IMG_MOD" 2>/dev/null | grep "${CHR_IMG_MOD}2" | awk '{print $2}')
if [[ -z "$OFFSET_SECTORS" ]]; then
    OFFSET_BYTES=33571840
else
    OFFSET_BYTES=$((OFFSET_SECTORS * 512))
fi

log_debug "Монтирование с offset: $OFFSET_BYTES"

mount -o loop,offset="$OFFSET_BYTES" "$CHR_IMG_MOD" "$MOUNT_POINT"

if [[ ! -d "$MOUNT_POINT/rw" ]]; then
    log_warn "Директория /rw не существует, создаём..."
    mkdir -p "$MOUNT_POINT/rw"
fi

# Создание autorun (без комментариев для совместимости с RouterOS)
# Формируем команды маршрута в зависимости от расположения gateway
if [[ "$GATEWAY_IN_SUBNET" == "true" ]]; then
    # Gateway в той же подсети - простой маршрут
    ROUTE_COMMANDS="/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY}"
else
    # Gateway в другой подсети - recursive routing через scope
    ROUTE_COMMANDS="/ip route add dst-address=${GATEWAY}/32 gateway=ether1 scope=10
/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY} target-scope=11"
fi

cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=ether1
${ROUTE_COMMANDS}
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
/ip pool add name=vpn-pool ranges=${VPN_POOL_START}-${VPN_POOL_END}
/ppp profile add name=vpn-profile local-address=${VPN_LOCAL_IP} remote-address=vpn-pool dns-server=${DNS_SERVERS} use-encryption=yes
/ppp secret add name=${VPN_USER} password=${VPN_USER_PASSWORD} profile=vpn-profile service=any
/interface pptp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2
/interface l2tp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2 use-ipsec=yes ipsec-secret=${IPSEC_SECRET}
/certificate add name=sstp-ca common-name=sstp-ca days-valid=3650 key-size=2048 key-usage=key-cert-sign,crl-sign
/certificate sign sstp-ca
/certificate add name=sstp-server common-name=${SERVER_IP} days-valid=3650 key-size=2048 key-usage=digital-signature,key-encipherment,tls-server
/certificate sign sstp-server ca=sstp-ca
/certificate set sstp-server trusted=yes
/interface sstp-server server set enabled=yes default-profile=vpn-profile authentication=mschap2 certificate=sstp-server port=${SSTP_PORT}
/certificate add name=ovpn-ca common-name=ovpn-ca days-valid=3650 key-size=2048 key-usage=key-cert-sign,crl-sign
/certificate sign ovpn-ca
/certificate add name=ovpn-server common-name=ovpn-server days-valid=3650 key-size=2048 key-usage=digital-signature,key-encipherment,tls-server
/certificate sign ovpn-server ca=ovpn-ca
/certificate set ovpn-server trusted=yes
/certificate add name=ovpn-client common-name=ovpn-client days-valid=3650 key-size=2048 key-usage=tls-client
/certificate sign ovpn-client ca=ovpn-ca
/interface ovpn-server server set enabled=yes default-profile=vpn-profile certificate=ovpn-server auth=sha256 cipher=aes256-cbc port=${OVPN_PORT} require-client-certificate=no
/interface wireguard add name=wg0 listen-port=${WG_SERVER_PORT} private-key="${WG_SERVER_PRIVATE_KEY}"
/ip address add address=${WG_NETWORK%.*}.1/24 interface=wg0
/ip firewall nat add chain=srcnat src-address=${VPN_POOL} action=masquerade
/ip firewall nat add chain=srcnat src-address=${WG_NETWORK} action=masquerade
/ip firewall nat add chain=dstnat protocol=tcp dst-port=${OVPN_TCP_PORT} action=redirect to-ports=${OVPN_PORT}
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
/ip firewall filter add chain=input protocol=tcp dst-port=1723 action=accept
/ip firewall filter add chain=input protocol=gre action=accept
/ip firewall filter add chain=input protocol=udp dst-port=500 action=accept
/ip firewall filter add chain=input protocol=udp dst-port=4500 action=accept
/ip firewall filter add chain=input protocol=udp dst-port=1701 action=accept
/ip firewall filter add chain=input protocol=ipsec-esp action=accept
/ip firewall filter add chain=input protocol=ipsec-ah action=accept
/ip firewall filter add chain=input protocol=tcp dst-port=${SSTP_PORT} action=accept
/ip firewall filter add chain=input protocol=tcp dst-port=${OVPN_PORT} action=accept
/ip firewall filter add chain=input protocol=udp dst-port=${OVPN_PORT} action=accept
/ip firewall filter add chain=input protocol=tcp dst-port=${OVPN_TCP_PORT} action=accept
/ip firewall filter add chain=input protocol=udp dst-port=${WG_SERVER_PORT} action=accept
/ip firewall filter add chain=input action=drop
/ip firewall filter add chain=forward connection-state=established,related action=accept
/ip firewall filter add chain=forward connection-state=invalid action=drop
/ip firewall filter add chain=forward src-address=${VPN_POOL} action=accept
/ip firewall filter add chain=forward src-address=${WG_NETWORK} action=accept
/ip firewall filter add chain=forward action=drop
/system script add name=backup-script source="/system backup save name=auto-backup"
/system scheduler add name=daily-backup interval=1d on-event=backup-script start-time=03:00:00
/system logging add topics=firewall action=memory
/system logging add topics=error action=memory
/system logging add topics=warning action=memory
/system logging add topics=pptp action=memory
/system logging add topics=l2tp action=memory
/system logging add topics=sstp action=memory
/system logging add topics=ovpn action=memory
/ip firewall nat add chain=srcnat out-interface=ether1 action=masquerade
/file remove [find name~"autorun"]
EOF

sync

log_debug "autorun.scr создан"

if [[ ! -s "$MOUNT_POINT/rw/autorun.scr" ]]; then
    log_error "autorun.scr пустой или не создан!"
    umount "$MOUNT_POINT"
    exit 1
fi

sync
umount "$MOUNT_POINT"
sync

# Проверка MD5 после модификации
MODIFIED_MD5=$(md5sum "$CHR_IMG_MOD" | awk '{print $1}')
log_debug "MD5 после модификации: $MODIFIED_MD5"

# Проверка MBR после модификации
MBR_SIG_MOD=$(xxd -s 510 -l 2 -p "$CHR_IMG_MOD")
if [[ "$MBR_SIG_MOD" != "55aa" ]]; then
    log_error "MBR повреждён после модификации! Сигнатура: $MBR_SIG_MOD"
    exit 1
fi

log_debug "MBR после модификации: OK"
FINAL_IMG="$CHR_IMG_MOD"
log_info "VPN настройка подготовлена ✓"

# ============================================
# ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ
# ============================================
echo ""
echo "============================================"
echo -e "${YELLOW}        ТОЧКА НЕВОЗВРАТА!${NC}"
echo "============================================"
echo ""
echo "Образ:        $FINAL_IMG"
echo "Диск:         $DISK_DEVICE ($DISK_SIZE)"
echo "IP:           $ADDRESS"
echo "Шлюз:         $GATEWAY"
echo "Имя:          $ROUTER_NAME"
echo "Часовой пояс: $TIMEZONE"
echo ""
echo -e "${GREEN}VPN серверы:${NC}"
echo "  ✓ PPTP       (порт 1723)"
echo "  ✓ L2TP/IPsec (порт 1701, UDP 500/4500)"
echo "  ✓ SSTP       (порт $SSTP_PORT)"
echo "  ✓ OpenVPN    (порт $OVPN_PORT UDP/TCP, $OVPN_TCP_PORT TCP)"
echo "  ✓ WireGuard  (порт $WG_SERVER_PORT)"
echo ""
echo -e "${CYAN}Учётные данные VPN:${NC}"
echo "  Пользователь: $VPN_USER"
echo "  Пароль:       $VPN_USER_PASSWORD"
echo "  IPsec PSK:    $IPSEC_SECRET"
echo "  VPN пул:      $VPN_POOL"
echo ""
echo -e "${CYAN}WireGuard:${NC}"
echo "  Сервер:       ${SERVER_IP}:${WG_SERVER_PORT}"
echo "  Сеть:         $WG_NETWORK"
echo "  Server PrivKey: $WG_SERVER_PRIVATE_KEY"
echo "  (Peer добавить вручную после получения публичного ключа клиента)"
echo ""
echo -e "${RED}ВСЕ ДАННЫЕ НА $DISK_DEVICE БУДУТ УНИЧТОЖЕНЫ!${NC}"
echo ""

if [[ "$AUTO_YES" == true ]]; then
    log_warn "Автоматический режим (--yes), продолжаем без подтверждения..."
else
    read -p "Введи 'YES' для продолжения: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "Отменено"
        exit 0
    fi
fi

# ============================================
# ЗАПИСЬ НА ДИСК
# ============================================
log_info "Запись образа на $DISK_DEVICE..."

log_info "Перевод файловой системы в read-only..."
sync
echo 1 > /proc/sys/kernel/sysrq
echo u > /proc/sysrq-trigger
sleep 2

dd if="$FINAL_IMG" of="$DISK_DEVICE" bs=4M oflag=direct status=progress

log_info "Запись завершена"

# ============================================
# ЗАВЕРШЕНИЕ
# ============================================
echo ""
log_info "=========================================="
log_info "Установка VPN-сервера завершена!"
log_info "=========================================="
echo ""
echo "CHR будет доступен: ${SERVER_IP}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}        СОХРАНИТЕ ЭТИ ДАННЫЕ!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo "Сервер:        ${SERVER_IP}"
echo "Admin пароль:  ${ADMIN_PASSWORD}"
echo ""
echo "PPTP/L2TP/SSTP/OpenVPN:"
echo "  Пользователь: ${VPN_USER}"
echo "  Пароль:       ${VPN_USER_PASSWORD}"
echo "  IPsec PSK:    ${IPSEC_SECRET}"
echo ""
echo "WireGuard:"
echo "  Endpoint:     ${SERVER_IP}:${WG_SERVER_PORT}"
echo "  Server Key:   ${WG_SERVER_PRIVATE_KEY}"
echo "  Сеть:         ${WG_NETWORK}"
echo "  Публичный ключ сервера получить: /interface wireguard print"
echo "  Добавить peer: /interface wireguard peers add interface=wg0 public-key=КЛЮЧ_КЛИЕНТА allowed-address=10.10.20.2/32"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

if [[ "$AUTO_YES" == true && "$AUTO_REBOOT" == true ]]; then
    log_info "Автоматическая перезагрузка через 5 секунд..."
    sleep 5
    echo 1 > /proc/sys/kernel/sysrq
    echo s > /proc/sysrq-trigger
    sleep 1
    echo u > /proc/sysrq-trigger
    sleep 1
    echo b > /proc/sysrq-trigger
elif [[ "$AUTO_YES" == true ]]; then
    log_info "Перезагрузи вручную: reboot"
else
    read -p "Перезагрузить сейчас? (y/n): " do_reboot
    if [[ "$do_reboot" == "y" ]]; then
        log_info "Перезагрузка..."
        sleep 2
        echo 1 > /proc/sys/kernel/sysrq
        echo s > /proc/sysrq-trigger
        sleep 1
        echo u > /proc/sysrq-trigger
        sleep 1
        echo b > /proc/sysrq-trigger
    else
        log_info "Перезагрузи вручную: reboot"
    fi
fi
