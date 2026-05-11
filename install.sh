#!/bin/bash
# ============================================================
#  Matrix Synapse — автоустановка v3.1
#  Debian 12+  •  запуск от root
#  github.com/ТВОЙ_НИК/matrix-deploy
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
err()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Проверка root ─────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && err "Запускай от root: sudo bash $0"

# ── Конфигурация путей ────────────────────────────────────
SECRETS_FILE="/root/.matrix_secrets"
PG_PASS_FILE="/root/.matrix_pg_pass"
BACKUP_DIR="/opt/matrix-backups"
BACKUP_KEEP=7
LIVEKIT_DOMAIN=""  # заполняется при вводе

# ── Баннер ───────────────────────────────────────────────
show_banner() {
  clear
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║     Matrix Synapse  •  Deploy v3.1              ║"
  echo "  ║     Debian 12+  •  One command install          ║"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ══════════════════════════════════════════════════════════
show_banner
echo -e "  Что хочешь сделать?\n"
echo -e "  ${BOLD}1.${NC} Установить Matrix с нуля"
echo -e "  ${BOLD}2.${NC} Починить / переустановить (данные сохраняются)"
echo -e "  ${BOLD}3.${NC} Сменить пароль пользователя"
echo -e "  ${BOLD}4.${NC} Создать бэкап"
echo -e "  ${BOLD}5.${NC} Восстановить из бэкапа"
echo ""
read -rp "  Выбор [1-5]: " MENU_CHOICE

case "$MENU_CHOICE" in
  1) MODE="install" ;;
  2) MODE="repair"  ;;
  3) MODE="passwd"  ;;
  4) MODE="backup"  ;;
  5) MODE="restore" ;;
  *) err "Неверный выбор" ;;
esac

# ══════════════════════════════════════════════════════════
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ══════════════════════════════════════════════════════════

# Установить пакеты если нужно
ensure_deps() {
  section "Зависимости"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget lsb-release apt-transport-https gnupg \
    nginx certbot python3-certbot-nginx python3 ufw \
    postgresql postgresql-contrib fail2ban jq coturn \
    qrencode dnsutils
}

# Загрузить секреты если есть
load_secrets() {
  [[ -f "$SECRETS_FILE" ]] && source "$SECRETS_FILE"
  [[ -f "$PG_PASS_FILE" ]] && PG_PASS=$(cat "$PG_PASS_FILE")
}

# Получить домен из конфига если уже установлен
get_installed_domain() {
  if [[ -f /etc/matrix-synapse/conf.d/server_name.yaml ]]; then
    grep 'server_name' /etc/matrix-synapse/conf.d/server_name.yaml | \
      sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' '
  elif [[ -f /etc/matrix-synapse/homeserver.yaml ]]; then
    grep '^server_name:' /etc/matrix-synapse/homeserver.yaml | \
      sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' '
  fi
}

# Получить токен администратора
get_admin_token() {
  local user="$1" pass="$2"
  curl -s -X POST "http://127.0.0.1:8008/_matrix/client/v3/login" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$user\"},\"password\":\"$pass\"}" \
    | jq -r '.access_token // empty'
}

# Показать QR + ссылку
show_qr_link() {
  local url="$1"
  local label="${2:-Ссылка}"
  echo ""
  echo -e "  ${CYAN}${label}:${NC}"
  echo -e "  ${BOLD}$url${NC}"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t UTF8 -o - "$url" | sed 's/^/  /'
  fi
  echo ""
}

# Проверка что домен резолвится в наш IP
check_dns() {
  local domain="$1"
  section "Проверка DNS"

  local server_ip
  server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
              hostname -I | awk '{print $1}')

  local domain_ip
  domain_ip=$(dig +short "$domain" A 2>/dev/null | tail -1 || \
              host "$domain" 2>/dev/null | grep 'has address' | awk '{print $4}' | head -1 || \
              getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1 || true)

  if [[ -z "$domain_ip" ]]; then
    warn "Не удалось проверить DNS для $domain (dig/host недоступны)"
    warn "Убедись что домен указывает на IP: $server_ip"
    read -rp "Продолжить? (y/n): " FORCE
    [[ "$FORCE" != "y" && "$FORCE" != "Y" ]] && err "Отмена"
    return
  fi

  if [[ "$server_ip" != "$domain_ip" ]]; then
    warn "IP сервера: $server_ip"
    warn "IP домена:  $domain_ip"
    warn "Домен указывает на другой сервер. Certbot скорее всего упадёт."
    read -rp "Продолжить всё равно? (y/n): " FORCE
    [[ "$FORCE" != "y" && "$FORCE" != "Y" ]] && err "Отмена"
  else
    log "DNS OK — $domain → $server_ip"
  fi
}

# Проверка свободных портов
check_ports() {
  section "Проверка портов"
  local failed=0
  for port in 80 443 3478; do
    if ss -tlnp | grep -q ":$port "; then
      local proc
      proc=$(ss -tlnp | grep ":$port " | grep -oP 'users:\(\("\K[^"]+' || echo "неизвестно")
      # nginx и certbot могут занимать 80/443 — это нормально
      if [[ "$proc" == "nginx" ]]; then
        log "Порт $port занят nginx — нормально"
      else
        warn "Порт $port занят: $proc"
        failed=1
      fi
    else
      log "Порт $port свободен"
    fi
  done
  [[ $failed -eq 1 ]] && warn "Некоторые порты заняты — установка может завершиться с ошибкой"
}

