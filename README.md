# Установщик 3X-UI и Remnawave

Production-oriented Bash-установщик с двумя независимыми потоками. При интерактивном запуске без аргументов он сначала спрашивает, с чем работаем: `3X-UI` или `Remnawave`. Неинтерактивный запуск без явного выбора сохраняет прежнее поведение 3X-UI.

Ветка 3X-UI ставит официальный stable 3X-UI, читает `install-result.env`, проверяет Bearer API и live OpenAPI, затем создаёт набор TCP/UDP-профилей. Ветка Remnawave вынесена в `remnawave-manager.sh` и следует официальной схеме Panel + PostgreSQL/Valkey + Caddy + отдельная Node.

Скрипт не обещает прохождение российского DPI: локальный end-to-end тест на VPS подтверждает серверную конфигурацию, но не доступность из сети конкретного российского оператора.

## Запуск

На чистом VPS с systemd:

```bash
curl -fsSLO https://github.com/thefuckerguy/3xui-installer/releases/latest/download/install-3xui-full.sh
curl -fsSLO https://github.com/thefuckerguy/3xui-installer/releases/latest/download/install-3xui-full.sh.sha256
sha256sum -c install-3xui-full.sh.sha256
sudo bash install-3xui-full.sh
```

Для явного выбора без общего меню:

```bash
sudo bash install-3xui-full.sh --product 3x-ui
sudo bash install-3xui-full.sh --product remnawave
```

## Remnawave

Remnawave требует домен: A/AAAA должен заранее указывать на VPS. Панель не поддерживает публикацию на подпути и не должна выставлять свои Docker-порты в интернет; Caddy публикует её на корне домена и выпускает TLS-сертификат.

```bash
# интерактивная установка Panel + Caddy
sudo bash install-3xui-full.sh --product remnawave install

# без вопросов
sudo REMNAWAVE_PANEL_DOMAIN=panel.example.com \
  bash install-3xui-full.sh --product remnawave install --non-interactive

# импорт профиля/inbound из актуального каталога remnawave/templates
sudo bash install-3xui-full.sh --product remnawave profile

# автоматизировать Config Profile, inbound, запись ноды и Compose-бандл
sudo bash install-3xui-full.sh --product remnawave configure

# установить локальный веб-мастер добавления нод
sudo bash install-3xui-full.sh --product remnawave web-install

# повторно показать команду SSH-туннеля и защищённый URL
sudo bash install-3xui-full.sh --product remnawave web-url

# шаги создания ноды
sudo bash install-3xui-full.sh --product remnawave node-guide

# на сервере ноды: установить Compose-бандл, сгенерированный командой configure
sudo REMNAWAVE_PANEL_SOURCE_CIDR=203.0.113.10/32 \
  bash remnawave-manager.sh node-install /root/remnanode-compose.yml
```

Перед автоматической настройкой скрипт скачивает live OpenAPI с `docs.rw` и проверяет ожидаемые endpoints/обязательные поля. Config Profile создаётся из JSON официального каталога `remnawave/templates`; API payload формируется только после этой проверки. `SECRET_KEY` генерирует панель, а скрипт записывает эквивалентный официальному Node Compose в root-only файл.

Если рядом с основным скриптом нет актуального `remnawave-manager.sh`, выбор Remnawave скачает его и отдельный `.sha256` из последнего GitHub Release, проверит SHA-256 и Bash-синтаксис и только затем запустит/установит companion. Команда `web-install` аналогично загружает `remnawave-web.py` с отдельной контрольной суммой и проверяет Python-синтаксис. Поэтому стандартная безопасная загрузка основного файла также работает для Remnawave.

