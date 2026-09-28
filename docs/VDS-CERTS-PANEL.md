ВДС (72.4.69.204) — сертификаты и панель 3x-ui
Записано 28.09.2026. Если что-то сломалось — отдай этот файл Claude целиком.

КАК УСТРОЕН ВДС
- Порт 443 принимает nginx (раздел stream, файл /etc/nginx/stream-enabled/stream.conf)
  и по имени сайта (SNI) решает, куда отправить:
    meduzagargona4221.online, meduzagargona4221.ru и всё незнакомое -> VPN (xray, 127.0.0.1:8443)
    vdsmusic.ru                -> сайт плеера (nginx 7443)
    cc.meduzagargona4221.ru    -> панель cc (nginx 8878)
- VPN (Reality) всё, что не является VPN-подключением (например, браузер), отдаёт на
  «страницу-маскировку» nginx 127.0.0.1:9443. Там же живёт панель 3x-ui:
  https://meduzagargona4221.ru/<секретный путь>/panel/  (путь — в закладке браузера).
- Сама панель 3x-ui — порт 57959; снаружи он закрыт защитой ВДС (ufw), открыты только 22, 80, 443.

ЧТО БЫЛО СЛОМАНО
1. Панель на .ru показывала «Подключение не защищено»: у страницы 9443 был подключён
   сертификат только от .online, а для .ru — нет.
2. Сертификат meduzagargona4221.online не мог продлиться сам: certbot продлевал его способом
   «standalone» (сам занимает порт 80), а порт 80 занят nginx. Пробное продление падало.
   Срок сертификата — 26.11.2026; без починки он бы истёк.

ЧТО СДЕЛАНО 28.09.2026
1. Страница 9443 разделена на две:
   /etc/nginx/sites-available/meduzagargona4221.online  -> только .online, сертификат .online
   /etc/nginx/sites-available/meduzagargona4221.ru-panel -> только .ru, сертификат .ru (новый файл,
      включён ссылкой в /etc/nginx/sites-enabled/)
2. /etc/nginx/sites-enabled/80.conf: для .ru и .online добавлен адрес /.well-known/acme-challenge/
   (папка /var/www/html) — через него Let's Encrypt проверяет домен при продлении.
3. /etc/letsencrypt/renewal/meduzagargona4221.online.conf: продление переведено со «standalone»
   на «webroot» (/var/www/html).
VPN, его настройки и ссылки НЕ менялись.

КАК ТЕПЕРЬ ПРОДЛЕВАЮТСЯ СЕРТИФИКАТЫ
- Служба certbot.timer запускается 2 раза в день, плюс ежемесячная строка в crontab root.
- Сертификат продлевается сам за 30 дней до конца срока. Руками ничего делать не нужно.
- Сертификаты: meduzagargona4221.ru, meduzagargona4221.online, cc.meduzagargona4221.ru, vdsmusic.ru.
  Пробное продление всех четырёх 28.09.2026 — успешно.

ПРОВЕРКА (команды на ВДС, от root)
  certbot renew --dry-run                 # пробное продление всех; должно быть «Congratulations»
  certbot certificates                    # сроки всех сертификатов
  nginx -t                                # проверка настроек nginx
  systemctl status certbot.timer          # когда следующий запуск продления

КАК ВЕРНУТЬ КАК БЫЛО
Копия до правки: /root/nginx-backup-20260928-panel/ (папки nginx и renewal).
  rm -rf /etc/nginx && cp -a /root/nginx-backup-20260928-panel/nginx /etc/nginx
  cp -a /root/nginx-backup-20260928-panel/renewal/. /etc/letsencrypt/renewal/
  nginx -t && systemctl reload nginx
