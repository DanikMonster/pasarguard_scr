# PasarGuard Installer & Manager (`pasarguard_scr`)

Интерактивный скрипт для установки и управления [PasarGuard](https://github.com/PasarGuard/panel) — панелью управления прокси на базе Xray-core.

Скрипт автоматизирует весь процесс: установку зависимостей, настройку базы данных, выпуск SSL-сертификата, создание администратора и (опционально) установку ноды. После установки скрипт сохраняется в систему как команда `pasarguard_scr` для дальнейшего управления панелью.

---

## Быстрый старт

Запустите одну команду на сервере от имени **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh)
```

Или в два шага:

```bash
curl -fsSLo /tmp/pasarguard_scr.sh https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh
sudo bash /tmp/pasarguard_scr.sh
```

После установки скрипт доступен как команда:

```bash
pasarguard_scr          # главное меню
pasarguard_scr manage   # меню управления
pasarguard_scr help     # справка по командам
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

## Режим установки

При первом запуске скрипт проведёт вас через интерактивную настройку:

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

### 7. Подтверждение и установка

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

После подтверждения начнётся автоматическая установка. Скрипт `pasarguard_scr` сохраняется в `/usr/local/bin/` и доступен как команда.

---

## Что устанавливается

- **Docker** и **Docker Compose** (если не установлены)
- **yq** — утилита для работы с YAML
- **jq**, **curl**, **openssl**, **socat** — вспомогательные утилиты
- **acme.sh** — менеджер SSL-сертификатов (при выборе Let's Encrypt)
- **cron** — для автообновления сертификатов
- **PasarGuard Panel** — Docker-контейнер с панелью
- **PasarGuard Node** — Xray-core нода (опционально)
- **pasarguard** — официальный CLI для управления
- **pasarguard_scr** — данный скрипт (в `/usr/local/bin/`)

---

## Режим управления

После установки вызовите `pasarguard_scr` или `pasarguard_scr manage` для открытия меню управления:

```
  ╔══════════════════════════════════════════════╗
  ║                                              ║
  ║     PasarGuard Manager                       ║
  ║                                              ║
  ╚══════════════════════════════════════════════╝

  1)  Status              — Show current configuration
  2)  Change domain       — Change panel domain & SSL
  3)  Change port         — Change panel port
  4)  Change dashboard URI— Change admin panel URL path
  5)  Subscription page   — Edit subscription HTML template
  6)  Home page           — Edit home page HTML template
  7)  Change admin        — Change admin password
  8)  Restart panel       — Restart PasarGuard services
  9)  View logs           — Show panel logs
  10) Edit .env           — Manually edit configuration
  11) Update script       — Update pasarguard_scr to latest

  0)  Exit
```

### Подробное описание каждого пункта

#### 1. Status — Текущий статус

Показывает текущую конфигурацию панели:

```
═══ PasarGuard Status ═══

  Panel URL:           https://panel.example.com:8000/dashboard/
  Port:                8000
  Domain:              panel.example.com
  Dashboard path:      /dashboard/
  Subscription path:   sub
  SSL cert:            /var/lib/pasarguard/certs/panel.example.com/fullchain.pem
  SSL key:             /var/lib/pasarguard/certs/panel.example.com/key.pem
  Templates dir:       /var/lib/pasarguard/templates
  Sub page template:   <default>
  Home page template:  <default>
```

Также показывает статус Docker-контейнеров.

#### 2. Change domain — Смена домена панели

Позволяет изменить домен и SSL-сертификат:

1. Введите новый домен
2. Выберите способ получения SSL:
   - **Let's Encrypt** — автоматический выпуск сертификата
   - **Custom** — свой сертификат
   - **No SSL** — без HTTPS
3. Панель автоматически перезапустится с новыми настройками

```bash
pasarguard_scr change-domain
```

> **Важно:** Перед сменой домена убедитесь, что новый домен уже указывает на IP сервера (A-запись в DNS).

#### 3. Change port — Смена порта

Изменяет порт, на котором слушает панель:

```
═══ Change Panel Port ═══

  Current port: 8000

> New port: 443
```

```bash
pasarguard_scr change-port
```

#### 4. Change dashboard URI — Смена URI входа в панель

Изменяет URL-путь для доступа к панели администратора. По умолчанию `/dashboard/`.

Примеры:
- `/dashboard/` — стандартный
- `/admin/` — альтернативный
- `/secret-panel-xyz/` — скрытый путь для безопасности

```
═══ Change Dashboard URI Path ═══

  Current path: /dashboard/

> New path (must start and end with /): /my-secret-panel/
```

```bash
pasarguard_scr change-uri
```

> **Совет:** Используйте нестандартный путь для защиты от ботов и сканеров.

#### 5. Subscription page — Смена HTML подписки

Управляет HTML-шаблоном страницы подписки, которую видят пользователи:

```
═══ Change Subscription Page HTML ═══

  Current template: <default>
  Templates dir:    /var/lib/pasarguard/templates

  Options:

  1) Edit subscription HTML in nano/vi
  2) Provide path to custom HTML file
  3) Reset to default template
  4) Change subscription URL path
```

- **Вариант 1:** Откроет текстовый редактор (nano или vi) с шаблоном. Если шаблон не существует — создаст базовый.
- **Вариант 2:** Скопирует ваш готовый HTML-файл как шаблон подписки.
- **Вариант 3:** Вернёт стандартный шаблон PasarGuard.
- **Вариант 4:** Изменит URL-путь подписки (по умолчанию `sub`).

```bash
pasarguard_scr change-sub
```

В HTML-шаблоне подписки доступна переменная `{{ sub_url }}` — ссылка на подписку пользователя.

#### 6. Home page — Смена главной страницы

Аналогично странице подписки, но для главной страницы сервера:

```bash
pasarguard_scr change-home
```

#### 7. Change admin — Смена пароля администратора

Показывает список текущих админов и позволяет изменить пароль:

```
═══ Change Admin Password ═══

Current admins:
  admin (sudo)

> Username to modify: admin
> New password: ************
> Confirm password: ************
```

```bash
pasarguard_scr change-admin
```

#### 8–9. Restart & Logs

```bash
pasarguard_scr restart   # перезапустить панель
pasarguard_scr logs      # просмотр логов (live)
```

#### 10. Edit .env — Ручное редактирование

Открывает файл конфигурации `/opt/pasarguard/.env` в текстовом редакторе. После сохранения панель автоматически перезапустится.

#### 11. Update script

Обновляет `pasarguard_scr` до последней версии с GitHub:

```bash
pasarguard_scr update
```

---

## Все команды

| Команда | Описание |
|---|---|
| `pasarguard_scr` | Главное меню (установка или управление) |
| `pasarguard_scr install` | Запустить установку |
| `pasarguard_scr manage` | Открыть меню управления |
| `pasarguard_scr change-domain` | Сменить домен панели и SSL |
| `pasarguard_scr change-port` | Сменить порт панели |
| `pasarguard_scr change-uri` | Сменить URI входа в панель |
| `pasarguard_scr change-sub` | Редактировать HTML подписки |
| `pasarguard_scr change-home` | Редактировать HTML главной |
| `pasarguard_scr change-admin` | Сменить пароль администратора |
| `pasarguard_scr status` | Показать статус и конфигурацию |
| `pasarguard_scr restart` | Перезапустить панель |
| `pasarguard_scr logs` | Показать логи (live) |
| `pasarguard_scr update` | Обновить скрипт до последней версии |
| `pasarguard_scr help` | Справка по командам |

---

## После установки

### Вход в панель

```
═══ Installation Complete! ═══

  PasarGuard has been installed successfully!

  Panel URL:     https://panel.example.com:8000/dashboard/
  Admin user:    admin
  Admin pass:    (the password you entered during setup)

  Management:    Run pasarguard_scr anytime to manage your panel.
```

### Добавление ноды

Если вы установили ноду, добавьте её в панели:

1. Войдите в панель → **Nodes** → **Add Node**
2. Укажите:
   - **Address:** IP-адрес сервера или `127.0.0.1`
   - **Port:** `62050` (или указанный при установке)
   - **API Key:** показан в выводе скрипта
   - **Certificate:** сертификат ноды (показан в выводе)

### Дополнительные команды PasarGuard

| Команда | Описание |
|---|---|
| `pasarguard status` | Статус Docker-сервисов |
| `pasarguard logs` | Логи панели |
| `pasarguard restart` | Перезапуск |
| `pasarguard cli` | Интерактивный CLI |
| `pasarguard cli admins -l` | Список админов |
| `pasarguard update` | Обновить PasarGuard |
| `pasarguard uninstall` | Удалить PasarGuard |

### Файлы конфигурации

| Файл | Описание |
|---|---|
| `/opt/pasarguard/.env` | Основной файл конфигурации |
| `/opt/pasarguard/docker-compose.yml` | Docker Compose |
| `/var/lib/pasarguard/` | Данные (БД, сертификаты, шаблоны) |
| `/var/lib/pasarguard/templates/` | Пользовательские HTML-шаблоны |
| `/usr/local/bin/pasarguard_scr` | Данный скрипт управления |

---

## Устранение неполадок

### SSL-сертификат не выпускается

- Убедитесь, что домен указывает на IP сервера: `dig panel.example.com`
- Порт **80** должен быть открыт: `ss -tlnp | grep :80`
- Попробуйте: `pasarguard_scr change-domain`

### Панель недоступна извне

- Проверьте порт в файрволе:
  ```bash
  ufw allow 8000/tcp
  ```
- Без SSL — используйте SSH-туннель:
  ```bash
  ssh -L 8000:localhost:8000 root@YOUR_SERVER_IP
  ```

### Ошибка "Incorrect username or password"

```bash
pasarguard_scr change-admin
# или
pasarguard cli admins -l
pasarguard cli admins -c admin -s
```

### Docker не запускается

```bash
systemctl status docker
journalctl -u docker.service
```

### Перезапуск и логи

```bash
pasarguard_scr restart
pasarguard_scr logs
```

---

## Обновление

### Обновить PasarGuard Panel

```bash
pasarguard update
```

### Обновить скрипт pasarguard_scr

```bash
pasarguard_scr update
```

---

## Удаление

```bash
pasarguard uninstall
rm -f /usr/local/bin/pasarguard_scr
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
