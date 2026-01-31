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
# КОНФИГУРАЦИЯ
# ============================================
CHR_VERSION="7.16.1"
CHR_URL="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"
CHR_ZIP="chr-${CHR_VERSION}.img.zip"
CHR_IMG="chr-${CHR_VERSION}.img"
WORK_DIR="/tmp/chr-install"
MOUNT_POINT="/mnt/chr"

# Настройки CHR
ADMIN_PASSWORD="PASSWORD"
DNS_SERVERS="8.8.8.8,8.8.4.4"
ROUTER_NAME="MikroTik-CHR"
TIMEZONE="Europe/Moscow"

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
    echo "Скрипт установки CHR с базовой настройкой безопасности:"
    echo "  - Файрвол с защитой от брутфорса SSH/WinBox"
    echo "  - Защита от DNS amplification атак"
    echo "  - Отключение небезопасных сервисов"
    echo "  - Настройка NTP и часового пояса"
    echo "  - Ежедневный автобэкап конфигурации"
    echo ""
    echo "Опции:"
    echo "  --force          Принудительно скачать образ заново"
    echo "  --yes, -y        Без подтверждений (автоматический режим)"
    echo "  --reboot         Автоматическая перезагрузка (требует --yes)"
    echo "  --version VER    Версия CHR (по умолчанию: $CHR_VERSION)"
    echo "  --password PASS  Пароль admin (по умолчанию: $ADMIN_PASSWORD)"
    echo "  --name NAME      Имя роутера (по умолчанию: $ROUTER_NAME)"
    echo "  --timezone TZ    Часовой пояс (по умолчанию: $TIMEZONE)"
    echo "  --dns SERVERS    DNS серверы (по умолчанию: $DNS_SERVERS)"
    echo "  -h, --help       Показать справку"
    echo ""
    echo "Примеры:"
    echo "  $0 --yes --reboot                           # Автоустановка с базовой настройкой"
    echo "  $0 --password MyPass123 --name VPN-Server   # Кастомный пароль и имя"
    echo "  $0 --timezone America/New_York              # Другой часовой пояс"
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
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        --name)
            ROUTER_NAME="$2"
            shift 2
            ;;
        --timezone)
            TIMEZONE="$2"
            shift 2
            ;;
        --dns)
            DNS_SERVERS="$2"
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
    
    # Проверка размера скачанного файла
    ACTUAL_SIZE=$(stat -c%s "$CHR_ZIP")
    log_debug "Размер скачанного файла: $ACTUAL_SIZE байт"
    
    if [[ $ACTUAL_SIZE -lt 30000000 ]]; then
        log_error "Файл слишком маленький, скачивание неполное"
        exit 1
    fi
    
    # Проверка типа файла
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

# Проверка MBR сигнатуры
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

if [[ -z "$INTERFACE" || -z "$ADDRESS" || -z "$GATEWAY" ]]; then
    log_error "Не удалось определить сетевые параметры"
    log_error "INTERFACE=$INTERFACE ADDRESS=$ADDRESS GATEWAY=$GATEWAY"
    exit 1
fi

log_info "Интерфейс: $INTERFACE | Адрес: $ADDRESS | Шлюз: $GATEWAY"

# ============================================
# ОПРЕДЕЛЕНИЕ ДИСКА
# ============================================
log_info "Определение целевого диска..."

echo ""
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E "(NAME|disk)"
echo ""

DISK_DEVICE=$(lsblk -ndo NAME,TYPE | grep disk | head -n1 | awk '{print "/dev/"$1}')

if [[ -z "$DISK_DEVICE" ]]; then
    log_error "Диск не найден"
    exit 1
fi

DISK_SIZE=$(lsblk -ndo SIZE "$DISK_DEVICE")
log_warn "Целевой диск: $DISK_DEVICE ($DISK_SIZE)"

# ============================================
# СОЗДАНИЕ AUTORUN С БАЗОВОЙ НАСТРОЙКОЙ
# ============================================
log_info "Создание autorun.scr с базовой настройкой безопасности..."

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

# Создание расширенного autorun с базовой настройкой
cat > "$MOUNT_POINT/rw/autorun.scr" <<EOF
# ============================================
# БАЗОВАЯ НАСТРОЙКА - СЕТЬ
# ============================================
/ip dns set servers=${DNS_SERVERS}
/ip dhcp-client remove [find]
/ip address add address=${ADDRESS} interface=[/interface ethernet find where name=ether1]
/ip route add gateway=${GATEWAY}

# ============================================
# ПОЛЬЗОВАТЕЛЬ И СИСТЕМА
# ============================================
/user set 0 name=admin password=${ADMIN_PASSWORD}
/system identity set name=${ROUTER_NAME}
/system clock set time-zone-name=${TIMEZONE}
/system ntp client set enabled=yes
/system ntp client servers add address=pool.ntp.org

# ============================================
# СЕРВИСЫ - ОТКЛЮЧАЕМ НЕБЕЗОПАСНЫЕ
# ============================================
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set ssh disabled=no port=22
/ip service set winbox disabled=no

