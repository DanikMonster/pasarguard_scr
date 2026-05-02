# PasarGuard Installer Script (`pasarguard_scr`)

Интерактивный скрипт для быстрой установки [PasarGuard](https://github.com/PasarGuard/panel) — панели управления прокси на базе Xray-core.

Скрипт автоматизирует весь процесс: установку зависимостей, настройку базы данных, выпуск SSL-сертификата, создание администратора и (опционально) установку ноды — всё через удобное интерактивное меню.

---

## Быстрый старт

Запустите одну команду на вашем сервере от имени **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh)
```

Или в два шага:

```bash
curl -fsSLo /tmp/pasarguard_scr.sh https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh
sudo bash /tmp/pasarguard_scr.sh
```

---

## Требования

| Требование | Минимум |
|---|---|
| **ОС** | Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12 |
| **Архитектура** | x86_64 (amd64) |
| **RAM** | 1 GB (рекомендуется 2 GB+) |
| **Доступ** | root или sudo |
| **Порты** | 80 (для SSL), 8000 (панель), 62050 (нода) |

> **Важно:** Перед установкой убедитесь, что домен (если используется) уже привязан к IP-адресу сервера через DNS (A-запись).

---

## Что делает скрипт

Скрипт проведёт вас через следующие шаги:

### 1. Домен панели

```
═══ Panel Domain / URL ═══

Enter the domain name that points to this server.
Example: panel.example.com
(Leave empty to use server IP only)

> Domain: panel.example.com
```

Введите домен, который указывает на ваш сервер. Если домена нет — оставьте пустым и панель будет доступна по IP.

### 2. Порт панели

```
═══ Panel Port ═══

Port on which the PasarGuard panel will listen.
Default: 8000

> Port [8000]:
```

Порт по умолчанию — **8000**. Можно изменить на любой свободный.

### 3. База данных

```
═══ Database Engine ═══

Choose the database for PasarGuard:

  1) SQLite        (default, simplest)
  2) MySQL
  3) MariaDB
  4) PostgreSQL    (v1.0.0+)
  5) TimescaleDB   (v1.0.0+)

> Choose [1]:
```

| Вариант | Описание |
|---|---|
| **SQLite** | Файловая БД, не требует настройки. Подходит для большинства случаев. |
| **MySQL / MariaDB** | Для больших нагрузок. Потребуется предварительная установка и настройка СУБД. |
| **PostgreSQL** | Рекомендуется для production. Поддерживается с версии v1.0.0. |
| **TimescaleDB** | Расширение PostgreSQL для аналитики. Поддерживается с версии v1.0.0. |

> При выборе MySQL/MariaDB/PostgreSQL/TimescaleDB вам потребуется вручную настроить строку подключения в файле `/opt/pasarguard/.env` после установки.

### 4. SSL-сертификат

```
═══ SSL Certificate ═══

Choose how to set up HTTPS for the panel:

  1) Let's Encrypt — automatic via domain   (recommended)
  2) Let's Encrypt — automatic via server IP
  3) Custom certificate (provide paths)
  4) No SSL (localhost only / reverse proxy)

> Choose [1]:
```

| Вариант | Описание |
|---|---|
| **Let's Encrypt (домен)** | Автоматический бесплатный сертификат. Нужен домен, направленный на сервер. Порт 80 должен быть свободен. |
| **Let's Encrypt (IP)** | Сертификат на IP-адрес сервера. Краткосрочный. |
| **Custom** | Укажите пути к вашему сертификату и ключу (`fullchain.pem`, `key.pem`). |
| **No SSL** | Без HTTPS. Панель будет доступна только через `localhost` или за reverse proxy (Nginx, Caddy). |

> **Рекомендация:** Если у вас есть домен — выбирайте вариант 1 (Let's Encrypt). Сертификат будет обновляться автоматически через cron.

### 5. Учётная запись администратора

```
═══ Admin Account ═══

Create a sudo administrator for the panel.

> Username [admin]: admin

