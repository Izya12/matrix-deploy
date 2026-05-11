Matrix Deploy
Автоустановка Matrix Synapse + Element Web на чистый Debian 12.

Один сервер. Одна команда. Всё готово.

Запуск
bash <(curl -fsSL https://raw.githubusercontent.com/konvasru-oss/matrix-deploy/main/install.sh)
Скрипт спросит домен, имя администратора и пароль. Больше ничего.

Что установится
Matrix Synapse — сервер сообщений
Element Web — веб-клиент (https://домен/element/)
Synapse Admin — панель управления пользователями (https://домен/admin/)
coturn — TURN/STUN сервер для звонков
PostgreSQL — база данных
Nginx + SSL (Let's Encrypt)
Fail2ban — защита от брутфорса
UFW — фаервол
Требования
Debian 12 (Bookworm) или новее
Root доступ
Домен с A-записью, указывающей на сервер
Открытые порты: 80, 443, 3478, 49152–65535
Меню
При запуске скрипт предлагает:

1. Установить Matrix с нуля
2. Починить / переустановить (данные сохраняются)
3. Сменить пароль пользователя
4. Создать бэкап
5. Восстановить из бэкапа
Команды после установки
Команда	Что делает
matrix-reset-password	Сменить пароль любого пользователя
matrix-backup	Создать бэкап вручную
matrix-backup yes	Бэкап с медиафайлами
matrix-add-federation домен	Добавить домен в federation whitelist
update-element	Обновить Element Web
Бэкапы хранятся в /opt/matrix-backups/, автоматически каждый день в 02:00.
Хранятся последние 7 бэкапов.

Создание пользователей
Открой Synapse Admin (https://домен/admin/) и создавай пользователей вручную.
QR-код и прямая ссылка появятся в конце установки прямо в терминале.

Лицензия
MIT
