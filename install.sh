#!/bin/bash
# ============================================================
#  Matrix Synapse "Easy-Start" — v3.8 (Ultra-Stable)
#  Специально для GitHub и новичков | Debian 12+ | root
# ============================================================

set -o pipefail

# ── Оформление ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# Проверка на root
if [[ "$EUID" -ne 0 ]]; then
    err "Скрипт должен быть запущен от root! Введи: sudo su -"
fi

# ── Конфигурация ───────────────────────────────────────────
GH_PROXY="https://ghproxy.com/"
ELEMENT_VER="v1.11.97"
SECRETS_FILE="/root/.matrix_secrets"
BACKUP_DIR="/opt/matrix-backups"
CONF_DIR="/etc/matrix-synapse"

# ── 1. Подготовка инструментов ──────────────────────────────
prepare_tools() {
    section "Подготовка системы"
    apt-get update -qq
    apt-get install -y -qq curl wget jq dnsutils iproute2 gnupg2 \
        software-properties-common apt-transport-https lsb-release \
        ufw postgresql nginx certbot python3-certbot-nginx \
        python3-bcrypt python3-yaml pwgen > /dev/null
    log "Инструменты установлены"
}

# ── 2. База Данных ──────────────────────────────────────────
setup_db() {
    section "Настройка базы данных"
    cd /tmp
    
    if [[ -f "$SECRETS_FILE" ]]; then source "$SECRETS_FILE"; fi
    [[ -z "$PG_PASS" ]] && PG_PASS=$(pwgen -s 32 1) && echo "PG_PASS=$PG_PASS" >> "$SECRETS_FILE"

    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw synapse_db; then
        sudo -u postgres psql -c "CREATE USER synapse_user WITH PASSWORD '$PG_PASS';"
        sudo -u postgres psql -c "CREATE DATABASE synapse_db OWNER synapse_user;"
        log "База данных synapse_db создана"
    else
        log "База данных уже готова"
    fi
}

# ── 3. Установка Synapse ────────────────────────────────────
setup_synapse() {
    section "Установка Matrix Synapse"
    if [ ! -f /etc/apt/sources.list.d/matrix-org.list ]; then
        curl -fSsL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/matrix-org-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/matrix-org.list
        apt-get update -qq
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

    if [ ! -f "$CONF_DIR/homeserver.yaml" ]; then
        python3 -m synapse.app.homeserver --server-name "$DOMAIN" --config-path "$CONF_DIR/homeserver.yaml" --generate-config --report-stats=no
    fi

    # Настройка Postgres в конфиге
    sed -i '/database:/,/args:/c\database:\n  name: psycopg2\n  args:\n    user: synapse_user\n    password: '"$PG_PASS"'\n    database: synapse_db\n    host: localhost\n    cp_min: 5\n    cp_max: 10' "$CONF_DIR/homeserver.yaml"
    
    systemctl enable --now matrix-synapse
    log "Synapse запущен"
}

# ── 4. Звонки LiveKit (Docker Host Mode) ────────────────────
setup_livekit() {
    [[ -z "$LIVEKIT_DOMAIN" ]] && return 0
    section "Настройка звонков (LiveKit)"
    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | sh; fi
    
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
    
    echo "LK_KEY=$LK_KEY" >> "$SECRETS_FILE"
    echo "LK_SEC=$LK_SEC" >> "$SECRETS_FILE"
    log "LiveKit активен в Docker"
}

# ── 5. Nginx & Element ──────────────────────────────────────
setup_web() {
    section "Настройка Nginx и Element"
    mkdir -p /var/www/element
    wget -qO /tmp/element.tar.gz "${GH_PROXY}https://github.com/element-hq/element-web/releases/download/${ELEMENT_VER}/element-${ELEMENT_VER}.tar.gz"
    tar -xzf /tmp/element.tar.gz -C /var/www/element --strip-components=1

    cat > /etc/nginx/sites-available/matrix <<EOF
server {
    listen 80;
    server_name $DOMAIN $LIVEKIT_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
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
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    fi

    ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    certbot --nginx -d "$DOMAIN" $([[ -n "$LIVEKIT_DOMAIN" ]] && echo "-d $LIVEKIT_DOMAIN") --non-interactive --agree-tos -m "admin@$DOMAIN"
    systemctl restart nginx
    log "Веб-интерфейс настроен"
}

# ── 6. Служебные команды (Бэкап/Восстановление) ─────────────
setup_tools() {
    # Бэкап
    cat > /usr/local/bin/matrix-backup <<EOF
#!/bin/bash
DATE=\$(date +%Y%m%d)
mkdir -p $BACKUP_DIR
cd /tmp
sudo -u postgres pg_dump synapse_db > $BACKUP_DIR/db_\$DATE.sql
tar -czf $BACKUP_DIR/matrix_files_\$DATE.tar.gz $CONF_DIR $SECRETS_FILE
echo "Бэкап создан в $BACKUP_DIR"
EOF
    # Восстановление
    cat > /usr/local/bin/matrix-restore <<EOF
#!/bin/bash
read -p "Введи дату бэкапа (ГГГГММДД): " BDATE
if [ ! -f $BACKUP_DIR/db_\$BDATE.sql ]; then echo "Файл не найден!"; exit 1; fi
cd /tmp
systemctl stop matrix-synapse
sudo -u postgres psql -c "DROP DATABASE synapse_db;"
sudo -u postgres psql -c "CREATE DATABASE synapse_db OWNER synapse_user;"
sudo -u postgres psql synapse_db < $BACKUP_DIR/db_\$BDATE.sql
tar -xzf $BACKUP_DIR/matrix_files_\$BDATE.tar.gz -C /
systemctl start matrix-synapse
echo "Сервер восстановлен!"
EOF
    chmod +x /usr/local/bin/matrix-backup /usr/local/bin/matrix-restore
}

# ── Главный цикл ─────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}Matrix Synapse v3.8 — Мастер Установки${NC}"
echo "1. Полная установка (для новичков)"
echo "2. Сделать бэкап сейчас"
echo "3. Восстановить из бэкапа (переезд)"
echo "4. Выход"
read -p "Твой выбор: " mode

case $mode in
    1)
        read -p "Основной домен (matrix.site.com): " DOMAIN
        read -p "Домен для звонков (lk.site.com, Enter - пропустить): " LIVEKIT_DOMAIN
        
        prepare_tools
        setup_db
        setup_synapse
        setup_livekit
        setup_web
        setup_tools
        
        # Создание админа
        ADMIN_PASS=$(pwgen -s 16 1)
        register_new_matrix_user -c $CONF_DIR/homeserver.yaml http://localhost:8008 -u admin -p $ADMIN_PASS -a
        
        section "УСТАНОВКА ЗАВЕРШЕНА"
        echo -e "${GREEN}==================================================${NC}"
        echo -e "  ${BOLD}Адрес сервера:${NC} https://$DOMAIN"
        echo -e "  ${BOLD}Админка:${NC}      https://$DOMAIN/admin"
        echo -e "  ------------------------------------------------"
        echo -e "  ${BOLD}Логин:${NC}        admin"
        echo -e "  ${BOLD}Пароль:${NC}       $ADMIN_PASS"
        echo -e "${GREEN}==================================================${NC}"
        info "Команды в системе: matrix-backup, matrix-restore"
        ;;
    2) /usr/local/bin/matrix-backup ;;
    3) /usr/local/bin/matrix-restore ;;
    *) exit 0 ;;
esac