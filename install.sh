#!/bin/bash
# ============================================================
#  Matrix Synapse + LiveKit  —  v0.9.0
#  Debian 12+  •  запуск от root
#  Меню: install / repair / passwd / backup / restore /
#        migration_backup / migration_restore / admin_passwd / status
# ============================================================

set -o pipefail

SCRIPT_VERSION="v0.9.0"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }
die()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && die "Запускай от root"

# ── Архитектура и Версии ─────────
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="amd64" ;;
  aarch64) ARCH_SUFFIX="arm64" ;;
  *)       ARCH_SUFFIX="amd64" ;;
esac

ELEMENT_VER="v1.12.18"
SYNAPSE_ADMIN_VER="0.10.2"
LIVEKIT_VER="1.11.0"
LKJWT_VER="v0.1.2"
GO_VER="1.24.3"

ELEMENT_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_VER}/element-${ELEMENT_VER}.tar.gz"
SYNAPSE_ADMIN_URL="https://github.com/Awesome-Technologies/synapse-admin/releases/download/${SYNAPSE_ADMIN_VER}/synapse-admin-${SYNAPSE_ADMIN_VER}.tar.gz"
LIVEKIT_URL="https://github.com/livekit/livekit/releases/download/v${LIVEKIT_VER}/livekit_${LIVEKIT_VER}_linux_${ARCH_SUFFIX}.tar.gz"
LKJWT_URL="https://github.com/element-hq/lk-jwt-service/releases/latest/download/lk-jwt-service_linux_${ARCH_SUFFIX}"
GO_URL="https://go.dev/dl/go${GO_VER}.linux-${ARCH_SUFFIX}.tar.gz"

SECRETS_FILE="/root/.matrix_secrets"
BACKUP_DIR="/opt/matrix-backups"
MIGRATION_DIR="/opt/matrix-migration"
BACKUP_KEEP=7

# ══════════════════════════════════════════════════════════
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════
load_secrets() {
  [ -f "$SECRETS_FILE" ] && . "$SECRETS_FILE"
}

# Безопасная запись конфига: пишет в темп, сравнивает, и только если есть отличия — заменяет (делая .bak)
# Возвращает 0 если файл не изменился, 1 если изменён.
safe_write() {
  local target="$1"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target" ]; then
    if diff -q "$tmp" "$target" >/dev/null; then
      rm "$tmp"
      return 0
    else
      cp "$target" "${target}.bak"
    fi
  fi
  mv "$tmp" "$target"
  return 1
}

# Безопасное скачивание с проверкой HTTP кода и целостности
download_file() {
  local url="$1"
  local output="$2"
  local description="${3:-файла}"
  info "Скачиваю $description..."
  curl -L --fail --silent --show-error "$url" -o "$output" || die "Не удалось скачать $description ($url)"
  if [ ! -s "$output" ]; then
    die "Скачанный файл $description пуст"
  fi
}

# Проверка DNS
check_dns() {
  local domain="$1"
  local public_ip
  public_ip=$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org)
  [ -z "$public_ip" ] && { warn "Не удалось определить публичный IP — пропускаю проверку DNS"; return 0; }

  local resolved_ip
  resolved_ip=$(host "$domain" | awk '/has address/ { print $NF; exit }')
  
  if [ -z "$resolved_ip" ] || [ "$resolved_ip" != "$public_ip" ]; then
    warn "Домен $domain резолвится в ${resolved_ip:-ничего}, а должен в $public_ip."
    read -rp "  Всё равно продолжить? (y/n): " CONTINUE_DNS
    [[ ! "$CONTINUE_DNS" =~ ^[yY]$ ]] && die "Исправьте DNS записи для $domain"
  fi
  return 0
}

get_installed_domain() {
  if [ -f /etc/matrix-synapse/homeserver.yaml ]; then
    grep '^server_name:' /etc/matrix-synapse/homeserver.yaml 2>/dev/null \
      | sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' '
  fi
}

get_admin_token() {
  local user="$1" pass="$2"
  curl -s -X POST "http://127.0.0.1:8008/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$user\"},\"password\":\"$pass\"}" \
    | jq -r '.access_token // empty'
}

