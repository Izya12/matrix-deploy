#!/bin/bash
# ============================================================
# Matrix Synapse "People's Edition" — v6.6 (Mobile Friendly)
# Исправлено: пути Python (venv), права Postgres
# ============================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ "$EUID" -ne 0 ]] && err "Запускай от root (sudo su -)"

# --- Пути ---
SECRETS="/root/.matrix_secrets"
CONF_DIR="/etc/matrix-synapse"
BACKUP_DIR="/opt/matrix-backups"
SYNAPSE_PYTHON="/opt/venvs/matrix-synapse/bin/python"
SYNAPSE_REGISTER="/opt/venvs/matrix-synapse/bin/register_new_matrix_user"

# --- 1. Главное Меню ---
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}Управление сервером Matrix${NC}"
    if [ -f "$SECRETS" ]; then
        echo "1. Сделать бэкап (архив для миграции)"
        echo "2. Сбросить пароль администратора"
        echo "3. Очистить медиа-кэш"
        echo "4. Выход"
        read -rp "Выбор: " m_choice
        case $m_choice in
            1) matrix_backup ;;
            2) matrix_reset_pwd ;;
            3) matrix_purge ;;
            *) exit 0 ;;
        esac
    else
        echo "1. Полная установка Matrix + LiveKit"
        echo "2. Выход"
        read -rp "Выбор: " m_choice
        case $m_choice in
            1) setup_all ;;
            *) exit 0 ;;
        esac
    fi
}

# --- 2. Функции обслуживания ---
matrix_backup() {
    section "Создание бэкапа"
    DATE=$(date +%Y%m%d_%H%M)
    mkdir -p "$BACKUP_DIR"
    cd /tmp
    sudo -u postgres pg_dump synapse_db > "$BACKUP_DIR/db_$DATE.sql"
    tar -czf "$BACKUP_DIR/matrix_bundle_$DATE.tar.gz" "$CONF_DIR" "$SECRETS" /etc/livekit /etc/nginx/sites-available/matrix 2>/dev/null
    log "Бэкап готов в $BACKUP_DIR"
    read -rp "Нажми Enter..." dummy; show_menu
}

matrix_reset_pwd() {
    section "Сброс пароля админа"
    read -rp "Новый пароль для 'admin': " NEW_P
    $SYNAPSE_REGISTER -c "$CONF_DIR/homeserver.yaml" http://localhost:8008 -u admin -p "$NEW_P" -a || true
    log "Пароль изменен!"
    read -rp "Нажми Enter..." dummy; show_menu
}

matrix_purge() {
    section "Очистка медиа"
    find /var/lib/matrix-synapse/media_store/remote_content -type f -atime +30 -delete 2>/dev/null || true
    log "Старый кэш удален."
    read -rp "Нажми Enter..." dummy; show_menu
}

# --- 3. Основная установка ---
setup_all() {
    section "Ввод данных"
    read -rp "Основной домен (matrix.site.ru): " DOMAIN
    read -rp "Домен для звонков (calls.site.ru): " CALLS_DOMAIN
    read -rp "Пароль админа (придумай): " ADMIN_PASS
    read -rp "Твой Email (для SSL): " EMAIL

    section "Установка зависимостей"
    apt-get update -qq && apt-get install -y -qq postgresql docker.io nginx certbot python3-certbot-nginx pwgen curl jq gnupg2

    section "База данных PostgreSQL"
    cd /tmp # Уходим из /root, чтобы у postgres были права
    PG_PASS=$(pwgen -s 24 1)
    sudo -u postgres psql -c "CREATE USER synapse_user WITH PASSWORD '$PG_PASS';" || true
    sudo -u postgres psql -c "CREATE DATABASE synapse_db OWNER synapse_user;" || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE synapse_db TO synapse_user;" || true
    
    echo "PG_PASS='$PG_PASS'" > "$SECRETS"
    echo "DOMAIN='$DOMAIN'" >> "$SECRETS"
    echo "ADMIN_PASS='$ADMIN_PASS'" >> "$SECRETS"

    section "Matrix Synapse (Native)"
    if [ ! -f /usr/share/keyrings/matrix-org-archive-keyring.gpg ]; then
        curl -fSsL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/matrix-org-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

    if [ ! -f "$CONF_DIR/homeserver.yaml" ]; then
        $SYNAPSE_PYTHON -m synapse.app.homeserver \
            --server-name "$DOMAIN" \
            --config-path "$CONF_DIR/homeserver.yaml" \
            --generate-config \
            --report-stats=no
    fi
    
    # Подключаем Postgres и отключаем открытую регистрацию
    sed -i '/database:/,+5d' "$CONF_DIR/homeserver.yaml"
    cat >> "$CONF_DIR/homeserver.yaml" <<EOF

database:
  name: psycopg2
  args:
    user: synapse_user
    password: $PG_PASS
    database: synapse_db
    host: localhost
    cp_min: 5
    cp_max: 10
EOF
    sed -i "s/enable_registration: .*/enable_registration: false/" "$CONF_DIR/homeserver.yaml"

    section "LiveKit (Звонки Element X)"
    LK_SEC=$(pwgen -s 32 1)
    mkdir -p /etc/livekit
    cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
keys:
    matrix: $LK_SEC
EOF
    docker rm -f livekit &>/dev/null || true
    docker run -d --name livekit --restart unless-stopped --net=host -v /etc/livekit/livekit.yaml:/livekit.yaml livekit/livekit server --config /livekit.yaml

    mkdir -p "$CONF_DIR/conf.d"
    cat > "$CONF_DIR/conf.d/livekit.yaml" <<EOF
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true
livekit:
  url: wss://$CALLS_DOMAIN
  jwt_service_url: "https://$DOMAIN/_matrix/client/unstable/com.element.msc4143/openid/request_token"
  api_key: "matrix"
  api_secret: "$LK_SEC"
EOF

    section "Nginx & SSL"
    mkdir -p /var/www/element
    wget -qO- https://github.com/element-hq/element-web/releases/download/v1.11.97/element-v1.11.97.tar.gz | tar xz -C /var/www/element --strip-components=1
    
    certbot --nginx -d "$DOMAIN" -d "$CALLS_DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

    cat > /etc/nginx/sites-available/matrix <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / { root /var/www/element; index index.html; }
    location /admin { return 301 https://awesome-technologies.github.io/synapse-admin/; }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        return 200 '{"m.homeserver":{"base_url":"https://$DOMAIN"},"org.matrix.msc4143.livekit":{"url":"wss://$CALLS_DOMAIN"}}';
    }

    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
server {
    listen 443 ssl http2;
    server_name $CALLS_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/ || true
    rm -f /etc/nginx/sites-enabled/default

    systemctl restart nginx matrix-synapse
    
    # Регистрация админа
    sleep 5 # Ждем запуска Synapse
    $SYNAPSE_REGISTER -c "$CONF_DIR/homeserver.yaml" http://localhost:8008 -u admin -p "$ADMIN_PASS" -a || true
    
    section "ГОТОВО!"
    echo -e "Чат:      https://$DOMAIN"
    echo -e "Админка:  https://$DOMAIN/admin (Сервер: https://$DOMAIN)"
    echo -e "Логин:    admin"
    echo -e "Пароль:   $ADMIN_PASS"
    echo -e "\nДля меню управления запусти скрипт еще раз."
}

show_menu