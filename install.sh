#!/bin/bash
# ============================================================
#  Matrix Synapse + LiveKit  —  v0.6.0
#  Debian 12+  •  запуск от root
#  Статус: в разработке, не для продакшена
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }
die()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && die "Запускай от root"

# ── Ссылки на скачивание ──────────────────────────────────
ELEMENT_URL="https://github.com/element-hq/element-web/releases/download/v1.12.18/element-v1.12.18.tar.gz"
LIVEKIT_URL="https://github.com/livekit/livekit/releases/download/v1.11.0/livekit_1.11.0_linux_amd64.tar.gz"
LKJWT_URL="https://github.com/element-hq/lk-jwt-service/releases/latest/download/lk-jwt-service_linux_amd64"

# ── Ввод данных ───────────────────────────────────────────
clear
echo -e "\n${CYAN}${BOLD}  Matrix Synapse + LiveKit  •  v0.6.0${NC}\n"

read -rp "  Домен Matrix  (matrix.example.com): " DOMAIN
[ -z "$DOMAIN" ] && die "Домен обязателен"

read -rp "  Домен LiveKit (livekit.example.com): " LIVEKIT_DOMAIN
[ -z "$LIVEKIT_DOMAIN" ] && die "Домен LiveKit обязателен"

read -rp "  Email для SSL: " LE_EMAIL
[ -z "$LE_EMAIL" ] && die "Email обязателен"

# Генерируем секреты
PG_PASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
REGISTRATION_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
MACAROON_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)
TURN_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c32)
LIVEKIT_KEY="matrix"
LIVEKIT_SECRET=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c48)

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

echo ""
info "Домен Matrix:  $DOMAIN"
info "Домен LiveKit: $LIVEKIT_DOMAIN"
info "Администратор: @${ADMIN_USER}:${DOMAIN}"
echo ""
read -rp "  Всё верно? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && die "Отмена"

# ══════════════════════════════════════════════════════════
#  ФАЕРВОЛ — первым делом
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
  curl wget gnupg lsb-release \
  nginx certbot python3-certbot-nginx \
  postgresql \
  jq coturn
log "Зависимости установлены"

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
  wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
    https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/matrix-org.list
  apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

# Удаляем конфиг с пустым server_name который ставится по умолчанию
rm -f /etc/matrix-synapse/conf.d/server_name.yaml

mkdir -p /var/lib/matrix-synapse/media
chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/ 2>/dev/null || true
chmod -R 750 /var/lib/matrix-synapse/

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
max-port=57000
log-file=/var/log/turnserver.log
EOF
systemctl enable coturn 2>/dev/null || true
systemctl restart coturn 2>/dev/null || true
log "coturn настроен"

# ══════════════════════════════════════════════════════════
#  SSL
# ══════════════════════════════════════════════════════════
section "SSL"
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/matrix-tmp <<NGINX
server {
    listen 80;
    server_name $DOMAIN $LIVEKIT_DOMAIN;
    root /var/www/html;
}
NGINX
ln -sf /etc/nginx/sites-available/matrix-tmp /etc/nginx/sites-enabled/matrix-tmp
nginx -t && systemctl restart nginx

certbot certonly --nginx -d "$DOMAIN" -d "$LIVEKIT_DOMAIN" \
  --non-interactive --agree-tos --email "$LE_EMAIL" \
  || die "Certbot не смог получить сертификат. Домены указывают на этот сервер?"

rm -f /etc/nginx/sites-enabled/matrix-tmp /etc/nginx/sites-available/matrix-tmp
log "SSL готов"

# ══════════════════════════════════════════════════════════
#  ELEMENT WEB
# ══════════════════════════════════════════════════════════
section "Element Web"
wget --timeout=120 "$ELEMENT_URL" -O /tmp/element.tar.gz
if file /tmp/element.tar.gz | grep -q compressed; then
  rm -rf /var/www/html/element
  mkdir -p /var/www/html/element
  tar -xzf /tmp/element.tar.gz -C /var/www/html/element --strip-components=1
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
  rm -f /tmp/element.tar.gz
  log "Element Web установлен"