Команда `configure` работает через локальный API `127.0.0.1:3000`: регистрирует первого admin или входит существующим, создаёт профиль, Internal Squad со всеми inbound и ноду по live OpenAPI-схеме, а затем записывает Compose с `SECRET_KEY` в root-only каталог `/opt/remnawave/node-bundles`. JWT и `SECRET_KEY` не печатаются. После этого администратор должен назначить нужных пользователей этому Internal Squad. Для неинтерактивного запуска задайте `REMNAWAVE_ADMIN_USERNAME`, `REMNAWAVE_ADMIN_PASSWORD`, `REMNAWAVE_PROFILE_NAME`, `REMNAWAVE_NODE_NAME`, `REMNAWAVE_NODE_ADDRESS`, `REMNAWAVE_NODE_PORT` и, при необходимости, `REMNAWAVE_TEMPLATE_NUMBER`.

После импорта Config Profile нужно включить его inbound в `Internal Squad`, затем назначить профиль/инбаунды ноде. Node Port должен быть доступен только с IP панели.

### Веб-мастер нод

`web-install` один раз спрашивает логин и пароль Remnawave super-admin, создаёт отдельный API token на 10 лет, устанавливает systemd-службу и выводит команду SSH-туннеля. Пароль администратора не сохраняется. Служба работает от отдельного системного пользователя, слушает только `127.0.0.1:8787` и защищена случайным access token.

В форме указываются название ноды, IPv4, SSH-порт, root-пароль, код страны и отдельный домен ноды. A-запись домена должна напрямую указывать на IPv4 ноды: это необходимо для trusted TLS у XHTTP, Trojan и Hysteria2. Перед передачей пароля мастер показывает ED25519 fingerprint SSH-сервера и требует его подтверждения.

После подтверждения мастер:

1. передаёт root-пароль `sshpass` через отдельный файловый дескриптор, устанавливает служебный ED25519-ключ и очищает пароль из задания;
2. проверяет чистую Debian 11+/Ubuntu 22.04+ ноду и свободные порты;
3. создаёт индивидуальные Config Profile, Internal Squad, Node и пять Hosts через локальный Remnawave API;
4. устанавливает Docker, Remnawave Node, Nginx SelfSteal через Unix-сокет, Certbot, BBR и UFW;
5. открывает Node Port `2222/tcp` (или случайный, если `2222` занят) только для публичного IP/CIDR панели и ожидает `isConnected=true`.

Создаются пять inbound: VLESS + REALITY + Vision на `443/tcp`, VLESS + XHTTP + TLS, Trojan + TLS, Shadowsocks 2022 TCP/UDP и Hysteria2 QUIC. Для каждой ноды генерируются отдельные X25519/shortId/Shadowsocks-ключи и случайные порты. При ошибке до запуска удалённой ноды созданные API-объекты удаляются в обратном порядке; после запуска они сохраняются для диагностики.

Веб-мастер не заменяет существующий `/opt/remnanode` и не подходит для обновления уже зарегистрированной ноды. Root-пароль не записывается в файлы или аргументы процессов, но первоначальное подключение всё равно нужно выполнять только после сверки SSH fingerprint.

При запуске без аргументов сначала открывается главное меню. Для новой установки выберите пункт `1 — Установить или настроить 3X-UI`, после чего откроется мастер. Он спросит:

1. устанавливать с доменом или по IP; в обоих режимах настраивается Let's Encrypt;
2. логин и пароль панели (пусто — безопасная автогенерация);
3. порт панели и `WebBasePath` (пусто — автогенерация);
4. базовое название инбаундов (Enter — `AUTO`);
5. SQLite или PostgreSQL;
6. включать ли Fail2ban и BBR;
7. подтверждение перед началом изменений.

Пароль и PostgreSQL DSN вводятся без отображения. Если терминала нет (cloud-init/CI),
скрипт автоматически использует ENV-параметры и безопасные значения по умолчанию.

С доменом, A/AAAA которого уже указывает на VPS:

```bash
sudo XUI_DOMAIN=vpn.example.com \
  bash install-3xui-full.sh
```

Принудительно без вопросов:

```bash
sudo bash install-3xui-full.sh --non-interactive
```

Принудительно открыть мастер (завершится ошибкой, если терминал недоступен):

```bash
sudo bash install-3xui-full.sh --interactive
```

## Управление после установки

