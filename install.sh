#!/usr/bin/env bash
#===============================================================================
# Telegram Web Proxy Auto-Installer
# Created by: xanka
# Description: Installs MTProxy + TProxy-Server + Caddy for Telegram Web Proxy
#===============================================================================

set -euo pipefail
umask 022

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

clear
echo -e "${CYAN}========================================================================${RESET}"
echo -e "${GREEN} __        __   _         ____                           ${RESET}"
echo -e "${GREEN} \ \      / /__| |__     |  _ \ _ __ _____  ___   _      ${RESET}"
echo -e "${GREEN}  \ \ /\ / / _ \ '_ \    | |_) | '__/ _ \ \/ / | | |     ${RESET}"
echo -e "${GREEN}   \ V  V /  __/ |_) |   |  __/| | | (_) >  <| |_| |     ${RESET}"
echo -e "${GREEN}    \_/\_/ \___|_.__/    |_|   |_|  \___/_/\_\\\__, |     ${RESET}"
echo -e "${GREEN}                                              |___/      ${RESET}"
echo -e "${CYAN}========================================================================${RESET}"
echo -e "${YELLOW}                      by xanka                  ${RESET}"
echo -e "${CYAN}========================================================================${RESET}"
echo ""

function step() { echo -e "\n${YELLOW}========================================\n$1\n========================================${RESET}"; }
function success() { echo -e "${GREEN}[+] $1${RESET}"; }
function error() { echo -e "${RED}[-] $1${RESET}"; exit 1; }
function warn() { echo -e "${YELLOW}[!] $1${RESET}"; }

if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (используйте sudo)"
fi

echo -e "${CYAN}"
cat << "EOF"
=================================================================
                                                                 
         T E L E G R A M   W E B   P R O X Y                     
                     by xanka                                    
                                                                 
=================================================================
EOF
echo -e "${RESET}"

if [[ -f /root/telegram_webproxy_info.txt ]]; then
    warn "Прокси уже установлен! Данные находятся в файле /root/telegram_webproxy_info.txt"
    exit 0
fi

if [[ $# -ge 1 ]]; then
    DOMAIN="$1"
else
    DOMAIN="${DOMAIN:-}"
fi

if [[ -z "$DOMAIN" || "$DOMAIN" == "proxy.example.com" ]]; then
    if [[ "$DOMAIN" == "proxy.example.com" ]]; then
        warn "Вы указали домен-пример (proxy.example.com)."
    fi
    read -rp "$(echo -e "${BLUE}Введите ВАШ домен для прокси (А-запись должна указывать на этот сервер): ${RESET}")" DOMAIN
fi

if [[ -z "$DOMAIN" || "$DOMAIN" == "proxy.example.com" ]]; then
    error "Реальный домен не указан! Установка прервана."
fi

EMAIL="admin@${DOMAIN}"
SECRET=$(head -c 16 /dev/urandom | xxd -p)
AD_TAG=""
WORKERS="${WORKERS:-1}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4096}"

success "Домен: $DOMAIN"
success "Email для SSL (авто): $EMAIL"
success "Секретный ключ (авто): $SECRET"

step "Обновление системы и установка зависимостей..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y \
    git curl build-essential libssl-dev zlib1g-dev \
    systemd jq python3 iptables xxd nftables \
    wget golang unzip software-properties-common

step "Создание системных пользователей..."

if ! id -u mtproxy >/dev/null 2>&1; then useradd -r -s /usr/sbin/nologin mtproxy; fi
if ! id -u tproxy >/dev/null 2>&1;  then useradd -r -s /usr/sbin/nologin tproxy;  fi
if ! id -u caddy >/dev/null 2>&1;   then useradd -r -d /var/lib/caddy -s /usr/sbin/nologin caddy; fi

step "Установка официального ядра MTProxy..."

if [[ -d /opt/MTProxy ]]; then rm -rf /opt/MTProxy; fi

git clone https://github.com/TelegramMessenger/MTProxy /opt/MTProxy
cd /opt/MTProxy
make -j"$(nproc)"

if [[ ! -x /opt/MTProxy/objs/bin/mtproto-proxy ]]; then
    error "Ошибка компиляции MTProxy!"
fi
success "MTProxy успешно скомпилирован"

step "Установка TProxy Server (Web-ретранслятор)..."

export GOPATH=/root/go
export GOCACHE=/root/.cache/go-build
go env -w GOCACHE=/root/.cache/go-build

TPROXY_SRC=$(mktemp -d)
git clone https://github.com/telegramdesktop/tproxy-server.git "$TPROXY_SRC"
cd "$TPROXY_SRC"

CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /usr/local/bin/tproxy-server ./cmd/tproxy-server

if [[ ! -x /usr/local/bin/tproxy-server ]]; then
    error "Ошибка компиляции TProxy Server!"
fi

if [[ -d deploy ]]; then
    mkdir -p /opt/tproxy-server
    cp -r deploy /opt/tproxy-server/
fi

rm -rf "$TPROXY_SRC"
success "TProxy Server установлен"

step "Установка Caddy Web Server..."

if ! command -v caddy >/dev/null 2>&1; then
    CADDY_URL="https://caddyserver.com/api/download?os=linux&arch=amd64"
    curl -sSL -o /usr/local/bin/caddy "$CADDY_URL"
    chmod 0755 /usr/local/bin/caddy
fi
success "Caddy установлен"

step "Настройка окружения..."

mkdir -p \
    /etc/tproxy-server \
    /etc/mtproxy \
    /srv/tproxy-site \
    /etc/caddy \
    /var/lib/caddy

chown root:tproxy /etc/tproxy-server
chmod 0750 /var/lib/caddy
chmod 0755 /srv/tproxy-site

cat > /srv/tproxy-site/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Site Under Maintenance</title>
    <style>
        body {
            margin: 0; padding: 0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: #f8f9fa; color: #333;
            display: flex; align-items: center; justify-content: center; height: 100vh;
        }
        .container {
            text-align: center; background: #fff; padding: 50px;
            border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); max-width: 500px;
        }
        h1 { margin-top: 0; color: #2c3e50; font-size: 26px; }
        p { color: #666; line-height: 1.6; font-size: 16px; }
        .footer { margin-top: 30px; font-size: 12px; color: #aaa; }
    </style>
</head>
<body>
    <div class="container">
        <h1>We'll be right back</h1>
        <p>Our website is currently undergoing scheduled maintenance and upgrades. We apologize for the inconvenience and appreciate your patience.</p>
        <div class="footer">&copy; 2024 IT Operations. All rights reserved.</div>
    </div>
</body>
</html>
EOF
chmod 0644 /srv/tproxy-site/index.html

cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/tproxy-site",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json",
  "enable_pprof": false
}
EOF

cat > /etc/tproxy-server/profiles.json <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "$SECRET",
      "backend": "127.0.0.1:2398"
    }
  ]
}
EOF