else
  warn "Не удалось скачать Element Web"
  rm -f /tmp/element.tar.gz
fi

# ══════════════════════════════════════════════════════════
#  LIVEKIT SERVER
# ══════════════════════════════════════════════════════════
section "LiveKit Server"
wget --timeout=120 "$LIVEKIT_URL" -O /tmp/livekit.tar.gz
if file /tmp/livekit.tar.gz | grep -q compressed; then
  mkdir -p /tmp/livekit-extract
  tar -xzf /tmp/livekit.tar.gz -C /tmp/livekit-extract/
  LK_BIN=$(find /tmp/livekit-extract -type f -executable 2>/dev/null | head -1)
  if [ -n "$LK_BIN" ]; then
    mv "$LK_BIN" /usr/local/bin/livekit-server
    chmod +x /usr/local/bin/livekit-server
    log "LiveKit бинарник установлен"
  else
    warn "Бинарник LiveKit не найден в архиве"
  fi
  rm -rf /tmp/livekit-extract /tmp/livekit.tar.gz
else
  warn "Не удалось скачать LiveKit"
  rm -f /tmp/livekit.tar.gz
fi

mkdir -p /etc/livekit
cat > /etc/livekit/livekit.yaml <<EOF
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
systemctl daemon-reload
systemctl enable livekit 2>/dev/null || true
systemctl restart livekit 2>/dev/null || true
log "LiveKit запущен"

# ══════════════════════════════════════════════════════════
#  LK-JWT-SERVICE
# ══════════════════════════════════════════════════════════
section "lk-jwt-service"
wget --timeout=60 "$LKJWT_URL" -O /tmp/lk-jwt-service
if file /tmp/lk-jwt-service | grep -q ELF; then
  mv /tmp/lk-jwt-service /usr/local/bin/lk-jwt-service
  chmod +x /usr/local/bin/lk-jwt-service
  log "lk-jwt-service скачан"
else
  warn "wget отдал не бинарник — собираю из исходников..."
  rm -f /tmp/lk-jwt-service
  apt-get install -y -qq golang-go git 2>/dev/null || true
  # Пробуем свежий Go если системный старый
  if [ ! -f /usr/local/go/bin/go ]; then
    wget -q https://go.dev/dl/go1.24.3.linux-amd64.tar.gz -O /tmp/go.tar.gz
    tar -xzf /tmp/go.tar.gz -C /usr/local/
    rm -f /tmp/go.tar.gz
  fi
  export PATH=$PATH:/usr/local/go/bin
  rm -rf /tmp/lkjwt
  git clone --depth=1 https://github.com/element-hq/lk-jwt-service /tmp/lkjwt 2>/dev/null
  if [ -d /tmp/lkjwt ]; then
    # Отключаем DisallowUnknownFields — иначе Element X не может авторизоваться
    sed -i 's/decoder.DisallowUnknownFields()/\/\/decoder.DisallowUnknownFields()/g' /tmp/lkjwt/main.go
    cd /tmp/lkjwt && /usr/local/go/bin/go build -o /usr/local/bin/lk-jwt-service . 2>/dev/null
    cd /root
    rm -rf /tmp/lkjwt
    if [ -f /usr/local/bin/lk-jwt-service ]; then
      log "lk-jwt-service собран из исходников"
    else
      warn "Не удалось собрать lk-jwt-service — звонки в Element X не будут работать"
    fi
  fi
fi

cat > /etc/systemd/system/lk-jwt-service.service <<EOF
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
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable lk-jwt-service 2>/dev/null || true
systemctl restart lk-jwt-service 2>/dev/null || true
sleep 2
if systemctl is-active --quiet lk-jwt-service; then
  log "lk-jwt-service запущен (порт 8080)"
else
  warn "lk-jwt-service не запустился — проверь: journalctl -u lk-jwt-service -n 20"
fi

# ══════════════════════════════════════════════════════════
#  NGINX
# ══════════════════════════════════════════════════════════
section "Nginx"