После успешной установки создаётся команда:

```bash
sudo 3xui-installer
# короткий вызов того же меню:
sudo dns
```

При каждом запуске команда сначала проверяет опубликованную версию. Если доступна новая версия, менеджер автоматически скачивает её, проверяет SHA-256, Bash-синтаксис и номер версии, атомарно обновляется, а затем уже новой версией открывает главное меню. Если сервер публикации временно недоступен, запускается установленная версия.

Главное меню позволяет начать установку, посмотреть настройки, восстановить или переустановить панель, вручную проверить обновление и полностью удалить 3X-UI.
Те же действия доступны напрямую:

```bash
sudo 3xui-installer settings
sudo 3xui-installer panel-update
sudo 3xui-installer add-inbounds
sudo 3xui-installer recreate-inbounds
sudo 3xui-installer web
sudo 3xui-installer repair
sudo 3xui-installer reinstall
sudo 3xui-installer reinstall-clean
sudo 3xui-installer check-update
sudo 3xui-installer update
sudo 3xui-installer uninstall
```

- `settings` показывает URL панели, логин, пароль, API-ключ, подписку, версию и состояние сервиса;
- `panel-update` создаёт резервную копию и обновляет 3X-UI до последней stable-версии, сохраняя базу, клиентов, существующие инбаунды и настройки; после обновления актуальный доступ выводится в терминал и сохраняется в `access-after-panel-update.txt`;
- `add-inbounds` предлагает имя и формат примечаний, затем добавляет только отсутствующие управляемые инбаунды в активную панель; существующие инбаунды и клиенты не удаляются и не редактируются;
- `recreate-inbounds` после подтверждения `RECREATE INBOUNDS` предлагает новое базовое имя и формат примечаний, создаёт резервную копию, удаляет только ранее управляемые установщиком инбаунды и создаёт их заново с новыми случайными портами, клиентами и ссылками; пользовательские инбаунды не изменяются. В режиме `--non-interactive` команда принимает подтверждение через `CONFIRM_RECREATE_INBOUNDS=RECREATE_INBOUNDS` и использует сохранённое имя и формат либо явно заданные `XUI_INBOUND_NAME` и `XUI_INBOUND_REMARK_MODE`;
- при настройке подписки установщик задаёт шаблон примечания панели ровно `{{INBOUND}}`, чтобы имя узла подписки содержало только примечание инбаунда;
- `web` запускает приватную страницу с данными сервера, кнопками копирования и краткой/полной инструкцией только на `127.0.0.1`;
- `repair` завершает прерванную установку и восстанавливает отсутствующий файл учётных данных;
- `reinstall` заново устанавливает бинарные файлы 3X-UI, сохраняя базу и настройки;
- `reinstall-clean` безвозвратно удаляет базу, инбаунды, клиентов и настройки, затем запускает полный мастер чистой установки; требуется ввести `DELETE DATABASE`;
- `check-update` сравнивает версию установленного менеджера с опубликованной версией;
- `update` скачивает новую версию менеджера, проверяет SHA-256, синтаксис и номер версии, а затем устанавливает её;
- `uninstall` удаляет панель, базу, созданные профили, результаты, системные настройки и правила firewall. Для удаления требуется ввести `DELETE`.

Команда `settings` также выводит информацию о доступном обновлении. Для первой миграции с версии ниже 1.5.0, где автоматического обновления при запуске ещё нет, используйте ручную загрузку с проверкой SHA-256 из файла `КОМАНДЫ-3XUI.txt`. После этого будущие версии будут подгружаться автоматически при запуске `sudo 3xui-installer`.

После ответов мастера установка по умолчанию работает в тихом режиме: в терминале показывается только процент, а подробности записываются в `/root/3x-ui-bootstrap/install.log`. После 100% выводятся данные входа и итог проверок. Для полного вывода используйте `QUIET_INSTALL=false`.

Конфигурация управляющей команды хранится root-only в `/etc/3xui-installer`, а результаты и секреты — в `/root/3x-ui-bootstrap`.

