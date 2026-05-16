#!/bin/bash
# ============================================================
#  Matrix Synapse — полная чистка сервера
#  Запускай от root на тестовом сервере
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo -e "${RED}Это удалит Matrix, Nginx, PostgreSQL, Docker и все данные.${NC}"
read -rp "Уверен? Введи yes: " SURE
if [ "$SURE" != "yes" ]; then echo "Отмена."; exit 0; fi

# Synapse
systemctl stop matrix-synapse 2>/dev/null || true
systemctl disable matrix-synapse 2>/dev/null || true
apt-get remove --purge -y matrix-synapse-py3 2>/dev/null || true
rm -rf /etc/matrix-synapse /var/lib/matrix-synapse /var/log/matrix-synapse
rm -f /etc/apt/sources.list.d/matrix-org.list
rm -f /usr/share/keyrings/matrix-org-archive-keyring.gpg
log "Synapse удалён"

# Docker контейнеры и образы
if command -v docker >/dev/null 2>&1; then
  docker stop element-web livekit-server 2>/dev/null || true
  docker rm element-web livekit-server 2>/dev/null || true
  docker rmi vectorim/element-web livekit/livekit-server 2>/dev/null || true
  log "Docker контейнеры удалены"
fi

# LiveKit
systemctl stop livekit lk-jwt-service 2>/dev/null || true
systemctl disable livekit lk-jwt-service 2>/dev/null || true
rm -f /etc/systemd/system/livekit.service
rm -f /etc/systemd/system/lk-jwt-service.service
rm -f /usr/local/bin/livekit-server
rm -f /usr/local/bin/lk-jwt-service
rm -rf /etc/livekit
systemctl daemon-reload
log "LiveKit удалён"

# Nginx
systemctl stop nginx 2>/dev/null || true
apt-get remove --purge -y nginx nginx-common certbot python3-certbot-nginx 2>/dev/null || true
rm -rf /etc/nginx /var/log/nginx
rm -rf /etc/letsencrypt
rm -rf /var/www/html/element /var/www/html/admin
rm -rf /etc/element-web
log "Nginx и SSL удалены"

# PostgreSQL
systemctl stop postgresql 2>/dev/null || true
apt-get remove --purge -y postgresql postgresql-* 2>/dev/null || true
rm -rf /var/lib/postgresql /etc/postgresql /var/log/postgresql
log "PostgreSQL удалён"

# coturn
systemctl stop coturn 2>/dev/null || true
apt-get remove --purge -y coturn 2>/dev/null || true
rm -f /etc/turnserver.conf
log "coturn удалён"

# fail2ban
systemctl stop fail2ban 2>/dev/null || true
apt-get remove --purge -y fail2ban 2>/dev/null || true
rm -f /etc/fail2ban/jail.local /etc/fail2ban/jail.d/matrix-synapse.conf
rm -f /etc/fail2ban/filter.d/matrix-synapse.conf
log "fail2ban удалён"

# Секреты и бэкапы
rm -f /root/.matrix_secrets /root/.matrix_pg_pass /root/.matrix_access_token /root/.matrix_reg_token
rm -rf /opt/matrix-backups
log "Секреты и бэкапы удалены"

# Команды и утилиты
rm -f /usr/local/bin/matrix-*
rm -f /etc/cron.d/matrix-*
rm -f /etc/cron.d/certbot-renew
log "Утилиты и cron задачи удалены"

# UFW сброс
ufw --force reset 2>/dev/null || true
ufw --force enable 2>/dev/null || true
ufw allow ssh 2>/dev/null || true
log "UFW сброшен (SSH оставлен)"

# Чистим мусор
apt-get autoremove -y -qq 2>/dev/null || true
apt-get clean 2>/dev/null || true

echo ""
echo -e "${GREEN}Сервер чист. Можно запускать install.sh${NC}"