WELL_KNOWN_CLIENT="{\"m.homeserver\":{\"base_url\":\"https://$DOMAIN\"},\"org.matrix.msc4143.rtc_foci\":[{\"type\":\"livekit\",\"livekit_service_url\":\"https://$DOMAIN/livekit/jwt\"}]}"

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

    # Well-known
    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '$WELL_KNOWN_CLIENT';
    }
    location /.well-known/matrix/server {
        default_type application/json;
        return 200 '{"m.server":"$DOMAIN:443"}';
    }

    # Element Web
    location /element/ {
        alias /var/www/html/element/;
        try_files \$uri \$uri/ /element/index.html;
    }

    # lk-jwt-service — авторизация для LiveKit (без 301 редиректов)
    location ^~ /livekit/jwt {
        rewrite ^/livekit/jwt/?(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Медиа — увеличенные таймауты
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

    # Synapse
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

# LiveKit домен
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

ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/matrix
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Nginx настроен"

# ══════════════════════════════════════════════════════════
#  ЗАПУСК SYNAPSE + АДМИНИСТРАТОР
# ══════════════════════════════════════════════════════════
section "Запуск Synapse"
systemctl stop matrix-synapse 2>/dev/null || true
sleep 2
systemctl enable matrix-synapse 2>/dev/null || true
systemctl start matrix-synapse

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

section "Администратор"
register_new_matrix_user \
  -c /etc/matrix-synapse/homeserver.yaml \
  -u "$ADMIN_USER" -p "$ADMIN_PASS" -a \
  http://127.0.0.1:8008 2>/dev/null \
  && log "Администратор @${ADMIN_USER}:${DOMAIN} создан" \
  || warn "Пользователь уже существует"

# Сохраняем секреты
cat > /root/.matrix_secrets <<EOF
DOMAIN=$DOMAIN
LIVEKIT_DOMAIN=$LIVEKIT_DOMAIN
ADMIN_USER=$ADMIN_USER
PG_PASS=$PG_PASS
REGISTRATION_SECRET=$REGISTRATION_SECRET
MACAROON_SECRET=$MACAROON_SECRET
TURN_SECRET=$TURN_SECRET
LIVEKIT_KEY=$LIVEKIT_KEY
LIVEKIT_SECRET=$LIVEKIT_SECRET
EOF
chmod 600 /root/.matrix_secrets

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
chk "lk-jwt-service"     "https://$DOMAIN/livekit/jwt/"
chk "LiveKit server"     "https://$LIVEKIT_DOMAIN"

MSC=$(curl -s http://127.0.0.1:8008/_matrix/client/versions \
  | jq -r '.unstable_features["org.matrix.msc4143"] // false' 2>/dev/null)
if [ "$MSC" = "true" ]; then
  log "MSC4143 активен — звонки должны работать"
else
  warn "MSC4143 не активен — проверь homeserver.yaml"
fi

# ══════════════════════════════════════════════════════════
#  ИТОГ
# ══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║            Matrix + LiveKit  •  v0.6.0                      ║"
echo "  ╠══════════════════════════════════════════════════════════════╣"
printf  "  ║  Чат:     https://%-42s║\n" "$DOMAIN/element/"
printf  "  ║  LiveKit: wss://%-44s║\n" "$LIVEKIT_DOMAIN"
echo    "  ╠══════════════════════════════════════════════════════════════╣"
printf  "  ║  Логин:   %-49s║\n" "$ADMIN_USER"
printf  "  ║  Пароль:  %-49s║\n" "$ADMIN_PASS"
echo    "  ╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${YELLOW}⚠  ЗАПИШИ логин и пароль!${NC}"
echo -e "  ${YELLOW}⚠  Секреты: /root/.matrix_secrets${NC}"
echo ""
echo -e "  ${CYAN}Управление пользователями:${NC}"
echo -e "  https://awesome-technologies.github.io/synapse-admin/"
echo -e "  Homeserver URL: https://$DOMAIN"
echo ""
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t UTF8 -o - "https://awesome-technologies.github.io/synapse-admin/" \
    2>/dev/null | sed 's/^/  /'
fi
echo ""