После успешной установки также создаётся автономная страница `/root/3x-ui-bootstrap/dashboard.html` с URL панели, логином, паролем, API-ключом, подписками, прямыми ссылками и инструкцией. Файл имеет режим `600`, не использует внешние шрифты, скрипты или аналитику и не публикуется в интернете. Для просмотра с рабочего компьютера выполните на сервере:

```bash
sudo dns web
```

Затем создайте SSH-туннель командой, которую выведет скрипт, и откройте `http://127.0.0.1:8765/`. На сервере с графической средой установщик дополнительно пытается открыть локальный HTML автоматически; на обычном headless VPS нужен SSH-туннель.

С явно выбранной REALITY-целью:

```bash
sudo XUI_REALITY_DEST=example.com:443 \
  XUI_REALITY_SNI=example.com \
  bash install-3xui-full.sh
```

Пользовательская цель принимается только после live-проверки штатным API панели. Для автоматического выбора проверяется пул целей.

## Что создаётся

Создаются ровно пять управляемых профилей:

1. `AUTO-RU-01-VLESS-REALITY-VISION` — VLESS + REALITY + XTLS Vision поверх TCP/RAW.
2. `AUTO-RU-02-VLESS-XHTTP-TLS` — VLESS + XHTTP + trusted TLS-сертификат.
3. `AUTO-RU-03-TROJAN-TLS` — Trojan + TLS поверх TCP/RAW.
4. `AUTO-RU-04-SHADOWSOCKS` — Shadowsocks 2022 с AEAD-2022.
5. `AUTO-RU-05-HYSTERIA2` — Hysteria2 поверх UDP/QUIC.

XHTTP использует минимальные поля `path`, `host`, `mode`; остальное оставлено актуальным upstream defaults. Обычный mux поверх XHTTP не включается. Старые управляемые профили предыдущих версий удаляются командой `recreate-inbounds` после подтверждения; `add-inbounds` добавляет недостающие пять профилей и сохраняет существующие inbound’ы.

При `REGION_PROFILE=GENERIC` основные имена получают `AUTO-GENERIC-*`. Скрипт не создаёт публичные HTTP/SOCKS proxy, не меняет SSH, маршруты, интерфейсы или gateway и не создаёт TUN/dokodemo-door.

`XUI_INBOUND_NAME` меняет общий префикс имён. В режиме `full` значение `Москва` создаст `Москва-RU-01-VLESS-REALITY-VISION`. В режиме `number` примечания будут короткими и последовательными: `Москва #1` … `Москва #5`. Все новые inbound получают независимые случайные свободные порты из широкого диапазона `XUI_PORT_START..XUI_PORT_END`; повторный запуск сохраняет имена и порты уже существующих профилей.

## TLS и отсутствие домена

Без домена официальный установщик выпускает короткоживущий сертификат Let's Encrypt для публичного IPv4 (примерно 6 дней) и включает автоматическое продление через `acme.sh`. TCP-порт 80 должен оставаться доступным снаружи. Этот сертификат назначается панели и серверу подписок, поэтому ссылки выдаются по HTTPS. Если trusted TLS-сертификат недоступен, XHTTP+TLS и Trojan+TLS пропускаются, а REALITY Vision, Shadowsocks и Hysteria2 продолжают создаваться; для Hysteria2 используется отдельный self-signed transport-сертификат с pin/`allowInsecure`.

При `XUI_DOMAIN` скрипт сверяет DNS с публичным адресом VPS и использует только реально доступный сертификат панели. Если trusted-сертификат не получен, VLESS XHTTP TLS и Trojan TLS помечаются `SKIPPED — TRUSTED CERTIFICATE UNAVAILABLE`.

## ENV-параметры

Все флаги принимают `true/false`, `1/0`, `yes/no`, `on/off`.

