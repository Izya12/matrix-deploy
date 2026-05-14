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
        curl -fSsL https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg | gpg --dearmor -o /usr/share/keyrings/matrix-org