Password requirements:
  - Minimum 12 characters
  - At least 2 digits
  - At least 2 uppercase letters
  - At least 1 special character (!@#$%^&* etc.)

> Password: ************
> Confirm password: ************
```

Скрипт проверяет сложность пароля и не даст продолжить, пока пароль не будет соответствовать требованиям.

### 6. Установка ноды

```
═══ Node Installation ═══

PasarGuard needs at least one Xray node to work.
Install a node on this same server?

> Install node? [Y/n]: Y
> Node service port [62050]:
> Node API port [62051]:
```

Нода Xray-core устанавливается на тот же сервер. Для production рекомендуется выносить ноды на отдельные серверы.

### 7. Подтверждение

```
═══ Installation Summary ═══

  Domain:       panel.example.com
  Port:         8000
  Database:     sqlite
  SSL:          domain
  Admin user:   admin
  Install node: y
  Node port:    62050
  Node API:     62051

Proceed with installation? [Y/n]:
```

После подтверждения начнётся автоматическая установка.

---

## Что устанавливается

Скрипт автоматически установит / настроит:

- **Docker** и **Docker Compose** (если не установлены)
- **yq** — утилита для работы с YAML
- **jq**, **curl**, **openssl**, **socat** — вспомогательные утилиты
- **acme.sh** — менеджер SSL-сертификатов (при выборе Let's Encrypt)
- **cron** — для автообновления сертификатов
- **PasarGuard Panel** — Docker-контейнер с панелью
- **PasarGuard Node** — Xray-core нода (опционально)
- **pasarguard** — CLI-утилита для управления

---

## После установки

### Вход в панель

После успешной установки вы увидите:

```
═══ Installation Complete! ═══

  PasarGuard has been installed successfully!

  Panel URL:     https://panel.example.com:8000/dashboard/
  Admin user:    admin
  Admin pass:    (the password you entered during setup)
  Database:      sqlite
  SSL:           domain
```

Откройте URL панели в браузере и войдите с указанными учётными данными.

### Добавление ноды

Если вы установили ноду, не забудьте добавить её в панели:

1. Войдите в панель → **Nodes** → **Add Node**
2. Укажите:
   - **Address:** IP-адрес сервера или `127.0.0.1` (если нода на том же сервере)
   - **Port:** `62050` (или указанный при установке)
   - **API Key:** будет показан в выводе скрипта
   - **Certificate:** вставьте сертификат ноды (также показан в выводе)

### Полезные команды

| Команда | Описание |
|---|---|
| `pasarguard status` | Проверить статус сервисов |
| `pasarguard logs` | Просмотр логов |
| `pasarguard restart` | Перезапуск сервисов |
| `pasarguard cli` | Интерактивный CLI |
| `pasarguard cli admins -l` | Список администраторов |
| `pasarguard cli admins -c <name> -s` | Создать нового админа |
| `pasarguard update` | Обновить до последней версии |
| `pasarguard uninstall` | Удалить PasarGuard |

### Файлы конфигурации

| Файл | Описание |
|---|---|
| `/opt/pasarguard/.env` | Основной файл конфигурации |
| `/opt/pasarguard/docker-compose.yml` | Docker Compose конфигурация |
| `/var/lib/pasarguard/` | Данные (БД, сертификаты) |

---

## Примеры использования

### Быстрая установка с настройками по умолчанию

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh)
```

Следуйте подсказкам скрипта. Для большинства пунктов можно нажать Enter, чтобы использовать значения по умолчанию.

### Установка на чистый сервер с доменом

1. Привяжите домен к серверу (A-запись в DNS):
   ```
   panel.example.com → 123.45.67.89
   ```

2. Подождите 5–10 минут для распространения DNS.

3. Запустите скрипт:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh)
   ```

4. При настройке укажите:
   - **Domain:** `panel.example.com`
   - **SSL:** `1` (Let's Encrypt — automatic via domain)
   - Остальное — по желанию

---

## Устранение неполадок

### SSL-сертификат не выпускается

- Убедитесь, что домен указывает на IP вашего сервера (`dig panel.example.com`)
- Порт **80** должен быть открыт и не занят другим сервисом
- Проверьте: `ss -tlnp | grep :80`

### Панель недоступна извне

- Проверьте, что порт **8000** открыт в файрволе:
  ```bash
  ufw allow 8000/tcp   # для UFW
  ```
- Если SSL не настроен, панель слушает только `localhost`. Используйте SSH-туннель:
  ```bash
  ssh -L 8000:localhost:8000 root@YOUR_SERVER_IP
  ```
  Затем откройте `http://localhost:8000` в браузере.

### Ошибка "Incorrect username or password"

- Проверьте, что администратор создан: `pasarguard cli admins -l`
- Создайте нового: `pasarguard cli admins -c admin -s`

### Docker не запускается

```bash
systemctl status docker
journalctl -u docker.service
```

### Перезапуск панели

```bash
pasarguard restart
# или
cd /opt/pasarguard && docker compose restart
```

### Просмотр логов

```bash
pasarguard logs
# или
cd /opt/pasarguard && docker compose logs -f
```

---

## Обновление PasarGuard

```bash
pasarguard update
```

Или вручную:

```bash
cd /opt/pasarguard
docker compose pull
docker compose down
docker compose up -d
```

---

## Удаление

```bash
pasarguard uninstall
```

Или вручную:

```bash
cd /opt/pasarguard
docker compose down -v
rm -rf /opt/pasarguard /var/lib/pasarguard
```

---

## Лицензия

MIT License. Скрипт распространяется «как есть», без гарантий.

PasarGuard — проект с открытым исходным кодом ([AGPL-3.0](https://github.com/PasarGuard/panel/blob/main/LICENSE)).

---

## Ссылки

- [PasarGuard Panel](https://github.com/PasarGuard/panel) — основной репозиторий
- [PasarGuard Scripts](https://github.com/PasarGuard/scripts) — официальные скрипты
- [PasarGuard Documentation](https://docs.pasarguard.org) — документация