| Параметр | По умолчанию | Назначение |
|---|---:|---|
| `REGION_PROFILE` | `RU` | `RU` или `GENERIC` |
| `XUI_DOMAIN` | пусто | Домен панели/TLS-профилей |
| `XUI_VERSION` | latest stable | Фиксированный тег вида `v3.8.5` |
| `XUI_USERNAME`, `XUI_PASSWORD` | случайные | Учётные данные панели |
| `XUI_PANEL_PORT` | случайный | Порт панели, `1024–65535` |
| `XUI_WEB_BASE_PATH` | случайный | Скрытый URL-путь панели |
| `XUI_INBOUND_NAME` | `AUTO` | Общий префикс названий инбаундов, до 48 символов |
| `XUI_INBOUND_REMARK_MODE` | `full` | `full` — полное техническое примечание; `number` — последовательные `Имя #1`, `Имя #2`, … |
| `XUI_DB_TYPE` | `sqlite` | `sqlite` или `postgres` |
| `XUI_DB_DSN` | пусто | DSN существующего PostgreSQL; без него PostgreSQL ставится локально |
| `XUI_ACME_EMAIL` | пусто | Email аккаунта Let's Encrypt |
| `XUI_ACME_HTTP_PORT` | `80` | Локальный порт ACME HTTP-01 для доменного/IP-сертификата; внешний порт 80 должен вести на него |
| `XUI_ENABLE_FAIL2BAN` | `true` | Настроить Fail2ban для функции IP Limit |
| `XUI_PORT_START`, `XUI_PORT_END` | `10000`, `65535` | Максимально широкий допустимый диапазон независимых случайных свободных портов инбаундов |
| `XUI_REALITY_DEST`, `XUI_REALITY_SNI` | пусто | Совместный override REALITY-цели |
| `ENABLE_BBR` | `true` | Включить BBR, только если ядро его предлагает |
| `INSTALLER_NONINTERACTIVE` | `auto` | `auto`, `true` или `false`; управляет мастером установки |
| `QUIET_INSTALL` | `true` | Показывать во время установки только процент; полный вывод остаётся в `install.log` |
| `DASHBOARD_PORT` | `8765` | Локальный порт приватной веб-страницы; слушает только `127.0.0.1` |

Набор из пяти профилей фиксирован. Если один профиль не прошёл проверку или требует недоступный trusted-сертификат, установщик завершится кодом `2`.

## Проверки и rollback

Для каждого нового inbound проверяются:

- HTTP status, валидность JSON и `success` ответа API;
- состояние Xray после изменения;
- прослушивание правильного TCP/UDP-порта;
- для VLESS XHTTP TLS, VLESS REALITY Vision и Hysteria2 — временный локальный Xray client, SOCKS и внешний HTTP-запрос;
- удаление только что созданного inbound, если он сломал конфигурацию или не прошёл end-to-end.

Для Shadowsocks и Trojan локальный универсальный Xray E2E-клиент не запускается; проверяются API, конфигурация Xray и прослушивание порта. Проверка из российской сети всегда остаётся `NOT VERIFIED`.

До изменений создаётся backup базы и снимок inbound. UDP buffers повышаются только если меньше 16 MiB. BBR включается только при наличии в ядре и проверяется после применения. Активный UFW/firewalld/nftables дополняется точечными правилами; firewall не включается и не сбрасывается автоматически.

## Результаты

Каталог `/root/3x-ui-bootstrap` имеет режим `700`, файлы с секретами — `600`:

- `result.env` — панель, API token, основные ссылки;
- `current-access.txt` — актуальные URL, логин, пароль, API-ключ и подписка;
- `dashboard.html` — автономная локальная карточка сервера с кнопками копирования и инструкцией;
- `access-after-panel-update.txt` — тот же доступ после выполнения `panel-update`;
- `summary.txt` — PASS/FAILED/SKIPPED и разделение server/RU test;
- `links.txt`, `xhttp-links.txt`, `subscriptions.txt`;
- `amneziawg-client.conf`, если link удалось декодировать;
- `inbounds.json`, `failed-inbounds.json`;
- `client-compatibility.txt`, `russia-diagnostics.txt`;
- `install.log`, `backups/`, `certs/`.