# ══════════════════════════════════════════════════════════
#  ВОССТАНОВЛЕНИЕ ИЗ ОБЫЧНОГО БЭКАПА (на этом же сервере)
# ══════════════════════════════════════════════════════════
do_restore() {
  section "Восстановление из бэкапа"

  if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
    die "Бэкапов не найдено в $BACKUP_DIR"
  fi

  echo ""
  echo "  Доступные бэкапы:"
  echo ""
  mapfile -t BACKUPS < <(ls -t "$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null)
  for i in "${!BACKUPS[@]}"; do
    local size
    size=$(du -sh "${BACKUPS[$i]}" | cut -f1)
    printf "  ${BOLD}%2d.${NC} %s  (%s)\n" "$((i+1))" "$(basename "${BACKUPS[$i]}")" "$size"
  done

  echo ""
  read -rp "  Номер бэкапа: " N
  [ -z "$N" ] || [ "$N" -lt 1 ] || [ "$N" -gt "${#BACKUPS[@]}" ] && die "Неверный номер"

  local CHOSEN="${BACKUPS[$((N-1))]}"
  echo ""
  warn "Это ЗАМЕНИТ текущие данные содержимым: $(basename "$CHOSEN")"
  read -rp "Уверен? (yes/n): " SURE
  [ "$SURE" != "yes" ] && die "Отмена"

  local TMP
  TMP=$(mktemp -d)
  tar -xzf "$CHOSEN" -C "$TMP"

  systemctl stop matrix-synapse 2>/dev/null || true

  if [ -f "$TMP/synapse.dump" ]; then
    log "Восстанавливаю базу..."
    su -c "dropdb --if-exists synapse" postgres
    su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
      --template=template0 --owner=synapse synapse" postgres
    su -c "pg_restore -d synapse" postgres < "$TMP/synapse.dump"
  fi

  [ -d "$TMP/matrix-synapse-conf" ] && {
    log "Восстанавливаю конфиги..."
    cp -r "$TMP/matrix-synapse-conf/." /etc/matrix-synapse/
  }
  [ -f "$TMP/matrix_secrets" ] && cp "$TMP/matrix_secrets" "$SECRETS_FILE" && chmod 600 "$SECRETS_FILE"

  if [ -d "$TMP/media" ]; then
    log "Восстанавливаю медиа..."
    cp -r "$TMP/media/." /var/lib/matrix-synapse/media/
    chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || true
  fi

  rm -rf "$TMP"
  systemctl start matrix-synapse
  log "Восстановление завершено"
}

# ══════════════════════════════════════════════════════════
#  ВОССТАНОВЛЕНИЕ С ДРУГОГО СЕРВЕРА (migration)
# ══════════════════════════════════════════════════════════
do_migration_restore() {
  section "Восстановление с другого сервера"

  echo ""
  warn "Эта операция предназначена для ЧИСТОГО сервера."
  warn "Все текущие данные Matrix (если есть) будут перезаписаны."
  echo ""

  read -rp "  Путь к migration-архиву (.tar.gz): " ARCHIVE
  [ -z "$ARCHIVE" ] && die "Путь обязателен"
  [ ! -f "$ARCHIVE" ] && die "Файл не найден: $ARCHIVE"

  read -rp "  Уверен что хочешь продолжить? (yes/n): " SURE
  [ "$SURE" != "yes" ] && die "Отмена"

  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget gnupg lsb-release file jq tar 2>/dev/null || true

  local TMP
  TMP=$(mktemp -d)
  log "Распаковываю архив..."
  tar -xzf "$ARCHIVE" -C "$TMP" || die "Не удалось распаковать архив"

  [ ! -f "$TMP/matrix_secrets" ]   && die "В архиве нет matrix_secrets — это не migration-архив"
  [ ! -f "$TMP/synapse.dump" ]     && die "В архиве нет synapse.dump"
  [ ! -d "$TMP/matrix-synapse-conf" ] && die "В архиве нет matrix-synapse-conf"

  . "$TMP/matrix_secrets"
  [ -z "$DOMAIN" ]         && die "В архиве нет DOMAIN"
  [ -z "$LIVEKIT_DOMAIN" ] && die "В архиве нет LIVEKIT_DOMAIN"
  [ -z "$PG_PASS" ]        && die "В архиве нет PG_PASS"

  info "Восстанавливаемые домены:"
  info "  Matrix:  $DOMAIN"
  info "  LiveKit: $LIVEKIT_DOMAIN"
  echo ""
  warn "Убедись что DNS этих доменов уже указывает на ЭТОТ сервер!"
  read -rp "  DNS настроен? (yes/n): " DNSOK
  [ "$DNSOK" != "yes" ] && { rm -rf "$TMP"; die "Сначала настрой DNS"; }

  section "Фаервол"
  apt-get install -y -qq ufw 2>/dev/null || true
  ufw --force enable 2>/dev/null || true
  for p in ssh 80/tcp 443/tcp 3478/tcp 3478/udp 7880/tcp 7881/tcp 49152:65535/udp; do
    ufw allow "$p" 2>/dev/null || true
  done
  log "Порты открыты"

  section "Зависимости"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nginx certbot python3-certbot-nginx postgresql \
    jq coturn qrencode file dnsutils
  log "Установлены"

  section "Synapse"
  if [ ! -f /etc/apt/sources.list.d/matrix-org.list ]; then
    download_file "https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg" \
      "/usr/share/keyrings/matrix-org-archive-keyring.gpg" "Matrix keyring"
    echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/matrix-org.list
    apt-get update -qq
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3
  systemctl stop matrix-synapse 2>/dev/null || true

  section "PostgreSQL"
  systemctl start postgresql
  cd /tmp
  HAS_USER=$(su -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='synapse'\"" postgres 2>/dev/null || true)
  if [ "$HAS_USER" != "1" ]; then
    su -c "psql -c \"CREATE USER synapse WITH PASSWORD '$PG_PASS';\"" postgres
  else
    su -c "psql -c \"ALTER USER synapse WITH PASSWORD '$PG_PASS';\"" postgres
  fi
  su -c "dropdb --if-exists synapse" postgres
  su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
    --template=template0 --owner=synapse synapse" postgres
  log "Восстанавливаю БД из дампа..."
  su -c "pg_restore -d synapse" postgres < "$TMP/synapse.dump"
  cd /root
  log "БД восстановлена"

  rm -rf /etc/matrix-synapse/conf.d 2>/dev/null
  cp -r "$TMP/matrix-synapse-conf/." /etc/matrix-synapse/

  mkdir -p /var/lib/matrix-synapse/media
  if [ -d "$TMP/media" ]; then
    log "Восстанавливаю медиа (может занять время)..."
    cp -r "$TMP/media/." /var/lib/matrix-synapse/media/
  fi
  chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || true
  chmod -R 750 /var/lib/matrix-synapse/

  cp "$TMP/matrix_secrets" "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"

  [ -f "$TMP/turnserver.conf" ] && cp "$TMP/turnserver.conf" /etc/turnserver.conf
  systemctl enable coturn 2>/dev/null || true
  systemctl restart coturn 2>/dev/null || true

  section "Сертификаты"
  if [ -d "$TMP/letsencrypt" ]; then
    log "Восстанавливаю сертификаты из архива..."
    mkdir -p /etc/letsencrypt
    cp -a "$TMP/letsencrypt/." /etc/letsencrypt/
    log "Сертификаты восстановлены"
  else
    warn "Сертификатов в архиве нет — буду запрашивать заново"
    rm -f /etc/nginx/sites-enabled/default
    cat > /etc/nginx/sites-available/matrix-tmp <<NGINX
server { listen 80; server_name $DOMAIN $LIVEKIT_DOMAIN; root /var/www/html; }
NGINX
    ln -sf /etc/nginx/sites-available/matrix-tmp /etc/nginx/sites-enabled/matrix-tmp
    nginx -t && systemctl restart nginx
    certbot certonly --nginx -d "$DOMAIN" -d "$LIVEKIT_DOMAIN" \
      --non-interactive --agree-tos --email "${LE_EMAIL:-admin@$DOMAIN}" \
      || die "Certbot не смог получить сертификат"
    rm -f /etc/nginx/sites-enabled/matrix-tmp /etc/nginx/sites-available/matrix-tmp
  fi

  section "LiveKit"
  [ -f "$TMP/livekit-server" ] && { cp "$TMP/livekit-server" /usr/local/bin/livekit-server; chmod +x /usr/local/bin/livekit-server; }
  [ -f "$TMP/lk-jwt-service" ] && { cp "$TMP/lk-jwt-service" /usr/local/bin/lk-jwt-service; chmod +x /usr/local/bin/lk-jwt-service; }
  [ -d "$TMP/livekit-conf" ] && { mkdir -p /etc/livekit; cp -r "$TMP/livekit-conf/." /etc/livekit/; }
  [ -f "$TMP/livekit.service" ]        && cp "$TMP/livekit.service" /etc/systemd/system/livekit.service
  [ -f "$TMP/lk-jwt-service.service" ] && cp "$TMP/lk-jwt-service.service" /etc/systemd/system/lk-jwt-service.service
  systemctl daemon-reload
  systemctl enable livekit lk-jwt-service 2>/dev/null || true

  if [ -d "$TMP/element-web" ]; then
    section "Element Web"
    rm -rf /var/www/html/element
    mkdir -p /var/www/html/element
    cp -r "$TMP/element-web/." /var/www/html/element/
    chown -R www-data:www-data /var/www/html/element
    log "Element Web восстановлен"
  fi

  section "Nginx"
  [ -f "$TMP/nginx-matrix" ] && {
    cp "$TMP/nginx-matrix" /etc/nginx/sites-available/matrix
    ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    log "Nginx восстановлен"
  }

  [ -d "$TMP/cron" ] && cp -a "$TMP/cron/." /etc/cron.d/
  [ -d "$TMP/utilities" ] && {
    cp -a "$TMP/utilities/." /usr/local/bin/
    chmod +x /usr/local/bin/matrix-* 2>/dev/null || true
  }

  section "Запуск сервисов"
  systemctl enable matrix-synapse 2>/dev/null || true
  systemctl start matrix-synapse
  systemctl restart livekit lk-jwt-service 2>/dev/null || true

  log "Жду Synapse..."
  for i in $(seq 1 45); do
    curl -sf http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 && break
    echo -n "."
    sleep 2
  done
  echo ""

  rm -rf "$TMP"

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║         Восстановление с другого сервера завершено          ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Чат:     https://$DOMAIN/element/"
  echo -e "  LiveKit: wss://$LIVEKIT_DOMAIN"
  echo -e "  Админ:   @${ADMIN_USER:-?}:${DOMAIN}"
  echo ""
}

# ══════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ══════════════════════════════════════════════════════════
clear
echo -e "\n${CYAN}${BOLD}  Matrix Synapse + LiveKit  •  ${SCRIPT_VERSION}${NC}\n"
echo -e "  Что хочешь сделать?\n"
echo -e "  ${BOLD}1.${NC} Установить Matrix + LiveKit с нуля"
echo -e "  ${BOLD}2.${NC} Починить / переустановить (данные сохраняются)"
echo -e "  ${BOLD}3.${NC} Сменить пароль пользователя"
echo -e "  ${BOLD}4.${NC} Создать бэкап"
echo -e "  ${BOLD}5.${NC} Восстановить из бэкапа"
echo -e "  ${BOLD}6.${NC} Бэкап для переезда на другой сервер"
echo -e "  ${BOLD}7.${NC} Восстановление с другого сервера"
echo -e "  ${BOLD}8.${NC} Сброс пароля администратора"
echo -e "  ${BOLD}9.${NC} Проверить состояние сервисов (status)"
echo ""
read -rp "  Выбор [1-9]: " MENU_CHOICE

case "$MENU_CHOICE" in
  1) MODE="install"           ;;
  2) MODE="repair"            ;;
  3) MODE="passwd"            ;;
  4) MODE="backup"            ;;
  5) MODE="restore"           ;;
  6) MODE="migration_backup"  ;;
  7) MODE="migration_restore" ;;
  8) MODE="admin_passwd"      ;;
  9) MODE="status"            ;;
  *) die "Неверный выбор"     ;;
