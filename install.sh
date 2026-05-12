#!/bin/bash
# ============================================================
#  Matrix Synapse — автоустановка v3.3
#  Debian 12+  •  запуск от root
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

die() {
  echo -e "${RED}[✗]${NC} $1"
  exit 1
}

if [ "$EUID" -ne 0 ]; then
  die "Запускай от root: sudo bash $0"
fi

# ── Пути и константы ─────────────────────────────────────
SECRETS_FILE="/root/.matrix_secrets"
PG_PASS_FILE="/root/.matrix_pg_pass"
BACKUP_DIR="/opt/matrix-backups"
BACKUP_KEEP=7

# ── Переменные (все инициализированы) ────────────────────
DOMAIN=""
LIVEKIT_DOMAIN=""
ADMIN_USER=""
ADMIN_PASS=""
LE_EMAIL=""
PG_PASS=""
REGISTRATION_SECRET=""
MACAROON_SECRET=""
TURN_SECRET=""
LIVEKIT_KEY=""
LIVEKIT_SECRET=""

# ══════════════════════════════════════════════════════════
#  МЕНЮ
# ══════════════════════════════════════════════════════════
clear
echo -e "\n${CYAN}${BOLD}  ╔══════════════════════════════════════════╗"
echo    "  ║   Matrix Synapse  •  Deploy v3.3        ║"
echo -e "  ╚══════════════════════════════════════════╝${NC}\n"
echo -e "  ${BOLD}1.${NC} Установить Matrix с нуля"
echo -e "  ${BOLD}2.${NC} Починить / переустановить (данные сохраняются)"
echo -e "  ${BOLD}3.${NC} Сменить пароль пользователя"
echo -e "  ${BOLD}4.${NC} Создать бэкап"
echo -e "  ${BOLD}5.${NC} Восстановить из бэкапа"
echo ""
read -rp "  Выбор [1-5]: " MENU_CHOICE

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: СМЕНА ПАРОЛЯ
# ══════════════════════════════════════════════════════════
if [ "$MENU_CHOICE" = "3" ]; then
  # Убеждаемся что bcrypt есть
  apt-get install -y -qq python3-bcrypt 2>/dev/null || true

  DOMAIN=$(grep '^server_name:' /etc/matrix-synapse/homeserver.yaml 2>/dev/null \
    | sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
  if [ -z "$DOMAIN" ]; then
    die "Matrix не найден на этом сервере"
  fi

  echo ""
  echo -e "${CYAN}${BOLD}━━━ Смена пароля ━━━${NC}\n"
  echo -e "${BLUE}[i]${NC} Пользователи на сервере:"
  su -c "psql -d synapse -tAc \"SELECT name FROM users WHERE deactivated=0 ORDER BY creation_ts;\"" \
    postgres 2>/dev/null | sed 's/^/  /' || echo "  (не удалось получить список)"
  echo ""
  read -rp "Имя пользователя (можно без @домен): " TARGET_USER
  if [ "${TARGET_USER:0:1}" != "@" ]; then
    TARGET_USER="@${TARGET_USER}:${DOMAIN}"
  fi
  echo -e "${BLUE}[i]${NC} Меняем пароль для: ${BOLD}$TARGET_USER${NC}\n"
  while true; do
    read -rsp "Новый пароль: " P1; echo ""
    read -rsp "Повтори:      " P2; echo ""
    if [ "$P1" = "$P2" ]; then
      break
    fi
    warn "Пароли не совпадают, попробуй ещё раз"
  done
  if [ ${#P1} -lt 6 ]; then
    die "Пароль слишком короткий (минимум 6 символов)"
  fi
  HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode('utf-8')
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
" "$P1" 2>/dev/null)
  if [ -z "$HASH" ]; then
    die "Ошибка хеширования пароля"
  fi
  su -c "psql -d synapse -c \"UPDATE users SET password_hash='$HASH' WHERE name='$TARGET_USER';\"" postgres
  log "Пароль изменён для $TARGET_USER"
  echo -e "\n${BLUE}[i]${NC} Пользователю нужно выйти и войти заново в Element.\n"
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: БЭКАП
# ══════════════════════════════════════════════════════════
if [ "$MENU_CHOICE" = "4" ]; then
  mkdir -p "$BACKUP_DIR"
  read -rp "Включить медиафайлы (коты и прочее)? (y/n): " WITH_MEDIA
  section "Бэкап"
  TMPDIR=$(mktemp -d)
  OUTFILE="$BACKUP_DIR/matrix-$(date +%Y-%m-%d_%H-%M).tar.gz"
  info "Дамп PostgreSQL..."
  su -c "pg_dump -Fc synapse" postgres > "$TMPDIR/synapse.dump" 2>/dev/null || warn "Не удалось сделать дамп БД"
  info "Конфиги..."
  cp -r /etc/matrix-synapse "$TMPDIR/conf" 2>/dev/null || true
  cp "$SECRETS_FILE" "$TMPDIR/" 2>/dev/null || true
  cp "$PG_PASS_FILE" "$TMPDIR/" 2>/dev/null || true
  if [ "$WITH_MEDIA" = "y" ] || [ "$WITH_MEDIA" = "Y" ]; then
    info "Медиафайлы..."
    cp -r /var/lib/matrix-synapse/media "$TMPDIR/" 2>/dev/null || true
  fi
  tar -czf "$OUTFILE" -C "$TMPDIR" . 2>/dev/null
  rm -rf "$TMPDIR"
  SIZE=$(du -sh "$OUTFILE" 2>/dev/null | cut -f1)
  log "Бэкап сохранён: $OUTFILE ($SIZE)"
  ls -t "$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs rm -f 2>/dev/null || true
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: ВОССТАНОВЛЕНИЕ
# ══════════════════════════════════════════════════════════
if [ "$MENU_CHOICE" = "5" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then
    die "Бэкапов не найдено в $BACKUP_DIR"
  fi
  mapfile -t BACKUPS < <(ls -t "$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null)
  if [ ${#BACKUPS[@]} -eq 0 ]; then
    die "Нет файлов бэкапа в $BACKUP_DIR"
  fi
  section "Восстановление"
  echo ""
  for i in "${!BACKUPS[@]}"; do
    SIZE=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
    printf "  ${BOLD}%2d.${NC} %s  (%s)\n" "$((i+1))" "$(basename "${BACKUPS[$i]}")" "$SIZE"
  done
  echo ""
  read -rp "  Номер бэкапа: " NUM
  if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
    die "Неверный номер"
  fi
  if [ "$NUM" -lt 1 ] || [ "$NUM" -gt "${#BACKUPS[@]}" ]; then
    die "Неверный номер"
  fi
  CHOSEN="${BACKUPS[$((NUM-1))]}"
  warn "Это ЗАМЕНИТ текущие данные содержимым: $(basename "$CHOSEN")"
  read -rp "Уверен? Введи слово yes: " SURE
  if [ "$SURE" != "yes" ]; then
    die "Отмена"
  fi
  TMPDIR=$(mktemp -d)
  tar -xzf "$CHOSEN" -C "$TMPDIR"
  systemctl stop matrix-synapse 2>/dev/null || true
  if [ -f "$TMPDIR/synapse.dump" ]; then
    info "Восстанавливаю базу данных..."
    su -c "dropdb --if-exists synapse" postgres
    su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C --template=template0 --owner=synapse synapse" postgres
    su -c "pg_restore -d synapse" postgres < "$TMPDIR/synapse.dump"
    log "БД восстановлена"
  fi
  if [ -d "$TMPDIR/conf" ]; then
    cp -r "$TMPDIR/conf/." /etc/matrix-synapse/
  fi
  if [ -f "$TMPDIR/.matrix_secrets" ]; then
    cp "$TMPDIR/.matrix_secrets" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
  fi
  if [ -f "$TMPDIR/.matrix_pg_pass" ]; then
    cp "$TMPDIR/.matrix_pg_pass" "$PG_PASS_FILE"
    chmod 600 "$PG_PASS_FILE"
  fi
  if [ -d "$TMPDIR/media" ]; then
    cp -r "$TMPDIR/media/." /var/lib/matrix-synapse/media/
    chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
  systemctl start matrix-synapse
  log "Восстановление завершено! Synapse запущен."
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  РЕЖИМ: УСТАНОВКА / ПОЧИНКА
# ══════════════════════════════════════════════════════════
if [ "$MENU_CHOICE" != "1" ] && [ "$MENU_CHOICE" != "2" ]; then
  die "Неверный выбор"
fi

MODE="install"
if [ "$MENU_CHOICE" = "2" ]; then
  MODE="repair"
fi

# ── Ввод данных ───────────────────────────────────────────
echo ""
section "Настройка"

if [ "$MODE" = "repair" ]; then
  FOUND=$(grep '^server_name:' /etc/matrix-synapse/homeserver.yaml 2>/dev/null \
    | sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
  if [ -n "$FOUND" ]; then
    info "Найден установленный домен: $FOUND"
    read -rp "  Использовать его? (y/n): " USE_IT
    if [ "$USE_IT" = "y" ] || [ "$USE_IT" = "Y" ]; then
      DOMAIN="$FOUND"
    fi
  fi
  if [ -f "$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE" 2>/dev/null || true
  fi
  if [ -f "$PG_PASS_FILE" ]; then
    PG_PASS=$(cat "$PG_PASS_FILE")
  fi
fi

if [ -z "$DOMAIN" ]; then
  read -rp "  Домен Matrix (например matrix.example.com): " DOMAIN
fi
if [ -z "$DOMAIN" ]; then
  die "Домен обязателен"
fi

read -rp "  Email для SSL сертификата: " LE_EMAIL
if [ -z "$LE_EMAIL" ]; then
  die "Email обязателен"
fi

echo ""
info "Для звонков в Element X нужен отдельный поддомен."
info "Пример: если Matrix на matrix.example.com,"
info "то LiveKit на livekit.example.com (та же A-запись, тот же IP)."
read -rp "  Домен LiveKit (или Enter — пропустить): " LIVEKIT_DOMAIN

# Генерируем имя и пароль админа
ADMIN_SUFFIX=$(tr -dc '0-9' </dev/urandom | head -c4)
ADMIN_USER="admin_${ADMIN_SUFFIX}"

echo ""
info "Имя администратора будет: ${BOLD}${ADMIN_USER}${NC}"
echo ""
while true; do
  read -rsp "  Пароль администратора: " ADMIN_PASS; echo ""
  read -rsp "  Повтори пароль:        " ADMIN_PASS2; echo ""
  if [ "$ADMIN_PASS" = "$ADMIN_PASS2" ]; then
    break
  fi
  warn "Пароли не совпадают, попробуй ещё раз"
done
if [ ${#ADMIN_PASS} -lt 6 ]; then
  die "Пароль слишком короткий (минимум 6 символов)"
fi

echo ""
info "Домен Matrix:  $DOMAIN"
if [ -n "$LIVEKIT_DOMAIN" ]; then
  info "Домен LiveKit: $LIVEKIT_DOMAIN"
fi
info "Администратор: @${ADMIN_USER}:${DOMAIN}"
echo ""
read -rp "  Всё верно? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  die "Отмена"
fi

# ── Бэкап перед починкой ─────────────────────────────────
if [ "$MODE" = "repair" ]; then
  section "Бэкап перед починкой"
  mkdir -p "$BACKUP_DIR"
  TMPDIR=$(mktemp -d)
  BFILE="$BACKUP_DIR/matrix-pre-repair-$(date +%Y-%m-%d_%H-%M).tar.gz"
  su -c "pg_dump -Fc synapse" postgres > "$TMPDIR/synapse.dump" 2>/dev/null || true
  cp -r /etc/matrix-synapse "$TMPDIR/conf" 2>/dev/null || true
  cp "$SECRETS_FILE" "$TMPDIR/" 2>/dev/null || true
  cp "$PG_PASS_FILE" "$TMPDIR/" 2>/dev/null || true
  tar -czf "$BFILE" -C "$TMPDIR" . 2>/dev/null || true
  rm -rf "$TMPDIR"
  log "Бэкап создан: $BFILE"
fi

# ══════════════════════════════════════════════════════════
#  ЗАВИСИМОСТИ
# ══════════════════════════════════════════════════════════
section "Зависимости"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget lsb-release apt-transport-https gnupg \
  nginx certbot python3-certbot-nginx \
  python3 python3-bcrypt \
  ufw postgresql postgresql-contrib \
  fail2ban jq coturn qrencode
log "Зависимости установлены"

# ══════════════════════════════════════════════════════════
#  POSTGRESQL
# ══════════════════════════════════════════════════════════
section "PostgreSQL"
if [ -f "$PG_PASS_FILE" ]; then
  PG_PASS=$(cat "$PG_PASS_FILE")
  log "Пароль БД загружен"
else
  PG_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
  echo "$PG_PASS" > "$PG_PASS_FILE"
  chmod 600 "$PG_PASS_FILE"
  log "Пароль БД сгенерирован"
fi

systemctl start postgresql

HAS_USER=$(su -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='synapse'\"" postgres 2>/dev/null || true)
if [ "$HAS_USER" != "1" ]; then
  su -c "createuser synapse" postgres
fi
su -c "psql -c \"ALTER USER synapse WITH PASSWORD '$PG_PASS';\"" postgres

HAS_DB=$(su -c "psql -lqt" postgres 2>/dev/null | cut -d'|' -f1 | grep -w synapse | xargs 2>/dev/null || true)
if [ -z "$HAS_DB" ]; then
  su -c "createdb --encoding=UTF8 --lc-collate=C --lc-ctype=C --template=template0 --owner=synapse synapse" postgres
fi
log "PostgreSQL готов"

# ══════════════════════════════════════════════════════════
#  SYNAPSE
# ══════════════════════════════════════════════════════════
section "Synapse"
if [ ! -f /etc/apt/sources.list.d/matrix-org.list ]; then
  wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
    https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -qq
fi

echo "matrix-synapse matrix-synapse/server-name string $DOMAIN" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

mkdir -p /etc/matrix-synapse/conf.d
echo "server_name: \"$DOMAIN\"" > /etc/matrix-synapse/conf.d/server_name.yaml

# Секреты — не перегенерируем при починке
if [ -f "$SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE" 2>/dev/null || true
  log "Секреты загружены"
fi
if [ -z "$REGISTRATION_SECRET" ]; then
  REGISTRATION_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
fi
if [ -z "$MACAROON_SECRET" ]; then
  MACAROON_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
fi
if [ -z "$TURN_SECRET" ]; then
  TURN_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
fi
cat > "$SECRETS_FILE" <<EOF
REGISTRATION_SECRET='$REGISTRATION_SECRET'
MACAROON_SECRET='$MACAROON_SECRET'
TURN_SECRET='$TURN_SECRET'
EOF
chmod 600 "$SECRETS_FILE"

# Права на медиа
mkdir -p /var/lib/matrix-synapse/media
chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null \
  || chown -R www-data:www-data /var/lib/matrix-synapse/ 2>/dev/null || true
chmod -R 750 /var/lib/matrix-synapse/

# homeserver.yaml
cat > /etc/matrix-synapse/homeserver.yaml <<EOF
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

enable_registration: true
registration_requires_token: true
registration_shared_secret: "$REGISTRATION_SECRET"
macaroon_secret_key: "$MACAROON_SECRET"

federation_domain_whitelist: []
allow_public_rooms_over_federation: false
allow_public_rooms_without_auth: false
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

user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true

rc_login:
  address:
    per_second: 0.15
    burst_count: 5
  account:
    per_second: 0.18
    burst_count: 4
EOF
log "Synapse настроен"

# ══════════════════════════════════════════════════════════
#  COTURN
# ══════════════════════════════════════════════════════════
section "coturn"
cat > /etc/turnserver.conf <<EOF
listening-port=3478
fingerprint
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$DOMAIN
total-quota=100
stale-nonce
no-multicast-peers
min-port=49152
max-port=65535
log-file=/var/log/turnserver.log
EOF
systemctl enable coturn 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
log "coturn настроен"

# ══════════════════════════════════════════════════════════
#  SSL
# ══════════════════════════════════════════════════════════
section "SSL (Let's Encrypt)"

# Открываем порты ДО certbot — иначе Let's Encrypt не достучится
ufw --force enable 2>/dev/null || true
ufw allow ssh 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true

# Временный nginx чтобы certbot мог пройти http-01 challenge
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/matrix-tmp <<NGINX
server {
    listen 80;
    server_name $DOMAIN${LIVEKIT_DOMAIN:+ $LIVEKIT_DOMAIN};
    location / {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/matrix-tmp /etc/nginx/sites-enabled/matrix-tmp
nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || true

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  CERTBOT_DOMAINS="-d $DOMAIN"
  if [ -n "$LIVEKIT_DOMAIN" ]; then
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $LIVEKIT_DOMAIN"
  fi
  certbot certonly --nginx $CERTBOT_DOMAINS \
    --non-interactive --agree-tos --email "$LE_EMAIL"
  if [ $? -ne 0 ]; then
    die "Certbot не смог получить сертификат. Убедись что домен $DOMAIN указывает на IP этого сервера и порт 80 открыт."
  fi
else
  log "SSL сертификат уже есть — пропускаю"
fi

rm -f /etc/nginx/sites-enabled/matrix-tmp /etc/nginx/sites-available/matrix-tmp
log "SSL готов"

# ══════════════════════════════════════════════════════════
#  NGINX
# ══════════════════════════════════════════════════════════
section "Nginx"
cat > /etc/nginx/sites-available/matrix <<NGINX
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

    # Well-known для федерации
    location /.well-known/matrix/ {
        root /var/www/html;
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
    }

    # Element Web
    location /element/ {
        alias /var/www/html/element/;
        try_files \$uri \$uri/ /element/index.html;
    }

    # Synapse Admin
    location /admin/ {
        alias /var/www/html/admin/;
        try_files \$uri \$uri/ /admin/index.html;
    }

    # Медиа — увеличенные таймауты для загрузки файлов
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

    # Всё остальное → Synapse
    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Nginx настроен"

# ══════════════════════════════════════════════════════════
#  WELL-KNOWN
# ══════════════════════════════════════════════════════════
mkdir -p /var/www/html/.well-known/matrix
printf '{"m.homeserver":{"base_url":"https://%s"}}' "$DOMAIN" \
  > /var/www/html/.well-known/matrix/client
printf '{"m.server":"%s:443"}' "$DOMAIN" \
  > /var/www/html/.well-known/matrix/server

# ══════════════════════════════════════════════════════════
#  FAIL2BAN
# ══════════════════════════════════════════════════════════
section "Fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
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

cat > /etc/fail2ban/filter.d/matrix-synapse.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST /_matrix/client/.*/login HTTP.*" 4[0-9][0-9]
ignoreregex =
EOF

systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true
log "Fail2ban настроен"

# ══════════════════════════════════════════════════════════
#  ELEMENT WEB
# ══════════════════════════════════════════════════════════
section "Element Web"
ELEMENT_TAG=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest \
  | jq -r .tag_name 2>/dev/null || true)
if [ -z "$ELEMENT_TAG" ] || [ "$ELEMENT_TAG" = "null" ]; then
  warn "Не удалось получить версию Element — пропускаю"
else
  log "Скачиваю Element $ELEMENT_TAG..."
  wget -q "https://github.com/element-hq/element-web/releases/download/${ELEMENT_TAG}/element-${ELEMENT_TAG}.tar.gz" \
    -O /tmp/element.tar.gz
  if [ $? -eq 0 ]; then
    tar -xzf /tmp/element.tar.gz -C /tmp/ 2>/dev/null
    rm -rf /var/www/html/element
    ELEMENT_DIR=$(find /tmp -maxdepth 1 -name 'element-*' -type d 2>/dev/null | head -1)
    if [ -n "$ELEMENT_DIR" ]; then
      mv "$ELEMENT_DIR" /var/www/html/element
      cat > /var/www/html/element/config.json <<EOF
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
      log "Element Web установлен"
    else
      warn "Не удалось найти папку Element после распаковки"
    fi
    rm -f /tmp/element.tar.gz
  else
    warn "Не удалось скачать Element"
  fi
fi

# ══════════════════════════════════════════════════════════
#  SYNAPSE ADMIN
# ══════════════════════════════════════════════════════════
section "Synapse Admin"
ADMIN_TAG=$(curl -s https://api.github.com/repos/etkecc/synapse-admin/releases/latest \
  | jq -r .tag_name 2>/dev/null || true)
if [ -n "$ADMIN_TAG" ] && [ "$ADMIN_TAG" != "null" ]; then
  wget -q "https://github.com/etkecc/synapse-admin/releases/download/${ADMIN_TAG}/synapse-admin.tar.gz" \
    -O /tmp/synapse-admin.tar.gz 2>/dev/null
  if [ $? -eq 0 ]; then
    tar -xzf /tmp/synapse-admin.tar.gz -C /tmp/ 2>/dev/null || true
    rm -rf /var/www/html/admin
    SADMIN_DIR=$(find /tmp -maxdepth 1 \( -name 'synapse-admin' -o -name 'synapse-admin-*' \) -type d 2>/dev/null | head -1)
    if [ -n "$SADMIN_DIR" ]; then
      mv "$SADMIN_DIR" /var/www/html/admin
      chown -R www-data:www-data /var/www/html/admin
      log "Synapse Admin установлен"
    fi
    rm -f /tmp/synapse-admin.tar.gz
  else
    warn "Не удалось скачать Synapse Admin — пропускаю"
  fi
else
  warn "Не удалось получить версию Synapse Admin — пропускаю"
fi

# ══════════════════════════════════════════════════════════
#  LIVEKIT (опционально)
# ══════════════════════════════════════════════════════════
if [ -n "$LIVEKIT_DOMAIN" ]; then
  section "LiveKit"
  LIVEKIT_KEY="matrix"

  # Загружаем существующие ключи или генерируем новые
  if grep -q 'LIVEKIT_SECRET' "$SECRETS_FILE" 2>/dev/null; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE" 2>/dev/null || true
  fi
  if [ -z "$LIVEKIT_SECRET" ]; then
    LIVEKIT_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
    echo "LIVEKIT_KEY='$LIVEKIT_KEY'" >> "$SECRETS_FILE"
    echo "LIVEKIT_SECRET='$LIVEKIT_SECRET'" >> "$SECRETS_FILE"
  fi

  # LiveKit server
  LK_TAG=$(curl -s https://api.github.com/repos/livekit/livekit/releases/latest \
    | jq -r .tag_name 2>/dev/null || true)
  if [ -n "$LK_TAG" ] && [ "$LK_TAG" != "null" ]; then
    wget -q "https://github.com/livekit/livekit/releases/download/${LK_TAG}/livekit_linux_amd64.tar.gz" \
      -O /tmp/livekit.tar.gz
    if [ $? -eq 0 ]; then
      tar -xzf /tmp/livekit.tar.gz -C /tmp/ 2>/dev/null
      if [ -f /tmp/livekit-server ]; then
        mv /tmp/livekit-server /usr/local/bin/livekit-server
      elif [ -f /tmp/livekit ]; then
        mv /tmp/livekit /usr/local/bin/livekit-server
      fi
      chmod +x /usr/local/bin/livekit-server 2>/dev/null || true
      rm -f /tmp/livekit.tar.gz
      log "LiveKit server скачан"
    else
      warn "Не удалось скачать LiveKit server"
    fi
  fi

  # livekit-jwt-service
  JWT_TAG=$(curl -s https://api.github.com/repos/element-hq/livekit-jwt-service/releases/latest \
    | jq -r .tag_name 2>/dev/null || true)
  if [ -n "$JWT_TAG" ] && [ "$JWT_TAG" != "null" ]; then
    wget -q "https://github.com/element-hq/livekit-jwt-service/releases/download/${JWT_TAG}/livekit-jwt-service-linux-amd64" \
      -O /usr/local/bin/livekit-jwt-service
    chmod +x /usr/local/bin/livekit-jwt-service 2>/dev/null || true
    log "livekit-jwt-service скачан"
  fi

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

  cat > /etc/livekit/jwt.yaml <<EOF
livekit_url: wss://$LIVEKIT_DOMAIN
livekit_key: $LIVEKIT_KEY
livekit_secret: $LIVEKIT_SECRET
listen_addr: 127.0.0.1:8889
EOF

  cat > /etc/systemd/system/livekit.service <<EOF
[Unit]
Description=LiveKit Server
After=network.target
[Service]
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/livekit-jwt.service <<EOF
[Unit]
Description=LiveKit JWT Service
After=network.target
[Service]
ExecStart=/usr/local/bin/livekit-jwt-service --config /etc/livekit/jwt.yaml
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable livekit livekit-jwt 2>/dev/null || true
  systemctl restart livekit livekit-jwt 2>/dev/null || true

  # SSL для LiveKit домена
  if [ ! -f "/etc/letsencrypt/live/$LIVEKIT_DOMAIN/fullchain.pem" ]; then
    certbot certonly --nginx -d "$LIVEKIT_DOMAIN" \
      --non-interactive --agree-tos --email "$LE_EMAIL" 2>/dev/null \
      || warn "Не удалось получить сертификат для $LIVEKIT_DOMAIN"
  fi

  # Nginx блок для LiveKit
  cat >> /etc/nginx/sites-available/matrix <<NGINX

server {
    listen 80;
    server_name $LIVEKIT_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $LIVEKIT_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$LIVEKIT_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$LIVEKIT_DOMAIN/privkey.pem;
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

    location /_matrix/client/unstable/com.element.msc4143/openid/request_token {
        proxy_pass http://127.0.0.1:8889;
        proxy_set_header Host \$host;
    }
}
NGINX

  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

  # Synapse конфиг для LiveKit
  cat > /etc/matrix-synapse/conf.d/livekit.yaml <<EOF
experimental_features:
  msc3266_enabled: true
  msc4143_enabled: true

livekit:
  url: wss://$LIVEKIT_DOMAIN
  jwt_service_url: https://$LIVEKIT_DOMAIN/_matrix/client/unstable/com.element.msc4143/openid/request_token
EOF

  ufw allow 7881/tcp 2>/dev/null || true
  ufw allow 50000:60000/udp 2>/dev/null || true
  log "LiveKit настроен"
fi

# ══════════════════════════════════════════════════════════
#  UFW
# ══════════════════════════════════════════════════════════
section "Фаервол"
ufw --force enable 2>/dev/null || true
ufw allow ssh 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 3478/tcp 2>/dev/null || true
ufw allow 3478/udp 2>/dev/null || true
ufw allow 49152:65535/udp 2>/dev/null || true
log "UFW настроен"

# ══════════════════════════════════════════════════════════
#  АВТОБЭКАП
# ══════════════════════════════════════════════════════════
mkdir -p "$BACKUP_DIR"
cat > /usr/local/bin/matrix-backup <<SCRIPT
#!/bin/bash
BACKUP_DIR="$BACKUP_DIR"
BACKUP_KEEP=$BACKUP_KEEP
WITH_MEDIA="\${1:-no}"
mkdir -p "\$BACKUP_DIR"
TMPDIR=\$(mktemp -d)
OUTFILE="\$BACKUP_DIR/matrix-\$(date +%Y-%m-%d_%H-%M).tar.gz"
su -c "pg_dump -Fc synapse" postgres > "\$TMPDIR/synapse.dump" 2>/dev/null || true
cp -r /etc/matrix-synapse "\$TMPDIR/conf" 2>/dev/null || true
cp /root/.matrix_secrets "\$TMPDIR/" 2>/dev/null || true
cp /root/.matrix_pg_pass "\$TMPDIR/" 2>/dev/null || true
if [ "\$WITH_MEDIA" = "yes" ]; then
  cp -r /var/lib/matrix-synapse/media "\$TMPDIR/" 2>/dev/null || true
fi
tar -czf "\$OUTFILE" -C "\$TMPDIR" . 2>/dev/null
rm -rf "\$TMPDIR"
SIZE=\$(du -sh "\$OUTFILE" 2>/dev/null | cut -f1)
echo "\$(date): Бэкап сохранён: \$OUTFILE (\$SIZE)"
ls -t "\$BACKUP_DIR"/matrix-*.tar.gz 2>/dev/null | tail -n +\$((BACKUP_KEEP+1)) | xargs rm -f 2>/dev/null || true
SCRIPT
chmod +x /usr/local/bin/matrix-backup
echo "0 2 * * * root /usr/local/bin/matrix-backup >> /var/log/matrix-backup.log 2>&1" \
  > /etc/cron.d/matrix-backup

# ══════════════════════════════════════════════════════════
#  MATRIX-RESET-PASSWORD
# ══════════════════════════════════════════════════════════
cat > /usr/local/bin/matrix-reset-password <<SCRIPT
#!/bin/bash
DOMAIN="$DOMAIN"
apt-get install -y -qq python3-bcrypt 2>/dev/null || true
echo ""
echo "=== Смена пароля Matrix ==="
echo ""
echo "Пользователи на сервере:"
su -c "psql -d synapse -tAc \"SELECT name FROM users WHERE deactivated=0 ORDER BY creation_ts;\"" \
  postgres 2>/dev/null | sed 's/^/  /' || echo "  (не удалось получить список)"
echo ""
read -rp "Имя пользователя (можно без @домен): " U
if [ "\${U:0:1}" != "@" ]; then
  U="@\${U}:\${DOMAIN}"
fi
echo "Меняем пароль для: \$U"
while true; do
  read -rsp "Новый пароль: " P1; echo ""
  read -rsp "Повтори:      " P2; echo ""
  if [ "\$P1" = "\$P2" ]; then break; fi
  echo "Пароли не совпадают"
done
HASH=\$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode('utf-8')
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
" "\$P1" 2>/dev/null)
if [ -z "\$HASH" ]; then
  echo "Ошибка хеширования пароля"
  exit 1
fi
su -c "psql -d synapse -c \"UPDATE users SET password_hash='\$HASH' WHERE name='\$U';\"" postgres
echo "Готово! Пользователю нужно выйти и войти заново в Element."
SCRIPT
chmod +x /usr/local/bin/matrix-reset-password

# Certbot renewal
echo "0 3 * * * root certbot renew --quiet --nginx" > /etc/cron.d/certbot-renew

# ══════════════════════════════════════════════════════════
#  ЗАПУСК SYNAPSE
# ══════════════════════════════════════════════════════════
section "Запуск Synapse"
systemctl stop matrix-synapse 2>/dev/null || true
sleep 2
systemctl enable matrix-synapse 2>/dev/null || true
systemctl start matrix-synapse

log "Жду готовности Synapse (до 90 сек)..."
SYNAPSE_OK=0
for i in $(seq 1 45); do
  if curl -sf http://127.0.0.1:8008/_matrix/client/versions >/dev/null 2>&1; then
    SYNAPSE_OK=1
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [ "$SYNAPSE_OK" -ne 1 ]; then
  die "Synapse не поднялся. Смотри лог: journalctl -u matrix-synapse -n 50"
fi
log "Synapse запущен"

# ══════════════════════════════════════════════════════════
#  СОЗДАНИЕ АДМИНИСТРАТОРА
# ══════════════════════════════════════════════════════════
section "Администратор"
register_new_matrix_user \
  -c /etc/matrix-synapse/homeserver.yaml \
  -u "$ADMIN_USER" -p "$ADMIN_PASS" -a \
  http://127.0.0.1:8008 2>/dev/null \
  && log "Администратор @${ADMIN_USER}:${DOMAIN} создан" \
  || warn "Пользователь уже существует — пропускаю"

# Перезапуск если LiveKit добавили конфиг
if [ -n "$LIVEKIT_DOMAIN" ]; then
  systemctl restart matrix-synapse 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════
#  ИТОГ
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║                      ГОТОВО!  🚀                            ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
printf  "  ║  Element:  https://%s/element/\n" "$DOMAIN"
printf  "  ║  Админка:  https://%s/admin/\n" "$DOMAIN"
echo    "  ╠══════════════════════════════════════════════════════════════╣"
printf  "  ║  Логин админа:  %-44s║\n" "$ADMIN_USER"
printf  "  ║  Пароль:        %-44s║\n" "$ADMIN_PASS"
if [ -n "$LIVEKIT_DOMAIN" ]; then
printf  "  ║  LiveKit:  wss://%-43s║\n" "$LIVEKIT_DOMAIN"
fi
echo    "  ╠══════════════════════════════════════════════════════════════╣"
echo    "  ║  Команды:                                                    ║"
echo    "  ║  matrix-reset-password  — сменить пароль пользователя       ║"
echo    "  ║  matrix-backup          — бэкап вручную                     ║"
echo    "  ║  matrix-backup yes      — бэкап с медиафайлами              ║"
echo    "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${YELLOW}⚠  Запиши логин и пароль администратора!${NC}"
echo -e "  ${YELLOW}⚠  Бэкапы: $BACKUP_DIR  (авто каждый день в 02:00)${NC}"
echo -e "  ${YELLOW}⚠  Первый вход — нужен VPN (один раз)${NC}"
echo -e "  ${YELLOW}⚠  iPhone: открывать ссылку в Safari, не в Телеграме${NC}"
echo ""
echo -e "  ${CYAN}${BOLD}━━━ Открой и создавай пользователей через админку ━━━${NC}"
echo ""
ADMIN_URL="https://$DOMAIN/admin/"
echo -e "  ${BOLD}${ADMIN_URL}${NC}"
echo ""
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t UTF8 -o - "$ADMIN_URL" 2>/dev/null | sed 's/^/  /'
fi
echo ""