# ══════════════════════════════════════════════════════════
#  POSTGRESQL
# ══════════════════════════════════════════════════════════
setup_postgres() {
  section "PostgreSQL"
  if [[ -f "$PG_PASS_FILE" ]]; then
    PG_PASS=$(cat "$PG_PASS_FILE")
    log "Пароль PostgreSQL загружен из файла"
  else
    PG_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
    echo "$PG_PASS" > "$PG_PASS_FILE"
    chmod 600 "$PG_PASS_FILE"
    log "Пароль PostgreSQL сгенерирован"
  fi

  systemctl start postgresql
  su -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='synapse'\"" postgres | grep -q 1 || \
    su -c "createuser synapse" postgres
  su -c "psql -c \"ALTER USER synapse WITH PASSWORD '$PG_PASS';\"" postgres
  su -c "psql -lqt" postgres | cut -d'|' -f1 | grep -qw synapse || \
    su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
      --template=template0 --owner=synapse synapse" postgres
  log "PostgreSQL готов"
}

# ══════════════════════════════════════════════════════════
#  SYNAPSE
# ══════════════════════════════════════════════════════════
setup_synapse() {
  local domain="$1"
  section "Synapse"

  # Репозиторий
  if [[ ! -f /etc/apt/sources.list.d/matrix-org.list ]]; then
    wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
      https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/matrix-org.list
    apt-get update -qq
  fi

  echo "matrix-synapse matrix-synapse/server-name string $domain" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

  mkdir -p /etc/matrix-synapse/conf.d
  echo "server_name: \"$domain\"" > /etc/matrix-synapse/conf.d/server_name.yaml

  # Секреты — не перегенерируем если уже есть
  if [[ -f "$SECRETS_FILE" ]]; then
    source "$SECRETS_FILE"
    log "Секреты загружены"
  else
    REGISTRATION_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
    MACAROON_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
    TURN_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
    cat > "$SECRETS_FILE" <<EOF
REGISTRATION_SECRET='$REGISTRATION_SECRET'
MACAROON_SECRET='$MACAROON_SECRET'
TURN_SECRET='$TURN_SECRET'
EOF
    chmod 600 "$SECRETS_FILE"
    log "Секреты сгенерированы"
  fi

  # Права на медиа
  mkdir -p /var/lib/matrix-synapse/media
  chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || \
    chown -R www-data:www-data /var/lib/matrix-synapse/
  chmod -R 750 /var/lib/matrix-synapse/

  write_homeserver_yaml "$domain"
  log "Synapse настроен"
}

write_homeserver_yaml() {
  local domain="$1"
  cat > /etc/matrix-synapse/homeserver.yaml <<EOF
server_name: "$domain"
public_baseurl: "https://$domain/"

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

media_retention:
  remote_media_lifetime: 90d

enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REGISTRATION_SECRET"
macaroon_secret_key: "$MACAROON_SECRET"

federation_domain_whitelist: []
federation_verify_certificates: true
allow_public_rooms_over_federation: false
allow_public_rooms_without_auth: false

report_stats: false
suppress_key_server_warning: true
trusted_key_servers:
  - server_name: "matrix.org"

turn_uris:
  - "turn:$domain:3478?transport=udp"
  - "turn:$domain:3478?transport=tcp"
  - "stun:$domain:3478"
turn_shared_secret: "$TURN_SECRET"
turn_user_lifetime: 86400000
turn_allow_guests: false

rc_message:
  per_second: 2
  burst_count: 40
rc_registration:
  per_second: 0.3
  burst_count: 5
rc_login:
  address:
    per_second: 0.15
    burst_count: 5
  account:
    per_second: 0.18
    burst_count: 4

user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true
EOF
}

# ══════════════════════════════════════════════════════════
#  NGINX
# ══════════════════════════════════════════════════════════
setup_nginx() {
  local domain="$1"
  section "Nginx"

  # Временный конфиг для certbot
  if [[ ! -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
    cat > /etc/nginx/sites-available/matrix-temp <<NGINX
server {
    listen 80;
    server_name $domain;
    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
NGINX
    ln -sf /etc/nginx/sites-available/matrix-temp /etc/nginx/sites-enabled/matrix-temp
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl restart nginx

    certbot certonly --nginx \
      -d "$domain" \
      --non-interactive \
      --agree-tos \
      --email "$LE_EMAIL" || err "Certbot не смог получить сертификат. Проверь что домен указывает на этот сервер."

    rm -f /etc/nginx/sites-enabled/matrix-temp /etc/nginx/sites-available/matrix-temp
  else
    log "SSL сертификат уже есть — пропускаю"
  fi

  write_nginx_config "$domain"

  ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  log "Nginx настроен"
}

write_nginx_config() {
  local domain="$1"
  cat > /etc/nginx/sites-available/matrix <<NGINX
limit_req_zone \$binary_remote_addr zone=matrix:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=matrix_login:10m rate=1r/s;

server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Well-known
    location /.well-known/matrix/ {
        root /var/www/html;
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
    }

    # Element Web
    location /element/ {
        alias /var/www/html/element/;
        index index.html;
        try_files \$uri \$uri/ /element/index.html;
    }

    # Synapse Admin
    location /admin/ {
        alias /var/www/html/admin/;
        index index.html;
        try_files \$uri \$uri/ /admin/index.html;
    }

    # Загрузка медиа — отдельный location с большими таймаутами
    location /_matrix/media/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_connect_timeout 60s;
        proxy_buffering off;
    }

    # Эндпоинт логина — строгий rate limit
    location ~* ^/_matrix/client/.*/login {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 1M;
        limit_req zone=matrix_login burst=5 nodelay;
    }

    # Всё остальное
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
        proxy_read_timeout 60s;
        limit_req zone=matrix burst=20 nodelay;
    }
}
NGINX
}

