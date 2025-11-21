#!/bin/bash
set -e

echo "=== Автоматическая установка Vaultwarden (Docker) в LXC на Proxmox VE 9 ==="

# --- Значения по умолчанию ---
DEF_CTID=150
DEF_HOSTNAME="vaultwarden"
DEF_PASSWORD="vaultpass"
DEF_DOMAIN="vault.codaro.ru"
DEF_CPU=2
DEF_RAM=1024
DEF_ROOTFS=8
DEF_STORAGE="local-lvm" 

# --- Спросим, использовать ли значения по умолчанию ---
# ... (Остальная часть обработки ввода остается без изменений) ...

read -p "Хотите использовать значения по умолчанию? [Y/n]: " USE_DEFAULT
USE_DEFAULT=${USE_DEFAULT:-Y}

if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    CTID=$DEF_CTID
    HOSTNAME=$DEF_HOSTNAME
    PASSWORD=$DEF_PASSWORD
    DOMAIN=$DEF_DOMAIN
    CPU=$DEF_CPU
    RAM=$DEF_RAM
    ROOTFS=$DEF_ROOTFS
    STORAGE=$DEF_STORAGE
else
    # --- Запрос параметров ---
    read -p "Введите ID контейнера (оставьте пустым для автоподстановки): " CTID
    read -p "Введите hostname контейнера (по умолчанию $DEF_HOSTNAME): " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEF_HOSTNAME}
    
    # Скрытый ввод пароля для безопасности
    read -s -p "Введите пароль root для контейнера: " PASSWORD
    echo # Добавляем новую строку после скрытого ввода
    
    read -p "Введите домен для Vaultwarden (по умолчанию $DEF_DOMAIN, без https://): " DOMAIN
    DOMAIN=${DOMAIN:-$DEF_DOMAIN}
    read -p "Введите количество CPU (по умолчанию $DEF_CPU): " CPU
    CPU=${CPU:-$DEF_CPU}
    read -p "Введите объем RAM в MB (по умолчанию $DEF_RAM): " RAM
    RAM=${RAM:-$DEF_RAM}
    read -p "Введите размер root-диска в GB (по умолчанию $DEF_ROOTFS): " ROOTFS
    ROOTFS=${ROOTFS:-$DEF_ROOTFS}
    read -p "Введите имя хранилища Proxmox (по умолчанию $DEF_STORAGE): " STORAGE
    STORAGE=${STORAGE:-$DEF_STORAGE}
fi

# --- Автоподстановка CTID если не указано ---
if [ -z "$CTID" ]; then
    EXISTING=$(pct list | awk 'NR>1 {print $1}')
    CTID=$DEF_CTID
    while echo "$EXISTING" | grep -q "^$CTID\$"; do
        CTID=$((CTID+1))
    done
    echo "Автоматически выбран CTID: $CTID"
fi

# --- Генерация ADMIN_TOKEN ---
read -p "Введите ADMIN TOKEN (оставьте пустым для автогенерации): " ADMIN_TOKEN
if [ -z "$ADMIN_TOKEN" ]; then
    ADMIN_TOKEN=$(openssl rand -hex 32)
    echo "Сгенерирован ADMIN_TOKEN: $ADMIN_TOKEN"
fi


# --- Обновляем шаблоны Proxmox ---
echo ">>> Обновляем список шаблонов Proxmox..."
pveam update
# Ищем шаблон Debian 13 (Trixie) - наиболее свежий и соответствующий Proxmox 9
TEMPLATE=$(pveam available | grep -E 'debian-13-standard.*amd64\.tar\.zst' | tail -n1 | awk '{print $2}')

# Если Debian 13 не найден, пробуем Debian 12 для обратной совместимости
if [ -z "$TEMPLATE" ]; then
    echo "Предупреждение: Шаблон Debian 13 не найден. Ищем Debian 12..."
    TEMPLATE=$(pveam available | grep -E 'debian-12-standard.*amd64\.tar\.zst' | tail -n1 | awk '{print $2}')
fi

if [ -z "$TEMPLATE" ]; then
    echo "Ошибка: Не найден шаблон Debian 13 или Debian 12!"
    exit 1
