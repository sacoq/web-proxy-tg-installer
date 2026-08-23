#!/usr/bin/env bash
set -euo pipefail
umask 022
GREEN='\033[1;32m'
BLUE='\033[1;34m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'
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
                     by @sacoq                                   
                                                                 
=================================================================
EOF
echo -e "${RESET}"
if [[ -f /root/telegram_webproxy_info.txt ]]; then
    warn "Прокси уже установлен! Данные находятся в файле /root/telegram_webproxy_info.txt"
    exit 0
fi
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
SECRET="${SECRET:-}"
AD_TAG="${AD_TAG:-}"
WORKERS="${WORKERS:-1}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4096}"
if [[ -z "$DOMAIN" ]]; then
    read -rp "$(echo -e "${BLUE}Введите домен для прокси (например, proxy.example.com): ${RESET}")" DOMAIN
fi
if [[ -z "$EMAIL" ]]; then
    read -rp "$(echo -e "${BLUE}Введите ваш email (для SSL-сертификата Let's Encrypt): ${RESET}")" EMAIL
fi
if [[ -z "$SECRET" ]]; then
    read -rp "$(echo -e "${BLUE}Введите Secret для прокси (оставьте пустым для автоматической генерации): ${RESET}")" SECRET_INPUT
    if [[ -z "$SECRET_INPUT" ]]; then
        SECRET=$(head -c 16 /dev/urandom | xxd -p)
        success "Сгенерирован Secret: $SECRET"
    else
        SECRET="$SECRET_INPUT"
    fi
fi
if [[ -z "$AD_TAG" ]]; then
    read -rp "$(echo -e "${BLUE}Введите Ad Tag для монетизации (оставьте пустым, если его нет): ${RESET}")" AD_TAG
fi
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
git clone https://github.com/gongt/tproxy-server.git "$TPROXY_SRC"
cd "$TPROXY_SRC"
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /usr/local/bin/tproxy-server .
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
cat > /srv/tproxy-site/index.html <<EOF
<!doctype html>
<html>
<head>
    <title>Web Proxy</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; max-width:700px; margin:80px auto; padding:20px; text-align: center; }
        h1 { color: #2AABEE; }
    </style>
</head>
<body>
    <h1>Telegram Web Proxy</h1>
    <p>Secure web transport relay is running.</p>
</body>
</html>
EOF
chmod 0644 /srv/tproxy-site/index.html
cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname":"$DOMAIN",
  "listen":"127.0.0.1:8080",
  "admin_listen":"127.0.0.1:8081",
  "public_dir":"/srv/tproxy-site"
}
EOF
cat > /etc/tproxy-server/profiles.json <<EOF
[
  {
    "id": "mtproxy",
    "dial": "127.0.0.1:8888",
    "secret": "$SECRET",
    "sni": "google.com"
  }
]
EOF
chmod 0640 /etc/tproxy-server/*.json
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
chmod 0640 /etc/caddy/Caddyfile
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
Ad Tag: ${AD_TAG:-отсутствует}
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