# ══════════════════════════════════════════════════════════
#  COTURN
# ══════════════════════════════════════════════════════════
setup_coturn() {
  local domain="$1"
  section "coturn (TURN/STUN)"
  cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$domain
total-quota=100
bps-capacity=0
stale-nonce
no-multicast-peers
min-port=49152
max-port=65535
log-file=/var/log/turnserver.log
EOF
  systemctl enable coturn
  systemctl restart coturn
  log "coturn настроен"
}

# ══════════════════════════════════════════════════════════
#  FAIL2BAN
# ══════════════════════════════════════════════════════════
setup_fail2ban() {
  section "Fail2ban"

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-limit-req]
enabled = true

[matrix-synapse]
enabled  = true
port     = http,https
filter   = matrix-synapse
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 300
bantime  = 3600
EOF

  # Фильтр для Matrix login endpoint
  cat > /etc/fail2ban/filter.d/matrix-synapse.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST /_matrix/client/.*/login HTTP.*" 4[0-9][0-9]
ignoreregex =
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  log "Fail2ban настроен (включая защиту Matrix login)"
}

# ══════════════════════════════════════════════════════════
#  ELEMENT WEB
# ══════════════════════════════════════════════════════════
setup_element() {
  local domain="$1"
  section "Element Web"

  local ELEMENT_TAG
  ELEMENT_TAG=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | jq -r .tag_name)
  local ELEMENT_VERSION="${ELEMENT_TAG#v}"

  log "Скачиваю Element $ELEMENT_TAG..."
  wget -q "https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_TAG}.tar.gz" \
    -O /tmp/element.tar.gz || \
  wget -q "https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_VERSION}.tar.gz" \
    -O /tmp/element.tar.gz || \
  err "Не удалось скачать Element"

  tar -xzf /tmp/element.tar.gz -C /tmp/
  rm -rf /var/www/html/element

  local ELEMENT_DIR
  ELEMENT_DIR=$(find /tmp -maxdepth 1 -name 'element-*' -type d | head -1)
  [[ -z "$ELEMENT_DIR" ]] && err "Папка Element не найдена после распаковки"
  mv "$ELEMENT_DIR" /var/www/html/element
  rm /tmp/element.tar.gz

  cat > /var/www/html/element/config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$domain",
            "server_name": "$domain"
        }
    },
    "disable_custom_urls": true,
    "default_federate": false,
    "brand": "Приватный чат",
    "piwik": false,
    "integrations_ui_url": "",
    "integrations_rest_url": "",
    "integrations_widgets_urls": [],
    "show_labs_settings": false,
    "features": {}
}
EOF

  chown -R www-data:www-data /var/www/html/element
  chmod -R 755 /var/www/html/element

  # Cron обновления
  cat > /usr/local/bin/update-element <<'SCRIPT'
#!/bin/bash
set -e
LATEST_TAG=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | jq -r .tag_name)
LATEST="${LATEST_TAG#v}"
CURRENT=$(jq -r .version /var/www/html/element/package.json 2>/dev/null || echo "0")
if [ "$CURRENT" = "$LATEST" ]; then
  echo "Element актуален: v$CURRENT"
  exit 0
fi
echo "Обновляю Element v$CURRENT -> v$LATEST..."
wget -q "https://github.com/element-hq/element-web/releases/download/${LATEST_TAG}/element-${LATEST_TAG}.tar.gz" \
  -O /tmp/element.tar.gz
tar -xzf /tmp/element.tar.gz -C /tmp/
cp /var/www/html/element/config.json /tmp/element-config-backup.json
rm -rf /var/www/html/element
ELEMENT_DIR=$(find /tmp -maxdepth 1 -name 'element-*' -type d | head -1)
mv "$ELEMENT_DIR" /var/www/html/element
cp /tmp/element-config-backup.json /var/www/html/element/config.json
chown -R www-data:www-data /var/www/html/element
rm -f /tmp/element.tar.gz /tmp/element-config-backup.json
echo "Element обновлён до v$LATEST"
SCRIPT
  chmod +x /usr/local/bin/update-element
  echo "0 3 1 * * root /usr/local/bin/update-element >> /var/log/element-update.log 2>&1" \
    > /etc/cron.d/element-update
  log "Element установлен"
}