# ============================================
# ФАЙРВОЛ - ЗАЩИТА ОТ БРУТФОРСА SSH
# ============================================
/ip firewall filter
add chain=input protocol=tcp dst-port=22 src-address-list=ssh_blacklist action=drop comment="Drop SSH brute force"
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage3 action=add-src-to-address-list address-list=ssh_blacklist address-list-timeout=1w
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage2 action=add-src-to-address-list address-list=ssh_stage3 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new src-address-list=ssh_stage1 action=add-src-to-address-list address-list=ssh_stage2 address-list-timeout=1m
add chain=input protocol=tcp dst-port=22 connection-state=new action=add-src-to-address-list address-list=ssh_stage1 address-list-timeout=1m

# ============================================
# ФАЙРВОЛ - ЗАЩИТА ОТ БРУТФОРСА WINBOX
# ============================================
add chain=input protocol=tcp dst-port=8291 src-address-list=winbox_blacklist action=drop comment="Drop WinBox brute force"
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage3 action=add-src-to-address-list address-list=winbox_blacklist address-list-timeout=1w
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage2 action=add-src-to-address-list address-list=winbox_stage3 address-list-timeout=1m
add chain=input protocol=tcp dst-port=8291 connection-state=new src-address-list=winbox_stage1 action=add-src-to-address-list address-list=winbox_stage2 address-list-timeout=1m
add chain=input protocol=tcp dst-port=8291 connection-state=new action=add-src-to-address-list address-list=winbox_stage1 address-list-timeout=1m

# ============================================
# ФАЙРВОЛ - ЗАЩИТА ОТ DNS AMPLIFICATION
# ============================================
# Отключаем DNS сервер для внешних запросов
/ip dns set allow-remote-requests=no

# Блокируем входящие DNS запросы извне (защита от использования как DNS reflector)
/ip firewall filter
add chain=input protocol=udp dst-port=53 action=drop comment="Drop external DNS queries (anti-amplification)"
add chain=input protocol=tcp dst-port=53 action=drop comment="Drop external DNS TCP queries"

# ============================================
# ФАЙРВОЛ - БАЗОВЫЕ ПРАВИЛА
# ============================================
add chain=input connection-state=established,related action=accept comment="Accept established connections"
add chain=input connection-state=invalid action=drop comment="Drop invalid connections"
add chain=input protocol=icmp action=accept comment="Accept ICMP (ping)"
add chain=input protocol=tcp dst-port=22 action=accept comment="Accept SSH"
add chain=input protocol=tcp dst-port=8291 action=accept comment="Accept WinBox"
add chain=input action=drop comment="Drop all other input"

# ============================================
# АВТОБЭКАП КОНФИГУРАЦИИ
# ============================================
/system script add name=backup-script source="/system backup save name=auto-backup"
/system scheduler add name=daily-backup interval=1d on-event=backup-script start-time=03:00:00

# ============================================
# ЛОГИРОВАНИЕ
# ============================================
/system logging add topics=firewall action=memory
/system logging add topics=error action=memory
/system logging add topics=warning action=memory
EOF

sync

log_debug "autorun.scr создан:"
cat "$MOUNT_POINT/rw/autorun.scr"

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
log_info "Базовая настройка подготовлена ✓"

# ============================================
# ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ
# ============================================
echo ""
echo "============================================"
echo -e "${YELLOW}        ТОЧКА НЕВОЗВРАТА!${NC}"
echo "============================================"
echo ""
echo "Образ:      $FINAL_IMG"
echo "Диск:       $DISK_DEVICE ($DISK_SIZE)"
echo "IP:         $ADDRESS"
echo "Шлюз:       $GATEWAY"
echo "Имя:        $ROUTER_NAME"
echo "Часовой пояс: $TIMEZONE"
echo ""
echo -e "${GREEN}Базовая настройка включает:${NC}"
echo "  ✓ Файрвол с защитой от брутфорса (SSH, WinBox)"
echo "  ✓ Защита от DNS amplification атак"
echo "  ✓ Отключение небезопасных сервисов"
echo "  ✓ Настройка NTP (pool.ntp.org)"
echo "  ✓ Ежедневный автобэкап (03:00)"
echo "  ✓ Логирование firewall/error/warning"
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
log_info "Установка CHR с базовой настройкой завершена!"
log_info "=========================================="
echo ""
echo "CHR будет доступен: ${ADDRESS%/*}"
echo ""
echo -e "${GREEN}Настроено:${NC}"
echo "  • Имя роутера: $ROUTER_NAME"
echo "  • Часовой пояс: $TIMEZONE"
echo "  • Файрвол с защитой от брутфорса"
echo "  • Защита от DNS amplification"
echo "  • Автобэкап каждый день в 03:00"
echo ""

if [[ "$AUTO_YES" == true && "$AUTO_REBOOT" == true ]]; then
    log_info "Автоматическая перезагрузка через 3 секунды..."
    sleep 3
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