esac

# ══════════════════════════════════════════════════════════
#  РАННИЕ ВЫХОДЫ
# ══════════════════════════════════════════════════════════
load_secrets

if [ "$MODE" = "passwd" ]; then
  [ -x /usr/local/bin/matrix-reset-password ] \
    || die "Утилита не установлена — сначала установи Matrix (пункт 1)"
  /usr/local/bin/matrix-reset-password
  exit 0
fi

if [ "$MODE" = "admin_passwd" ]; then
  [ -x /usr/local/bin/matrix-admin-reset-password ] \
    || die "Утилита не установлена — сначала установи Matrix (пункт 1)"
  /usr/local/bin/matrix-admin-reset-password
  exit 0
fi

if [ "$MODE" = "status" ]; then
  [ -x /usr/local/bin/matrix-status ] \
    || die "Утилита не установлена — сначала установи Matrix (пункт 1)"
  /usr/local/bin/matrix-status
  exit 0
fi

if [ "$MODE" = "backup" ]; then
  [ -x /usr/local/bin/matrix-backup ] \
    || die "Утилита не установлена — сначала установи Matrix (пункт 1)"
  echo ""
  read -rp "  Включить медиафайлы? (y/n): " WM
  WITH_MEDIA="no"
  [[ "$WM" =~ ^[yY]$ ]] && WITH_MEDIA="yes"
  /usr/local/bin/matrix-backup "$WITH_MEDIA"
  exit 0
fi

if [ "$MODE" = "restore" ]; then
  do_restore
  exit 0
fi

if [ "$MODE" = "migration_backup" ]; then
  [ -x /usr/local/bin/matrix-migration-backup ] \
    || die "Утилита не установлена — сначала установи Matrix (пункт 1)"
  /usr/local/bin/matrix-migration-backup
  exit 0
fi

if [ "$MODE" = "migration_restore" ]; then
  do_migration_restore
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  INSTALL / REPAIR — ввод данных
# ══════════════════════════════════════════════════════════
clear
echo -e "\n${CYAN}${BOLD}  Matrix Synapse + LiveKit  •  ${SCRIPT_VERSION}${NC}\n"

if [ "$MODE" = "repair" ]; then
  INSTALLED_DOMAIN=$(get_installed_domain)
  if [ -n "$INSTALLED_DOMAIN" ]; then
    info "Найден установленный домен: $INSTALLED_DOMAIN"
    read -rp "  Использовать его? (y/n): " USE_EX
    if [[ "$USE_EX" =~ ^[yY]$ ]]; then
      DOMAIN="$INSTALLED_DOMAIN"
    else
      read -rp "  Домен Matrix: " DOMAIN
    fi
  else
    read -rp "  Домен Matrix: " DOMAIN
  fi
  load_secrets
  [ -z "$LIVEKIT_DOMAIN" ] && read -rp "  Домен LiveKit: " LIVEKIT_DOMAIN
  [ -z "$LE_EMAIL" ]       && read -rp "  Email для SSL:  " LE_EMAIL
else
  read -rp "  Домен Matrix  (matrix.example.com):  " DOMAIN
  read -rp "  Домен LiveKit (livekit.example.com): " LIVEKIT_DOMAIN
  read -rp "  Email для SSL: " LE_EMAIL
fi

[ -z "$DOMAIN" ]         && die "Домен Matrix обязателен"
[ -z "$LIVEKIT_DOMAIN" ] && die "Домен LiveKit обязателен"
[ -z "$LE_EMAIL" ]       && die "Email обязателен"

[ -z "$PG_PASS" ]             && PG_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
[ -z "$REGISTRATION_SECRET" ] && REGISTRATION_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
[ -z "$MACAROON_SECRET" ]     && MACAROON_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
[ -z "$TURN_SECRET" ]         && TURN_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
[ -z "$LIVEKIT_KEY" ]         && LIVEKIT_KEY="matrix"
[ -z "$LIVEKIT_SECRET" ]      && LIVEKIT_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)

