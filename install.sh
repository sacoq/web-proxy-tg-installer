#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

clear 2>/dev/null || true

BANNER_LINES=(
    '========================================================================'
    ' __        __   _         ____                           '
    ' \ \      / /__| |__     |  _ \ _ __ _____  ___   _      '
    "  \\ \\ /\\ / / _ \\ '_ \\    | |_) | '__/ _ \\ \\/ / | | |     "
    '   \ V  V /  __/ |_) |   |  __/| | | (_) >  <| |_| |     '
    '    \_/\_/ \___|_.__/    |_|   |_|  \___/_/\_\\__, |     '
    '                                              |___/      '
    '========================================================================'
    '                 AUTO-INSTALLER by @sacoq                  '
    '========================================================================'
)
PASTEL_COLORS=(
    $'\033[38;2;255;179;186m'
    $'\033[38;2;255;209;179m'
    $'\033[38;2;255;239;186m'
    $'\033[38;2;190;238;199m'
    $'\033[38;2;174;217;255m'
    $'\033[38;2;198;190;255m'
    $'\033[38;2;235;190;255m'
    $'\033[38;2;255;190;222m'
)

render_banner() {
    local frame="$1"
    local line line_index character_index color_index
    for line_index in "${!BANNER_LINES[@]}"; do
        line="${BANNER_LINES[$line_index]}"
        printf '\r\033[2K'
        for ((character_index = 0; character_index < ${#line}; character_index++)); do
            color_index=$(( (character_index / 6 + line_index + frame) % ${#PASTEL_COLORS[@]} ))
            printf '%b%s' "${PASTEL_COLORS[$color_index]}" "${line:$character_index:1}"
        done
        printf '%b\n' "$RESET"
    done
}

render_static_banner() {
    local line_index color
    for line_index in "${!BANNER_LINES[@]}"; do
        color="$GREEN"
        if (( line_index == 0 || line_index == 7 || line_index == 9 )); then
            color="$CYAN"
        elif (( line_index == 8 )); then
            color="$YELLOW"
        fi
        printf '%b%s%b\n' "$color" "${BANNER_LINES[$line_index]}" "$RESET"
    done
}

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    for FRAME in $(seq 0 15); do
        if (( FRAME > 0 )); then
            printf '\033[%dA' "${#BANNER_LINES[@]}"
        fi
        render_banner "$FRAME"
        sleep 0.16
    done
else
    render_static_banner
fi
echo ""

function step() { echo -e "\n${YELLOW}========================================\n$1\n========================================${RESET}"; }
function success() { echo -e "${GREEN}[+] $1${RESET}"; }
function error() { echo -e "${RED}[-] $1${RESET}"; exit 1; }
function warn() { echo -e "${YELLOW}[!] $1${RESET}"; }

if [[ $EUID -ne 0 ]]; then
    error "Скрипт должен быть запущен от имени root (используйте sudo)"
fi

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
SECRET="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
AD_TAG=""
WORKERS="${WORKERS:-1}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-4096}"
TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"
MTPROXY_CHECKSUM="919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655"
GO_VERSION="1.26.5"
GO_CHECKSUM="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
CADDY_VERSION="2.11.4"
CADDY_CHECKSUM="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
TEMP_PATHS=()

cleanup() {
    local path
    for path in "${TEMP_PATHS[@]}"; do
        if [[ -n "$path" && "$path" == /tmp/* ]]; then
            rm -rf -- "$path"
        fi
    done
}
trap cleanup EXIT

success "Домен: $DOMAIN"
success "Email для SSL (авто): $EMAIL"
success "Секретный ключ (авто): $SECRET"

step "Обновление системы и установка зависимостей..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl build-essential libssl-dev zlib1g-dev \
    systemd jq python3 iptables xxd nftables \
    wget unzip software-properties-common ca-certificates tar

GO_BINARY=""
if command -v go >/dev/null 2>&1; then
    GO_MINOR="$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/')"
    if [[ "$GO_MINOR" =~ ^[0-9]+$ ]] && (( GO_MINOR >= 20 )); then
        GO_BINARY="$(command -v go)"
    fi
fi
if [[ -z "$GO_BINARY" ]]; then
    GO_ARCHIVE="$(mktemp /tmp/go-linux-amd64.XXXXXX.tar.gz)"
    GO_TEMP="$(mktemp -d /tmp/go-linux-amd64.XXXXXX)"
    TEMP_PATHS+=("$GO_ARCHIVE" "$GO_TEMP")
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$GO_ARCHIVE" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    [[ "$(sha256sum "$GO_ARCHIVE" | awk '{print $1}')" == "$GO_CHECKSUM" ]] || error "Ошибка установки TProxy Server!"
    tar -C "$GO_TEMP" -xzf "$GO_ARCHIVE"
    if [[ ! -d "/opt/go${GO_VERSION}" ]]; then
        mv "$GO_TEMP/go" "/opt/go${GO_VERSION}"
    fi
    GO_BINARY="/opt/go${GO_VERSION}/bin/go"
fi
[[ -x "$GO_BINARY" ]] || error "Ошибка установки TProxy Server!"

step "Создание системных пользователей..."

if ! id -u mtproxy >/dev/null 2>&1; then useradd -r -s /usr/sbin/nologin mtproxy; fi
if ! id -u tproxy >/dev/null 2>&1;  then useradd -r -s /usr/sbin/nologin tproxy;  fi
if ! id -u caddy >/dev/null 2>&1;   then useradd -r -d /var/lib/caddy -s /usr/sbin/nologin caddy; fi

step "Установка официального ядра MTProxy..."

MTPROXY_TEMP="$(mktemp -d /tmp/mtproxy-build.XXXXXX)"
TEMP_PATHS+=("$MTPROXY_TEMP")
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$MTPROXY_TEMP/MTProxy.tar.gz" \
    "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz"
[[ "$(sha256sum "$MTPROXY_TEMP/MTProxy.tar.gz" | awk '{print $1}')" == "$MTPROXY_CHECKSUM" ]] || error "Ошибка компиляции MTProxy!"
mkdir -p "$MTPROXY_TEMP/source"
tar -C "$MTPROXY_TEMP/source" --strip-components=1 -xzf "$MTPROXY_TEMP/MTProxy.tar.gz"
make -C "$MTPROXY_TEMP/source" -j"$(nproc)"

if [[ ! -x "$MTPROXY_TEMP/source/objs/bin/mtproto-proxy" ]]; then
    error "Ошибка компиляции MTProxy!"
fi
if [[ -d /opt/MTProxy ]]; then
    mv /opt/MTProxy "/opt/MTProxy.before-tproxy.$(date +%Y%m%d%H%M%S)"
fi
mv "$MTPROXY_TEMP/source" /opt/MTProxy
success "MTProxy успешно скомпилирован"

step "Установка TProxy Server (Web-ретранслятор)..."

export GOPATH=/root/go
export GOCACHE=/root/.cache/go-build

TPROXY_SRC="$(mktemp -d /tmp/tproxy-server.XXXXXX)"
TEMP_PATHS+=("$TPROXY_SRC")
git -C "$TPROXY_SRC" init -q
git -C "$TPROXY_SRC" remote add origin https://github.com/telegramdesktop/tproxy-server.git
git -C "$TPROXY_SRC" fetch -q --depth 1 origin "$TPROXY_COMMIT"
git -C "$TPROXY_SRC" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$TPROXY_SRC" rev-parse HEAD)" == "$TPROXY_COMMIT" ]] || error "Ошибка компиляции TProxy Server!"

(cd "$TPROXY_SRC" && "$GO_BINARY" test ./...)
(cd "$TPROXY_SRC" && CGO_ENABLED=0 "$GO_BINARY" build -trimpath -ldflags "-s -w" -o /usr/local/bin/tproxy-server ./cmd/tproxy-server)

if [[ ! -x /usr/local/bin/tproxy-server ]]; then
    error "Ошибка компиляции TProxy Server!"
fi

mkdir -p /opt/tproxy-server
rm -rf /opt/tproxy-server/deploy
cp -a "$TPROXY_SRC/deploy" /opt/tproxy-server/
success "TProxy Server установлен"

step "Установка Caddy Web Server..."

if ! command -v caddy >/dev/null 2>&1; then
    CADDY_ARCHIVE="$(mktemp /tmp/caddy-linux-amd64.XXXXXX.tar.gz)"
    CADDY_TEMP="$(mktemp -d /tmp/caddy-linux-amd64.XXXXXX)"
    TEMP_PATHS+=("$CADDY_ARCHIVE" "$CADDY_TEMP")
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$CADDY_ARCHIVE" \
        "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
    [[ "$(sha512sum "$CADDY_ARCHIVE" | awk '{print $1}')" == "$CADDY_CHECKSUM" ]] || error "Ошибка установки Caddy!"
    tar -C "$CADDY_TEMP" -xzf "$CADDY_ARCHIVE"
    install -m 0755 "$CADDY_TEMP/caddy" /usr/local/bin/caddy
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
chmod 0750 /etc/tproxy-server
chown caddy:caddy /var/lib/caddy
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
chmod 0640 /etc/tproxy-server/config.json
chmod 0400 /etc/tproxy-server/profiles.json

curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://core.telegram.org/getProxySecret" -o /etc/mtproxy/proxy-secret
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    "https://core.telegram.org/getProxyConfig" -o /etc/mtproxy/proxy-multi.conf
[[ "$(wc -c < /etc/mtproxy/proxy-secret)" -eq 128 ]] || error "Ошибка настройки MTProxy!"
[[ "$(wc -c < /etc/mtproxy/proxy-multi.conf)" -ge 100 ]] || error "Ошибка настройки MTProxy!"

cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$SECRET
MTPROXY_WORKERS=$WORKERS
MTPROXY_MAX_CONNECTIONS=$MAX_CONNECTIONS
EOF

chown -R root:mtproxy /etc/mtproxy
chmod 0640 /etc/mtproxy/*

step "Создание SystemD сервисов..."

install -m 0644 /opt/tproxy-server/deploy/mtproxy.service /etc/systemd/system/mtproxy.service
install -m 0644 /opt/tproxy-server/deploy/tproxy-server.service /etc/systemd/system/tproxy-server.service
install -m 0644 /opt/tproxy-server/deploy/tproxy-firewall.service /etc/systemd/system/tproxy-firewall.service
install -m 0644 /opt/tproxy-server/deploy/refresh-mtproxy-config.service /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 /opt/tproxy-server/deploy/refresh-mtproxy-config.timer /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0644 /opt/tproxy-server/deploy/firewall.nft /etc/tproxy-server/firewall.nft
install -m 0755 /opt/tproxy-server/deploy/refresh-mtproxy-config.sh /usr/local/sbin/refresh-mtproxy-config
install -m 0644 /opt/tproxy-server/deploy/Caddyfile /etc/caddy/Caddyfile
install -m 0644 /opt/tproxy-server/deploy/caddy.service /etc/systemd/system/caddy.service
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$DOMAIN
Environment=TPROXY_SITE_ROOT=/srv/tproxy-site
Environment=ACME_EMAIL=$EMAIL
EOF

/usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    -check
TPROXY_HOSTNAME="$DOMAIN" TPROXY_SITE_ROOT=/srv/tproxy-site ACME_EMAIL="$EMAIL" \
    /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

step "Запуск всех сервисов..."

systemctl daemon-reload
systemctl reset-failed || true
systemctl enable --now tproxy-firewall.service
systemctl enable --now mtproxy.service
systemctl restart mtproxy.service
systemctl enable --now tproxy-server.service
systemctl enable --now refresh-mtproxy-config.timer
systemctl enable --now caddy.service
systemctl restart caddy.service

for SERVICE in tproxy-firewall mtproxy tproxy-server caddy; do
    systemctl is-active --quiet "$SERVICE.service" || error "Ошибка запуска сервисов!"
done

READY=""
for ATTEMPT in $(seq 1 20); do
    if curl --fail --silent --output /dev/null http://127.0.0.1:8081/readyz; then
        READY="1"
        break
    fi
    sleep 1
done
[[ -n "$READY" ]] || error "Ошибка запуска сервисов!"

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
