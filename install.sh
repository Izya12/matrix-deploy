#!/bin/bash
# MATRIX SYNAPSE CLEAN ARCHITECTURE (NO DOCKER)
# Version: 8.0 "Professional"

set -e

# --- Цвета и логи ---
green="\e[32m"
red="\e[31m"
end="\e[0m"
log() { echo -e "${green}[INFO]${end} $1"; }

# --- 1. Ввод данных ---
echo -e "${green}━━━ Сбор параметров ━━━${end}"
read -p "Основной домен (напр. matrix.example.com): " DOMAIN
read -p "Домен для звонков (напр. calls.example.com): " CALLS_DOMAIN
read -p "Email для SSL (Certbot): " EMAIL
read -p "Пароль админа Matrix: " ADMIN_PASS
read -p "Пароль к Postgres (уже созданной базы): " DB_PASS

# --- 2. Установка системных пакетов ---
log "Установка зависимостей..."
apt update && apt install -y curl wget nginx certbot python3-certbot-nginx \
    python3-pip python3-venv libpq-dev python3-dev build-essential pwgen ufw fail2ban

# --- 3. Настройка LiveKit (Бинарник) ---
log "Установка LiveKit (Бинарник)..."
LK_VERSION="1.11.0"
wget -q "https://github.com/livekit/livekit/releases/download/v${LK_VERSION}/livekit_${LK_VERSION}_linux_amd64.tar.gz"
tar -xzf "livekit_${LK_VERSION}_linux_amd64.tar.gz"
mv livekit-server /usr/local/bin/ && chmod +x /usr/local/bin/livekit-server
rm "livekit_${LK_VERSION}_linux_amd64.tar.gz"

# Ключи для связи Synapse <-> LiveKit
LK_KEY="matrix_key"
LK_SECRET=$(pwgen -s 32 1)

mkdir -p /etc/livekit
cat > /etc/livekit/livekit.yaml <<EOF
port: 7880
keys:
    $LK_KEY: $LK_SECRET
EOF

# Сервис LiveKit
cat > /etc/systemd/system/livekit.service <<EOF
[Unit]
Description=LiveKit Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

# --- 4. Установка Matrix Synapse (Venv) ---
log "Установка Synapse в venv..."
mkdir -p /opt/venvs /var/lib/matrix-synapse/media
python3 -m venv /opt/venvs/matrix-synapse
/opt/venvs/matrix-synapse/bin/pip install --upgrade pip setuptools
/opt/venvs/matrix-synapse/bin/pip install matrix-synapse[postgres]

REG_SECRET=$(pwgen -s 32 1)
MAC_SECRET=$(pwgen -s 32 1)

cat > /etc/matrix-synapse/homeserver.yaml <<EOF
server_name: "$DOMAIN"
pid_file: /run/matrix-synapse.pid
presence: { enabled: true }
database:
  name: psycopg2
  args:
    user: synapse_user
    password: "$DB_PASS"
    database: synapse_db
    host: localhost
log_config: "/etc/matrix-synapse/log.config"
report_stats: false
registration_shared_secret: "$REG_SECRET"
macaroon_secret_key: "$MAC_SECRET"
media_store_path: "/var/lib/matrix-synapse/media"
public_baseurl: "https://$DOMAIN/"

# Настройка звонков (MSC4143 / v3_auth)
v3_auth_enabled: true
experimental_features:
  msc3882_enabled: true
  msc4143_enabled: true

# Привязка LiveKit
livekit:
  enabled: true
  url: "https://$CALLS_DOMAIN"
  key: "$LK_KEY"
  secret: "$LK_SECRET"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    resources: [{names: [client, federation], compress: false}]
EOF

if [ ! -f /etc/matrix-synapse/log.config ]; then
    wget -qO /etc/matrix-synapse/log.config https://raw.githubusercontent.com/matrix-org/synapse/develop/res/log.config
fi

# --- 5. Element-Web (Статика) ---
log "Установка Element-Web..."
mkdir -p /var/www/element
wget -qO- https://github.com/element-hq/element-web/releases/download/v1.11.97/element-v1.11.97.tar.gz | tar xz -C /var/www/element --strip-components=1

# --- 6. Nginx + SSL + Well-Known ---
log "Настройка Nginx и SSL..."
certbot --nginx -d "$DOMAIN" -d "$CALLS_DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

cat > /etc/nginx/sites-available/matrix <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / { root /var/www/element; index index.html; }

    location /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin * always;
        return 200 '{"m.homeserver":{"base_url":"https://$DOMAIN"},"org.matrix.msc4143.rtc_foci":[{"type":"livekit","livekit_service_url":"https://$CALLS_DOMAIN"}]}';
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

ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/

# --- 7. Запуск ---
log "Запуск сервисов..."
cat > /etc/systemd/system/matrix-synapse.service <<EOF
[Unit]
Description=Synapse Matrix homeserver
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/matrix-synapse
ExecStart=/opt/venvs/matrix-synapse/bin/python -m synapse.app.homeserver -c /etc/matrix-synapse/homeserver.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable livekit matrix-synapse
systemctl restart nginx livekit matrix-synapse

log "Ожидание прогрева Synapse..."
sleep 15
/opt/venvs/matrix-synapse/bin/register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml http://localhost:8008 -u admin -p "$ADMIN_PASS" -a || true

echo -e "${green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${end}"
echo -e " ГОТОВО! Элемент: https://$DOMAIN"
echo -e " Звонки через LiveKit настроены напрямую в Synapse."
echo -e " Логин: admin | Пароль: $ADMIN_PASS"
echo -e "${green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${end}"