if [ "$MODE" = "install" ]; then
  ADMIN_SUFFIX=$(tr -dc '0-9' </dev/urandom | head -c4)
  ADMIN_USER="admin_${ADMIN_SUFFIX}"
  echo ""
  info "Имя администратора: ${BOLD}${ADMIN_USER}${NC}"
  echo ""
  while true; do
    read -rsp "  Пароль администратора: " ADMIN_PASS; echo ""
    read -rsp "  Повтори пароль:        " ADMIN_PASS2; echo ""
    [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] && break
    warn "Пароли не совпадают"
  done
  [ ${#ADMIN_PASS} -lt 6 ] && die "Пароль слишком короткий"
fi

echo ""
info "Домен Matrix:  $DOMAIN"
info "Домен LiveKit: $LIVEKIT_DOMAIN"
[ "$MODE" = "install" ] && info "Администратор: @${ADMIN_USER}:${DOMAIN}"
[ "$MODE" = "repair" ]  && info "Режим:         починка существующей установки"
echo ""
read -rp "  Всё верно? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && die "Отмена"

if [ "$MODE" = "repair" ] && [ -x /usr/local/bin/matrix-backup ]; then
  section "Бэкап перед починкой"
  mkdir -p "$BACKUP_DIR"
  /usr/local/bin/matrix-backup no || warn "Не удалось сделать бэкап — продолжаю"
fi

# ══════════════════════════════════════════════════════════
#  ФАЕРВОЛ
# ══════════════════════════════════════════════════════════
section "Фаервол"
apt-get install -y -qq ufw 2>/dev/null || true
ufw --force enable 2>/dev/null || true
ufw allow ssh 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 3478/tcp 2>/dev/null || true
ufw allow 3478/udp 2>/dev/null || true
ufw allow 7880/tcp 2>/dev/null || true
ufw allow 7881/tcp 2>/dev/null || true
ufw allow 49152:65535/udp 2>/dev/null || true
log "Порты открыты"

# ══════════════════════════════════════════════════════════
#  ЗАВИСИМОСТИ
# ══════════════════════════════════════════════════════════
section "Зависимости"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget gnupg lsb-release file dnsutils \
  nginx certbot python3-certbot-nginx \
  postgresql fail2ban \
  jq coturn qrencode


# ══════════════════════════════════════════════════════════
#  POSTGRESQL
# ══════════════════════════════════════════════════════════
section "PostgreSQL"
systemctl start postgresql
cd /tmp
HAS_USER=$(su -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='synapse'\"" postgres 2>/dev/null || true)
if [ "$HAS_USER" != "1" ]; then
  su -c "psql -c \"CREATE USER synapse WITH PASSWORD '$PG_PASS';\"" postgres
else
  su -c "psql -c \"ALTER USER synapse WITH PASSWORD '$PG_PASS';\"" postgres
fi
HAS_DB=$(su -c "psql -lqt" postgres 2>/dev/null | cut -d'|' -f1 | grep -w synapse | xargs 2>/dev/null || true)
if [ -z "$HAS_DB" ]; then
  su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
    --template=template0 --owner=synapse synapse" postgres
fi
cd /root
log "PostgreSQL готов"

# ══════════════════════════════════════════════════════════
#  SYNAPSE
# ══════════════════════════════════════════════════════════
section "Synapse"
if [ ! -f /etc/apt/sources.list.d/matrix-org.list ]; then
  download_file "https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg" \
    "/usr/share/keyrings/matrix-org-archive-keyring.gpg" "Matrix keyring"
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

rm -f /etc/matrix-synapse/conf.d/server_name.yaml

mkdir -p /var/lib/matrix-synapse/media
chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || true
chmod -R 750 /var/lib/matrix-synapse/

SYNAPSE_CHANGED=0
safe_write /etc/matrix-synapse/homeserver.yaml <<EOF || SYNAPSE_CHANGED=1
server_name: "$DOMAIN"
public_baseurl: "https://$DOMAIN/"
pid_file: "/var/run/matrix-synapse.pid"

trusted_proxies:
  - 127.0.0.1
  - ::1

listeners:
  - port: 8008
    bind_addresses: ['127.0.0.1']
    type: http
    x_forwarded: true
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  args:
    user: synapse
    password: "$PG_PASS"
    database: synapse
    host: 127.0.0.1
    cp_min: 5
    cp_max: 10

log_config: "/etc/matrix-synapse/log.yaml"
media_store_path: /var/lib/matrix-synapse/media
signing_key_path: "/etc/matrix-synapse/homeserver.signing.key"
max_upload_size: 50M

# Автоудаление удалённых медиа (картинок/видео с других серверов) через 30 дней
media_retention:
  remote_media_lifetime: 30d

enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REGISTRATION_SECRET"
macaroon_secret_key: "$MACAROON_SECRET"

# Федерация — whitelist (по умолчанию только matrix.org).
# Добавить:  matrix-add-federation example.org
# Убрать:    matrix-remove-federation example.org
federation_domain_whitelist:
  - matrix.org
allow_public_rooms_over_federation: false
allow_public_rooms_without_auth: false
federation_verify_certificates: true

# Поиск пользователей — работает сразу после старта
user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true

report_stats: false
suppress_key_server_warning: true
trusted_key_servers:
  - server_name: "matrix.org"

turn_uris:
  - "turn:$DOMAIN:3478?transport=udp"
  - "turn:$DOMAIN:3478?transport=tcp"
  - "stun:$DOMAIN:3478"
turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false

rc_login:
  address:
    per_second: 0.15
    burst_count: 5
  account:
    per_second: 0.18
    burst_count: 4

# MatrixRTC / Element X звонки
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true
  msc3882_enabled: true

matrix_rtc:
  transports:
    - type: livekit
      livekit_service_url: "https://$DOMAIN/livekit/jwt"
EOF
log "Synapse настроен"

# ══════════════════════════════════════════════════════════
#  FAIL2BAN
# ══════════════════════════════════════════════════════════
section "fail2ban"
safe_write /etc/fail2ban/filter.d/matrix-synapse.conf <<EOF
[Definition]
failregex = ^<HOST> - .* - .* - \{.*\} - POST - /_matrix/client/.*/login - 40[13] - \{.*"error":"(Invalid password|Unknown user)".*\}
ignoreregex =
EOF

safe_write /etc/fail2ban/jail.d/matrix-synapse.conf <<EOF
[matrix-synapse]
enabled = true
port = 80,443,8008
filter = matrix-synapse
logpath = /var/log/matrix-synapse/homeserver.log
maxretry = 5
bantime = 3600
EOF

systemctl restart fail2ban
log "fail2ban настроен"

# ══════════════════════════════════════════════════════════
#  COTURN
# ══════════════════════════════════════════════════════════
section "coturn"
COTURN_CHANGED=0
safe_write /etc/turnserver.conf <<EOF || COTURN_CHANGED=1
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$DOMAIN
total-quota=100
stale-nonce
no-multicast-peers
min-port=49152
max-port=57000
log-file=/var/log/turnserver.log
EOF

if [ $COTURN_CHANGED -eq 1 ]; then
  systemctl enable coturn 2>/dev/null || true
  systemctl restart coturn 2>/dev/null || true
  log "coturn настроен и перезапущен"
else
  systemctl enable coturn 2>/dev/null || true
  systemctl start coturn 2>/dev/null || true
  log "coturn без изменений"
fi

# ══════════════════════════════════════════════════════════
#  SSL — с проверкой существующих сертификатов и DNS
# ══════════════════════════════════════════════════════════
section "SSL"
rm -f /etc/nginx/sites-enabled/default

HAS_MAIN_CERT=0
HAS_LK_CERT=0
[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]         && HAS_MAIN_CERT=1
[ -f "/etc/letsencrypt/live/$LIVEKIT_DOMAIN/fullchain.pem" ] && HAS_LK_CERT=1

if [ $HAS_MAIN_CERT -eq 1 ] && [ $HAS_LK_CERT -eq 1 ]; then
  log "Сертификаты для $DOMAIN и $LIVEKIT_DOMAIN уже есть — пропускаю"
else
  # Проверка DNS перед запросом SSL
  [ $HAS_MAIN_CERT -eq 0 ] && check_dns "$DOMAIN"
  [ $HAS_LK_CERT -eq 0 ]   && check_dns "$LIVEKIT_DOMAIN"

  DOMAINS_TO_REQUEST=""
  [ $HAS_MAIN_CERT -eq 0 ] && DOMAINS_TO_REQUEST="$DOMAINS_TO_REQUEST -d $DOMAIN"
  [ $HAS_LK_CERT -eq 0 ]   && DOMAINS_TO_REQUEST="$DOMAINS_TO_REQUEST -d $LIVEKIT_DOMAIN"

  cat > /etc/nginx/sites-available/matrix-tmp <<NGINX
server {
    listen 80;
    server_name $DOMAIN $LIVEKIT_DOMAIN;
    root /var/www/html;
}
NGINX
  ln -sf /etc/nginx/sites-available/matrix-tmp /etc/nginx/sites-enabled/matrix-tmp
  nginx -t && systemctl restart nginx

  certbot certonly --nginx $DOMAINS_TO_REQUEST \
    --non-interactive --agree-tos --email "$LE_EMAIL" \
    || die "Certbot не смог получить сертификат. Домены указывают на этот сервер?"

  rm -f /etc/nginx/sites-enabled/matrix-tmp /etc/nginx/sites-available/matrix-tmp
  log "SSL готов"
fi

# ══════════════════════════════════════════════════════════
#  ELEMENT WEB
# ══════════════════════════════════════════════════════════
section "Element Web"
ELEMENT_VERSION=$(echo "$ELEMENT_URL" | grep -oP 'v\d+\.\d+\.\d+' | head -1)
CURRENT_ELEMENT_VER=$(cat /var/www/html/element/version 2>/dev/null || echo "none")

if [ "$ELEMENT_VERSION" = "$CURRENT_ELEMENT_VER" ] && [ -d /var/www/html/element ]; then
  log "Element Web $ELEMENT_VERSION уже установлен"
else
  download_file "$ELEMENT_URL" "/tmp/element.tar.gz" "Element Web"
  if file /tmp/element.tar.gz | grep -q compressed; then
    rm -rf /var/www/html/element
    mkdir -p /var/www/html/element
    tar -xzf /tmp/element.tar.gz -C /var/www/html/element --strip-components=1
    echo "$ELEMENT_VERSION" > /var/www/html/element/version
    log "Element Web распакован ($ELEMENT_VERSION)"
  else
    warn "Некорректный архив Element Web"
    rm -f /tmp/element.tar.gz
  fi
fi

if [ -d /var/www/html/element ]; then
  safe_write /var/www/html/element/config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$DOMAIN",
            "server_name": "$DOMAIN"
        }
    },
    "disable_custom_urls": true,
    "default_federate": false,
    "brand": "Приватный чат",
    "features": {
        "feature_video_rooms": true,
        "feature_element_call": true
    }
}
EOF
  chown -R www-data:www-data /var/www/html/element
  log "Element Web настроен"
fi
rm -f /tmp/element.tar.gz

# ══════════════���══�����══════��═════════════════════════════════
#  LIVEKIT SERVER
# ════════════════════���═══════���═════════════════════════════
# ══════════════════════════════════════════════════════════
#  SYNAPSE ADMIN
# ══════════════════════════════════════════════════════════
section "Synapse Admin"
CURRENT_SADMIN_VER=$(cat /var/www/html/admin/version 2>/dev/null || echo "none")

if [ "$SYNAPSE_ADMIN_VER" = "$CURRENT_SADMIN_VER" ] && [ -d /var/www/html/admin ]; then
  log "Synapse Admin $SYNAPSE_ADMIN_VER уже установлен"
