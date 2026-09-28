#!/bin/bash
# SoundFlow — настройка своего ВДС для доступа к музыке с телефона вне дома (28.09.2026).
# Команду с ключом показывает мастер первого запуска SoundFlow на компьютере; её вставляют в консоль ВДС:
#   curl -fsSL https://vdsmusic.ru/soundflow/apk/vds-setup.sh | sudo bash -s -- <ключ> [домен]
# Что делает (Ubuntu/Debian):
#   - пользователь soundflow-relay без входа в консоль: ключу разрешено только открыть 127.0.0.1:8093;
#   - nginx + бесплатный сертификат Let's Encrypt; своего домена нет — берётся <ip>.sslip.io;
#   - на ВДС уже есть VPN (xray/3x-ui) и nginx разбирает 443 по имени сайта (stream + ssl_preread) —
#     443 не трогаем, встраиваемся в этот разбор своим именем и своим внутренним портом 7453;
#   - адрес https://<домен>/soundflow-remote/ ведёт в SoundFlow на домашнем компьютере.
# Перед правкой nginx — копия всей /etc/nginx; проверка nginx не прошла — всё возвращается как было.
# Настройки SSH-сервера не меняются. Повторный запуск безопасен: ключ заменяется, остальное проверяется.
set -euo pipefail

KEY_B64="${1:-}"
DOMAIN="${2:-}"
[ -n "$KEY_B64" ] || { echo "ОШИБКА: не передан ключ. Скопируйте команду из SoundFlow целиком."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "ОШИБКА: запустите от root (через sudo)."; exit 1; }
PUBKEY="$(echo "$KEY_B64" | base64 -d 2>/dev/null || true)"
case "$PUBKEY" in ssh-ed25519\ *) ;; *) echo "ОШИБКА: ключ повреждён. Скопируйте команду из SoundFlow заново."; exit 1;; esac

IP="$(curl -4 -fsS https://api.ipify.org || true)"
[ -n "$IP" ] || { echo "ОШИБКА: не удалось узнать внешний адрес ВДС."; exit 1; }
[ -n "$DOMAIN" ] || DOMAIN="${IP//./-}.sslip.io"
echo "== SoundFlow: адрес $DOMAIN =="

OWNER443="$(ss -ltnpH 'sport = :443' 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true)"
if [ -n "$OWNER443" ] && [ "$OWNER443" != "nginx" ]; then
  echo "ОШИБКА: порт 443 занят программой $OWNER443 (не nginx). Автоматически не настроить —"
  echo "напишите тому, кто дал вам SoundFlow. Ничего не изменено."
  exit 1
fi

echo "== программы (nginx, certbot) =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null

echo "== пользователь канала =="
id soundflow-relay >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin soundflow-relay
install -d -m 700 -o soundflow-relay -g soundflow-relay /home/soundflow-relay/.ssh
echo "no-pty,no-agent-forwarding,no-X11-forwarding,no-user-rc,permitlisten=\"127.0.0.1:8093\" $PUBKEY" \
  > /home/soundflow-relay/.ssh/authorized_keys
chown soundflow-relay:soundflow-relay /home/soundflow-relay/.ssh/authorized_keys
chmod 600 /home/soundflow-relay/.ssh/authorized_keys

echo "== nginx =="
BK="/root/soundflow-nginx-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -a /etc/nginx "$BK/"
echo "   копия настроек: $BK"
restore() {
  echo "ОШИБКА nginx — возвращаю настройки как были"
  rm -rf /etc/nginx
  cp -a "$BK/nginx" /etc/nginx
  nginx -t && systemctl reload nginx
  exit 1
}
STREAM_CONF="$(grep -rlE 'ssl_preread[[:space:]]+on' /etc/nginx/ 2>/dev/null | grep -v '\.bak' | head -1 || true)"
SITE=/etc/nginx/sites-available/soundflow-remote

# 1) только порт 80 — чтобы Let's Encrypt проверил домен
printf 'server {\n    listen 80;\n    server_name %s;\n    root /var/www/html;\n}\n' "$DOMAIN" > "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/soundflow-remote
nginx -t || restore
systemctl reload nginx

echo "== сертификат =="
certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
  || { echo "Сертификат не получен: проверьте, что порт 80 открыт снаружи."; restore; }

# 2) https-часть
if [ -n "$STREAM_CONF" ]; then
  echo "   443 разбирается по имени сайта ($STREAM_CONF) — добавляю своё имя"
  PP=""
  grep -qE 'proxy_protocol[[:space:]]+on' "$STREAM_CONF" && PP=" proxy_protocol"
  LISTEN="listen 127.0.0.1:7453 ssl$PP;"
  grep -q "upstream soundflow_www" "$STREAM_CONF" \
    || printf '\nupstream soundflow_www {\n    server 127.0.0.1:7453;\n}\n' >> "$STREAM_CONF"
  if ! grep -qE "^[[:space:]]*$DOMAIN[[:space:]]+soundflow_www;" "$STREAM_CONF"; then
    grep -qE '^[[:space:]]*hostnames;' "$STREAM_CONF" || { echo "В $STREAM_CONF не найден список имён сайтов"; restore; }
    sed -i -E "0,/^([[:space:]]*)hostnames;/s//\1hostnames;\n\1$DOMAIN soundflow_www;/" "$STREAM_CONF"
  fi
else
  LISTEN="listen 443 ssl;"
fi
{
  printf 'server {\n    listen 80;\n    server_name %s;\n    root /var/www/html;\n' "$DOMAIN"
  printf '    location /.well-known/acme-challenge/ { }\n'
  printf '    location / { return 301 https://$host$request_uri; }\n}\n'
  printf 'server {\n    %s\n    server_name %s;\n' "$LISTEN" "$DOMAIN"
  printf '    ssl_certificate /etc/letsencrypt/live/%s/fullchain.pem;\n' "$DOMAIN"
  printf '    ssl_certificate_key /etc/letsencrypt/live/%s/privkey.pem;\n' "$DOMAIN"
  printf '    location /soundflow-remote/ {\n'
  printf '        proxy_pass http://127.0.0.1:8093/;\n'
  printf '        proxy_http_version 1.1;\n'
  printf '        proxy_set_header Connection "";\n'
  printf '        proxy_read_timeout 90s;\n'
  printf '        proxy_send_timeout 90s;\n'
  printf '        client_max_body_size 50m;\n'
  printf '    }\n}\n'
} > "$SITE"
nginx -t || restore
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi

echo
echo "ГОТОВО. Вернитесь в SoundFlow и нажмите «Проверить»."
echo "Адрес для телефона: https://$DOMAIN/soundflow-remote"