chown root:tproxy /etc/tproxy-server/*.json

curl -sSL "https://core.telegram.org/getProxySecret" -o /etc/mtproxy/proxy-secret
curl -sSL "https://core.telegram.org/getProxyConfig" -o /etc/mtproxy/proxy-multi.conf

chown -R root:mtproxy /etc/mtproxy
chmod 0640 /etc/mtproxy/*

step "Создание SystemD сервисов..."

cat > /etc/systemd/system/mtproxy.service <<EOF
[Unit]
Description=Official Telegram MTProxy backend
After=network.target

[Service]
Type=simple
User=root
ExecStart=/bin/sh -c "/opt/MTProxy/objs/bin/mtproto-proxy \
  -u mtproxy \
  -p 8888 \
  -H 2398 \
  -S \\"\$\${MTPROXY_SECRET}\\" \
  \$\${AD_TAG_ARG} \
  --aes-pwd /etc/mtproxy/proxy-secret \
  /etc/mtproxy/proxy-multi.conf \
  -M \\"\$\${MTPROXY_WORKERS}\\" \
  -C \\"\$\${MTPROXY_MAX_CONNECTIONS}\\""

Environment="MTPROXY_SECRET=$SECRET"
Environment="MTPROXY_WORKERS=$WORKERS"
Environment="MTPROXY_MAX_CONNECTIONS=$MAX_CONNECTIONS"
EOF

if [[ -n "$AD_TAG" ]]; then
    sed -i "s/\$\${AD_TAG_ARG}/-P \"$AD_TAG\"/" /etc/systemd/system/mtproxy.service
else
    sed -i "s/\$\${AD_TAG_ARG}//" /etc/systemd/system/mtproxy.service
fi

cat > /etc/systemd/system/tproxy-server.service <<'EOF'
[Unit]
Description=Browser HTTPS transport relay
After=network.target mtproxy.service

[Service]
Type=simple
User=tproxy
Group=tproxy
LimitNOFILE=1048576
LoadCredential=profiles.json:/etc/tproxy-server/profiles.json

ExecStart=/bin/sh -c 'exec /usr/local/bin/tproxy-server \
  -config /etc/tproxy-server/config.json \
  -profiles-file "$${CREDENTIALS_DIRECTORY}/profiles.json"'

Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
}
$DOMAIN {
    encode gzip zstd
    reverse_proxy 127.0.0.1:8080 {
        transport http {
            response_header_timeout 40s
        }
    }
}
EOF

chown root:caddy /etc/caddy/Caddyfile
chmod 0644 /etc/caddy/Caddyfile

cat > /etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy Web Server
After=network.target

[Service]
Type=simple
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

if [[ -f /opt/tproxy-server/deploy/tproxy-firewall.service ]]; then
    install -m 0644 /opt/tproxy-server/deploy/tproxy-firewall.service /etc/systemd/system/tproxy-firewall.service
    install -m 0644 /opt/tproxy-server/deploy/firewall.nft /etc/tproxy-server/firewall.nft
fi

step "Запуск всех сервисов..."

systemctl daemon-reload
systemctl reset-failed || true

systemctl enable mtproxy tproxy-server caddy || true
systemctl start mtproxy tproxy-server caddy || true

if systemctl is-active --quiet tproxy-firewall; then
    systemctl restart tproxy-firewall
fi

cat > /root/telegram_webproxy_info.txt <<EOF
========================================
       Telegram WEB Proxy by xanka
========================================

Установленные компоненты:
- MTProxy (официальное ядро на C)
- TProxy-Server (веб-ретранслятор на Go)
- Caddy (HTTPS-сервер)

Параметры:
Домен: $DOMAIN
Secret: $SECRET

========================================
Ссылка для подключения в Telegram:
tg://webproxy?server=$DOMAIN&secret=$SECRET
========================================
EOF
chmod 0600 /root/telegram_webproxy_info.txt

echo -e "\n${GREEN}========================================${RESET}"
echo -e "${GREEN}      УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!      ${RESET}"
echo -e "${GREEN}========================================${RESET}"
cat /root/telegram_webproxy_info.txt