else
  download_file "$SYNAPSE_ADMIN_URL" "/tmp/synapse-admin.tar.gz" "Synapse Admin"
  if file /tmp/synapse-admin.tar.gz | grep -q compressed; then
    rm -rf /var/www/html/admin
    mkdir -p /var/www/html/admin
    tar -xzf /tmp/synapse-admin.tar.gz -C /var/www/html/admin --strip-components=1
    echo "$SYNAPSE_ADMIN_VER" > /var/www/html/admin/version
    chown -R www-data:www-data /var/www/html/admin
    log "Synapse Admin распакован ($SYNAPSE_ADMIN_VER)"
  else
    warn "Некорректный архив Synapse Admin"
  fi
  rm -f /tmp/synapse-admin.tar.gz
fi

section "LiveKit Server"
LK_VERSION=$(echo "$LIVEKIT_URL" | grep -oP '\d+\.\d+\.\d+' | head -1)
CURRENT_LK_VER=$(/usr/local/bin/livekit-server --version 2>/dev/null | awk '{print $3}')

LK_CHANGED=0
if [ "$LK_VERSION" = "$CURRENT_LK_VER" ] && [ -x /usr/local/bin/livekit-server ]; then
  log "LiveKit Server $LK_VERSION уже установлен"
else
  download_file "$LIVEKIT_URL" "/tmp/livekit.tar.gz" "LiveKit Server"
  if file /tmp/livekit.tar.gz | grep -q compressed; then
    mkdir -p /tmp/livekit-extract
    tar -xzf /tmp/livekit.tar.gz -C /tmp/livekit-extract/
    LK_BIN=$(find /tmp/livekit-extract -type f -executable 2>/dev/null | head -1)
    if [ -n "$LK_BIN" ]; then
      mv "$LK_BIN" /usr/local/bin/livekit-server
      chmod +x /usr/local/bin/livekit-server
      LK_CHANGED=1
      log "LiveKit бинарник установлен ($LK_VERSION)"
    else
      warn "Бинарник LiveKit не найден в архиве"
    fi
    rm -rf /tmp/livekit-extract /tmp/livekit.tar.gz
  else
    warn "Некорректный архив LiveKit"
    rm -f /tmp/livekit.tar.gz
  fi
fi

mkdir -p /etc/livekit
safe_write /etc/livekit/livekit.yaml <<EOF || LK_CHANGED=1
port: 7880
rtc:
  tcp_port: 7881
  port_range_start: 57001
  port_range_end: 65535
  use_external_ip: true
keys:
  $LIVEKIT_KEY: $LIVEKIT_SECRET
logging:
  level: info
EOF

safe_write /etc/systemd/system/livekit.service <<EOF || LK_CHANGED=1
[Unit]
Description=LiveKit Server
After=network.target

[Service]
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=5

# Security Hardening
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
PrivateDevices=yes
DevicePolicy=closed
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF

if [ $LK_CHANGED -eq 1 ]; then
  systemctl daemon-reload
  systemctl enable livekit 2>/dev/null || true
  systemctl restart livekit 2>/dev/null || true
  log "LiveKit запущен/перезапущен"
else
  systemctl enable livekit 2>/dev/null || true
  systemctl start livekit 2>/dev/null || true
fi

# ════���═════════════════════════════════════════════════════
#  LK-JWT-SERVICE
# ══════════════════════════════════════════════════════════
section "lk-jwt-service"
JWT_CHANGED=0

CURRENT_JWT_VER=${INSTALLED_LKJWT_VER:-none}

if [ "$LKJWT_VER" = "$CURRENT_JWT_VER" ] && [ -x /usr/local/bin/lk-jwt-service ]; then
  log "lk-jwt-service $LKJWT_VER уже установлен"
else
  info "Проверяю/скачиваю lk-jwt-service..."
  curl -L --fail --silent --show-error "$LKJWT_URL" -o /tmp/lk-jwt-service || warn "Не удалось скачать бинарник lk-jwt-service"
  if [ -f /tmp/lk-jwt-service ] && file /tmp/lk-jwt-service | grep -q ELF; then
    mv /tmp/lk-jwt-service /usr/local/bin/lk-jwt-service
    chmod +x /usr/local/bin/lk-jwt-service
    JWT_CHANGED=1
    log "lk-jwt-service установлен из бинарника"
  else
    warn "Бинарник lk-jwt-service не найден или не валиден — собираю из исходников..."
    rm -f /tmp/lk-jwt-service
    apt-get install -y -qq golang-go git 2>/dev/null || true
    if ! command -v go >/dev/null 2>&1; then
      download_file "$GO_URL" "/tmp/go.tar.gz" "Go"
      tar -xzf /tmp/go.tar.gz -C /usr/local/
      rm -f /tmp/go.tar.gz
      export PATH=$PATH:/usr/local/go/bin
    fi
    rm -rf /tmp/lkjwt
    git clone --depth=1 https://github.com/element-hq/lk-jwt-service /tmp/lkjwt 2>/dev/null
    if [ -d /tmp/lkjwt ]; then
      sed -i 's/decoder.DisallowUnknownFields()/\/\/decoder.DisallowUnknownFields()/g' /tmp/lkjwt/main.go
      cd /tmp/lkjwt && go build -o /usr/local/bin/lk-jwt-service . 2>/dev/null
      cd /root
      rm -rf /tmp/lkjwt
      if [ -f /usr/local/bin/lk-jwt-service ]; then
        JWT_CHANGED=1
        log "lk-jwt-service собран из исходников"
      else
        warn "Не удалось собрать lk-jwt-service"
      fi
    fi
  fi
fi

safe_write /etc/systemd/system/lk-jwt-service.service <<EOF || JWT_CHANGED=1
[Unit]
Description=LiveKit JWT Service for Matrix
After=network.target

[Service]
Environment="LIVEKIT_URL=wss://$LIVEKIT_DOMAIN"
Environment="LIVEKIT_KEY=$LIVEKIT_KEY"
Environment="LIVEKIT_SECRET=$LIVEKIT_SECRET"
Environment="LIVEKIT_FULL_ACCESS_HOMESERVERS=$DOMAIN"
ExecStart=/usr/local/bin/lk-jwt-service
Restart=always
RestartSec=5

# Security Hardening
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
PrivateDevices=yes
DevicePolicy=closed
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF

if [ $JWT_CHANGED -eq 1 ]; then
  systemctl daemon-reload
  systemctl enable lk-jwt-service 2>/dev/null || true
  systemctl restart lk-jwt-service 2>/dev/null || true
  log "lk-jwt-service запущен/перезапущен"
else
  systemctl enable lk-jwt-service 2>/dev/null || true
  systemctl start lk-jwt-service 2>/dev/null || true
fi
section "Nginx"

WELL_KNOWN_CLIENT="{\"m.homeserver\":{\"base_url\":\"https://$DOMAIN\"},\"org.matrix.msc4143.rtc_foci\":[{\"type\":\"livekit\",\"livekit_service_url\":\"https://$DOMAIN/livekit/jwt\"}]}"

NGINX_CHANGED=0
safe_write /etc/nginx/sites-available/matrix <<NGINX || NGINX_CHANGED=1
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '$WELL_KNOWN_CLIENT';
    }
    location /.well-known/matrix/server {
        default_type application/json;
        return 200 '{"m.server":"$DOMAIN:443"}';
    }

    location /element/ {
        alias /var/www/html/element/;
        try_files \$uri \$uri/ /element/index.html;
    }

    location /admin/ {
        alias /var/www/html/admin/;
        try_files \$uri \$uri/ /admin/index.html;
    }

    location ^~ /livekit/jwt {
        rewrite ^/livekit/jwt/?(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /_matrix/media/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }

    location /_matrix/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
    }
    location /_synapse/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}

server {
    listen 80;
    server_name $LIVEKIT_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $LIVEKIT_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
    }
}
NGINX

if [ $NGINX_CHANGED -eq 1 ]; then
  ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  log "Nginx настроен и перезагружен"
else
  log "Nginx без изменений"
fi

