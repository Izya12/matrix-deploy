#!/bin/bash
# ============================================================
#  Matrix Synapse "Easy-Start" — v4.0 (Super-Stable)
# ============================================================

set -o pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

[[ "$EUID" -ne 0 ]] && err "Запускай от root!"

# ── Параметры ──────────────────────────────────────────────
ELEMENT_VER="v1.11.97"
# Пробуем разные зеркала для Element, если одно сбоит
ELEMENT_URLS=(
    "https://github.com/element-hq/element-web/releases/download/${ELEMENT_VER}/element-${ELEMENT_VER}.tar.gz"
    "https://ghproxy.com/https://github.com/element-hq/element-web/releases/download/${ELEMENT_VER}/element-${ELEMENT_VER}.tar.gz"
)
SECRETS_FILE="/root/.matrix_secrets"
CONF_DIR="/etc/matrix-synapse"

# ── 1. Подготовка ──────────────────────────────────────────
prepare() {
    section "Чистка и подготовка"
    rm -f /etc/apt/sources.list.d/docker.list # Убираем дубли
    apt-get update -qq
    apt-get install -y -qq curl wget jq dnsutils gnupg2 software-properties-common \
        ufw postgresql nginx certbot python3-certbot-nginx pwgen > /dev/null
    log "Система готова"
}

# ── 2. База ────────────────────────────────────────────────
setup_db() {
    section "База данных"
    cd /tmp
    if [[ -f "$SECRETS_FILE" ]]; then source "$SECRETS_FILE"; fi
    [[ -z "$PG_PASS" ]] && PG_PASS=$(pwgen -s 32 1)
    
    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw synapse_db; then
        sudo -u postgres psql -c "CREATE USER synapse_user WITH PASSWORD '$PG_PASS';"
        sudo -u postgres psql -c "CREATE DATABASE synapse_db OWNER synapse_user;"
    fi
    echo "PG_PASS=$PG_PASS" > "$SECRETS_FILE"
    log "Postgres настроен"
}

# ── 3. Synapse ─────────────────────────────────────────────
setup_synapse() {
    section "Matrix Synapse"
    if [ ! -f /etc/apt/sources.list.d/matrix-org.list ]; then
        curl -fSsL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/matrix-org-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
        apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3
    
    if [ ! -f "$CONF_DIR/homeserver.yaml" ]; then
        python3 -m synapse.app.homeserver --server-name "$DOMAIN" --config-path "$CONF_DIR/homeserver.yaml" --generate-config --report-stats=no
    fi
    sed -i '/database:/,/args:/c\database:\n  name: psycopg2\n  args:\n    user: synapse_user\n    password: '"$PG_PASS"'\n    database: synapse_db\n    host: localhost\n    cp_min: 5\n    cp_max: 10' "$CONF_DIR/homeserver.yaml"
    systemctl enable --now matrix-synapse
    log "Synapse активен"
}

# ── 4. LiveKit ─────────────────────────────────────────────
setup_livekit() {
    [[ -z "$LIVEKIT_DOMAIN" ]] && return 0
    section "LiveKit (Звонки)"
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh; fi
    
    # Пытаемся скачать образ с повторами
    log "Скачиваем LiveKit..."
    docker pull livekit/livekit:latest || warn "Docker Hub капризничает, попробуем запустить напрямую"
    
    mkdir -p /etc/livekit
    LK_KEY=$(pwgen -s 12 1); LK_SEC=$(pwgen -s 32 1)
    cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
rtc:
    tcp_port: 7881
    port_range_start: 50000
    port_range_end: 60000
    use_external_ip: true
keys:
    $LK_KEY: $LK_SEC
EOF
    docker rm -f livekit &>/dev/null || true
    docker run -d --name livekit --restart unless-stopped --net=host -v /etc/livekit/livekit.yaml:/livekit.yaml livekit/livekit server --config /livekit.yaml
    log "LiveKit запущен"
}

# ── 5. Nginx + Element + SSL ───────────────────────────────
setup_web() {
    section "Nginx и SSL"
    mkdir -p /var/www/element
    
    # Качаем Element с проверкой
    SUCCESS=0
    for url in "${ELEMENT_URLS[@]}"; do
        log "Пробуем скачать Element с $url..."
        if wget -qO /tmp/element.tar.gz "$url" && tar -xzf /tmp/element.tar.gz -C /var/www/element --strip-components=1 2>/dev/null; then
            SUCCESS=1; break
        fi
    done
    [[ $SUCCESS -eq 0 ]] && err "Не удалось скачать Element. Проверь сеть!"

    # 1. Временный конфиг для Certbot (без SSL)
    cat > /etc/nginx/sites-available/matrix <<EOF
server {
    listen 80;
    server_name $DOMAIN $LIVEKIT_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    # 2. Получаем сертификат
    log "Получаем SSL сертификат..."
    certbot certonly --nginx -d "$DOMAIN" $([[ -n "$LIVEKIT_DOMAIN" ]] && echo "-d $LIVEKIT_DOMAIN") --non-interactive --agree-tos -m "admin@$DOMAIN" || err "Certbot не смог выдать сертификат!"

    # 3. Финальный конфиг с SSL
    cat > /etc/nginx/sites-available/matrix <<EOF
server {
    listen 80;
    server_name $DOMAIN $LIVEKIT_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / { root /var/www/element; index index.html; }
    location /admin { return 301 https://awesome-technologies.github.io/synapse-admin/; }
    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    if [[ -n "$LIVEKIT_DOMAIN" ]]; then
        cat >> /etc/nginx/sites-available/matrix <<EOF
server {
    listen 443 ssl http2;
    server_name $LIVEKIT_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    fi
    systemctl restart nginx
    log "Nginx и SSL настроены"
}

# ── Запуск ──────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}Matrix Synapse v4.0 — Финальная сборка${NC}"
read -p "Основной домен: " DOMAIN
read -p "Домен LiveKit (calls.site.com): " LIVEKIT_DOMAIN

prepare
setup_db
setup_synapse
setup_livekit
setup_web

# Регистрация
PASS=$(pwgen -s 16 1)
register_new_matrix_user -c $CONF_DIR/homeserver.yaml http://localhost:8008 -u admin -p $PASS -a

section "УСТАНОВКА ЗАВЕРШЕНА"
echo -e "Matrix: https://$DOMAIN"
echo -e "Админка: https://$DOMAIN/admin"
echo -e "Логин: admin / Пароль: $PASS"