Повторный запуск находит свои inbound по точному `remark`, добавляет отсутствующие и не удаляет пользовательские объекты. Стабильные `subId`/client email сохраняются в `state.env`.

Для старой существующей установки без `/etc/x-ui/install-result.env` сначала сохраняется аварийный backup и запускается официальный upgrade/repair. Если plaintext-пароль всё равно невозможно восстановить, скрипт намеренно ротирует panel login и отдельный API token, записывает новые данные в root-only env и сообщает об этом в журнале и терминале.

## Публикация и обновления

Актуальная инструкция размещена на [GitHub Pages](https://thefuckerguy.github.io/3xui-installer/). Файлы установщика и контрольные суммы публикуются как assets последнего [GitHub Release](https://github.com/thefuckerguy/3xui-installer/releases/latest). `check-update` и `update` скачивают `VERSION`, скрипт и `.sha256` из одного опубликованного релиза. Выпуск нового релиза запускается тегом `vX.Y.Z`: workflow проверяет синтаксис, контрольные суммы и соответствие тега `VERSION`, затем создаёт релиз один раз. Для репозитория включена неизменяемость релизов.

Для локального зеркала на собственном distribution-сервере:

На distribution-сервере:

```bash
sudo PUBLISH_ROOT=/var/www/3xui-installer \
  PUBLISH_BASE_URL=https://install.example.com \
  bash publish-installer.sh
```

Скрипт выполняет `bash -n`, запускает ShellCheck при наличии, считает SHA-256, защищает versioned release от тихой перезаписи и атомарно обновляет latest. Он не меняет конфигурацию существующего nginx/Caddy/Apache.

Безопасная загрузка:

```bash
curl -fsSLO https://install.example.com/install-3xui-full.sh
curl -fsSLO https://install.example.com/install-3xui-full.sh.sha256
sha256sum -c install-3xui-full.sh.sha256
sudo bash install-3xui-full.sh
```

При ошибке checksum файл запускать нельзя.

Минимальный nginx `location`, если virtual host уже создан администратором:

```nginx
location / {
    alias /var/www/3xui-installer/;
    autoindex off;
    default_type application/octet-stream;
}
```

## Матрица испытаний

Перед публикацией локально выполняются syntax и static checks. Полная acceptance-матрица требует отдельных VPS: Ubuntu 22.04/24.04, Debian 12; IPv4 и dual-stack; fresh/existing 3X-UI; UFW/firewalld/nftables; занятый/свободный 443; domain/no-domain; API/Xray failure и второй запуск. Без выполнения этой инфраструктурной матрицы нельзя утверждать, что конкретный provider/kernel/firewall прошёл acceptance.

На целевом VPS после выполнения полезно проверить:

```bash
sudo systemctl status x-ui --no-pager
sudo cat /root/3x-ui-bootstrap/summary.txt
sudo cat /root/3x-ui-bootstrap/failed-inbounds.json
```

## Источники совместимости

Реализация сверена с актуальными исходниками проекта: [3X-UI](https://github.com/MHSanaei/3x-ui), [релиз v3.8.5](https://github.com/MHSanaei/3x-ui/releases/tag/v3.8.5), [официальный install.sh](https://github.com/MHSanaei/3x-ui/blob/v3.8.5/install.sh), [OpenAPI v3.8.5](https://github.com/MHSanaei/3x-ui/blob/v3.8.5/docs/public/openapi.json), [Xray-core v26.9.9](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9), [официальная установка Remnawave Node](https://docs.rw/install/remnawave-node/), [Remnawave OpenAPI](https://docs.rw/api/), [официальные Remnawave templates](https://github.com/remnawave/templates) и учебная SelfSteal/reverse-proxy реализация [eGamesAPI/remnawave-reverse-proxy](https://github.com/eGamesAPI/remnawave-reverse-proxy). Итоговый `client-compatibility.txt` намеренно использует `VERSION DEPENDENT`/`LIMITED`, когда один и тот же UI может работать с разными core или терять поля при импорте.