# ══════════════════════════════════════════════════════════
#  ЗАПУСК SYNAPSE + АДМИНИСТРАТОР
# ══════════════════════════════════════════════════════════
section "Запуск Synapse"
if [ $SYNAPSE_CHANGED -eq 1 ]; then
  systemctl restart matrix-synapse
  log "Synapse перезапущен (конфиг изменён)"
else
  systemctl enable matrix-synapse 2>/dev/null || true
  systemctl start matrix-synapse
  log "Synapse запущен (без изменений в конфиге)"
fi

log "Жду Synapse (до 90 сек)..."
for i in $(seq 1 45); do
  curl -sf http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 && break
  echo -n "."
  sleep 2
done
echo ""
curl -sf http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 \
  || die "Synapse не поднялся. Смотри: journalctl -u matrix-synapse -n 50"
log "Synapse запущен"

if [ "$MODE" = "install" ]; then
  section "Администратор"
  register_new_matrix_user \
    -c /etc/matrix-synapse/homeserver.yaml \
    -u "$ADMIN_USER" -p "$ADMIN_PASS" -a \
    http://127.0.0.1:8008 2>/dev/null \
    && log "Администратор @${ADMIN_USER}:${DOMAIN} создан" \
    || warn "Пользователь уже существует"
fi

safe_write "$SECRETS_FILE" <<EOF
DOMAIN=$DOMAIN
LIVEKIT_DOMAIN=$LIVEKIT_DOMAIN
ADMIN_USER=${ADMIN_USER:-}
LE_EMAIL=$LE_EMAIL
PG_PASS=$PG_PASS
REGISTRATION_SECRET=$REGISTRATION_SECRET
MACAROON_SECRET=$MACAROON_SECRET
TURN_SECRET=$TURN_SECRET
LIVEKIT_KEY=$LIVEKIT_KEY
LIVEKIT_SECRET=$LIVEKIT_SECRET
INSTALLED_ELEMENT_VER=$ELEMENT_VER
INSTALLED_LIVEKIT_VER=$LIVEKIT_VER
INSTALLED_LKJWT_VER=$LKJWT_VER
EOF
chmod 600 "$SECRETS_FILE"

# Регенерация user directory — чтобы поиск работал сразу
if [ "$MODE" = "install" ] && [ -n "$ADMIN_PASS" ]; then
  sleep 3
  ACCESS_TOKEN=$(get_admin_token "$ADMIN_USER" "$ADMIN_PASS")
  if [ -n "$ACCESS_TOKEN" ]; then
    curl -s -X POST "http://127.0.0.1:8008/_synapse/admin/v1/background_updates/start_job" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"job_name":"regenerate_directory"}' >/dev/null 2>&1 \
      && log "User directory регенерируется — поиск заработает через несколько секунд" \
      || warn "Не удалось запустить регенерацию user directory"
    echo "$ACCESS_TOKEN" > /root/.matrix_access_token
    chmod 600 /root/.matrix_access_token
  fi
fi

# ══════════════════════════════════════════════════════════
#  УТИЛИТЫ В /usr/local/bin
# ══════════════════════════════════════════════════════════
section "Утилиты"

safe_write /usr/local/bin/matrix-reset-password <<SCRIPT
#!/bin/bash
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOMAIN="$DOMAIN"

echo ""
echo -e "\${CYAN}\${BOLD}━━━ Смена пароля Matrix ━━━\${NC}"
echo ""

echo -e "\${BLUE}[i]\${NC} Пользователи (★ = админ):"
su -c "psql -d synapse -tAc \"SELECT name, admin FROM users WHERE deactivated=0 ORDER BY creation_ts;\"" postgres 2>/dev/null \
  | awk -F'|' '{ printf "  %s%s\n", \$1, (\$2==1 ? "  ★" : "") }' \
  || echo "  (не удалось получить список)"

echo ""
read -rp "Имя пользователя (anton или @anton:\$DOMAIN): " TARGET_USER
[[ "\$TARGET_USER" != @* ]] && TARGET_USER="@\${TARGET_USER}:\$DOMAIN"

echo -e "\${BLUE}[i]\${NC} Меняем пароль для: \${BOLD}\$TARGET_USER\${NC}"
echo ""

while true; do
  read -rsp "Новый пароль: " NEW_PASS; echo ""
  read -rsp "Повтори:      " NEW_PASS2; echo ""
  [ "\$NEW_PASS" = "\$NEW_PASS2" ] && break
  echo -e "\${YELLOW}[!]\${NC} Не совпадают"
done