# ══════════════════════════════════════════════════════════
#  SYNAPSE ADMIN
# ══════════════════════════════════════════════════════════
setup_synapse_admin() {
  section "Synapse Admin"
  local ADMIN_TAG
  ADMIN_TAG=$(curl -s https://api.github.com/repos/etkecc/synapse-admin/releases/latest | jq -r .tag_name)
  wget -q "https://github.com/etkecc/synapse-admin/releases/download/${ADMIN_TAG}/synapse-admin.tar.gz" \
    -O /tmp/synapse-admin.tar.gz || { warn "Не удалось скачать Synapse Admin — пропускаю"; return; }

  tar -xzf /tmp/synapse-admin.tar.gz -C /tmp/
  rm -rf /var/www/html/admin
  mv /tmp/synapse-admin /var/www/html/admin
  chown -R www-data:www-data /var/www/html/admin
  rm /tmp/synapse-admin.tar.gz
  log "Synapse Admin установлен"
}

# ══════════════════════════════════════════════════════════
#  WELL-KNOWN
# ══════════════════════════════════════════════════════════
setup_wellknown() {
  local domain="$1"
  section "Well-known"
  mkdir -p /var/www/html/.well-known/matrix
  echo "{\"m.homeserver\":{\"base_url\":\"https://$domain\"}}" \
    > /var/www/html/.well-known/matrix/client
  echo "{\"m.server\":\"$domain:443\"}" \
    > /var/www/html/.well-known/matrix/server
  log "Well-known настроен"
}

# ══════════════════════════════════════════════════════════
#  ФАЕРВОЛ
# ══════════════════════════════════════════════════════════
setup_ufw() {
  section "Фаервол (UFW)"
  ufw --force enable
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 3478/tcp
  ufw allow 3478/udp
  ufw allow 49152:65535/udp
  log "UFW настроен"
}

# ══════════════════════════════════════════════════════════
#  ВСПОМОГАТЕЛЬНЫЕ КОМАНДЫ
# ══════════════════════════════════════════════════════════
setup_helper_commands() {
  local domain="$1"
  section "Вспомогательные команды"

  # matrix-reset-password
  cat > /usr/local/bin/matrix-reset-password <<SCRIPT
#!/bin/bash
set -e
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "\${CYAN:-}\${BOLD}━━━ Смена пароля Matrix ━━━\${NC}"
echo ""

# Показываем список пользователей
echo -e "\${BLUE}[i]\${NC} Пользователи на этом сервере:"
su -c "psql -d synapse -tAc \"SELECT name FROM users WHERE deactivated=0 ORDER BY creation_ts;\"" postgres 2>/dev/null \
  | sed 's/^/  /' || echo "  (не удалось получить список)"

echo ""
read -rp "Имя пользователя (например @anton:$domain или просто anton): " TARGET_USER

# Нормализуем — добавляем @...домен если не указан
if [[ "\$TARGET_USER" != @* ]]; then
  TARGET_USER="@\${TARGET_USER}:$domain"
fi

echo -e "\${BLUE}[i]\${NC} Меняем пароль для: \${BOLD}\$TARGET_USER\${NC}"
echo ""

while true; do
  read -rsp "Новый пароль: " NEW_PASS
  echo ""
  read -rsp "Повтори пароль: " NEW_PASS2
  echo ""
  [[ "\$NEW_PASS" == "\$NEW_PASS2" ]] && break
  echo -e "\${YELLOW}[!]\${NC} Пароли не совпадают, попробуй ещё раз"
done

[[ \${#NEW_PASS} -lt 6 ]] && { echo -e "\${RED}[✗]\${NC} Пароль слишком короткий (минимум 6 символов)"; exit 1; }

hash=\$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode('utf-8')
hashed = bcrypt.hashpw(pw, bcrypt.gensalt())
print(hashed.decode('utf-8'))
" "\$NEW_PASS" 2>/dev/null) || {
  # fallback через synapse напрямую
  hash=\$(python3 -c "
from synapse.util.stringutils import random_string
" 2>/dev/null || echo "")
}

if [[ -n "\$hash" ]]; then
  su -c "psql -d synapse -c \"UPDATE users SET password_hash='\$hash' WHERE name='\$TARGET_USER';\"" postgres
  echo -e "\${GREEN}[✓]\${NC} Пароль изменён для \$TARGET_USER"
else
  # Fallback через register_new_matrix_user с флагом --no-admin
  hash_pw=\$(python3 -c "
import bcrypt
pw = '\$NEW_PASS'.encode('utf-8')
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
")
  su -c "psql -d synapse -c \"UPDATE users SET password_hash='\$hash_pw' WHERE name='\$TARGET_USER';\"" postgres
  echo -e "\${GREEN}[✓]\${NC} Пароль изменён для \$TARGET_USER"
fi

echo ""
echo -e "\${BLUE}[i]\${NC} Пользователю нужно:"
echo "  1. Открыть Element"
echo "  2. Выйти из аккаунта (если был залогинен)"
echo "  3. Войти с новым паролем"
echo ""
SCRIPT
  chmod +x /usr/local/bin/matrix-reset-password

  # matrix-add-federation
  cat > /usr/local/bin/matrix-add-federation <<'SCRIPT'
#!/bin/bash
set -e
[[ -z "$1" ]] && { echo "Использование: matrix-add-federation домен"; exit 1; }
FEDOMAIN="$1"
CONFIG="/etc/matrix-synapse/homeserver.yaml"
sed -i "/federation_domain_whitelist:/a\  - $FEDOMAIN" "$CONFIG"
systemctl restart matrix-synapse
echo "Домен $FEDOMAIN добавлен в federation whitelist"
SCRIPT
  chmod +x /usr/local/bin/matrix-add-federation

  log "Команды готовы: matrix-reset-password, matrix-add-federation"
}

# ══════════════════════════════════════════════════════════
#  БЭКАП
# ══════════════════════════════════════════════════════════
setup_backup_cron() {
  section "Автобэкап"
  mkdir -p "$BACKUP_DIR"

  cat > /usr/local/bin/matrix-backup <<SCRIPT
#!/bin/bash
set -e
BACKUP_DIR="$BACKUP_DIR"
BACKUP_KEEP=$BACKUP_KEEP
WITH_MEDIA="\${1:-no}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "\${BLUE}[i]\${NC} Начинаю бэкап Matrix..."
mkdir -p "\$BACKUP_DIR"

TIMESTAMP=\$(date +%Y-%m-%d_%H-%M)
TMPDIR=\$(mktemp -d)
OUTFILE="\$BACKUP_DIR/matrix-\$TIMESTAMP.tar.gz"

# PostgreSQL дамп
echo -e "\${BLUE}[i]\${NC} Дамп PostgreSQL..."
su -c "pg_dump -Fc synapse" postgres > "\$TMPDIR/synapse.dump"

# Конфиги
echo -e "\${BLUE}[i]\${NC} Конфиги..."
cp -r /etc/matrix-synapse "\$TMPDIR/matrix-synapse-conf"
cp /root/.matrix_secrets "\$TMPDIR/matrix_secrets" 2>/dev/null || true
cp /root/.matrix_pg_pass "\$TMPDIR/matrix_pg_pass" 2>/dev/null || true

# Медиа (опционально)
if [[ "\$WITH_MEDIA" == "yes" ]]; then
  echo -e "\${BLUE}[i]\${NC} Медиафайлы..."
  cp -r /var/lib/matrix-synapse/media "\$TMPDIR/media" 2>/dev/null || true
fi

# Упаковываем
echo -e "\${BLUE}[i]\${NC} Упаковываю..."
tar -czf "\$OUTFILE" -C "\$TMPDIR" .
rm -rf "\$TMPDIR"

SIZE=\$(du -sh "\$OUTFILE" | cut -f1)
echo -e "\${GREEN}[✓]\${NC} Бэкап сохранён: \$OUTFILE (\$SIZE)"

# Удаляем старые
ls -t "\$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null | tail -n +\$((BACKUP_KEEP+1)) | xargs rm -f
echo -e "\${BLUE}[i]\${NC} Старые бэкапы старше \$BACKUP_KEEP штук удалены"
SCRIPT
  chmod +x /usr/local/bin/matrix-backup

  # Cron каждые 24 часа в 02:00
  echo "0 2 * * * root /usr/local/bin/matrix-backup >> /var/log/matrix-backup.log 2>&1" \
    > /etc/cron.d/matrix-backup

  log "Автобэкап: каждый день в 02:00 → $BACKUP_DIR"
  log "Вручную: matrix-backup [yes — с медиа]"
}

# ══════════════════════════════════════════════════════════
#  ВОССТАНОВЛЕНИЕ
# ══════════════════════════════════════════════════════════
do_restore() {
  section "Восстановление из бэкапа"

  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]]; then
    err "Бэкапов не найдено в $BACKUP_DIR"
  fi

  echo -e "\n  Доступные бэкапы:\n"
  mapfile -t BACKUPS < <(ls -t "$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null)
  for i in "${!BACKUPS[@]}"; do
    local size
    size=$(du -sh "${BACKUPS[$i]}" | cut -f1)
    printf "  ${BOLD}%2d.${NC} %s  (%s)\n" "$((i+1))" "$(basename "${BACKUPS[$i]}")" "$size"
  done

  echo ""
  read -rp "  Выбери номер бэкапа: " BACKUP_NUM
  [[ -z "$BACKUP_NUM" || "$BACKUP_NUM" -lt 1 || "$BACKUP_NUM" -gt "${#BACKUPS[@]}" ]] && \
    err "Неверный номер"

  local CHOSEN="${BACKUPS[$((BACKUP_NUM-1))]}"
  echo ""
  warn "Это ЗАМЕНИТ текущие данные содержимым бэкапа: $(basename "$CHOSEN")"
  read -rp "Уверен? (yes/n): " SURE
  [[ "$SURE" != "yes" ]] && err "Отмена"

  local TMPDIR
  TMPDIR=$(mktemp -d)
  tar -xzf "$CHOSEN" -C "$TMPDIR"

  # Останавливаем Synapse
  systemctl stop matrix-synapse 2>/dev/null || true

  # Восстанавливаем PostgreSQL
  if [[ -f "$TMPDIR/synapse.dump" ]]; then
    log "Восстанавливаю базу данных..."
    su -c "dropdb --if-exists synapse" postgres
    su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C \
      --template=template0 --owner=synapse synapse" postgres
    su -c "pg_restore -d synapse" postgres < "$TMPDIR/synapse.dump"
    log "БД восстановлена"
  fi

  # Конфиги
  if [[ -d "$TMPDIR/matrix-synapse-conf" ]]; then
    log "Восстанавливаю конфиги..."
    cp -r "$TMPDIR/matrix-synapse-conf/." /etc/matrix-synapse/
  fi

  # Секреты
  [[ -f "$TMPDIR/matrix_secrets" ]] && cp "$TMPDIR/matrix_secrets" /root/.matrix_secrets && chmod 600 /root/.matrix_secrets
  [[ -f "$TMPDIR/matrix_pg_pass" ]] && cp "$TMPDIR/matrix_pg_pass" /root/.matrix_pg_pass && chmod 600 /root/.matrix_pg_pass

  # Медиа
  if [[ -d "$TMPDIR/media" ]]; then
    log "Восстанавливаю медиафайлы..."
    cp -r "$TMPDIR/media/." /var/lib/matrix-synapse/media/
    chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || \
      chown -R www-data:www-data /var/lib/matrix-synapse/
  fi

  rm -rf "$TMPDIR"
  systemctl start matrix-synapse
  log "Восстановление завершено! Synapse запущен."
}

# ══════════════════════════════════════════════════════════
#  HEALTH CHECK
# ══════════════════════════════════════════════════════════
do_healthcheck() {
  local domain="$1"
  section "Проверка работоспособности"
  local ok=0 fail=0

  check_endpoint() {
    local label="$1" url="$2"
    if curl -s -f --max-time 10 "$url" >/dev/null 2>&1; then
      log "$label"
      ((ok++))
    else
      warn "НЕДОСТУПНО: $label ($url)"
      ((fail++))
    fi
  }

  check_endpoint "Synapse API (локально)"     "http://127.0.0.1:8008/_matrix/client/versions"
  check_endpoint "Synapse API (через nginx)"  "https://$domain/_matrix/client/versions"
  check_endpoint "Element Web"                "https://$domain/element/"
  check_endpoint "Synapse Admin"              "https://$domain/admin/"
  check_endpoint "Well-known client"          "https://$domain/.well-known/matrix/client"

  if [[ -n "$LIVEKIT_DOMAIN" ]]; then
    check_endpoint "LiveKit server"           "https://$LIVEKIT_DOMAIN"
    check_endpoint "LiveKit JWT service"      "https://$LIVEKIT_DOMAIN/_matrix/client/unstable/com.element.msc4143/openid/request_token"
  fi

  echo ""
  if [[ $fail -eq 0 ]]; then
    log "Всё работает ($ok/$(( ok+fail )))"
  else
    warn "Проблемы: $fail из $(( ok+fail )) проверок не прошли"
  fi
}

# ══════════════════════════════════════════════════════════
#  МЕДИА CLEANUP CRON
# ══════════════════════════════════════════════════════════
setup_media_cleanup() {
  cat > /usr/local/bin/matrix-media-cleanup <<'SCRIPT'
#!/bin/bash
find /var/lib/matrix-synapse/media/remote_content -type f -mtime +90 -delete 2>/dev/null || true
find /var/lib/matrix-synapse/media/remote_thumbnail -type f -mtime +90 -delete 2>/dev/null || true
echo "$(date): Media cleanup done" >> /var/log/matrix-media-cleanup.log
SCRIPT
  chmod +x /usr/local/bin/matrix-media-cleanup
  echo "0 4 * * 0 root /usr/local/bin/matrix-media-cleanup" > /etc/cron.d/matrix-media-cleanup
}

# ══════════════════════════════════════════════════════════
#  LIVEKIT (звонки для Element X)
# ══════════════════════════════════════════════════════════
setup_livekit() {
  local lk_domain="$1"
  local matrix_domain="$2"
  section "LiveKit (звонки Element X)"

  # Генерируем ключи если нет
  if grep -q 'LIVEKIT_KEY' "$SECRETS_FILE" 2>/dev/null; then
    source "$SECRETS_FILE"
    log "LiveKit ключи загружены"
  else
    LIVEKIT_KEY="matrix"
    LIVEKIT_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
    cat >> "$SECRETS_FILE" <<EOF
LIVEKIT_KEY='$LIVEKIT_KEY'
LIVEKIT_SECRET='$LIVEKIT_SECRET'
EOF
    log "LiveKit ключи сгенерированы"
  fi

  # Скачиваем LiveKit server
  log "Скачиваю LiveKit server..."
  local LK_VERSION
  LK_VERSION=$(curl -s https://api.github.com/repos/livekit/livekit/releases/latest | jq -r .tag_name)
  local LK_URL="https://github.com/livekit/livekit/releases/download/${LK_VERSION}/livekit_linux_amd64.tar.gz"

  wget -q "$LK_URL" -O /tmp/livekit.tar.gz || err "Не удалось скачать LiveKit"
  tar -xzf /tmp/livekit.tar.gz -C /tmp/
  mv /tmp/livekit-server /usr/local/bin/livekit-server 2>/dev/null || \
    mv /tmp/livekit /usr/local/bin/livekit-server
  chmod +x /usr/local/bin/livekit-server
  rm -f /tmp/livekit.tar.gz
  log "LiveKit server установлен"

  # Скачиваем livekit-jwt-service (нужен для авторизации Matrix)
  log "Скачиваю livekit-jwt-service..."
  local JWT_VERSION
  JWT_VERSION=$(curl -s https://api.github.com/repos/element-hq/livekit-jwt-service/releases/latest | jq -r .tag_name)
  local JWT_URL="https://github.com/element-hq/livekit-jwt-service/releases/download/${JWT_VERSION}/livekit-jwt-service-linux-amd64"

  wget -q "$JWT_URL" -O /usr/local/bin/livekit-jwt-service || \
    err "Не удалось скачать livekit-jwt-service"
  chmod +x /usr/local/bin/livekit-jwt-service
  log "livekit-jwt-service установлен"

  # Конфиг LiveKit
  mkdir -p /etc/livekit
  cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
rtc:
  port_range_start: 50000
  port_range_end: 60000
  tcp_port: 7881
  use_external_ip: true
keys:
  $LIVEKIT_KEY: $LIVEKIT_SECRET
logging:
  level: info
EOF

  # Конфиг livekit-jwt-service
  cat > /etc/livekit/jwt.yaml <<EOF
livekit_url: wss://$lk_domain
livekit_key: $LIVEKIT_KEY
livekit_secret: $LIVEKIT_SECRET
listen_addr: 127.0.0.1:8889
EOF

  # Systemd для LiveKit server
  cat > /etc/systemd/system/livekit.service <<EOF
[Unit]
Description=LiveKit Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  # Systemd для livekit-jwt-service
  cat > /etc/systemd/system/livekit-jwt.service <<EOF
[Unit]
Description=LiveKit JWT Service for Matrix
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/livekit-jwt-service --config /etc/livekit/jwt.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable livekit livekit-jwt
  systemctl restart livekit livekit-jwt

  log "LiveKit запущен"

  # SSL для livekit домена
  log "SSL сертификат для $lk_domain..."
  certbot certonly --nginx \
    -d "$lk_domain" \
    --non-interactive \
    --agree-tos \
    --email "$LE_EMAIL" || err "Не удалось получить сертификат для $lk_domain"

  # Nginx для LiveKit
  cat >> /etc/nginx/sites-available/matrix <<NGINX

# ── LiveKit ──────────────────────────────────────────────
server {
    listen 80;
    server_name $lk_domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $lk_domain;

    ssl_certificate /etc/letsencrypt/live/$lk_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$lk_domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # LiveKit WebSocket и HTTP API
    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # JWT service для Matrix
    location /_matrix/client/unstable/com.element.msc4143/openid/request_token {
        proxy_pass http://127.0.0.1:8889;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

  nginx -t && systemctl reload nginx

  # Добавляем конфиг звонков в Synapse
  cat > /etc/matrix-synapse/conf.d/livekit.yaml <<EOF
# LiveKit звонки для Element X
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true

livekit:
  url: wss://$lk_domain
  jwt_service_url: https://$lk_domain/_matrix/client/unstable/com.element.msc4143/openid/request_token
EOF

  # Добавляем порты в UFW
  ufw allow 7881/tcp   # LiveKit TCP RTC
  ufw allow 50000:60000/udp  # LiveKit UDP RTC

  systemctl restart matrix-synapse
  log "LiveKit интегрирован с Synapse"

  # Обновляем Element конфиг для поддержки звонков
  if [[ -f /var/www/html/element/config.json ]]; then
    local tmp
    tmp=$(mktemp)
    jq --arg lk "wss://$lk_domain" \
       --arg jwt "https://$lk_domain/_matrix/client/unstable/com.element.msc4143/openid/request_token" \
       '. + {
         "features": {
           "feature_video_rooms": true,
           "feature_element_call": true
         },
         "element_call": {
           "url": "https://call.element.io",
           "use_exclusively": false,
           "participant_limit": 8,
           "brand": "Element Call"
         }
       }' /var/www/html/element/config.json > "$tmp"
    mv "$tmp" /var/www/html/element/config.json
    chown www-data:www-data /var/www/html/element/config.json
    log "Element Web обновлён для поддержки звонков"
  fi
}


  if ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
    echo "0 3 * * * root certbot renew --quiet --nginx" > /etc/cron.d/certbot-renew
  fi
}

# ══════════════════════════════════════════════════════════
#  ЗАПУСК SYNAPSE + СОЗДАНИЕ ADMIN + ТОКЕН
# ══════════════════════════════════════════════════════════
start_synapse_and_init() {
  local domain="$1"
  local admin_user="$2"
  local admin_pass="$3"

  section "Запуск Synapse"
  systemctl stop matrix-synapse 2>/dev/null || true
  fuser -k 8008/tcp 2>/dev/null || true
  sleep 2
  systemctl enable matrix-synapse
  systemctl start matrix-synapse

  log "Ожидаю Synapse (до 120 сек)..."
  for i in {1..60}; do
    if curl -s -f http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
      log "Synapse готов!"
      break
    fi
    echo -n "."
    sleep 2
  done
  echo ""
  curl -s -f http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1 || \
    err "Synapse не поднялся. Смотри: journalctl -u matrix-synapse -xe"

  # Создаём админа (если уже есть — пропускаем)
  section "Администратор"
  register_new_matrix_user \
    -c /etc/matrix-synapse/homeserver.yaml \
    -u "$admin_user" \
    -p "$admin_pass" \
    -a \
    http://127.0.0.1:8008 || warn "Пользователь @$admin_user уже существует — пропускаю"

  # Получаем токен
  sleep 3
  ACCESS_TOKEN=$(get_admin_token "$admin_user" "$admin_pass")
  [[ -z "$ACCESS_TOKEN" ]] && err "Не удалось получить токен администратора"

  # Создаём токен регистрации
  REG_TOKEN=$(curl -s -X POST "http://127.0.0.1:8008/_synapse/admin/v1/registration_tokens/new" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{}' \
    | jq -r '.token // empty')
  [[ -z "$REG_TOKEN" ]] && warn "Не удалось создать токен регистрации"

  # Переиндексация
  curl -s -X POST "http://127.0.0.1:8008/_synapse/admin/v1/background_updates/start_job" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"job_name":"user_directory_prefill"}' >/dev/null 2>&1 || true

  # Сохраняем для итогового блока
  echo "$REG_TOKEN" > /root/.matrix_reg_token
  echo "$ACCESS_TOKEN" > /root/.matrix_access_token
  chmod 600 /root/.matrix_reg_token /root/.matrix_access_token
}

# ══════════════════════════════════════════════════════════
#  ИТОГОВЫЙ БЛОК
# ══════════════════════════════════════════════════════════
show_final() {
  local domain="$1"
  local admin_user="$2"
  REG_TOKEN=$(cat /root/.matrix_reg_token 2>/dev/null || echo "—")

  local ADMIN_URL="https://$domain/admin/"
  local ELEMENT_URL="https://$domain/element/"

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║                      ГОТОВО!  🚀                            ║"
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  printf  "  ║  Element:   https://%s/element/\n" "$domain"
  printf  "  ║  Админка:   https://%s/admin/\n" "$domain"
  printf  "  ║  Админ:     @%s:%s\n" "$admin_user" "$domain"
  if [[ -n "$LIVEKIT_DOMAIN" ]]; then
  printf  "  ║  LiveKit:   wss://%s\n" "$LIVEKIT_DOMAIN"
  echo    "  ║  Звонки:    Element X ✓  •  Element Classic ✓           ║"
  else
  echo    "  ║  Звонки:    Element Classic ✓ (LiveKit не установлен)   ║"
  fi
  echo "  ╠══════════════════════════════════════════════════════════════╣"
  echo "  ║  Команды:                                                    ║"
  echo "  ║  matrix-reset-password   — сменить пароль пользователя      ║"
  echo "  ║  matrix-backup           — создать бэкап вручную            ║"
  echo "  ║  matrix-backup yes       — бэкап с медиафайлами             ║"
  echo "  ║  matrix-add-federation   — добавить домен в федерацию       ║"
  echo "  ║  update-element          — обновить Element                  ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${YELLOW}⚠  Бэкапы: $BACKUP_DIR  (авто каждый день в 02:00)${NC}"
  echo -e "  ${YELLOW}⚠  Первый вход в приложение — нужен VPN (один раз)${NC}"
  echo -e "  ${YELLOW}⚠  iPhone: открывать ссылку в Safari, не в Телеграме${NC}"
  echo ""

  # QR + ссылка на Synapse Admin
  echo -e "  ${CYAN}${BOLD}━━━ Synapse Admin (создавать пользователей здесь) ━━━${NC}"
  show_qr_link "$ADMIN_URL" "Ссылка на админку"
}

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: СМЕНА ПАРОЛЯ
# ══════════════════════════════════════════════════════════
if [[ "$MODE" == "passwd" ]]; then
  INSTALLED_DOMAIN=$(get_installed_domain)
  [[ -z "$INSTALLED_DOMAIN" ]] && err "Matrix не установлен на этом сервере"
  /usr/local/bin/matrix-reset-password
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: БЭКАП
# ══════════════════════════════════════════════════════════
if [[ "$MODE" == "backup" ]]; then
  echo ""
  read -rp "  Включить медиафайлы (коты и прочее)? (y/n): " WITH_MEDIA_CHOICE
  WITH_MEDIA="no"
  [[ "$WITH_MEDIA_CHOICE" =~ ^[yY]$ ]] && WITH_MEDIA="yes"
  /usr/local/bin/matrix-backup "$WITH_MEDIA"
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: ВОССТАНОВЛЕНИЕ
# ══════════════════════════════════════════════════════════
if [[ "$MODE" == "restore" ]]; then
  do_restore
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: УСТАНОВКА / ПОЧИНКА
# ══════════════════════════════════════════════════════════

# Определяем домен
if [[ "$MODE" == "repair" ]]; then
  INSTALLED_DOMAIN=$(get_installed_domain)
  if [[ -n "$INSTALLED_DOMAIN" ]]; then
    info "Найден установленный домен: $INSTALLED_DOMAIN"
    read -rp "Использовать его? (y/n): " USE_EXISTING
    if [[ "$USE_EXISTING" =~ ^[yY]$ ]]; then
      DOMAIN="$INSTALLED_DOMAIN"
    else
      read -rp "Домен сервера: " DOMAIN
    fi
  else
    read -rp "Домен сервера: " DOMAIN
  fi
  load_secrets
else
  read -rp "  Домен сервера (matrix.example.com): " DOMAIN
fi

[[ -z "$DOMAIN" ]] && err "Домен обязателен"

read -rp "  Имя администратора (латиница): " ADMIN_USER
[[ -z "$ADMIN_USER" ]] && err "Имя админа обязательно"

while true; do
  read -rsp "  Пароль администратора: " ADMIN_PASS; echo ""
  read -rsp "  Повтори пароль: " ADMIN_PASS2; echo ""
  [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && break
  warn "Пароли не совпадают"
done

read -rp "  Email для Let's Encrypt: " LE_EMAIL
[[ -z "$LE_EMAIL" ]] && err "Email обязателен"

echo ""
info "Звонки через Element X требуют отдельного поддомена."
info "Например: если Matrix на matrix.example.com,"
info "то LiveKit можно поставить на livekit.example.com"
info "Оба должны заранее указывать на IP этого сервера."
echo ""
read -rp "  Домен LiveKit (или Enter чтобы пропустить): " LIVEKIT_DOMAIN

echo ""
info "Домен Matrix:  $DOMAIN"
[[ -n "$LIVEKIT_DOMAIN" ]] && info "Домен LiveKit: $LIVEKIT_DOMAIN"
info "Админ:         @$ADMIN_USER:$DOMAIN"
echo ""
read -rp "  Всё верно? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && err "Отмена"

# Делаем бэкап перед починкой
if [[ "$MODE" == "repair" ]]; then
  section "Бэкап перед починкой"
  mkdir -p "$BACKUP_DIR"
  /usr/local/bin/matrix-backup 2>/dev/null || warn "Не удалось сделать бэкап — продолжаю"
fi

# Минимальные зависимости для проверок до основной установки
apt-get update -qq
apt-get install -y -qq curl dnsutils 2>/dev/null || true

# Основная установка
check_ports
check_dns "$DOMAIN"
[[ -n "$LIVEKIT_DOMAIN" ]] && check_dns "$LIVEKIT_DOMAIN"
ensure_deps
setup_postgres
setup_synapse "$DOMAIN"
setup_nginx "$DOMAIN"
setup_wellknown "$DOMAIN"
setup_coturn "$DOMAIN"
setup_fail2ban
setup_element "$DOMAIN"
setup_synapse_admin
setup_helper_commands "$DOMAIN"
setup_backup_cron
setup_media_cleanup
setup_certbot_renewal
[[ -n "$LIVEKIT_DOMAIN" ]] && setup_livekit "$LIVEKIT_DOMAIN" "$DOMAIN"
start_synapse_and_init "$DOMAIN" "$ADMIN_USER" "$ADMIN_PASS"
setup_ufw
do_healthcheck "$DOMAIN"
show_final "$DOMAIN" "$ADMIN_USER"
