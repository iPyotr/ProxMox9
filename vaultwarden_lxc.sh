#!/bin/bash

set -e

echo "=== Автоматическая установка Vaultwarden в LXC на Proxmox VE 9 ==="

# --- Ввод параметров пользователем ---
# Автоматический выбор CTID, если пользователь оставляет пустое поле
read -p "Введите ID контейнера (например 150, оставьте пустым для автоподстановки): " CTID
if [ -z "$CTID" ]; then
    # ищем первый свободный CTID >=150
    EXISTING=$(pct list | awk 'NR>1 {print $1}')
    CTID=150
    while echo "$EXISTING" | grep -q "^$CTID\$"; do
        CTID=$((CTID+1))
    done
    echo "Автоматически выбран CTID: $CTID"
fi

read -p "Введите hostname контейнера (например vaultwarden, оставьте пустым для автоподстановки): " HOSTNAME
HOSTNAME=${HOSTNAME:-vaultwarden}

read -p "Введите пароль root для контейнера: " PASSWORD
read -p "Введите домен для Vaultwarden (например https://vault.codaro.ru): " DOMAIN
read -p "Введите ADMIN TOKEN (оставьте пустым для автогенерации): " ADMIN_TOKEN

if [ -z "$ADMIN_TOKEN" ]; then
    ADMIN_TOKEN=$(openssl rand -hex 32)
fi

read -p "Введите количество CPU (по умолчанию 2): " CPU
CPU=${CPU:-2}

read -p "Введите объем RAM в MB (по умолчанию 1024): " RAM
RAM=${RAM:-1024}

read -p "Введите размер root-диска в GB (по умолчанию 8): " ROOTFS
ROOTFS=${ROOTFS:-8}

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

# --- Установка Docker и Vaultwarden ---
echo ">>> Устанавливаем Vaultwarden внутри контейнера..."
pct exec $CTID -- bash <<EOF

set -e

# Устанавливаем недостающие пакеты
apt update && apt upgrade -y
apt install -y curl sudo gnupg lsb-release apt-transport-https software-properties-common

# Docker
if ! command -v docker &> /dev/null; then
    apt install -y docker.io docker-compose-plugin
    systemctl enable --now docker
fi

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