[ \${#NEW_PASS} -lt 6 ] && { echo -e "\${RED}[✗]\${NC} Слишком короткий"; exit 1; }

HASH=\$(hash_password -p "\$NEW_PASS" -c /etc/matrix-synapse/homeserver.yaml 2>/dev/null)
[ -z "\$HASH" ] && { echo -e "\${RED}[✗]\${NC} hash_password не сработал"; exit 1; }

su -c "psql -d synapse -c \"UPDATE users SET password_hash='\$HASH' WHERE name='\$TARGET_USER';\"" postgres >/dev/null
su -c "psql -d synapse -c \"DELETE FROM access_tokens WHERE user_id='\$TARGET_USER';\"" postgres >/dev/null

echo -e "\${GREEN}[✓]\${NC} Пароль изменён, все сессии завершены"
SCRIPT
chmod +x /usr/local/bin/matrix-reset-password

safe_write /usr/local/bin/matrix-admin-reset-password <<SCRIPT
#!/bin/bash
set -e
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DOMAIN="$DOMAIN"

echo ""
echo -e "\${CYAN}\${BOLD}━━━ Сброс пароля администратора ━━━\${NC}"
echo ""

mapfile -t ADMINS < <(su -c "psql -d synapse -tAc \"SELECT name FROM users WHERE admin=1 AND deactivated=0 ORDER BY creation_ts;\"" postgres 2>/dev/null)

if [ \${#ADMINS[@]} -eq 0 ]; then
  echo -e "\${RED}[✗]\${NC} Администраторов не найдено"
  exit 1
fi

echo -e "\${BLUE}[i]\${NC} Администраторы:"
for i in "\${!ADMINS[@]}"; do
  printf "  %d. %s\n" "\$((i+1))" "\${ADMINS[\$i]}"
done

echo ""
read -rp "Номер администратора: " N
[ -z "\$N" ] || [ "\$N" -lt 1 ] || [ "\$N" -gt \${#ADMINS[@]} ] && { echo -e "\${RED}[✗]\${NC} Неверный выбор"; exit 1; }

TARGET="\${ADMINS[\$((N-1))]}"
echo -e "\${BLUE}[i]\${NC} Меняем пароль для: \${BOLD}\$TARGET\${NC}"
echo ""

while true; do
  read -rsp "Новый пароль: " NEW_PASS; echo ""
  read -rsp "Повтори:      " NEW_PASS2; echo ""
  [ "\$NEW_PASS" = "\$NEW_PASS2" ] && break
  echo -e "\${YELLOW}[!]\${NC} Не совпадают"
done

[ \${#NEW_PASS} -lt 6 ] && { echo -e "\${RED}[✗]\${NC} Слишком короткий"; exit 1; }

HASH=\$(hash_password -p "\$NEW_PASS" -c /etc/matrix-synapse/homeserver.yaml 2>/dev/null)
[ -z "\$HASH" ] && { echo -e "\${RED}[✗]\${NC} hash_password не сработал"; exit 1; }

su -c "psql -d synapse -c \"UPDATE users SET password_hash='\$HASH' WHERE name='\$TARGET';\"" postgres >/dev/null
su -c "psql -d synapse -c \"DELETE FROM access_tokens WHERE user_id='\$TARGET';\"" postgres >/dev/null

echo -e "\${GREEN}[✓]\${NC} Пароль администратора \$TARGET изменён"
echo -e "\${GREEN}[✓]\${NC} Все его сессии завершены"
SCRIPT
chmod +x /usr/local/bin/matrix-admin-reset-password

safe_write /usr/local/bin/matrix-backup <<'SCRIPT'
#!/bin/bash
set -e
BACKUP_DIR="/opt/matrix-backups"
BACKUP_KEEP=7
WITH_MEDIA="${1:-no}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}[i]${NC} Начинаю бэкап Matrix..."
mkdir -p "$BACKUP_DIR"

TS=$(date +%Y-%m-%d_%H-%M)
TMP=$(mktemp -d)
OUT="$BACKUP_DIR/matrix-$TS.tar.gz"

echo -e "${BLUE}[i]${NC} Дамп PostgreSQL..."
su -c "pg_dump -Fc synapse" postgres > "$TMP/synapse.dump"

echo -e "${BLUE}[i]${NC} Конфиги..."
cp -r /etc/matrix-synapse "$TMP/matrix-synapse-conf"
cp /root/.matrix_secrets "$TMP/matrix_secrets" 2>/dev/null || true

if [ "$WITH_MEDIA" = "yes" ]; then
  echo -e "${BLUE}[i]${NC} Медиа..."
  cp -r /var/lib/matrix-synapse/media "$TMP/media" 2>/dev/null || true
fi

echo -e "${BLUE}[i]${NC} Упаковываю..."
tar -czf "$OUT" -C "$TMP" .
rm -rf "$TMP"

SIZE=$(du -sh "$OUT" | cut -f1)
echo -e "${GREEN}[✓]${NC} $OUT ($SIZE)"

ls -t "$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs rm -f 2>/dev/null || true
SCRIPT
chmod +x /usr/local/bin/matrix-backup

safe_write /usr/local/bin/matrix-migration-backup <<'SCRIPT'
#!/bin/bash
set -e
MIGRATION_DIR="/opt/matrix-migration"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}━━━ Бэкап для переезда на другой сервер ━━━${NC}"
echo ""
echo -e "${YELLOW}[!]${NC} В архив попадут ВСЕ данные включая медиа, сертификаты"
echo -e "${YELLOW}[!]${NC} Это полный снимок для развёртывания на чистом сервере"
echo ""
read -rp "Продолжить? (y/n): " GO
[ "$GO" != "y" ] && [ "$GO" != "Y" ] && exit 0

mkdir -p "$MIGRATION_DIR"
TS=$(date +%Y-%m-%d_%H-%M)
TMP=$(mktemp -d)
OUT="$MIGRATION_DIR/matrix-migration-$TS.tar.gz"

echo -e "${BLUE}[i]${NC} Дамп PostgreSQL..."
su -c "pg_dump -Fc synapse" postgres > "$TMP/synapse.dump"

echo -e "${BLUE}[i]${NC} Конфиги Synapse (включая signing.key)..."
cp -r /etc/matrix-synapse "$TMP/matrix-synapse-conf"

echo -e "${BLUE}[i]${NC} Секреты..."
cp /root/.matrix_secrets "$TMP/matrix_secrets"

echo -e "${BLUE}[i]${NC} Медиафайлы..."
[ -d /var/lib/matrix-synapse/media ] && cp -r /var/lib/matrix-synapse/media "$TMP/media"

echo -e "${BLUE}[i]${NC} Сертификаты Let's Encrypt..."
[ -d /etc/letsencrypt ] && cp -a /etc/letsencrypt "$TMP/letsencrypt"

echo -e "${BLUE}[i]${NC} Nginx конфиг..."
[ -f /etc/nginx/sites-available/matrix ] && cp /etc/nginx/sites-available/matrix "$TMP/nginx-matrix"

echo -e "${BLUE}[i]${NC} coturn..."
[ -f /etc/turnserver.conf ] && cp /etc/turnserver.conf "$TMP/turnserver.conf"

echo -e "${BLUE}[i]${NC} LiveKit (конфиги, бинари, systemd-юниты)..."
[ -d /etc/livekit ] && cp -r /etc/livekit "$TMP/livekit-conf"
[ -f /usr/local/bin/livekit-server ] && cp /usr/local/bin/livekit-server "$TMP/livekit-server"
[ -f /usr/local/bin/lk-jwt-service ] && cp /usr/local/bin/lk-jwt-service "$TMP/lk-jwt-service"
[ -f /etc/systemd/system/livekit.service ]        && cp /etc/systemd/system/livekit.service "$TMP/livekit.service"
[ -f /etc/systemd/system/lk-jwt-service.service ] && cp /etc/systemd/system/lk-jwt-service.service "$TMP/lk-jwt-service.service"

echo -e "${BLUE}[i]${NC} Element Web..."
[ -d /var/www/html/element ] && cp -r /var/www/html/element "$TMP/element-web"

echo -e "${BLUE}[i]${NC} Cron задачи..."
mkdir -p "$TMP/cron"
for f in /etc/cron.d/matrix-* /etc/cron.d/certbot-renew; do
  [ -f "$f" ] && cp "$f" "$TMP/cron/"
done

echo -e "${BLUE}[i]${NC} Утилиты matrix-*..."
mkdir -p "$TMP/utilities"
for f in /usr/local/bin/matrix-*; do
  [ -f "$f" ] && cp "$f" "$TMP/utilities/"
done

echo -e "${BLUE}[i]${NC} Упаковываю (может занять время)..."
tar -czf "$OUT" -C "$TMP" .
rm -rf "$TMP"

SIZE=$(du -sh "$OUT" | cut -f1)
echo ""
echo -e "${GREEN}[✓]${NC} Migration-архив готов: $OUT ($SIZE)"
echo ""
echo -e "${CYAN}Дальше:${NC}"
echo "  1. Скачай архив на новый сервер: scp $OUT root@новый-сервер:/root/"
echo "  2. На новом сервере направь DNS этих доменов на его IP"
echo "  3. Запусти install.sh → пункт 7 (Восстановление с другого сервера)"
echo "  4. Укажи путь к архиву"
SCRIPT
chmod +x /usr/local/bin/matrix-migration-backup

safe_write /usr/local/bin/matrix-media-cleanup <<'SCRIPT'
#!/bin/bash
# Чистит кэш медиа с других серверов старше 30 дней через Admin API
TOKEN_FILE="/root/.matrix_access_token"
if [ ! -f "$TOKEN_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): error: no access token found in $TOKEN_FILE" >> /var/log/matrix-media-cleanup.log
    exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")
BEFORE_TS=$(date -d "30 days ago" +%s%3N)

RESPONSE=$(curl -s -X POST "http://127.0.0.1:8008/_synapse/admin/v1/purge_media_cache?before_ts=$BEFORE_TS" \
     -H "Authorization: Bearer $TOKEN")

echo "$(date '+%Y-%m-%d %H:%M:%S'): media cleanup done. Response: $RESPONSE" >> /var/log/matrix-media-cleanup.log
SCRIPT
chmod +x /usr/local/bin/matrix-media-cleanup

safe_write /usr/local/bin/matrix-add-federation <<'SCRIPT'
#!/bin/bash
set -e
[ -z "$1" ] && { echo "Использование: matrix-add-federation домен"; exit 1; }
FEDOMAIN="$1"
CONFIG="/etc/matrix-synapse/homeserver.yaml"
ESC="${FEDOMAIN//./\\.}"

if grep -qE "^[[:space:]]*-[[:space:]]+${ESC}[[:space:]]*$" "$CONFIG"; then
  echo "Домен $FEDOMAIN уже в whitelist"
  exit 0
fi

if grep -qE "^federation_domain_whitelist:[[:space:]]*\[[[:space:]]*\][[:space:]]*$" "$CONFIG"; then
  sed -i 's/^federation_domain_whitelist:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/federation_domain_whitelist:/' "$CONFIG"
fi

sed -i "/^federation_domain_whitelist:[[:space:]]*$/a\\  - $FEDOMAIN" "$CONFIG"

systemctl restart matrix-synapse
echo "Домен $FEDOMAIN добавлен в federation whitelist"
SCRIPT
chmod +x /usr/local/bin/matrix-add-federation

safe_write /usr/local/bin/matrix-remove-federation <<'SCRIPT'
#!/bin/bash
set -e
[ -z "$1" ] && { echo "Использование: matrix-remove-federation домен"; exit 1; }
FEDOMAIN="$1"
CONFIG="/etc/matrix-synapse/homeserver.yaml"
ESC="${FEDOMAIN//./\\.}"

sed -i "/^[[:space:]]*-[[:space:]]\+${ESC}[[:space:]]*$/d" "$CONFIG"

systemctl restart matrix-synapse
echo "Домен $FEDOMAIN удалён из federation whitelist"
SCRIPT
chmod +x /usr/local/bin/matrix-remove-federation

safe_write /usr/local/bin/matrix-status <<'SCRIPT'
#!/bin/bash
[ "$EUID" -ne 0 ] && { echo "Запускай от root"; exit 1; }
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "\n${CYAN}${BOLD}━━━ Состояние Matrix + LiveKit ━━━${NC}\n"

# 1. Сервисы
echo -e "${BOLD}Сервисы:${NC}"
services=("matrix-synapse" "postgresql" "nginx" "coturn" "fail2ban" "livekit" "lk-jwt-service")
for svc in "${services[@]}"; do
if systemctl is-active --quiet "$svc"; then
  printf "  %-20s ${GREEN}[RUNNING]${NC}\n" "$svc"
else
  printf "  %-20s ${RED}[STOPPED]${NC}\n" "$svc"
fi
done

# 2. Порты
echo -e "\n${BOLD}Порты:${NC}"
ports=(8008 3478 7880 8080)
names=("Synapse" "TURN" "LiveKit" "LK-JWT")
for i in "${!ports[@]}"; do
if ss -tuln | grep -q ":${ports[$i]} "; then
  printf "  %-12s (:%-4s) ${GREEN}[LISTEN]${NC}\n" "${names[$i]}" "${ports[$i]}"
else
  printf "  %-12s (:%-4s) ${RED}[DOWN]${NC}\n" "${names[$i]}" "${ports[$i]}"
fi
done

# 3. SSL
echo -e "\n${BOLD}SSL Сертификаты:${NC}"
for domain in $(ls /etc/letsencrypt/live/ 2>/dev/null); do
[ "$domain" = "README" ] && continue
cert="/etc/letsencrypt/live/$domain/fullchain.pem"
if [ -f "$cert" ]; then
  expiry=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
  expiry_s=$(date -d "$expiry" +%s)
  now_s=$(date +%s)
  diff=$(( (expiry_s - now_s) / 86400 ))

  if [ $diff -gt 15 ]; then
    color=$GREEN
  elif [ $diff -gt 0 ]; then
    color=$YELLOW
  else
    color=$RED
  fi
  printf "  %-20s ${color}%s дней${NC} (до %s)\n" "$domain" "$diff" "$expiry"
fi
done

# 4. Диск
echo -e "\n${BOLD}Дисковое пространство:${NC}"
df -h / | awk 'NR==2 { printf "  Корень: %s используется из %s (%s свободно)\n", $3, $2, $4 }'
[ -d /var/lib/matrix-synapse/media ] && du -sh /var/lib/matrix-synapse/media | awk '{ printf "  Медиа:  %s\n", $1 }'
[ -d /opt/matrix-backups ] && du -sh /opt/matrix-backups | awk '{ printf "  Бэкапы: %s\n", $1 }'

echo ""
SCRIPT
chmod +x /usr/local/bin/matrix-status

log "Утилиты установлены"

# ══════════════════════════════════════════════════════════
#  CRON ЗАДАЧИ
# ══════════════════════════════════════════════════════════
section "Cron задачи"

# Медиа cleanup — 1-го числа в 04:00
safe_write /etc/cron.d/matrix-media-cleanup <<EOF
0 4 1 * * root /usr/local/bin/matrix-media-cleanup
EOF

# Ежедневный бэкап — 02:00, без медиа
safe_write /etc/cron.d/matrix-backup <<EOF
0 2 * * * root /usr/local/bin/matrix-backup no >> /var/log/matrix-backup.log 2>&1
EOF

# Certbot renewal
if ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
  safe_write /etc/cron.d/certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --nginx
EOF
fi

mkdir -p "$BACKUP_DIR" "$MIGRATION_DIR"
log "Cron задачи установлены"

# ══════════════════════════════════════════════════════════
#  ПРОВЕРКА
# ══════════════════════════════════════════════════════════
section "Проверка"
sleep 3

chk() {
  local label="$1" url="$2"
  if curl -sf --max-time 10 "$url" >/dev/null 2>&1; then
    log "$label"
  else
    warn "НЕДОСТУПНО: $label ($url)"
  fi
}
chk "Synapse API"        "https://$DOMAIN/_matrix/client/versions"
chk "Element Web"        "https://$DOMAIN/element/"
chk "Well-known client"  "https://$DOMAIN/.well-known/matrix/client"
chk "Well-known server"  "https://$DOMAIN/.well-known/matrix/server"
chk "lk-jwt-service"     "https://$DOMAIN/livekit/jwt/"
chk "LiveKit server"     "https://$LIVEKIT_DOMAIN"

MSC=$(curl -s http://127.0.0.1:8008/_matrix/client/versions \
  | jq -r '.unstable_features["org.matrix.msc4143"] // false' 2>/dev/null)
if [ "$MSC" = "true" ]; then
  log "MSC4143 активен — звонки должны работать"
else
  warn "MSC4143 не активен — проверь homeserver.yaml"
fi

FED_ACCESSIBLE=$(curl -s --max-time 5 "https://$DOMAIN/_matrix/federation/v1/version" 2>/dev/null | jq -r '.server.name // empty' 2>/dev/null)
if [ -n "$FED_ACCESSIBLE" ]; then
  log "Federation endpoint доступен"
else
  warn "Federation endpoint не отвечает"
fi

# ══════════════════════════════════════════════════════════
#  ИТОГ
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║            Matrix + LiveKit  •  ${SCRIPT_VERSION}                      ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
printf  "  ║  Чат:     https://%-42s║\n" "$DOMAIN/element/"
printf  "  ║  Админка: https://%-42s║\n" "$DOMAIN/admin/"
printf  "  ║  LiveKit: wss://%-44s║\n" "$LIVEKIT_DOMAIN"
echo    "  ╠══════════════════════════════════════════════════════════════╣"
if [ "$MODE" = "install" ]; then
printf  "  ║  Логин:   %-49s║\n" "$ADMIN_USER"
printf  "  ║  Пароль:  %-49s║\n" "$ADMIN_PASS"
else
printf  "  ║  Админ:   %-49s║\n" "${ADMIN_USER:-?}"
fi
echo    "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$MODE" = "install" ]; then
  echo -e "  ${YELLOW}⚠  ЗАПИШИ логин и пароль!${NC}"
fi
echo -e "  ${YELLOW}⚠  Секреты:    /root/.matrix_secrets${NC}"
echo -e "  ${YELLOW}⚠  Бэкапы:     $BACKUP_DIR  (каждый день в 02:00)${NC}"
echo -e "  ${YELLOW}⚠  Media wipe: 1 числа в 04:00 (remote медиа >30 дней)${NC}"
echo ""

echo -e "  ${CYAN}Команды:${NC}"
echo -e "    matrix-status                 — проверить состояние сервисов"
echo -e "    matrix-reset-password         — сменить пароль пользователя"
echo -e "    matrix-admin-reset-password   — сбросить пароль адм��нистратора"
echo -e "    matrix-backup [yes]           — обычный бэкап (yes = с медиа)"
echo -e "    matrix-migration-backup       — бэкап для переезда"
echo -e "    matrix-add-federation X       — разрешить федерацию с X"
echo -e "    matrix-remove-federation X    — запретить федерацию с X"
echo ""

echo -e "  ${CYAN}Управление пользователями (Админка):${NC}"
echo -e "  https://$DOMAIN/admin/"
echo -e "  Homeserver URL: https://$DOMAIN"
echo ""

if command -v qrencode >/dev/null 2>&1; then
  qrencode -t UTF8 -o - "https://$DOMAIN/admin/" \
    2>/dev/null | sed 's/^/  /'
fi
echo ""
