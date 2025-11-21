#!/bin/bash
set -e

echo "=== Автоматическая установка Vaultwarden в LXC на Proxmox VE 9 ==="

# --- Значения по умолчанию ---
DEF_CTID=150
DEF_HOSTNAME="vaultwarden"
DEF_PASSWORD="vaultpass"
DEF_DOMAIN="https://vault.codaro.ru"
DEF_CPU=2
DEF_RAM=1024
DEF_ROOTFS=8

read -p "Хотите использовать значения по умолчанию? [Y/n]: " USE_DEFAULT
USE_DEFAULT=${USE_DEFAULT:-Y}

if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
    CTID=""
    HOSTNAME=$DEF_HOSTNAME
    PASSWORD=$DEF_PASSWORD
    DOMAIN=$DEF_DOMAIN
    CPU=$DEF_CPU
    RAM=$DEF_RAM
    ROOTFS=$DEF_ROOTFS
else
    read -p "Введите ID контейнера (оставьте пустым для автоподстановки): " CTID
    read -p "Введите hostname контейнера (по умолчанию vaultwarden): " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEF_HOSTNAME}
    read -p "Введите пароль root для контейнера: " PASSWORD
    read -p "Введите домен для Vaultwarden (по умолчанию $DEF_DOMAIN): " DOMAIN
    DOMAIN=${DOMAIN:-$DEF_DOMAIN}
    read -p "Введите количество CPU (по умолчанию $DEF_CPU): " CPU
    CPU=${CPU:-$DEF_CPU}
    read -p "Введите объем RAM в MB (по умолчанию $DEF_RAM): " RAM
    RAM=${RAM:-$DEF_RAM}
    read -p "Введите размер root-диска в GB (по умолчанию $DEF_ROOTFS): " ROOTFS
    ROOTFS=${ROOTFS:-$DEF_ROOTFS}
fi

# --- Автоматический выбор CTID ---
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
fi

STORAGE="local-lvm"

# --- Определяем последний шаблон Debian 13 ---
echo ">>> Обновляем список шаблонов Proxmox..."
pveam update
TEMPLATE=$(pveam available | grep -E 'debian-13-standard.*amd64\.tar\.zst' | tail -n1 | awk '{print $2}')

if [ -z "$TEMPLATE" ]; then
    echo "Ошибка: не найден шаблон Debian 13!"
    exit 1
fi
echo "Используем шаблон: $TEMPLATE"

# --- Скачиваем шаблон если его нет локально ---
if ! pveam list local | grep -q "$TEMPLATE"; then
    echo ">>> Скачиваем шаблон в локальное хранилище..."
    pveam download local $TEMPLATE
fi

# --- Создание контейнера ---
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
sleep 20

# --- Настройка локали, Docker и Vaultwarden ---
echo ">>> Настраиваем контейнер..."
pct exec $CTID -- bash <<EOF
set -e

# Устанавливаем необходимые пакеты
apt update
apt install -y locales curl sudo gnupg lsb-release apt-transport-https ca-certificates software-properties-common

# Генерация локали ru_RU.UTF-8
if ! grep -q "ru_RU.UTF-8 UTF-8" /etc/locale.gen; then
    echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
fi
locale-gen ru_RU.UTF-8

# Экспорт переменных локали
export LANG=ru_RU.UTF-8
export LC_ALL=ru_RU.UTF-8
echo "export LANG=ru_RU.UTF-8" >> /root/.bashrc
echo "export LC_ALL=ru_RU.UTF-8" >> /root/.bashrc

# Установка Docker
if ! command -v docker &> /dev/null; then
    apt install -y docker.io docker-compose-plugin
    systemctl enable --now docker
fi

# Настройка Vaultwarden
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
      DOMAIN: "$DOMAIN"
      ADMIN_TOKEN: "$ADMIN_TOKEN"
      ROCKET_PORT: 80
    volumes:
      - ./data:/data
    ports:
      - "8080:80"
EOL

docker compose up -d
EOF

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo ""
echo "✅ Контейнер успешно создан и настроен!"
echo "Контейнер ID: $CTID"
echo "IP контейнера: $IP"
echo "URL: http://$IP:8080"
echo "Домен: $DOMAIN"
echo "Админ-панель: $DOMAIN/admin"
echo "ADMIN TOKEN: $ADMIN_TOKEN"
echo "CPU: $CPU | RAM: $RAM MB | Root Disk: $ROOTFS GB"
echo ""