fi
echo "Используем шаблон: $TEMPLATE"

# --- Скачиваем шаблон если отсутствует ---
if ! pveam list local | grep -q "$TEMPLATE"; then
    echo ">>> Скачиваем шаблон в локальное хранилище..."
    pveam download local $TEMPLATE
fi

# --- Создаём контейнер ---
echo ">>> Создаём LXC контейнер с DHCP и nesting..."
pct create $CTID local:vztmpl/$TEMPLATE \
    --hostname $HOSTNAME \
    --password $PASSWORD \
    --storage $STORAGE \
    --rootfs $STORAGE:$ROOTFS \
    --memory $RAM \
    --swap $(($RAM / 2)) \
    --cores $CPU \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --ostype debian

echo ">>> Запускаем контейнер..."
pct start $CTID

# --- Проверка готовности контейнера (более надежно, чем sleep) ---
echo ">>> Ожидаем запуск контейнера и сетевой конфигурации..."
MAX_ATTEMPTS=15
ATTEMPTS=0
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if pct status $CTID | grep -q 'running'; then
        # Проверяем, что контейнер готов принимать команды
        if pct exec $CTID -- bash -c 'true' 2>/dev/null; then
            echo "Контейнер $CTID запущен и готов."
            break
        fi
    fi
    sleep 4
    ATTEMPTS=$((ATTEMPTS+1))
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Ошибка: Контейнер $CTID не запустился или недоступен для выполнения команд."
    exit 1
fi

# --- Настройка контейнера ---
echo ">>> Настраиваем контейнер: обновляем, устанавливаем Docker и Node.js..."
pct exec $CTID -- bash <<EOF
set -e

# --- Обновление и установка базовых пакетов ---
apt update && apt upgrade -y
apt install -y locales curl sudo gnupg apt-transport-https ca-certificates lsb-release

# --- Настройка локали ru_RU.UTF-8 (Игнорируем предупреждение, если не получается) ---
# Это решит проблему с "warning: setlocale: LC_ALL: cannot change locale (ru_RU.UTF-8)"
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen 

# --- Установка Docker с официального репозитория (Исправлено) ---
echo ">>> Установка Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Используем os-release, чтобы гарантировать правильное кодовое имя ОС внутри контейнера
OS_CODENAME=\$(. /etc/os-release && echo "\$VERSION_CODENAME")

echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  \$OS_CODENAME stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# --- Установка Node.js ---
echo ">>> Установка Node.js и npm..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs 

# --- Установка Vaultwarden ---
mkdir -p /opt/vaultwarden
cd /opt/vaultwarden

cat > docker-compose.yml <<EOL
version: '3'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: always
    environment:
      WEBSOCKET_ENABLED: "true"
      SIGNUPS_ALLOWED: "false"
      DOMAIN: "https://$DOMAIN"
      ADMIN_TOKEN: "$ADMIN_TOKEN"
      ROCKET_PORT: 80
    volumes:
      - ./data:/data
    ports:
      - "8080:80"
EOL

docker compose up -d
EOF

# --- Вывод итогов ---
# Ждем 5 секунд, чтобы DHCP успел выдать IP и Docker запустился
sleep 5 
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo ""
echo "======================================================="
echo "✅ Контейнер $CTID успешно создан и Vaultwarden запущен!"
echo "======================================================="
echo " Контейнер ID: $CTID"
# ... (Остальная часть вывода) ...
echo " IP контейнера: $IP"
echo " Hostname: $HOSTNAME"
echo "---"
echo " Vaultwarden (через Proxmox): http://$IP:8080"
echo " Домен для прокси: $DOMAIN"
echo " Админ-панель: https://$DOMAIN/admin"
echo " ADMIN TOKEN: $ADMIN_TOKEN"
echo "---"
echo " Технические данные: CPU: $CPU | RAM: $RAM MB | Root Disk: $ROOTFS GB"
echo ""

# --- Дополнительное примечание ---
echo "⚠️ ВАЖНО: Vaultwarden внутри контейнера слушает порт 80. "
echo "Для использования https:// необходимо настроить внешний реверс-прокси (Nginx/Traefik)!"
