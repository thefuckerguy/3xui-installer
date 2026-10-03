#!/usr/bin/env bash
# 3X-UI Universal RU Installer
# Upstream compatibility baseline: 3x-ui v3.8.5 / Xray-core v26.9.9.
# The live panel OpenAPI document is queried before any inbound is created.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly INSTALLER_VERSION="2.1.0"
readonly RESULT_DIR="/root/3x-ui-bootstrap"
readonly STATE_FILE="${RESULT_DIR}/state.env"
readonly LOG_FILE="${RESULT_DIR}/install.log"
readonly FAILED_FILE="${RESULT_DIR}/failed-inbounds.json"
readonly INSTALL_RESULT="/etc/x-ui/install-result.env"
readonly OFFICIAL_REPO="MHSanaei/3x-ui"
readonly OFFICIAL_INSTALLER="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
readonly MANAGER_PATH="/usr/local/sbin/3xui-installer"
readonly DNS_COMMAND_PATH="/usr/local/sbin/dns"
readonly MANAGER_CONFIG_DIR="/etc/3xui-installer"
readonly MANAGER_CONFIG="${MANAGER_CONFIG_DIR}/config.env"
readonly FIREWALL_STATE="${MANAGER_CONFIG_DIR}/firewall.env"
readonly SELF_UPDATE_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/install-3xui-full.sh"
readonly SELF_UPDATE_CHECKSUM_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/install-3xui-full.sh.sha256"
readonly SELF_UPDATE_VERSION_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/VERSION"
readonly DASHBOARD_FILE="${RESULT_DIR}/dashboard.html"
readonly REMNAWAVE_INSTALLED_PATH="/usr/local/lib/3xui-installer/remnawave-manager.sh"
readonly REMNAWAVE_DOWNLOAD_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/remnawave-manager.sh"
readonly REMNAWAVE_CHECKSUM_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/remnawave-manager.sh.sha256"

REGION_PROFILE="${REGION_PROFILE:-RU}"
XUI_DOMAIN="${XUI_DOMAIN:-}"
RECREATE_INBOUND_NAME_OVERRIDE="${XUI_INBOUND_NAME:-}"
RECREATE_REMARK_MODE_OVERRIDE="${XUI_INBOUND_REMARK_MODE:-}"
XUI_INBOUND_NAME="${XUI_INBOUND_NAME:-AUTO}"
XUI_INBOUND_REMARK_MODE="${XUI_INBOUND_REMARK_MODE:-full}"
XUI_PORT_START="${XUI_PORT_START:-10000}"
XUI_PORT_END="${XUI_PORT_END:-65535}"
XUI_REALITY_DEST="${XUI_REALITY_DEST:-}"
XUI_REALITY_SNI="${XUI_REALITY_SNI:-}"
XUI_VERSION="${XUI_VERSION:-}"
XUI_USERNAME="${XUI_USERNAME:-}"
XUI_PASSWORD="${XUI_PASSWORD:-}"
XUI_PANEL_PORT="${XUI_PANEL_PORT:-}"
XUI_WEB_BASE_PATH="${XUI_WEB_BASE_PATH:-}"
XUI_DB_TYPE="${XUI_DB_TYPE:-sqlite}"
XUI_DB_DSN="${XUI_DB_DSN:-}"
XUI_ACME_EMAIL="${XUI_ACME_EMAIL:-}"
XUI_ACME_HTTP_PORT="${XUI_ACME_HTTP_PORT:-80}"
XUI_ENABLE_FAIL2BAN="${XUI_ENABLE_FAIL2BAN:-true}"

ENABLE_BBR="${ENABLE_BBR:-true}"
INSTALLER_NONINTERACTIVE="${INSTALLER_NONINTERACTIVE:-auto}"
INTERACTIVE_MODE="false"
ACTION="install"
FORCE_REINSTALL="false"
CLEAN_REINSTALL_PENDING="false"
PANEL_UPDATE="false"
INBOUNDS_ONLY="false"
RECREATE_INBOUNDS="false"
RECREATE_OLD_INBOUND_NAME=""
RECREATE_OLD_REMARK_MODE=""
RECREATE_OLD_REGION_PROFILE=""
QUIET_INSTALL="${QUIET_INSTALL:-true}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8765}"
QUIET_ACTIVE="false"
MANAGER_UPDATED="false"

OS_ID=""
OS_VERSION=""
ARCH=""
PUBLIC_IPV4=""
PUBLIC_IPV6=""
PUBLIC_HOST=""
SHARE_HOST=""
PANEL_BASE_URL=""
API_BASE_URL=""
PANEL_VERSION=""
XRAY_VERSION=""
OPENAPI_JSON=""
PROTOCOL_ENUM=""
REALITY_DEST=""
REALITY_SNI=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
TLS_CERT_FILE=""
TLS_KEY_FILE=""
TLS_TRUSTED="false"
SELF_CERT_FILE=""
SELF_KEY_FILE=""
SELF_CERT_PIN=""
SUB_ID=""
SUB_EMAIL_PREFIX=""
SUB_PORT=""
SUB_PATH=""
SUB_JSON_PATH=""
SUB_CLASH_PATH=""
SUBSCRIPTION_URL=""
SUBSCRIPTION_JSON_URL=""
SUBSCRIPTION_CLASH_URL=""
XRAY_BIN=""
RESERVED_PORTS=""
FIREWALL_PORTS=""
CREATED_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
RUN_BACKUP_DIR=""
FIREWALL_KIND="none"
NFT_FAMILY=""
NFT_TABLE=""
NFT_CHAIN=""
CURRENT_REMARK="bootstrap"
CURRENT_CREATED_NEW="false"
declare -a RESULT_ROWS=()
declare -a OWNED_IDS=()
declare -a OWNED_EMAILS=()

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log_line() {
    local level="$1"; shift
    local line="[$level] $*"
    if [[ "$QUIET_ACTIVE" == "true" ]]; then
        printf '%s %s\n' "$(timestamp)" "$line"
    else
        printf '%s\n' "$line"
    fi
    if [[ "$QUIET_ACTIVE" != "true" && -d "$RESULT_DIR" ]]; then
        printf '%s %s\n' "$(timestamp)" "$line" >> "$LOG_FILE"
    fi
}

info() { log_line INFO "$@"; }
ok()   { log_line OK "$@"; }
pass() { log_line PASS "$@"; }
warn() { log_line WARN "$@"; }
error(){ log_line ERROR "$@"; }
skip() { log_line SKIP "$@"; }

die() {
    error "$*"
    if [[ "$QUIET_ACTIVE" == "true" ]]; then
        restore_console_output
        printf '\nERROR: %s\nПодробности: %s\n' "$*" "$LOG_FILE" >&2
    fi
    exit 1
}

on_error() {
    local rc="$1" line="$2"
    error "Unexpected failure at line ${line} (exit ${rc}); last profile: ${CURRENT_REMARK}"
    if [[ "$QUIET_ACTIVE" == "true" ]]; then
        restore_console_output
        printf '\nERROR: установка прервана на строке %s (код %s).\nПодробности: %s\n' "$line" "$rc" "$LOG_FILE" >&2
    fi
}

setup_quiet_output() {
    is_true "$QUIET_INSTALL" || return 0
    exec 3>&1 4>&2
    exec >> "$LOG_FILE" 2>&1
    QUIET_ACTIVE="true"
}

show_progress() {
    local percent="$1"
    [[ "$QUIET_ACTIVE" == "true" ]] || return 0
    printf '\rУстановка: %3d%%' "$percent" >&3
    (( percent < 100 )) || printf '\n' >&3
}

restore_console_output() {
    [[ "$QUIET_ACTIVE" == "true" ]] || return 0
    exec 1>&3 2>&4
    exec 3>&- 4>&-
    QUIET_ACTIVE="false"
}

cleanup() {
    [[ -n "${OPENAPI_JSON:-}" && -f "$OPENAPI_JSON" ]] && rm -f -- "$OPENAPI_JSON"
    return 0
}

trap 'on_error $? $LINENO' ERR
trap cleanup EXIT

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

is_false() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        0|false|no|off) return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    cat <<'EOF'
3X-UI Universal RU Installer

Usage:
  sudo bash install-3xui-full.sh [command] [--interactive|--non-interactive]
  sudo bash install-3xui-full.sh --product remnawave [command]
  sudo 3xui-installer [command]
  sudo dns [command]

Commands:
  --manage, menu      Open the management menu.
  install             Open the installation wizard.
  settings            Show panel credentials, URLs, versions, and service state.
  panel-update        Update 3X-UI while preserving its database and clients.
  add-inbounds        Add missing managed inbounds without deleting existing clients/inbounds.
  recreate-inbounds   Back up, delete, and recreate installer-managed inbounds.
  web                 Serve the private local dashboard on 127.0.0.1.
  repair              Repair/finish provisioning without reinstalling the panel.
  reinstall           Reinstall panel binaries while preserving the database/settings.
  reinstall-clean     Delete the database/settings and perform a fresh installation.
  check-update        Check whether a newer installer/manager is available.
  update              Verify and install the latest manager script.
  uninstall           Completely remove 3X-UI and installer-owned configuration.

Options for install/repair/recreate-inbounds:
  --product PRODUCT   Select 3x-ui or remnawave. Without arguments, a TTY menu asks.
  --interactive      Require and show the installation wizard.
  --non-interactive  Do not ask questions; use environment variables/defaults.
  -h, --help         Show this help.

By default the wizard is shown when a controlling terminal is available.
EOF
}

parse_args() {
    if (( $# == 0 )); then
        ACTION="manage"
        return 0
    fi
    while (( $# > 0 )); do
        case "$1" in
            --interactive) INSTALLER_NONINTERACTIVE="false" ;;
            --non-interactive) INSTALLER_NONINTERACTIVE="true" ;;
            --manage|menu) ACTION="manage" ;;
            --install|install) ACTION="install" ;;
            --show-settings|settings|show) ACTION="settings" ;;
            --panel-update|panel-update|update-panel) ACTION="panel-update" ;;
            --add-inbounds|add-inbounds|inbounds) ACTION="add-inbounds" ;;
            --recreate-inbounds|recreate-inbounds|reset-inbounds) ACTION="recreate-inbounds" ;;
            --web|web|dashboard) ACTION="web" ;;
            --repair|repair) ACTION="repair" ;;
            --reinstall|reinstall) ACTION="reinstall" ;;
            --reinstall-clean|reinstall-clean|clean-reinstall|reset) ACTION="reinstall-clean" ;;
            --check-update|check-update) ACTION="check-update" ;;
            --update|update|self-update) ACTION="update" ;;
            --uninstall|uninstall|remove) ACTION="uninstall" ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1 (use --help)" ;;
        esac
        shift
    done
}

tty_available() {
    [[ -c /dev/tty ]] && (: </dev/tty) 2>/dev/null
}

select_interactive_mode() {
    if is_true "$INSTALLER_NONINTERACTIVE"; then
        INTERACTIVE_MODE="false"
    elif is_false "$INSTALLER_NONINTERACTIVE"; then
        tty_available || die "Interactive mode requires a terminal; use --non-interactive for cloud-init/CI"
        INTERACTIVE_MODE="true"
    elif [[ "$(printf '%s' "$INSTALLER_NONINTERACTIVE" | tr '[:upper:]' '[:lower:]')" == "auto" ]]; then
        if tty_available; then INTERACTIVE_MODE="true"; else INTERACTIVE_MODE="false"; fi
    else
        die "INSTALLER_NONINTERACTIVE must be auto, true, or false"
    fi
}

prompt_line() {
    local __var="$1" prompt="$2" default="${3:-}" value=""
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
    else
        printf '%s: ' "$prompt" > /dev/tty
    fi
    IFS= read -r value < /dev/tty || die "Input was interrupted"
    [[ -n "$value" ]] || value="$default"
    printf -v "$__var" '%s' "$value"
}

prompt_secret() {
    local __var="$1" prompt="$2" value="" tty_state
    printf '%s: ' "$prompt" > /dev/tty
    tty_state="$(stty -g < /dev/tty)" || die "Cannot read terminal settings"
    stty -echo < /dev/tty
    if ! IFS= read -r value < /dev/tty; then
        stty "$tty_state" < /dev/tty || true
        die "Input was interrupted"
    fi
    stty "$tty_state" < /dev/tty || true
    printf '\n' > /dev/tty
    printf -v "$__var" '%s' "$value"
}

prompt_yes_no() {
    local __var="$1" prompt="$2" default="$3" input_value normalized
    while true; do
        if [[ "$default" == "yes" ]]; then
            printf '%s [Y/n]: ' "$prompt" > /dev/tty
        else
            printf '%s [y/N]: ' "$prompt" > /dev/tty
        fi
        IFS= read -r input_value < /dev/tty || die "Input was interrupted"
        normalized="$(printf '%s' "$input_value" | tr '[:upper:]' '[:lower:]')"
        [[ -n "$normalized" ]] || normalized="$default"
        case "$normalized" in
            y|yes|д|да) printf -v "$__var" '%s' "true"; return 0 ;;
            n|no|н|нет) printf -v "$__var" '%s' "false"; return 0 ;;
            *) printf 'Введите y/да или n/нет.\n' > /dev/tty ;;
        esac
    done
}

valid_domain_name() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,}|xn--[A-Za-z0-9-]{2,})$ ]]
}

valid_inbound_name() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 48 ]] || return 1
    [[ "$value" != ' '* && "$value" != *' ' ]] || return 1
    [[ "$value" != *'|'* && "$value" != *'['* && "$value" != *']'* ]] || return 1
    if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
    return 0
}

interactive_inbound_naming() {
    local inbound_name remark_choice example_suffix
    while true; do
        prompt_line inbound_name "Базовое название инбаундов" "$XUI_INBOUND_NAME"
        if valid_inbound_name "$inbound_name"; then
            XUI_INBOUND_NAME="$inbound_name"
            break
        fi
        printf 'Введите 1–48 символов без пробелов по краям и без [, ], |.\n' > /dev/tty
    done

    printf '\nФормат примечания инбаунда:\n' > /dev/tty
    printf '  1) Полный: %s-RU-01-VLESS-REALITY-VISION\n' "$XUI_INBOUND_NAME" > /dev/tty
    printf '  2) Короткий порядковый номер: %s #1, %s #2, %s #3 ...\n' \
        "$XUI_INBOUND_NAME" "$XUI_INBOUND_NAME" "$XUI_INBOUND_NAME" > /dev/tty
    while true; do
        [[ "$XUI_INBOUND_REMARK_MODE" == "number" ]] && remark_choice="2" || remark_choice="1"
        prompt_line remark_choice "Выбор" "$remark_choice"
        case "$remark_choice" in
            1) XUI_INBOUND_REMARK_MODE="full"; break ;;
            2) XUI_INBOUND_REMARK_MODE="number"; break ;;
            *) printf 'Введите 1 или 2.\n' > /dev/tty ;;
        esac
    done

    example_suffix="RU-01-VLESS-REALITY-VISION"
    printf 'Пример итогового примечания: %s\n' "$(inbound_remark "$example_suffix")" > /dev/tty
}

interactive_add_inbounds_configuration() {
    [[ "$INTERACTIVE_MODE" == "true" ]] || return 0
    local proceed
    printf '\n============================================================\n' > /dev/tty
    printf '       ДОБАВЛЕНИЕ ИНБАУНДОВ В АКТИВНУЮ 3X-UI\n' > /dev/tty
    printf '============================================================\n' > /dev/tty
    printf 'Существующие инбаунды и клиенты удаляться или изменяться не будут.\n' > /dev/tty
    interactive_inbound_naming
    prompt_yes_no proceed "Создать только отсутствующие инбаунды с выбранными именами?" "yes"
    [[ "$proceed" == "true" ]] || { info "Inbound creation cancelled"; exit 0; }
    printf '\n' > /dev/tty
}

confirm_recreate_inbounds() {
    local confirmation="${CONFIRM_RECREATE_INBOUNDS:-}"
    if tty_available && ! is_true "$INSTALLER_NONINTERACTIVE"; then
        printf 'Будут удалены и заново созданы только инбаунды, управляемые этим установщиком.\n' > /dev/tty
        printf 'Их порты, клиенты и ссылки изменятся. Пользовательские инбаунды не затрагиваются.\n' > /dev/tty
        printf 'Перед удалением будет создана резервная копия базы и списка инбаундов.\n' > /dev/tty
        prompt_line confirmation "Для продолжения введите RECREATE INBOUNDS" ""
    fi
    [[ "$confirmation" == "RECREATE INBOUNDS" || "$confirmation" == "RECREATE_INBOUNDS" ]] || \
        die "Inbound recreation cancelled; confirmation RECREATE INBOUNDS was not provided"
}

interactive_configuration() {
    [[ "$INTERACTIVE_MODE" == "true" ]] || {
        info "Non-interactive mode: environment variables and safe defaults will be used"
        return 0
    }

    local use_domain domain_default panel_user panel_password password_confirm panel_port web_path
    local db_choice pg_mode acme_port fail2ban_choice bbr_choice proceed
    domain_default="no"
    [[ -n "$XUI_DOMAIN" ]] && domain_default="yes"

    printf '\n============================================================\n' > /dev/tty
    printf '          МАСТЕР УСТАНОВКИ 3X-UI\n' > /dev/tty
    printf '============================================================\n' > /dev/tty
    printf 'Enter принимает значение по умолчанию.\n\n' > /dev/tty

    prompt_yes_no use_domain "Устанавливать с доменом и Let's Encrypt?" "$domain_default"
    if [[ "$use_domain" == "true" ]]; then
        while true; do
            prompt_line XUI_DOMAIN "Домен (A/AAAA уже должен указывать на этот сервер)" "$XUI_DOMAIN"
            XUI_DOMAIN="$(printf '%s' "$XUI_DOMAIN" | tr '[:upper:]' '[:lower:]')"
            valid_domain_name "$XUI_DOMAIN" && break
            printf 'Некорректный домен. Пример: vpn.example.com\n' > /dev/tty
        done
    else
        XUI_DOMAIN=""
        printf 'Для публичного IPv4 будет выпущен короткоживущий сертификат Let\x27s Encrypt с автопродлением.\n' > /dev/tty
        printf 'Внешний TCP-порт 80 должен быть доступен для проверки и продления сертификата.\n' > /dev/tty
    fi

    prompt_line XUI_ACME_EMAIL "Email для уведомлений Let's Encrypt (необязательно)" "$XUI_ACME_EMAIL"
    while true; do
        prompt_line acme_port "Порт локальной проверки ACME HTTP-01" "$XUI_ACME_HTTP_PORT"
        if [[ "$acme_port" =~ ^[0-9]+$ ]] && (( acme_port >= 1 && acme_port <= 65535 )); then
            XUI_ACME_HTTP_PORT="$acme_port"
            break
        fi
        printf 'Введите порт от 1 до 65535.\n' > /dev/tty
    done

    while true; do
        prompt_line panel_user "Логин панели (пусто = сгенерировать автоматически)" "$XUI_USERNAME"
        if [[ -z "$panel_user" || "$panel_user" =~ ^[A-Za-z0-9._@-]{3,64}$ ]]; then
            XUI_USERNAME="$panel_user"
            break
        fi
        printf 'Допустимы 3–64 символа: латиница, цифры, ., _, @ и -.\n' > /dev/tty
    done

    while true; do
        prompt_secret panel_password "Пароль панели (пусто = сгенерировать автоматически)"
        if [[ -z "$panel_password" ]]; then break; fi
        if (( ${#panel_password} < 8 )); then
            printf 'Пароль должен содержать минимум 8 символов.\n' > /dev/tty
            continue
        fi
        prompt_secret password_confirm "Повторите пароль"
        if [[ "$panel_password" == "$password_confirm" ]]; then
            XUI_PASSWORD="$panel_password"
            break
        fi
        printf 'Пароли не совпадают. Повторите ввод.\n' > /dev/tty
    done

    while true; do
        prompt_line panel_port "Порт панели (пусто = случайный)" "$XUI_PANEL_PORT"
        if [[ -z "$panel_port" ]] || { [[ "$panel_port" =~ ^[0-9]+$ ]] && (( panel_port >= 1024 && panel_port <= 65535 )); }; then
            XUI_PANEL_PORT="$panel_port"
            break
        fi
        printf 'Введите порт от 1024 до 65535 либо оставьте поле пустым.\n' > /dev/tty
    done

    while true; do
        prompt_line web_path "WebBasePath панели без / (пусто = сгенерировать)" "$XUI_WEB_BASE_PATH"
        web_path="${web_path#/}"; web_path="${web_path%/}"
        if [[ -z "$web_path" || "$web_path" =~ ^[A-Za-z0-9_-]{4,64}$ ]]; then
            XUI_WEB_BASE_PATH="$web_path"
            break
        fi
        printf 'Допустимы 4–64 символа: латиница, цифры, _ и -.\n' > /dev/tty
    done

    interactive_inbound_naming

    printf '\nБаза данных:\n  1) SQLite (рекомендуется для обычной установки)\n  2) PostgreSQL\n' > /dev/tty
    while true; do
        [[ "$XUI_DB_TYPE" == "postgres" ]] && db_choice="2" || db_choice="1"
        prompt_line db_choice "Выбор" "$db_choice"
        case "$db_choice" in
            1) XUI_DB_TYPE="sqlite"; XUI_DB_DSN=""; break ;;
            2)
                XUI_DB_TYPE="postgres"
                printf '  1) Установить PostgreSQL локально\n  2) Использовать существующий сервер\n' > /dev/tty
                prompt_line pg_mode "Выбор" "1"
                if [[ "$pg_mode" == "2" ]]; then
                    while [[ -z "$XUI_DB_DSN" ]]; do
                        prompt_secret XUI_DB_DSN "PostgreSQL DSN"
                    done
                else
                    XUI_DB_DSN=""
                fi
                break
                ;;
            *) printf 'Введите 1 или 2.\n' > /dev/tty ;;
        esac
    done

    prompt_yes_no fail2ban_choice "Установить и настроить Fail2ban для IP Limit?" "yes"
    XUI_ENABLE_FAIL2BAN="$fail2ban_choice"
    if is_true "$ENABLE_BBR"; then bbr_choice="yes"; else bbr_choice="no"; fi
    prompt_yes_no ENABLE_BBR "Включить BBR, если его поддерживает ядро?" "$bbr_choice"

    printf '\n------------------- ПАРАМЕТРЫ -------------------\n' > /dev/tty
    if [[ -n "$XUI_DOMAIN" ]]; then
        printf 'Режим:       домен %s + Let\x27s Encrypt\n' "$XUI_DOMAIN" > /dev/tty
    else
        printf 'Режим:       IP-сертификат Let\x27s Encrypt + автопродление\n' > /dev/tty
    fi
    printf 'Логин:       %s\n' "${XUI_USERNAME:-автоматический}" > /dev/tty
    if [[ -n "$XUI_PASSWORD" ]]; then
        printf 'Пароль:      задан пользователем\n' > /dev/tty
    else
        printf 'Пароль:      автоматический\n' > /dev/tty
    fi
    printf 'Порт панели: %s\n' "${XUI_PANEL_PORT:-случайный}" > /dev/tty
    printf 'WebBasePath: %s\n' "${XUI_WEB_BASE_PATH:-автоматический}" > /dev/tty
    printf 'Инбаунды:    %s + ещё 4 профиля (случайные порты %s–%s)\n' "$(inbound_remark "RU-01-VLESS-REALITY-VISION")" "$XUI_PORT_START" "$XUI_PORT_END" > /dev/tty
    printf 'База:        %s\n' "$XUI_DB_TYPE" > /dev/tty
    printf 'Fail2ban:    %s\n' "$XUI_ENABLE_FAIL2BAN" > /dev/tty
    printf 'BBR:         %s\n' "$ENABLE_BBR" > /dev/tty
    printf '%s\n' '--------------------------------------------------' > /dev/tty
    prompt_yes_no proceed "Начать установку?" "yes"
    [[ "$proceed" == "true" ]] || { info "Installation cancelled by user"; exit 0; }
    printf '\n' > /dev/tty
}

source_root_env() {
    local file="$1" owner mode
    [[ -r "$file" ]] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null || echo invalid)"
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo invalid)"
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]?[0-7][0-7]$ ]] || return 1
    (( (8#$mode & 022) == 0 )) || return 1
    # shellcheck disable=SC1090
    . "$file"
}

root_env_value() {
    local file="$1" variable="$2" owner mode
    [[ "$variable" =~ ^[A-Z0-9_]+$ && -r "$file" ]] || return 1
    owner="$(stat -c '%u' "$file" 2>/dev/null || echo invalid)"
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo invalid)"
    [[ "$owner" == "0" && "$mode" =~ ^[0-7]?[0-7][0-7]$ ]] || return 1
    (( (8#$mode & 022) == 0 )) || return 1
    bash -c '. "$1"; printf "%s" "${!2-}"' _ "$file" "$variable"
}

valid_installer_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]
}

fetch_latest_installer_version() {
    local latest
    command -v curl >/dev/null 2>&1 || return 1
    latest="$(curl --silent --show-error --fail --location \
        --connect-timeout 5 --max-time 10 "$SELF_UPDATE_VERSION_URL" 2>/dev/null | tr -d '[:space:]')" || return 1
    valid_installer_version "$latest" || return 1
    printf '%s' "$latest"
}

version_is_newer() {
    local current="$1" candidate="$2" highest
    [[ "$current" != "$candidate" ]] || return 1
    highest="$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1)"
    [[ "$highest" == "$candidate" ]]
}

print_update_status() {
    local explicit="${1:-false}" latest=""
    if ! latest="$(fetch_latest_installer_version)"; then
        if [[ "$explicit" == "true" ]]; then
            printf 'Не удалось проверить обновление. Проверьте подключение к %s\n' "$SELF_UPDATE_VERSION_URL" >&2
            return 1
        fi
        return 0
    fi

    if version_is_newer "$INSTALLER_VERSION" "$latest"; then
        printf '\nДоступно обновление установщика: %s -> %s\n' "$INSTALLER_VERSION" "$latest"
        printf 'Установить: sudo 3xui-installer update\n'
    elif [[ "$explicit" == "true" ]]; then
        if [[ "$latest" == "$INSTALLER_VERSION" ]]; then
            printf 'Установщик уже обновлён: версия %s.\n' "$INSTALLER_VERSION"
        else
            printf 'Установленная версия %s новее опубликованной %s.\n' "$INSTALLER_VERSION" "$latest"
        fi
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

install_dns_shortcut() {
    if [[ ! -e "$DNS_COMMAND_PATH" ]] || \
       { [[ -L "$DNS_COMMAND_PATH" ]] && [[ "$(readlink -f "$DNS_COMMAND_PATH" 2>/dev/null || true)" == "$MANAGER_PATH" ]]; }; then
        ln -sfn "$MANAGER_PATH" "$DNS_COMMAND_PATH"
        return 0
    fi
    warn "Команда dns не установлена: ${DNS_COMMAND_PATH} уже занят посторонним файлом"
    return 1
}

update_manager_command() {
    local mode="${1:-manual}" latest="" answer="true" staged_script="" staged_checksum=""
    local expected_hash="" actual_hash="" downloaded_version="" temporary_manager=""

    if ! latest="$(fetch_latest_installer_version)"; then
        if [[ "$mode" == "automatic" ]]; then
            warn "Автоматическая проверка обновления недоступна; продолжаю с версией ${INSTALLER_VERSION}"
            return 0
        fi
        die "Не удалось получить опубликованную версию установщика"
    fi
    if ! version_is_newer "$INSTALLER_VERSION" "$latest"; then
        if [[ "$mode" != "automatic" ]]; then
            if [[ "$latest" == "$INSTALLER_VERSION" ]]; then
                printf 'Установщик уже обновлён: версия %s.\n' "$INSTALLER_VERSION"
            else
                printf 'Установленная версия %s новее опубликованной %s.\n' "$INSTALLER_VERSION" "$latest"
            fi
        fi
        return 0
    fi

    if [[ "$mode" == "automatic" ]]; then
        printf 'Найдена новая версия установщика %s. Выполняется безопасное обновление...\n' "$latest"
    else
        printf 'Доступно обновление установщика: %s -> %s\n' "$INSTALLER_VERSION" "$latest"
    fi
    if [[ "$mode" != "automatic" ]] && tty_available; then
        prompt_yes_no answer "Загрузить и установить обновление?" "yes"
        [[ "$answer" == "true" ]] || { info "Update cancelled"; return 0; }
    fi

    staged_script="$(mktemp /tmp/3xui-installer-update.XXXXXX)"
    staged_checksum="$(mktemp /tmp/3xui-installer-checksum.XXXXXX)"
    if ! curl_common --fail "$SELF_UPDATE_URL" -o "$staged_script" || \
       ! curl_common --fail "$SELF_UPDATE_CHECKSUM_URL" -o "$staged_checksum"; then
        rm -f -- "$staged_script" "$staged_checksum"
        die "Не удалось скачать файлы обновления"
    fi

    expected_hash="$(awk '$2 == "install-3xui-full.sh" {print tolower($1); exit}' "$staged_checksum")"
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || {
        rm -f -- "$staged_script" "$staged_checksum"
        die "Файл контрольной суммы обновления некорректен"
    }
    actual_hash="$(sha256_file "$staged_script")" || {
        rm -f -- "$staged_script" "$staged_checksum"
        die "Для проверки обновления требуется sha256sum или shasum"
    }
    [[ "$actual_hash" == "$expected_hash" ]] || {
        rm -f -- "$staged_script" "$staged_checksum"
        die "SHA-256 обновления не совпадает; файл не установлен"
    }
    bash -n "$staged_script" || {
        rm -f -- "$staged_script" "$staged_checksum"
        die "Скачанное обновление не прошло проверку синтаксиса"
    }
    downloaded_version="$(sed -n 's/^readonly INSTALLER_VERSION="\([^"]*\)"$/\1/p' "$staged_script" | head -n 1)"
    [[ "$downloaded_version" == "$latest" ]] || {
        rm -f -- "$staged_script" "$staged_checksum"
        die "Версия скачанного файла не совпадает с опубликованной"
    }

    install -d -m 755 "$(dirname "$MANAGER_PATH")"
    temporary_manager="${MANAGER_PATH}.new.$$"
    if ! install -m 700 "$staged_script" "$temporary_manager" || \
       ! mv -f -- "$temporary_manager" "$MANAGER_PATH"; then
        rm -f -- "$temporary_manager" "$staged_script" "$staged_checksum"
        die "Не удалось атомарно установить обновление"
    fi
    install_dns_shortcut || true
    rm -f -- "$staged_script" "$staged_checksum"
    MANAGER_UPDATED="true"
    printf 'Установщик обновлён: %s -> %s.\n' "$INSTALLER_VERSION" "$latest"
    if [[ "$mode" != "automatic" ]]; then
        printf 'Повторите нужную команду, например: sudo 3xui-installer settings\n'
    fi
}

running_as_installed_manager() {
    [[ -f "$MANAGER_PATH" ]] || return 1
    [[ "$(readlink -f "${BASH_SOURCE[0]}")" == "$(readlink -f "$MANAGER_PATH")" ]]
}

auto_update_manager_on_start() {
    running_as_installed_manager || return 0
    case "$ACTION" in update|check-update) return 0 ;; esac
    update_manager_command automatic
}

load_manager_config() {
    source_root_env "$MANAGER_CONFIG" || return 0
}

save_manager_config() {
    install -d -m 700 "$MANAGER_CONFIG_DIR"
    {
        printf 'REGION_PROFILE=%q\n' "$REGION_PROFILE"
        printf 'XUI_DOMAIN=%q\n' "$XUI_DOMAIN"
        printf 'XUI_INBOUND_NAME=%q\n' "$XUI_INBOUND_NAME"
        printf 'XUI_INBOUND_REMARK_MODE=%q\n' "$XUI_INBOUND_REMARK_MODE"
        printf 'XUI_PORT_START=%q\n' "$XUI_PORT_START"
        printf 'XUI_PORT_END=%q\n' "$XUI_PORT_END"
        printf 'XUI_VERSION=%q\n' "$XUI_VERSION"
        printf 'XUI_DB_TYPE=%q\n' "${XUI_DB_TYPE:-sqlite}"
        printf 'XUI_ACME_EMAIL=%q\n' "$XUI_ACME_EMAIL"
        printf 'XUI_ACME_HTTP_PORT=%q\n' "$XUI_ACME_HTTP_PORT"
        printf 'XUI_ENABLE_FAIL2BAN=%q\n' "$XUI_ENABLE_FAIL2BAN"
        printf 'ENABLE_BBR=%q\n' "$ENABLE_BBR"
    } > "$MANAGER_CONFIG"
    chmod 600 "$MANAGER_CONFIG"
}

install_manager_command() {
    local source_file="${BASH_SOURCE[0]}" staged="" companion_source=""
    install -d -m 755 "$(dirname "$MANAGER_PATH")"
    if [[ -f "$source_file" ]] && bash -n "$source_file"; then
        if [[ "$(readlink -f "$source_file")" == "$(readlink -f "$MANAGER_PATH" 2>/dev/null || true)" ]]; then
            chmod 700 "$MANAGER_PATH"
        else
            install -m 700 "$source_file" "$MANAGER_PATH"
        fi
    else
        staged="$(mktemp /tmp/3xui-manager.XXXXXX)"
        curl_common --fail "$SELF_UPDATE_URL" -o "$staged"
        bash -n "$staged" || { rm -f -- "$staged"; die "Downloaded manager failed syntax validation"; }
        install -m 700 "$staged" "$MANAGER_PATH"
        rm -f -- "$staged"
    fi
    companion_source="$(dirname -- "$source_file")/remnawave-manager.sh"
    if [[ -f "$companion_source" ]]; then
        bash -n "$companion_source" || die "Remnawave companion failed syntax validation"
        install -d -m 755 "$(dirname -- "$REMNAWAVE_INSTALLED_PATH")"
        install -m 700 "$companion_source" "$REMNAWAVE_INSTALLED_PATH"
        ok "Remnawave companion installed: ${REMNAWAVE_INSTALLED_PATH}"
    fi
    install_dns_shortcut || true
    ok "Management command installed: ${MANAGER_PATH}"
    [[ -L "$DNS_COMMAND_PATH" ]] && ok "Short menu command installed: dns"
}

show_installed_settings() {
    local service_state="not-installed" version="unknown"
    local panel_url="unknown" panel_user="unknown" panel_password="unavailable" api_token="unavailable"
    local subscription="unavailable" result_file="${RESULT_DIR}/result.env"
    local inbound_name="AUTO" inbound_mode="full" port_start="10000" port_end="65535"

    inbound_name="$(root_env_value "$MANAGER_CONFIG" XUI_INBOUND_NAME || true)"
    inbound_mode="$(root_env_value "$MANAGER_CONFIG" XUI_INBOUND_REMARK_MODE || true)"
    port_start="$(root_env_value "$MANAGER_CONFIG" XUI_PORT_START || true)"
    port_end="$(root_env_value "$MANAGER_CONFIG" XUI_PORT_END || true)"
    inbound_name="${inbound_name:-AUTO}"
    inbound_mode="${inbound_mode:-full}"
    port_start="${port_start:-10000}"
    port_end="${port_end:-65535}"

    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        service_state="$(systemctl is-active x-ui 2>/dev/null || true)"
    fi
    if [[ -x /usr/local/x-ui/x-ui ]]; then
        version="$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)"
        version="${version:-installed}"
    fi
    if [[ -r "$result_file" ]]; then
        panel_url="$(root_env_value "$result_file" PANEL_URL || true)"
        panel_user="$(root_env_value "$result_file" PANEL_USERNAME || true)"
        panel_password="$(root_env_value "$result_file" PANEL_PASSWORD || true)"
        api_token="$(root_env_value "$result_file" API_TOKEN || true)"
        subscription="$(root_env_value "$result_file" SUBSCRIPTION_URL || true)"
        panel_url="${panel_url:-unknown}"
        panel_user="${panel_user:-unknown}"
        panel_password="${panel_password:-unavailable}"
        api_token="${api_token:-unavailable}"
        subscription="${subscription:-unavailable}"
    elif source_root_env "$INSTALL_RESULT"; then
        local scheme="http" host
        [[ "${XUI_ACCESS_URL:-}" == https://* ]] && scheme="https"
        host="${XUI_DOMAIN:-${PUBLIC_IPV4:-SERVER_IP}}"
        panel_url="${scheme}://${host}:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}"
        panel_user="${XUI_USERNAME:-unknown}"
        panel_password="${XUI_PASSWORD:-unavailable}"
        api_token="${XUI_API_TOKEN:-unavailable}"
    fi

    printf '============================================================\n'
    printf '3X-UI SETTINGS\n'
    printf '============================================================\n'
    printf 'Service:      %s\n' "$service_state"
    printf 'Version:      %s\n' "$version"
    printf 'Installer:    %s\n' "$INSTALLER_VERSION"
    printf 'Panel URL:    %s\n' "$panel_url"
    printf 'Username:     %s\n' "$panel_user"
    printf 'Password:     %s\n' "$panel_password"
    printf 'API key:      %s\n' "$api_token"
    printf 'Subscription: %s\n' "$subscription"
    if [[ "$inbound_mode" == "number" ]]; then
        printf 'Inbound name: %s #1, %s #2, ...\n' "$inbound_name" "$inbound_name"
    else
        printf 'Inbound name: %s-*\n' "$inbound_name"
    fi
    printf 'Remark mode:  %s\n' "$inbound_mode"
    printf 'Inbound ports: random, %s-%s\n' "$port_start" "$port_end"
    printf '\nFiles:\n'
    printf '  Results:    %s\n' "$RESULT_DIR"
    printf '  Credentials:%s\n' "$INSTALL_RESULT"
    printf '\nCommands:\n'
    printf '  sudo 3xui-installer settings\n'
    printf '  sudo 3xui-installer panel-update\n'
    printf '  sudo 3xui-installer add-inbounds\n'
    printf '  sudo 3xui-installer recreate-inbounds\n'
    printf '  sudo dns web\n'
    printf '  sudo 3xui-installer repair\n'
    printf '  sudo 3xui-installer reinstall\n'
    printf '  sudo 3xui-installer reinstall-clean\n'
    printf '  sudo 3xui-installer check-update\n'
    printf '  sudo 3xui-installer update\n'
    printf '  sudo 3xui-installer uninstall\n'
    print_update_status false
}

confirm_reinstall() {
    local answer
    if tty_available; then
        prompt_yes_no answer "Переустановить файлы 3X-UI с сохранением базы и настроек?" "no"
        [[ "$answer" == "true" ]] || { info "Reinstall cancelled"; exit 0; }
    else
        is_true "${CONFIRM_REINSTALL:-false}" || die "Set CONFIRM_REINSTALL=true for unattended reinstall"
    fi
}

confirm_panel_update() {
    local answer
    if tty_available; then
        printf 'Перед обновлением будет создана резервная копия базы. Клиенты, инбаунды и настройки сохраняются.\n' > /dev/tty
        prompt_yes_no answer "Обновить 3X-UI до последней стабильной версии?" "yes"
        [[ "$answer" == "true" ]] || { info "Panel update cancelled"; exit 0; }
    else
        is_true "${CONFIRM_PANEL_UPDATE:-false}" || die "Set CONFIRM_PANEL_UPDATE=true for unattended panel update"
    fi
}

require_existing_panel() {
    [[ -x /usr/local/x-ui/x-ui ]] || die "3X-UI is not installed; choose menu item 1 first"
}

require_active_panel() {
    require_existing_panel
    systemctl is-active --quiet x-ui 2>/dev/null || die "3X-UI service is not active; run repair first"
}

confirm_clean_reinstall() {
    local confirmation="${CONFIRM_CLEAN_REINSTALL:-}"
    if tty_available; then
        printf 'Будут безвозвратно удалены база 3X-UI, все инбаунды, клиенты и настройки панели.\n' > /dev/tty
        prompt_line confirmation "Для чистой переустановки введите DELETE DATABASE" ""
    fi
    [[ "$confirmation" == "DELETE DATABASE" || "$confirmation" == "DELETE_DATABASE" ]] || \
        die "Clean reinstall cancelled; confirmation DELETE DATABASE was not provided"
}

remove_managed_firewall_rules() {
    local number family table chain handle proto port
    if command -v ufw >/dev/null 2>&1; then
        while true; do
            number="$(ufw status numbered 2>/dev/null | awk '/3xui-bootstrap/ {gsub(/[][]/,"",$1); n=$1} END {print n}')"
            [[ "$number" =~ ^[0-9]+$ ]] || break
            yes | ufw delete "$number" >/dev/null 2>&1 || break
        done
    fi
    if command -v nft >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r family table chain handle; do
            [[ -n "$family" && -n "$table" && -n "$chain" && "$handle" =~ ^[0-9]+$ ]] || continue
            nft delete rule "$family" "$table" "$chain" handle "$handle" >/dev/null 2>&1 || true
        done < <(nft -j -a list ruleset 2>/dev/null | jq -r '.nftables[].rule | select((.comment? // "") | startswith("3xui-bootstrap-")) | [.family,.table,.chain,.handle] | @tsv' 2>/dev/null || true)
    fi
    if source_root_env "$FIREWALL_STATE" && [[ "${FIREWALL_KIND:-}" == "firewalld" ]] && command -v firewall-cmd >/dev/null 2>&1; then
        while IFS=: read -r proto port; do
            [[ -n "$proto" && "$port" =~ ^[0-9]+$ ]] || continue
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        done <<<"${MANAGED_FIREWALL_PORTS:-}"
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

wipe_panel_database() {
    local env_file="" db_type="sqlite" dsn=""
    local candidate
    for candidate in /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; do
        if [[ -r "$candidate" ]]; then env_file="$candidate"; break; fi
    done
    if [[ -n "$env_file" ]]; then
        db_type="$(root_env_value "$env_file" XUI_DB_TYPE || true)"
        db_type="${db_type:-sqlite}"
    fi
    systemctl stop x-ui >/dev/null 2>&1 || true
    if [[ "$db_type" == postgres ]]; then
        dsn="$(root_env_value "$env_file" XUI_DB_DSN || true)"
        [[ -n "$dsn" ]] || die "Cannot erase PostgreSQL safely: XUI_DB_DSN is unavailable"
        command -v psql >/dev/null 2>&1 || die "Cannot erase PostgreSQL safely: psql is not installed"
        PGCONNECT_TIMEOUT=10 psql "$dsn" -v ON_ERROR_STOP=1 \
            -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;' >/dev/null || \
            die "PostgreSQL cleanup failed; installation was not removed"
        ok "PostgreSQL schema erased"
    else
        rm -f -- /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db
        ok "SQLite database erased"
    fi
}

remove_installation_files() {
    local managed_domain=""

    if source_root_env "$MANAGER_CONFIG"; then managed_domain="${XUI_DOMAIN:-}"; fi
    remove_managed_firewall_rules
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    pkill -f '/usr/local/x-ui/x-ui' >/dev/null 2>&1 || true
    pkill -f 'xray-linux-.*-c bin/config.json' >/dev/null 2>&1 || true
    rm -f -- /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service /lib/systemd/system/x-ui.service
    rm -rf -- /usr/local/x-ui /etc/x-ui /var/log/x-ui /root/3x-ui-bootstrap
    rm -f -- /usr/bin/x-ui /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui
    rm -f -- /etc/sysctl.d/99-3xui-bbr.conf /etc/sysctl.d/99-3xui-bootstrap.conf
    rm -f -- /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf
    rm -f -- /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf
    if [[ -n "$managed_domain" ]] && valid_domain_name "$managed_domain"; then
        rm -rf -- "/root/cert/${managed_domain}"
    fi
    rm -rf -- "$MANAGER_CONFIG_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    if [[ -L "$DNS_COMMAND_PATH" ]] && [[ "$(readlink -f "$DNS_COMMAND_PATH" 2>/dev/null || true)" == "$MANAGER_PATH" ]]; then
        rm -f -- "$DNS_COMMAND_PATH"
    fi
    rm -f -- "$MANAGER_PATH"
}

uninstall_completely() {
    local confirmation="${CONFIRM_UNINSTALL:-}"
    if tty_available; then
        printf 'Будут удалены панель, база, профили, ссылки, сервис и созданные правила firewall.\n' > /dev/tty
        prompt_line confirmation "Для полного удаления введите DELETE" ""
    fi
    [[ "$confirmation" == "DELETE" ]] || die "Uninstall cancelled; confirmation DELETE was not provided"
    wipe_panel_database
    remove_installation_files
    printf '3X-UI and installer-owned configuration were completely removed.\n'
}

prepare_clean_reinstall() {
    confirm_clean_reinstall
    load_manager_config
    ACTION="install"
    FORCE_REINSTALL="false"
    CLEAN_REINSTALL_PENDING="true"
}

execute_clean_reinstall() {
    wipe_panel_database
    remove_installation_files
    info "Previous database and installation removed; starting a fresh setup"
}

management_menu() {
    tty_available || die "Management menu requires a terminal"
    local choice default_choice="1"
    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then default_choice="2"; fi
    printf '\n3X-UI INSTALLER — ГЛАВНОЕ МЕНЮ\n' > /dev/tty
    printf 'Версия установщика: %s\n\n' "$INSTALLER_VERSION" > /dev/tty
    printf '  1) Установить или настроить 3X-UI\n' > /dev/tty
    printf '  2) Показать настройки и данные входа\n' > /dev/tty
    printf '  3) Обновить 3X-UI с сохранением клиентов\n' > /dev/tty
    printf '  4) Добавить отсутствующие инбаунды в активную панель\n' > /dev/tty
    printf '  5) Проверить и восстановить установку\n' > /dev/tty
    printf '  6) Переустановить 3X-UI с сохранением базы\n' > /dev/tty
    printf '  7) Переустановить 3X-UI без сохранения базы\n' > /dev/tty
    printf '  8) Проверить и установить обновление скрипта\n' > /dev/tty
    printf '  9) Полностью удалить 3X-UI\n' > /dev/tty
    printf ' 10) Пересоздать управляемые инбаунды в активной панели\n' > /dev/tty
    printf ' 11) Локальная веб-страница с данными и инструкцией\n' > /dev/tty
    printf '  0) Выход\n' > /dev/tty
    prompt_line choice "Выбор" "$default_choice"
    case "$choice" in
        1) ACTION="install" ;;
        2) ACTION="settings" ;;
        3) ACTION="panel-update" ;;
        4) ACTION="add-inbounds" ;;
        5) ACTION="repair" ;;
        6) ACTION="reinstall" ;;
        7) ACTION="reinstall-clean" ;;
        8) ACTION="update" ;;
        9) ACTION="uninstall" ;;
        10) ACTION="recreate-inbounds" ;;
        11) ACTION="web" ;;
        0) exit 0 ;;
        *) die "Unknown menu choice" ;;
    esac
}

require_integer() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be an integer"
}

check_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo bash install-3xui-full.sh"
}

initialize_result_dir() {
    install -d -m 700 "$RESULT_DIR" "$RESULT_DIR/backups" "$RESULT_DIR/certs"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    printf '[]\n' > "$FAILED_FILE"
    chmod 600 "$FAILED_FILE"
}

validate_environment() {
    case "$REGION_PROFILE" in RU|GENERIC) ;; *) die "REGION_PROFILE must be RU or GENERIC" ;; esac
    require_integer XUI_PORT_START "$XUI_PORT_START"
    require_integer XUI_PORT_END "$XUI_PORT_END"
    (( XUI_PORT_START >= 1024 && XUI_PORT_START <= 65535 )) || die "XUI_PORT_START is out of range"
    (( XUI_PORT_END >= XUI_PORT_START && XUI_PORT_END <= 65535 )) || die "XUI_PORT_END is out of range"
    [[ -z "$XUI_DOMAIN" ]] || valid_domain_name "$XUI_DOMAIN" || die "Invalid XUI_DOMAIN"
    valid_inbound_name "$XUI_INBOUND_NAME" || die "XUI_INBOUND_NAME must contain 1-48 safe display characters"
    [[ "$XUI_INBOUND_REMARK_MODE" == "full" || "$XUI_INBOUND_REMARK_MODE" == "number" ]] || \
        die "XUI_INBOUND_REMARK_MODE must be full or number"
    [[ -z "$XUI_USERNAME" || "$XUI_USERNAME" =~ ^[A-Za-z0-9._@-]{3,64}$ ]] || die "XUI_USERNAME must use 3-64 safe characters"
    [[ -z "$XUI_PASSWORD" || ${#XUI_PASSWORD} -ge 8 ]] || die "XUI_PASSWORD must be at least 8 characters"
    if [[ -n "$XUI_PANEL_PORT" ]]; then
        require_integer XUI_PANEL_PORT "$XUI_PANEL_PORT"
        (( XUI_PANEL_PORT >= 1024 && XUI_PANEL_PORT <= 65535 )) || die "XUI_PANEL_PORT is out of range"
    fi
    [[ -z "$XUI_WEB_BASE_PATH" || "$XUI_WEB_BASE_PATH" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || die "Invalid XUI_WEB_BASE_PATH"
    [[ "$XUI_DB_TYPE" == "sqlite" || "$XUI_DB_TYPE" == "postgres" ]] || die "XUI_DB_TYPE must be sqlite or postgres"
    if [[ -n "$XUI_DB_DSN" ]]; then
        [[ "$XUI_DB_TYPE" == "postgres" ]] || die "XUI_DB_DSN requires XUI_DB_TYPE=postgres"
        [[ "$XUI_DB_DSN" == postgres://* || "$XUI_DB_DSN" == postgresql://* ]] || die "Invalid PostgreSQL DSN"
    fi
    require_integer XUI_ACME_HTTP_PORT "$XUI_ACME_HTTP_PORT"
    (( XUI_ACME_HTTP_PORT >= 1 && XUI_ACME_HTTP_PORT <= 65535 )) || die "XUI_ACME_HTTP_PORT is out of range"
    if [[ -n "$XUI_VERSION" ]]; then
        [[ "$XUI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "XUI_VERSION must look like v3.8.5"
    fi
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect operating system"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|fedora|centos|rhel|almalinux|rocky|ol|arch|manjaro|opensuse*|sles|alpine) ;;
        *) warn "OS ${OS_ID} ${OS_VERSION} is supported by upstream but is outside this installer's tested matrix" ;;
    esac
    ok "Detected OS: ${OS_ID} ${OS_VERSION}"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        i386|i686) ARCH="386" ;;
        s390x) ARCH="s390x" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
    ok "Detected architecture: ${ARCH}"
}

install_dependencies() {
    info "Installing required packages"
    case "$OS_ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y --no-install-recommends curl jq openssl ca-certificates uuid-runtime socat iproute2 dnsutils procps python3
            ;;
        fedora|centos|rhel|almalinux|rocky|ol)
            local pm="dnf"; command -v dnf >/dev/null 2>&1 || pm="yum"
            "$pm" install -y curl jq openssl ca-certificates util-linux socat iproute bind-utils procps-ng python3
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm --needed curl jq openssl ca-certificates util-linux socat iproute2 bind procps-ng python
            ;;
        opensuse*|sles)
            zypper --non-interactive install curl jq openssl ca-certificates util-linux socat iproute2 bind-utils procps python3
            ;;
        alpine)
            apk add --no-cache bash curl jq openssl ca-certificates util-linux socat iproute2 bind-tools procps python3
            ;;
        *)
            for cmd in curl jq openssl ss; do command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"; done
            ;;
    esac
}

check_resource_limits() {
    local nofile
    nofile="$(ulimit -n 2>/dev/null || echo unknown)"
    if [[ "$nofile" =~ ^[0-9]+$ ]] && (( nofile < 4096 )); then
        warn "Open-file limit is ${nofile}; 3X-UI may need a higher systemd LimitNOFILE under heavy load"
    else
        info "Open-file limit: ${nofile}"
    fi
}

curl_common() {
    curl --silent --show-error --location \
        --connect-timeout 10 --max-time 45 --retry 3 --retry-delay 2 --retry-connrefused "$@"
}

detect_public_ipv4() {
    local endpoint value
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co/ip; do
        value="$(curl_common --ipv4 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IPV4="$value"
            break
        fi
    done
    if [[ -n "$PUBLIC_IPV4" ]]; then ok "Public IPv4 detected"; else warn "Public IPv4 not detected"; fi
}

detect_public_ipv6() {
    local endpoint value
    for endpoint in https://api64.ipify.org https://ipv6.icanhazip.com; do
        value="$(curl_common --ipv6 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$value" == *:* ]]; then
            PUBLIC_IPV6="$value"
            break
        fi
    done
    if [[ -n "$PUBLIC_IPV6" ]]; then ok "Public IPv6 detected"; else info "Public IPv6 is unavailable"; fi
}

detect_webserver() {
    local found=""
    command -v nginx >/dev/null 2>&1 && found+=" nginx"
    command -v caddy >/dev/null 2>&1 && found+=" caddy"
    { command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; } && found+=" apache"
    if [[ -n "$found" ]]; then info "Detected web server binaries:${found}"; else info "No nginx/Caddy/Apache binary detected"; fi
}

resolve_stable_version() {
    [[ -n "$XUI_VERSION" ]] && return 0
    XUI_VERSION="$(curl_common -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true)"
    if [[ ! "$XUI_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Could not resolve latest stable tag; official installer will choose stable"
        XUI_VERSION=""
    else
        info "Latest upstream stable release: ${XUI_VERSION}"
    fi
}

recover_install_result() {
    local xui_bin=/usr/local/x-ui/x-ui show username password port web_path token cert scheme host db_type=sqlite
    [[ -x "$xui_bin" ]] || return 1
    warn "Official result env is still absent; rotating panel credentials and a named CLI API token to recover automation safely"
    username="${XUI_USERNAME:-bootstrap-$(openssl rand -hex 5)}"
    password="${XUI_PASSWORD:-$(openssl rand -base64 30 | tr -d '\n')}"
    show="$("$xui_bin" setting -show)" || return 1
    port="${XUI_PANEL_PORT:-$(awk -F': ' '/^[[:space:]]*port:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' <<<"$show")}"
    web_path="${XUI_WEB_BASE_PATH:-$(awk -F': ' '/webBasePath:/ {gsub(/[[:space:]]/,"",$2); sub("^/","",$2); print $2; exit}' <<<"$show")}"
    [[ "$port" =~ ^[0-9]+$ ]] || port="$(shuf -i 1024-62000 -n 1)"
    [[ "$web_path" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || web_path="panel-$(openssl rand -hex 9)"
    "$xui_bin" setting -username "$username" -password "$password" -port "$port" -webBasePath "$web_path" >/dev/null || return 1
    token="$("$xui_bin" setting -getApiToken -tokenName bootstrap-installer | awk '/apiToken:/ {print $2}' | tail -1)"
    [[ "$port" =~ ^[0-9]+$ && -n "$web_path" && -n "$token" ]] || return 1
    cert="$("$xui_bin" setting -getCert true | awk -F': ' '/^cert:/ {print $2; exit}' | tr -d '[:space:]')"
    scheme=http
    [[ -n "$cert" && -r "$cert" ]] && scheme=https
    host="$PUBLIC_HOST"
    [[ "$host" == *:* && "$host" != \[*\] ]] && host="[${host}]"
    if [[ -r /etc/default/x-ui ]]; then
        db_type="$(awk -F= '/^XUI_DB_TYPE=/ {gsub(/[[:space:]"]/ ,"",$2); print $2; exit}' /etc/default/x-ui)"
        db_type="${db_type:-sqlite}"
    fi
    install -d -m 700 "$(dirname "$INSTALL_RESULT")"
    {
        printf 'XUI_USERNAME=%q\n' "$username"
        printf 'XUI_PASSWORD=%q\n' "$password"
        printf 'XUI_PANEL_PORT=%q\n' "$port"
        printf 'XUI_WEB_BASE_PATH=%q\n' "$web_path"
        printf 'XUI_ACCESS_URL=%q\n' "${scheme}://${host}:${port}/${web_path}"
        printf 'XUI_API_TOKEN=%q\n' "$token"
        printf 'XUI_DB_TYPE=%q\n' "$db_type"
    } > "$INSTALL_RESULT"
    chmod 600 "$INSTALL_RESULT"
    systemctl restart x-ui
    XUI_USERNAME="$username"
    XUI_PASSWORD="$password"
    XUI_PANEL_PORT="$port"
    XUI_WEB_BASE_PATH="$web_path"
    ok "Recovered ${INSTALL_RESULT}; previous panel login was intentionally rotated because its plaintext password was unrecoverable"
}

existing_ip_certificate_valid() {
    local cert key
    [[ -n "$PUBLIC_IPV4" && -x /usr/local/x-ui/x-ui ]] || return 1
    cert="$(/usr/local/x-ui/x-ui setting -getCert true 2>/dev/null | awk -F': ' '/^cert:/ {print $2; exit}' | tr -d '[:space:]')"
    key="$(/usr/local/x-ui/x-ui setting -getCert true 2>/dev/null | awk -F': ' '/^key:/ {print $2; exit}' | tr -d '[:space:]')"
    [[ -r "$cert" && -r "$key" ]] || return 1
    openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
    openssl x509 -in "$cert" -noout -checkip "$PUBLIC_IPV4" >/dev/null 2>&1 || return 1
    return 0
}

install_3xui() {
    if [[ "$INBOUNDS_ONLY" == "true" ]]; then
        systemctl is-active --quiet x-ui 2>/dev/null || die "3X-UI service is not active; inbound creation stopped"
        if [[ -r "$INSTALL_RESULT" ]] || recover_install_result; then
            ok "Active 3X-UI retained; panel binaries, database, clients, and existing inbounds are unchanged"
            return 0
        fi
        die "Could not safely obtain API access for the active panel"
    fi

    if [[ "$FORCE_REINSTALL" != "true" ]] && systemctl is-active --quiet x-ui 2>/dev/null && [[ -r "$INSTALL_RESULT" ]]; then
        if [[ -z "$XUI_DOMAIN" ]] && ! existing_ip_certificate_valid; then
            warn "Existing panel has no valid public-IP certificate; official repair will configure one"
        else
            ok "Existing 3X-UI installation detected; reinstall skipped"
            return 0
        fi
    fi

    if [[ "$FORCE_REINSTALL" != "true" ]] && systemctl is-active --quiet x-ui 2>/dev/null && [[ ! -r "$INSTALL_RESULT" ]]; then
        if recover_install_result; then
            ok "Existing 3X-UI installation repaired without reinstalling panel binaries"
            return 0
        fi
        warn "Direct recovery failed; falling back to the official repair installer"
    fi

    if systemctl is-active --quiet x-ui 2>/dev/null || [[ "$FORCE_REINSTALL" == "true" ]]; then
        if [[ "$PANEL_UPDATE" == "true" ]]; then
            info "Panel update requested; database, clients, inbounds, and settings will be preserved"
        elif [[ "$FORCE_REINSTALL" == "true" ]]; then
            info "Reinstall requested; the database and panel settings will be preserved"
        else
            warn "Existing 3X-UI lacks ${INSTALL_RESULT}; the official installer will upgrade/repair it so API credentials can be discovered safely"
        fi
        local emergency_backup
        emergency_backup="${RESULT_DIR}/backups/pre-repair-$(date '+%Y-%m-%d_%H-%M-%S')"
        install -d -m 700 "$emergency_backup"
        [[ -f /etc/x-ui/x-ui.db ]] && cp -a /etc/x-ui/x-ui.db "$emergency_backup/x-ui.db"
        [[ -f /etc/default/x-ui ]] && cp -a /etc/default/x-ui "$emergency_backup/x-ui.env"
        [[ -f "$INSTALL_RESULT" ]] && cp -a "$INSTALL_RESULT" "$emergency_backup/install-result.env"
        [[ -f "$MANAGER_CONFIG" ]] && cp -a "$MANAGER_CONFIG" "$emergency_backup/manager-config.env"
        if [[ -x /usr/local/x-ui/x-ui ]]; then
            /usr/local/x-ui/x-ui setting -show > "$emergency_backup/panel-settings.txt" 2>&1 || true
        fi
        chmod -R go-rwx "$emergency_backup"
        info "Pre-update panel backup created at ${emergency_backup}"
    fi

    resolve_stable_version
    local installer
    installer="$(mktemp /tmp/install-3xui-official.XXXXXX)"
    if [[ -n "$XUI_VERSION" ]]; then
        curl_common --fail "https://raw.githubusercontent.com/${OFFICIAL_REPO}/${XUI_VERSION}/install.sh" -o "$installer"
    else
        curl_common --fail "$OFFICIAL_INSTALLER" -o "$installer"
    fi
    bash -n "$installer" || die "Official installer failed syntax validation"
    chmod 700 "$installer"
    info "Running official stable 3X-UI installer"
    # The wrapper has already collected and validated the answers. Keep the
    # upstream installer non-interactive to avoid a second questionnaire.
    export XUI_NONINTERACTIVE=1
    export XUI_DB_TYPE XUI_ENABLE_FAIL2BAN XUI_ACME_HTTP_PORT
    [[ -n "$XUI_USERNAME" ]] && export XUI_USERNAME
    [[ -n "$XUI_PASSWORD" ]] && export XUI_PASSWORD
    [[ -n "$XUI_PANEL_PORT" ]] && export XUI_PANEL_PORT
    [[ -n "$XUI_WEB_BASE_PATH" ]] && export XUI_WEB_BASE_PATH
    [[ -n "$XUI_DB_DSN" ]] && export XUI_DB_DSN
    [[ -n "$XUI_ACME_EMAIL" ]] && export XUI_ACME_EMAIL
    if [[ -n "$XUI_DOMAIN" ]]; then
        export XUI_SSL_MODE=domain
        export XUI_DOMAIN
    else
        export XUI_SSL_MODE=ip
    fi
    if [[ -n "$XUI_VERSION" ]]; then
        bash "$installer" "$XUI_VERSION"
    else
        bash "$installer"
    fi
    rm -f -- "$installer"
    systemctl enable --now x-ui >/dev/null 2>&1 || true
    [[ -r "$INSTALL_RESULT" ]] || recover_install_result || die "Could not create ${INSTALL_RESULT} for the existing panel"
    ok "3X-UI installation completed"
}

load_install_result() {
    [[ -r "$INSTALL_RESULT" ]] || die "Missing ${INSTALL_RESULT}; cannot safely discover panel credentials"
    # shellcheck disable=SC1090
    . "$INSTALL_RESULT"
    : "${XUI_USERNAME:?missing XUI_USERNAME}"
    : "${XUI_PASSWORD:?missing XUI_PASSWORD}"
    : "${XUI_PANEL_PORT:?missing XUI_PANEL_PORT}"
    : "${XUI_WEB_BASE_PATH:?missing XUI_WEB_BASE_PATH}"
    : "${XUI_API_TOKEN:?missing XUI_API_TOKEN}"
    XUI_DB_TYPE="${XUI_DB_TYPE:-sqlite}"
    local base_path="/${XUI_WEB_BASE_PATH#/}"
    base_path="${base_path%/}"
    local scheme="http"
    [[ "${XUI_ACCESS_URL:-}" == https://* ]] && scheme="https"
    PANEL_BASE_URL="${scheme}://127.0.0.1:${XUI_PANEL_PORT}${base_path}"
    API_BASE_URL="${PANEL_BASE_URL}/panel/api"
    chmod 600 "$INSTALL_RESULT"
}

wait_for_panel() {
    local i code alternate_code alternate_base alternate_api alternate_scheme
    if [[ "$PANEL_BASE_URL" == https://* ]]; then
        alternate_scheme=http
        alternate_base="http://${PANEL_BASE_URL#https://}"
    else
        alternate_scheme=https
        alternate_base="https://${PANEL_BASE_URL#http://}"
    fi
    alternate_api="${alternate_base}/panel/api"
    for i in $(seq 1 60); do
        code="$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
            --connect-timeout 2 --max-time 5 "${API_BASE_URL}/server/status" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" || true)"
        [[ "$code" == "200" ]] && { ok "Panel API is ready"; return 0; }
        alternate_code="$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
            --connect-timeout 2 --max-time 5 "${alternate_api}/server/status" \
            -H "Authorization: Bearer ${XUI_API_TOKEN}" || true)"
        if [[ "$alternate_code" == "200" ]]; then
            PANEL_BASE_URL="$alternate_base"
            API_BASE_URL="$alternate_api"
            if [[ -n "${XUI_ACCESS_URL:-}" ]]; then
                XUI_ACCESS_URL="${alternate_scheme}://${XUI_ACCESS_URL#*://}"
            fi
            warn "Panel responded over ${alternate_scheme}; recorded access scheme was corrected in memory"
            return 0
        fi
        sleep 1
    done
    die "Panel API did not become ready"
}

api_request() {
    local method="$1" path="$2" body="${3:-}" content_type="${4:-application/json}"
    local response_file status response
    response_file="$(mktemp /tmp/3xui-api.XXXXXX)"
    local -a args=(--insecure --request "$method" --output "$response_file" --write-out '%{http_code}'
        -H "Authorization: Bearer ${XUI_API_TOKEN}" -H "Accept: application/json")
    if [[ -n "$body" ]]; then
        args+=(-H "Content-Type: ${content_type}" --data "$body")
    fi
    status="$(curl_common "${args[@]}" "${API_BASE_URL}${path}" 2>/dev/null || true)"
    response="$(cat "$response_file" 2>/dev/null || true)"
    rm -f -- "$response_file"
    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        warn "API ${method} ${path} returned HTTP ${status:-transport-error}"
        return 1
    fi
    jq -e . >/dev/null 2>&1 <<<"$response" || { warn "API ${method} ${path} returned invalid JSON"; return 1; }
    if jq -e 'has("success") and (.success == false)' >/dev/null 2>&1 <<<"$response"; then
        warn "API ${method} ${path} failed: $(jq -r '.msg // "unknown error"' <<<"$response")"
        return 1
    fi
    printf '%s' "$response"
}

urlencode() {
    jq -rn --arg v "$1" '$v|@uri'
}

test_api() {
    local response
    response="$(api_request GET /inbounds/list)" || die "Bearer-token API authentication failed"
    jq -e '.success == true and (.obj | type == "array")' >/dev/null <<<"$response" || die "Unexpected API response shape"
    ok "Bearer-token API verified"
}

reserve_existing_inbound_ports() {
    local response port tuple
    response="$(api_request GET /inbounds/list)" || return 1
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        for tuple in "tcp:${port}" "udp:${port}"; do
            port_in_list "$tuple" || RESERVED_PORTS+="${RESERVED_PORTS:+$'\n'}${tuple}"
        done
    done < <(jq -r '.obj[]?.port // empty' <<<"$response")
    ok "Existing inbound ports reserved against reuse"
}

detect_3xui_capabilities() {
    OPENAPI_JSON="$(mktemp /tmp/3xui-openapi.XXXXXX)"
    local response
    response="$(api_request GET /openapi.json)" || die "Unable to load live panel OpenAPI document"
    jq -e '.openapi and .paths["/panel/api/inbounds/add"]' >/dev/null <<<"$response" || die "Live OpenAPI lacks inbound API"
    printf '%s' "$response" > "$OPENAPI_JSON"
    PROTOCOL_ENUM="$(jq -r '.components.schemas.Inbound.properties.protocol.enum[]? // empty' "$OPENAPI_JSON")"
    response="$(api_request GET /server/status)" || die "Unable to read server status"
    XRAY_VERSION="$(jq -r '.obj.xray.version // "unknown"' <<<"$response")"
    PANEL_VERSION="$(jq -r '.obj.panelVersion // empty' <<<"$response")"
    if [[ -z "$PANEL_VERSION" ]]; then
        PANEL_VERSION="$(systemctl status x-ui --no-pager 2>/dev/null | sed -n 's/.*3x-ui[[:space:]]\+v\{0,1\}\([0-9][0-9.]*\).*/v\1/p' | head -1 || true)"
    fi
    [[ -z "$PANEL_VERSION" ]] && PANEL_VERSION="${XUI_VERSION:-installed}"
    info "Capabilities source: live OpenAPI; panel ${PANEL_VERSION}; Xray ${XRAY_VERSION}"
}

protocol_supported() {
    grep -Fxq "$1" <<<"$PROTOCOL_ENUM"
}

backup_existing_config() {
    RUN_BACKUP_DIR="${RESULT_DIR}/backups/$(date '+%Y-%m-%d_%H-%M-%S')"
    install -d -m 700 "$RUN_BACKUP_DIR"
    [[ -f /etc/x-ui/x-ui.db ]] && cp -a /etc/x-ui/x-ui.db "$RUN_BACKUP_DIR/x-ui.db"
    [[ -f "$INSTALL_RESULT" ]] && cp -a "$INSTALL_RESULT" "$RUN_BACKUP_DIR/install-result.env"
    api_request GET /inbounds/list > "$RUN_BACKUP_DIR/inbounds-before.json" || true
    chmod -R go-rwx "$RUN_BACKUP_DIR"
    ok "Backup created at ${RUN_BACKUP_DIR}"
}

load_or_create_state() {
    if [[ -r "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
    if [[ -z "${SUB_ID:-}" ]]; then SUB_ID="$(openssl rand -hex 12)"; fi
    if [[ -z "${SUB_EMAIL_PREFIX:-}" ]]; then SUB_EMAIL_PREFIX="auto-$(openssl rand -hex 4)"; fi
    {
        printf 'SUB_ID=%q\n' "$SUB_ID"
        printf 'SUB_EMAIL_PREFIX=%q\n' "$SUB_EMAIL_PREFIX"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

find_xray_binary() {
    local candidate
    for candidate in /usr/local/x-ui/bin/xray-linux-* /usr/local/x-ui/bin/xray /usr/bin/xray /usr/local/bin/xray; do
        if [[ -x "$candidate" ]]; then XRAY_BIN="$candidate"; break; fi
    done
    if [[ -n "$XRAY_BIN" ]]; then info "Xray binary located"; else warn "Xray client binary not found; local E2E tests will be limited"; fi
}

normalize_server_host() {
    PUBLIC_HOST="${PUBLIC_IPV4:-$PUBLIC_IPV6}"
    [[ -n "$PUBLIC_HOST" ]] || die "Neither a public IPv4 nor IPv6 address was detected"
    SHARE_HOST="${XUI_DOMAIN:-$PUBLIC_HOST}"
}

dns_matches_server() {
    [[ -n "$XUI_DOMAIN" ]] || return 1
    local addresses
    addresses="$( { dig +short A "$XUI_DOMAIN"; dig +short AAAA "$XUI_DOMAIN"; } 2>/dev/null | sed '/^$/d' || true)"
    if [[ -n "$PUBLIC_IPV4" ]] && grep -Fxq "$PUBLIC_IPV4" <<<"$addresses"; then return 0; fi
    if [[ -n "$PUBLIC_IPV6" ]] && grep -Fxiq "$PUBLIC_IPV6" <<<"$addresses"; then return 0; fi
    return 1
}

port_in_list() {
    local needle="$1" item
    for item in $RESERVED_PORTS; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

port_is_listening() {
    local proto="$1" port="$2"
    if [[ "$proto" == tcp ]]; then
        ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit !found}'
    else
        ss -H -lun 2>/dev/null | awk -v p=":${port}" '$5 ~ p"$" || $4 ~ p"$" {found=1} END {exit !found}'
    fi
}

port_available() {
    local proto="$1" port="$2"
    port_in_list "${proto}:${port}" && return 1
    port_is_listening "$proto" "$port" && return 1
    return 0
}

reserve_port() {
    local proto="$1" port="$2"
    RESERVED_PORTS+="${RESERVED_PORTS:+$'\n'}${proto}:${port}"
    FIREWALL_PORTS+="${FIREWALL_PORTS:+$'\n'}${proto}:${port}"
}

release_port() {
    local proto="$1" port="$2"
    local needle="${proto}:${port}"
    RESERVED_PORTS="$(grep -Fxv "$needle" <<<"$RESERVED_PORTS" || true)"
    FIREWALL_PORTS="$(grep -Fxv "$needle" <<<"$FIREWALL_PORTS" || true)"
}

random_port_in_range() {
    local span random_value
    span=$((XUI_PORT_END - XUI_PORT_START + 1))
    random_value="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
    [[ "$random_value" =~ ^[0-9]+$ ]] || random_value=$(( (RANDOM << 16) | RANDOM ))
    printf '%s' $((XUI_PORT_START + random_value % span))
}

find_free_port() {
    local proto="$1" port first offset span attempt
    span=$((XUI_PORT_END - XUI_PORT_START + 1))
    first="$(random_port_in_range)"
    offset=$((first - XUI_PORT_START))
    for ((attempt=0; attempt<span; attempt++)); do
        port=$((XUI_PORT_START + (offset + attempt) % span))
        if port_available "$proto" "$port"; then
            reserve_port "$proto" "$port"
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

inbound_remark() {
    local suffix="$1" profile_number=""
    if [[ "$XUI_INBOUND_REMARK_MODE" == "number" ]]; then
        case "$suffix" in
            *-01-VLESS-REALITY-VISION) profile_number="1" ;;
            *-02-VLESS-XHTTP-TLS) profile_number="2" ;;
            *-03-TROJAN-TLS) profile_number="3" ;;
            *-04-SHADOWSOCKS) profile_number="4" ;;
            *-05-HYSTERIA2) profile_number="5" ;;
            *) profile_number="99" ;;
        esac
        printf '%s #%s' "$XUI_INBOUND_NAME" "$profile_number"
        return 0
    fi
    if [[ "$XUI_INBOUND_NAME" == "AUTO" && "$suffix" == "COMPAT-WIREGUARD" ]]; then
        printf '%s' "$suffix"
    else
        printf '%s-%s' "$XUI_INBOUND_NAME" "$suffix"
    fi
}

managed_inbound_remarks_json() {
    local prefix="RU" legacy_prefix i suffix
    [[ "$REGION_PROFILE" == "GENERIC" ]] && prefix="GENERIC"
    legacy_prefix="$prefix"
    {
        inbound_remark "${prefix}-01-VLESS-REALITY-VISION"
        inbound_remark "${prefix}-02-VLESS-XHTTP-TLS"
        inbound_remark "${prefix}-03-TROJAN-TLS"
        inbound_remark "${prefix}-04-SHADOWSOCKS"
        inbound_remark "${prefix}-05-HYSTERIA2"
        # Keep historical full-name profiles discoverable so recreate-inbounds
        # can remove them after upgrading from older installer versions.
        for suffix in \
            01-VLESS-XHTTP-REALITY-AUTO 02-VLESS-XHTTP-REALITY-PACKET \
            03-VLESS-REALITY-VISION 04-VLESS-REALITY-GRPC 05-AMNEZIAWG-3.1 \
            06-HYSTERIA2 07-TUIC-V5 08-VLESS-TLS-WS 09-TROJAN-TLS \
            10-VMESS-TLS-WS 11-SHADOWSOCKS; do
            printf '%s-%s\n' "$XUI_INBOUND_NAME" "$legacy_prefix-$suffix"
        done
        if [[ "$XUI_INBOUND_NAME" == "AUTO" ]]; then
            printf 'COMPAT-WIREGUARD\n'
        else
            printf '%s-COMPAT-WIREGUARD\n' "$XUI_INBOUND_NAME"
        fi
        if [[ "$XUI_INBOUND_REMARK_MODE" == "number" ]]; then
            # Older releases assigned numeric names #1 through #14.
            for ((i=1; i<=14; i++)); do printf '%s #%s\n' "$XUI_INBOUND_NAME" "$i"; done
        fi
    } | jq -R 'select(length > 0)' | jq -s 'unique'
}

owned_inbounds_snapshot_json() {
    local snapshot="${RESULT_DIR}/inbounds.json"
    [[ -r "$snapshot" ]] || die "Managed inbound inventory is unavailable: ${snapshot}; run repair first"
    jq -ce '[.[] | select((.id | type) == "number" and (.remark | type) == "string") | {id,remark}]' \
        "$snapshot" || die "Managed inbound inventory is invalid: ${snapshot}; run repair first"
}

delete_managed_inbounds_for_recreation() {
    local response old_remarks_json new_remarks_json owned_json collision deleted=0 inbound_id remark
    [[ "$RECREATE_INBOUNDS" == "true" ]] || return 0
    [[ -n "$RECREATE_OLD_INBOUND_NAME" && -n "$RECREATE_OLD_REMARK_MODE" && -n "$RECREATE_OLD_REGION_PROFILE" ]] || \
        die "Previous managed inbound naming is unavailable; no inbounds were deleted"
    response="$(api_request GET /inbounds/list)" || die "Could not list inbounds before recreation"
    old_remarks_json="$(XUI_INBOUND_NAME="$RECREATE_OLD_INBOUND_NAME" \
        XUI_INBOUND_REMARK_MODE="$RECREATE_OLD_REMARK_MODE" \
        REGION_PROFILE="$RECREATE_OLD_REGION_PROFILE" managed_inbound_remarks_json)"
    new_remarks_json="$(managed_inbound_remarks_json)"
    owned_json="$(owned_inbounds_snapshot_json)"
    collision="$(jq -r --argjson target "$new_remarks_json" --argjson old "$old_remarks_json" --argjson owned "$owned_json" '
        .obj[]?
        | .id as $id | .remark as $remark
        | select(($target | index($remark)) != null
            and ((($old | index($remark)) != null
                and ($owned | any(.id == $id and .remark == $remark))) | not))
        | .remark' <<<"$response")"
    [[ -z "$collision" ]] || die "New inbound remark already belongs to an existing inbound: ${collision}; no inbounds were deleted"
    while IFS=$'\t' read -r inbound_id remark; do
        [[ "$inbound_id" =~ ^[0-9]+$ && -n "$remark" ]] || continue
        api_request POST "/inbounds/del/${inbound_id}" >/dev/null || \
            die "Could not delete managed inbound ${remark}; backup remains at ${RUN_BACKUP_DIR}"
        ((deleted+=1))
        ok "Removed managed inbound before recreation: ${remark}"
    done < <(jq -r --argjson remarks "$old_remarks_json" --argjson owned "$owned_json" '
        .obj[]?
        | select(.id as $id | .remark as $remark
            | ($remarks | index($remark)) != null
            and ($owned | any(.id == $id and .remark == $remark)))
        | [.id,.remark] | @tsv' <<<"$response")
    wait_xray_healthy || die "Xray did not recover after removing managed inbounds; restore from ${RUN_BACKUP_DIR}"
    ok "Managed inbound recreation prepared: ${deleted} old inbound(s) removed; custom inbounds retained"
}

generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'; else cat /proc/sys/kernel/random/uuid; fi
}

generate_password() { openssl rand -base64 32 | tr -d '\n'; }
generate_short_id() { openssl rand -hex 8; }

generate_random_path() {
    local a b
    a="$(openssl rand -base64 12 | tr '+/' '-_' | tr -d '=\n')"
    b="$(openssl rand -base64 12 | tr '+/' '-_' | tr -d '=\n')"
    printf '/%s/%s' "$a" "$b"
}

generate_reality_keys() {
    local response
    response="$(api_request GET /server/getNewX25519Cert)" || die "3X-UI could not generate an X25519 keypair"
    REALITY_PRIVATE_KEY="$(jq -r '.obj.privateKey // empty' <<<"$response")"
    REALITY_PUBLIC_KEY="$(jq -r '.obj.publicKey // empty' <<<"$response")"
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Invalid X25519 generator response"
}

select_reality_destination() {
    if [[ -n "$XUI_REALITY_DEST" || -n "$XUI_REALITY_SNI" ]]; then
        [[ -n "$XUI_REALITY_DEST" && -n "$XUI_REALITY_SNI" ]] || die "Set both XUI_REALITY_DEST and XUI_REALITY_SNI"
        local override_response
        override_response="$(api_request POST /server/scanRealityTarget \
            "target=$(urlencode "$XUI_REALITY_DEST")&sni=$(urlencode "$XUI_REALITY_SNI")&xver=0" \
            application/x-www-form-urlencoded)" || die "Custom REALITY target probe failed"
        jq -e '.obj.feasible == true' >/dev/null <<<"$override_response" || die "Custom REALITY target is not feasible: $(jq -r '.obj.reason // "unknown"' <<<"$override_response")"
        REALITY_DEST="$XUI_REALITY_DEST"
        REALITY_SNI="$XUI_REALITY_SNI"
        ok "Custom REALITY target passed the upstream panel probe"
        return 0
    fi

    local candidates response
    candidates="www.microsoft.com:443,www.apple.com:443,www.cloudflare.com:443,addons.mozilla.org:443"
    response="$(api_request POST /server/scanRealityTargets \
        "targets=$(urlencode "$candidates")" application/x-www-form-urlencoded)" || die "REALITY target scan failed"
    REALITY_DEST="$(jq -r '.obj[] | select(.feasible == true) | .target' <<<"$response" | head -1)"
    REALITY_SNI="$(jq -r '.obj[] | select(.feasible == true) | (.serverNames[0] // .host)' <<<"$response" | head -1)"
    [[ -n "$REALITY_DEST" && -n "$REALITY_SNI" ]] || die "No REALITY candidate passed TLS 1.3, h2, X25519, and certificate checks"
    ok "REALITY target selected by live TLS probe: ${REALITY_DEST}"
}

get_panel_certificate_paths() {
    local response
    response="$(api_request GET /server/getWebCertFiles 2>/dev/null || true)"
    [[ -n "$response" ]] || return 1
    TLS_CERT_FILE="$(jq -r '.obj.webCertFile // empty' <<<"$response")"
    TLS_KEY_FILE="$(jq -r '.obj.webKeyFile // empty' <<<"$response")"
    [[ -r "$TLS_CERT_FILE" && -r "$TLS_KEY_FILE" ]] || return 1
    openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 3600 >/dev/null 2>&1 || return 1
    TLS_TRUSTED="true"
    return 0
}

generate_self_signed_transport_certificate() {
    local cert_dir="${RESULT_DIR}/certs" san subject
    SELF_CERT_FILE="${cert_dir}/transport-fullchain.pem"
    SELF_KEY_FILE="${cert_dir}/transport-privkey.pem"
    if [[ ! -s "$SELF_CERT_FILE" || ! -s "$SELF_KEY_FILE" ]] || ! openssl x509 -in "$SELF_CERT_FILE" -noout -checkend 3600 >/dev/null 2>&1; then
        if [[ "$PUBLIC_HOST" == *:* ]]; then
            san="IP:${PUBLIC_HOST}"
        elif [[ "$PUBLIC_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            san="IP:${PUBLIC_HOST}"
        else
            san="DNS:${PUBLIC_HOST}"
        fi
        subject="/CN=${PUBLIC_HOST}"
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
            -subj "$subject" -addext "subjectAltName=${san}" \
            -keyout "$SELF_KEY_FILE" -out "$SELF_CERT_FILE" >/dev/null 2>&1
        chmod 600 "$SELF_CERT_FILE" "$SELF_KEY_FILE"
    fi
    SELF_CERT_PIN="$(openssl x509 -in "$SELF_CERT_FILE" -outform DER | openssl dgst -sha256 -hex | awk '{print $2}')"
    [[ -n "$SELF_CERT_PIN" ]] || die "Failed to calculate transport certificate pin"
}

configure_tls() {
    if [[ -n "$XUI_DOMAIN" ]]; then
        if dns_matches_server && get_panel_certificate_paths; then
            ok "Trusted panel certificate will be reused for TLS profiles"
        else
            TLS_TRUSTED="false"
            warn "Domain DNS/certificate validation failed; trusted TLS compatibility profiles will be skipped"
        fi
    elif get_panel_certificate_paths && openssl x509 -in "$TLS_CERT_FILE" -noout -checkip "$PUBLIC_IPV4" >/dev/null 2>&1; then
        ok "Trusted public-IP certificate will be reused for the panel, subscription, and TLS profiles"
    else
        TLS_TRUSTED="false"
        warn "Public-IP certificate is unavailable; the panel/subscription may remain HTTP until ACME succeeds on tcp/80"
    fi
    generate_self_signed_transport_certificate
}

base_inbound_payload() {
    local remark="$1" port="$2" protocol="$3" settings="$4" stream="$5" sort_index="$6"
    jq -cn \
        --arg remark "$remark" --argjson port "$port" --arg protocol "$protocol" \
        --argjson settings "$settings" --argjson stream "$stream" --arg share "$SHARE_HOST" \
        --argjson sort "$sort_index" '
        {
          up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
          trafficReset:"never", trafficResetDay:1, lastTrafficResetTime:0,
          listen:"", port:$port, protocol:$protocol, settings:$settings,
          streamSettings:$stream,
          sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:false,ipsExcluded:[],domainsExcluded:[]},
          tag:("auto-" + ($remark|ascii_downcase|gsub("[^a-z0-9]+";"-"))),
          shareAddrStrategy:"custom", shareAddr:$share, subSortIndex:$sort,
          excludeFromSub:false, disableFlow:false
        }'
}

reality_stream() {
    local network="$1" transport_settings="$2"
    local sid="$3"
    jq -cn \
        --arg network "$network" --argjson transport "$transport_settings" \
        --arg target "$REALITY_DEST" --arg sni "$REALITY_SNI" \
        --arg private "$REALITY_PRIVATE_KEY" --arg public "$REALITY_PUBLIC_KEY" --arg sid "$sid" '
        ({network:$network,security:"reality"}
        + (if $network=="xhttp" then {xhttpSettings:$transport}
           elif $network=="grpc" then {grpcSettings:$transport}
           else {tcpSettings:$transport} end)
        + {realitySettings:{show:false,xver:0,target:$target,serverNames:[$sni],privateKey:$private,
             minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],
             settings:{publicKey:$public,fingerprint:"chrome",serverName:$sni,spiderX:"/",mldsa65Verify:""}}})'
}

tls_settings_json() {
    local cert="$1" key="$2" sni="$3" pin="${4:-}" alpn_json="${5:-[\"h2\",\"http/1.1\"]}"
    jq -cn --arg cert "$cert" --arg key "$key" --arg sni "$sni" --arg pin "$pin" --argjson alpn "$alpn_json" '
      {serverName:$sni,minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,
       disableSystemRoot:false,enableSessionResumption:false,
       certificates:[{certificateFile:$cert,keyFile:$key,ocspStapling:0,oneTimeLoading:false,usage:"encipherment",buildChain:false}],
       alpn:$alpn,echServerKeys:"",
       settings:{fingerprint:"",echConfigList:"",pinnedPeerCertSha256:(if $pin=="" then [] else [$pin] end),verifyPeerCertByName:""}}'
}

find_inbound_by_remark() {
    local remark="$1" response
    response="$(api_request GET /inbounds/list)" || return 1
    jq -c --arg remark "$remark" '.obj[] | select(.remark == $remark)' <<<"$response" | head -1
}

record_failure() {
    local remark="$1" reason="$2" tmp
    tmp="$(mktemp /tmp/3xui-failed.XXXXXX)"
    jq --arg remark "$remark" --arg reason "$reason" --arg time "$(timestamp)" \
        '. + [{remark:$remark,reason:$reason,time:$time}]' "$FAILED_FILE" > "$tmp"
    install -m 600 "$tmp" "$FAILED_FILE"
    rm -f -- "$tmp"
}

mark_result() {
    local status="$1" remark="$2" proto="$3" port="$4" test_result="$5"
    RESULT_ROWS+=("${status}|${remark}|${proto}|${port}|${test_result}")
    case "$status" in
        PASS) ((PASSED_COUNT+=1)) ;;
        FAILED) ((FAILED_COUNT+=1)) ;;
        SKIPPED) ((SKIPPED_COUNT+=1)) ;;
    esac
}

client_email_for() {
    local _remark="$1" canonical slug
    canonical="$(inbound_remark "RU-01-VLESS-REALITY-VISION")"
    [[ "$REGION_PROFILE" == "GENERIC" ]] && canonical="$(inbound_remark "GENERIC-01-VLESS-REALITY-VISION")"
    slug="$(tr '[:upper:]' '[:lower:]' <<<"$canonical" | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-42)"
    printf '%s-%s@bootstrap.invalid' "$SUB_EMAIL_PREFIX" "$slug"
}

ensure_client_attached() {
    local inbound_id="$1" remark="$2" flow="${3:-}" email response path payload
    email="$(client_email_for "$remark")"
    path="/clients/get/$(urlencode "$email")"
    response="$(api_request GET "$path" 2>/dev/null || true)"
    if [[ -n "$response" ]] && jq -e --argjson id "$inbound_id" '.obj.inboundIds | index($id) != null' >/dev/null 2>&1 <<<"$response"; then
        printf '%s' "$email"
        return 0
    fi

    # Re-posting the same email with its stored subId is the documented API
    # path for adding another inbound while preserving protocol credentials.
    # It also lets the panel persist a per-inbound Vision flow override.
    payload="$(jq -cn --arg email "$email" --arg sub "$SUB_ID" --arg flow "$flow" --argjson id "$inbound_id" '
      {client:{email:$email,subId:$sub,flow:$flow,totalGB:0,expiryTime:0,limitIp:0,limitHwid:0,
               tgId:0,comment:"Created by install-3xui-full",enable:true,reset:0},inboundIds:[$id]}')"
    api_request POST /clients/add "$payload" >/dev/null || return 1
    printf '%s' "$email"
}

wait_xray_healthy() {
    local i response state stable=0
    for i in $(seq 1 30); do
        response="$(api_request GET /server/status 2>/dev/null || true)"
        state="$(jq -r '.obj.xray.state // empty' <<<"${response:-{}}" 2>/dev/null || true)"
        if [[ "$state" == "running" ]]; then
            ((stable+=1))
            (( stable >= 3 )) && return 0
        else
            stable=0
        fi
        sleep 1
    done
    return 1
}

capture_xray_diagnostics() {
    local remark="$1" safe_remark file
    safe_remark="$(tr '[:upper:]' '[:lower:]' <<<"$remark" | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-64)"
    file="${RESULT_DIR}/xray-failure-${safe_remark:-unknown}.log"
    {
        printf 'Captured: %s\nProfile: %s\n\n' "$(timestamp)" "$remark"
        systemctl status x-ui --no-pager 2>&1 || true
        printf '\nRecent journal:\n'
        journalctl -u x-ui --no-pager -n 80 2>&1 || true
    } > "$file"
    chmod 600 "$file"
}

verify_port() {
    local proto="$1" port="$2" i
    if [[ "$proto" == both ]]; then
        for i in $(seq 1 20); do
            if port_is_listening tcp "$port" && port_is_listening udp "$port"; then return 0; fi
            sleep 1
        done
        return 1
    fi
    for i in $(seq 1 20); do
        port_is_listening "$proto" "$port" && return 0
        sleep 1
    done
    return 1
}

rollback_bad_inbound() {
    local inbound_id="$1" remark="$2" reason="$3"
    warn "Rolling back ${remark}: ${reason}"
    api_request POST "/inbounds/del/${inbound_id}" >/dev/null || warn "API rollback failed for inbound ${inbound_id}"
    wait_xray_healthy || warn "Xray did not recover promptly after rollback"
    record_failure "$remark" "$reason"
}

find_local_socks_port() {
    local port
    for ((port=31080; port<=31980; port++)); do
        port_is_listening tcp "$port" || { printf '%s' "$port"; return 0; }
    done
    return 1
}

build_vless_e2e_config() {
    local detail="$1" email="$2" socks_port="$3"
    jq -c --arg email "$email" --argjson socks "$socks_port" '
      .obj as $ib |
      ($ib.settings.clients[] | select(.email==$email)) as $c |
      $ib.streamSettings as $ss |
      {
        log:{loglevel:"error"},
        inbounds:[{listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{udp:true}}],
        outbounds:[{
          protocol:"vless",tag:"proxy",
          settings:{vnext:[{address:"127.0.0.1",port:$ib.port,users:[{id:$c.id,encryption:"none",flow:($c.flow // "")}]}]},
          streamSettings:(
            {network:$ss.network,security:$ss.security}
            + (if $ss.network=="xhttp" then {xhttpSettings:{path:$ss.xhttpSettings.path,host:($ss.xhttpSettings.host // ""),mode:($ss.xhttpSettings.mode // "auto")}}
               elif $ss.network=="grpc" then {grpcSettings:$ss.grpcSettings}
               else {tcpSettings:($ss.tcpSettings // {})} end)
            + (if $ss.security=="reality" then {realitySettings:{serverName:($ss.realitySettings.settings.serverName // $ss.realitySettings.serverNames[0]),
                 fingerprint:($ss.realitySettings.settings.fingerprint // "chrome"),
                 publicKey:$ss.realitySettings.settings.publicKey,
                 shortId:$ss.realitySettings.shortIds[0],spiderX:($ss.realitySettings.settings.spiderX // "/")}}
               else {tlsSettings:{serverName:$ss.tlsSettings.serverName,fingerprint:($ss.tlsSettings.settings.fingerprint // ""),
                    alpn:($ss.tlsSettings.alpn // []),allowInsecure:false}} end)
          )
        }]
      }' <<<"$detail"
}

build_hysteria_e2e_config() {
    local detail="$1" email="$2" socks_port="$3"
    jq -c --arg email "$email" --argjson socks "$socks_port" '
      .obj as $ib |
      ($ib.settings.clients[] | select(.email==$email)) as $c |
      $ib.streamSettings as $ss |
      {
        log:{loglevel:"error"},
        inbounds:[{listen:"127.0.0.1",port:$socks,protocol:"socks",settings:{udp:true}}],
        outbounds:[{
          protocol:"hysteria",tag:"proxy",settings:{address:"127.0.0.1",port:$ib.port,version:2},
          streamSettings:{network:"hysteria",security:"tls",
            hysteriaSettings:{version:2,auth:$c.auth,udpIdleTimeout:60},
            tlsSettings:{serverName:$ss.tlsSettings.serverName,alpn:$ss.tlsSettings.alpn,
              fingerprint:"",pinnedPeerCertSha256:($ss.tlsSettings.settings.pinnedPeerCertSha256[0] // "")}}
        }]
      }' <<<"$detail"
}

run_xray_e2e() {
    local inbound_id="$1" email="$2" kind="$3" detail socks_port tmp_dir config pid="" result="" endpoint candidate
    [[ -n "$XRAY_BIN" ]] || return 2
    detail="$(api_request GET "/inbounds/get/${inbound_id}")" || return 1
    socks_port="$(find_local_socks_port)" || return 2
    tmp_dir="$(mktemp -d /tmp/3xui-e2e.XXXXXX)"
    chmod 700 "$tmp_dir"
    case "$kind" in
        vless) config="$(build_vless_e2e_config "$detail" "$email" "$socks_port")" || { rm -rf -- "$tmp_dir"; return 1; } ;;
        hysteria) config="$(build_hysteria_e2e_config "$detail" "$email" "$socks_port")" || { rm -rf -- "$tmp_dir"; return 1; } ;;
        *) rm -rf -- "$tmp_dir"; return 2 ;;
    esac
    printf '%s\n' "$config" > "$tmp_dir/client.json"
    chmod 600 "$tmp_dir/client.json"
    "$XRAY_BIN" run -test -c "$tmp_dir/client.json" >"$tmp_dir/test.log" 2>&1 || { rm -rf -- "$tmp_dir"; return 1; }
    "$XRAY_BIN" run -c "$tmp_dir/client.json" >"$tmp_dir/client.log" 2>&1 &
    pid=$!
    local i
    for i in $(seq 1 30); do
        port_is_listening tcp "$socks_port" && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if port_is_listening tcp "$socks_port"; then
        for endpoint in https://api.ipify.org https://ipv4.icanhazip.com http://api.ipify.org; do
            candidate="$(curl --silent --show-error --fail --socks5-hostname "127.0.0.1:${socks_port}" \
                --connect-timeout 8 --max-time 30 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$candidate" == *:* ]]; then
                result="$candidate"
                break
            fi
        done
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf -- "$tmp_dir"
    [[ -n "$result" ]] || return 1
    return 0
}

ensure_inbound() {
    local remark="$1" protocol="$2" port_proto="$3" payload="$4" flow="$5" e2e_kind="$6"
    local existing response inbound_id actual_port email e2e_status="CONFIG PASS; E2E NOT RUN" requested_port
    requested_port="$(jq -r '.port' <<<"$payload")"
    CURRENT_REMARK="$remark"
    CURRENT_CREATED_NEW="false"

    existing="$(find_inbound_by_remark "$remark" || true)"
    if [[ -n "$existing" ]]; then
        inbound_id="$(jq -r '.id' <<<"$existing")"
        actual_port="$(jq -r '.port' <<<"$existing")"
        if [[ "$actual_port" != "$requested_port" ]]; then
            if [[ "$port_proto" == both ]]; then
                release_port tcp "$requested_port"; release_port udp "$requested_port"
            else
                release_port "$port_proto" "$requested_port"
            fi
        fi
        info "Existing managed inbound retained: ${remark}"
    else
        response="$(api_request POST /inbounds/add "$payload")" || {
            if [[ "$port_proto" == both ]]; then
                release_port tcp "$requested_port"; release_port udp "$requested_port"
            else
                release_port "$port_proto" "$requested_port"
            fi
            error "Failed to create ${remark}"
            record_failure "$remark" "API rejected inbound"
            mark_result FAILED "$remark" "$protocol" "-" "API REJECTED"
            return 1
        }
        inbound_id="$(jq -r '.obj.id // empty' <<<"$response")"
        actual_port="$(jq -r '.obj.port // empty' <<<"$response")"
        [[ "$inbound_id" =~ ^[0-9]+$ && "$actual_port" =~ ^[0-9]+$ ]] || {
            if [[ "$port_proto" == both ]]; then
                release_port tcp "$requested_port"; release_port udp "$requested_port"
            else
                release_port "$port_proto" "$requested_port"
            fi
            record_failure "$remark" "API response did not contain inbound id/port"
            mark_result FAILED "$remark" "$protocol" "-" "INVALID API RESPONSE"
            return 1
        }
        CURRENT_CREATED_NEW="true"
        ((CREATED_COUNT+=1))
        ok "Created ${remark} on ${port_proto}/${actual_port}"
    fi

    email="$(ensure_client_attached "$inbound_id" "$remark" "$flow")" || {
        if [[ "$CURRENT_CREATED_NEW" == true ]]; then
            rollback_bad_inbound "$inbound_id" "$remark" "client creation failed"
            if [[ "$port_proto" == both ]]; then release_port tcp "$actual_port"; release_port udp "$actual_port"; else release_port "$port_proto" "$actual_port"; fi
        fi
        mark_result FAILED "$remark" "$protocol" "$actual_port" "CLIENT FAILED"
        return 1
    }

    if ! wait_xray_healthy || ! verify_port "$port_proto" "$actual_port"; then
        capture_xray_diagnostics "$remark"
        if [[ "$CURRENT_CREATED_NEW" == true ]]; then
            rollback_bad_inbound "$inbound_id" "$remark" "Xray/port verification failed"
            if [[ "$port_proto" == both ]]; then release_port tcp "$actual_port"; release_port udp "$actual_port"; else release_port "$port_proto" "$actual_port"; fi
        fi
        mark_result FAILED "$remark" "$protocol" "$actual_port" "SERVER CONFIG FAILED"
        return 1
    fi

    if [[ "$e2e_kind" != none ]]; then
        if run_xray_e2e "$inbound_id" "$email" "$e2e_kind"; then
            e2e_status="E2E PASS"
        else
            local e2e_rc=$?
            if [[ "$e2e_rc" -eq 2 ]]; then
                e2e_status="CONFIG PASS; E2E CLIENT UNAVAILABLE"
                warn "Local E2E client unavailable for ${remark}; server configuration remains verified"
            else
                if [[ "$CURRENT_CREATED_NEW" == true ]]; then rollback_bad_inbound "$inbound_id" "$remark" "local end-to-end test failed"; fi
                if [[ "$CURRENT_CREATED_NEW" == true ]]; then
                    if [[ "$port_proto" == both ]]; then release_port tcp "$actual_port"; release_port udp "$actual_port"; else release_port "$port_proto" "$actual_port"; fi
                fi
                mark_result FAILED "$remark" "$protocol" "$actual_port" "E2E FAILED"
                return 1
            fi
        fi
    fi

    if [[ "$port_proto" == both ]]; then
        reserve_port tcp "$actual_port"; reserve_port udp "$actual_port"
    else
        reserve_port "$port_proto" "$actual_port"
    fi
    OWNED_IDS+=("$inbound_id")
    OWNED_EMAILS+=("$email")
    pass "${remark}: ${e2e_status}"
    mark_result PASS "$remark" "$protocol" "$actual_port" "$e2e_status"
    return 0
}

find_free_dual_port() {
    local port first offset span attempt
    span=$((XUI_PORT_END - XUI_PORT_START + 1))
    first="$(random_port_in_range)"
    offset=$((first - XUI_PORT_START))
    for ((attempt=0; attempt<span; attempt++)); do
        port=$((XUI_PORT_START + (offset + attempt) % span))
        if port_available tcp "$port" && port_available udp "$port"; then
            reserve_port tcp "$port"; reserve_port udp "$port"; printf '%s' "$port"; return 0
        fi
    done
    return 1
}

skip_profile() {
    local remark="$1" protocol="$2" reason="$3"
    skip "${remark}: ${reason}"
    mark_result SKIPPED "$remark" "$protocol" "-" "$reason"
}

create_xhttp_reality_profile() {
    local remark="$1" mode="$2" sort_index="$3" port path sid transport stream settings payload
    port="$(find_free_port tcp)" || { skip_profile "$remark" vless "NO FREE TCP PORT"; return; }
    path="$(generate_random_path)"
    sid="$(generate_short_id)"
    transport="$(jq -cn --arg path "$path" --arg mode "$mode" '{path:$path,host:"",mode:$mode}')"
    stream="$(reality_stream xhttp "$transport" "$sid")"
    settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
    payload="$(base_inbound_payload "$remark" "$port" vless "$settings" "$stream" "$sort_index")"
    ensure_inbound "$remark" vless tcp "$payload" "" vless || true
}

create_reality_vision() {
    local remark port sid transport stream settings payload
    remark="$(inbound_remark "RU-01-VLESS-REALITY-VISION")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-01-VLESS-REALITY-VISION")"
    port="$(find_free_port tcp)" || { skip_profile "$remark" vless "NO FREE TCP PORT"; return; }
    sid="$(generate_short_id)"
    transport='{"acceptProxyProtocol":false,"header":{"type":"none"}}'
    stream="$(reality_stream tcp "$transport" "$sid")"
    settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
    payload="$(base_inbound_payload "$remark" "$port" vless "$settings" "$stream" 1)"
    ensure_inbound "$remark" vless tcp "$payload" "xtls-rprx-vision" vless || true
}

create_reality_grpc() {
    local remark port sid service transport stream settings payload
    remark="$(inbound_remark "RU-04-VLESS-REALITY-GRPC")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-04-VLESS-REALITY-GRPC")"
    port="$(find_free_port tcp)" || { skip_profile "$remark" vless "NO FREE TCP PORT"; return; }
    sid="$(generate_short_id)"
    service="$(openssl rand -hex 10)"
    transport="$(jq -cn --arg service "$service" '{serviceName:$service,authority:"",multiMode:false}')"
    stream="$(reality_stream grpc "$transport" "$sid")"
    settings='{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}'
    payload="$(base_inbound_payload "$remark" "$port" vless "$settings" "$stream" 4)"
    ensure_inbound "$remark" vless tcp "$payload" "" vless || true
}

create_amneziawg() {
    local remark port payload
    remark="$(inbound_remark "RU-05-AMNEZIAWG-3.1")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-05-AMNEZIAWG-3.1")"
    protocol_supported amneziawg || { skip_profile "$remark" amneziawg "PROTOCOL NOT ADVERTISED BY LIVE OPENAPI"; return; }
    port="$(find_free_port udp)" || { skip_profile "$remark" amneziawg "NO FREE UDP PORT"; return; }
    payload="$(base_inbound_payload "$remark" "$port" amneziawg '{}' '{}' 5)"
    ensure_inbound "$remark" amneziawg udp "$payload" "" none || true
}

create_hysteria2() {
    local remark port tls stream settings payload
    remark="$(inbound_remark "RU-05-HYSTERIA2")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-05-HYSTERIA2")"
    protocol_supported hysteria || { skip_profile "$remark" hysteria "PROTOCOL NOT ADVERTISED BY LIVE OPENAPI"; return; }
    port="$(find_free_port udp)" || { skip_profile "$remark" hysteria "NO FREE UDP PORT"; return; }
    if [[ "$TLS_TRUSTED" == true ]]; then
        tls="$(tls_settings_json "$TLS_CERT_FILE" "$TLS_KEY_FILE" "${XUI_DOMAIN:-$PUBLIC_HOST}" "" '["h3"]')"
    else
        tls="$(tls_settings_json "$SELF_CERT_FILE" "$SELF_KEY_FILE" "$PUBLIC_HOST" "$SELF_CERT_PIN" '["h3"]')"
    fi
    stream="$(jq -cn --argjson tls "$tls" '{network:"hysteria",security:"tls",hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60},tlsSettings:$tls}')"
    settings='{"version":2,"clients":[]}'
    payload="$(base_inbound_payload "$remark" "$port" hysteria "$settings" "$stream" 5)"
    ensure_inbound "$remark" hysteria udp "$payload" "" hysteria || true
}

create_tuic() {
    local remark port cert key sni settings stream payload
    remark="$(inbound_remark "RU-07-TUIC-V5")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-07-TUIC-V5")"
    protocol_supported tuic || { skip_profile "$remark" tuic "PROTOCOL NOT ADVERTISED BY LIVE OPENAPI"; return; }
    port="$(find_free_port udp)" || { skip_profile "$remark" tuic "NO FREE UDP PORT"; return; }
    if [[ "$TLS_TRUSTED" == true ]]; then
        cert="$TLS_CERT_FILE"; key="$TLS_KEY_FILE"; sni="${XUI_DOMAIN:-$PUBLIC_HOST}"
        stream='{}'
    else
        cert="$SELF_CERT_FILE"; key="$SELF_KEY_FILE"; sni="$PUBLIC_HOST"
        stream="$(jq -cn --arg host "$SHARE_HOST" --arg sni "$sni" --argjson port "$port" \
            '{externalProxy:[{dest:$host,port:$port,sni:$sni,alpn:["h3"],allowInsecure:true}]}')"
    fi
    settings="$(jq -cn --arg cert "$cert" --arg key "$key" --arg sni "$sni" '
      {server:{certificate:$cert,private_key:$key,congestion_control:"bbr",alpn:["h3"],udp_relay_mode:"native",
               zero_rtt_handshake:true,log_level:"info",max_idle_time:15,authentication_timeout:3,
               max_udp_relay_packet_size:1500,sni:$sni},clients:[]}')"
    payload="$(base_inbound_payload "$remark" "$port" tuic "$settings" "$stream" 7)"
    ensure_inbound "$remark" tuic udp "$payload" "" none || true
}

trusted_tls_stream() {
    local network="$1" transport="$2" tls
    tls="$(tls_settings_json "$TLS_CERT_FILE" "$TLS_KEY_FILE" "${XUI_DOMAIN:-$PUBLIC_HOST}")"
    jq -cn --arg network "$network" --argjson transport "$transport" --argjson tls "$tls" '
      ({network:$network,security:"tls",tlsSettings:$tls}
       + (if $network=="ws" then {wsSettings:$transport}
          elif $network=="xhttp" then {xhttpSettings:$transport}
          else {tcpSettings:$transport} end))'
}

create_vless_xhttp_tls() {
    local remark port path transport stream payload
    remark="$(inbound_remark "RU-02-VLESS-XHTTP-TLS")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-02-VLESS-XHTTP-TLS")"
    [[ "$TLS_TRUSTED" == true ]] || { skip_profile "$remark" vless "TRUSTED CERTIFICATE UNAVAILABLE"; return; }
    port="$(find_free_port tcp)" || { skip_profile "$remark" vless "NO FREE TCP PORT"; return; }
    path="$(generate_random_path)"
    transport="$(jq -cn --arg path "$path" --arg host "$XUI_DOMAIN" '{path:$path,host:$host,mode:"auto"}')"
    stream="$(trusted_tls_stream xhttp "$transport")"
    payload="$(base_inbound_payload "$remark" "$port" vless '{"clients":[],"decryption":"none","encryption":"none","fallbacks":[]}' "$stream" 2)"
    ensure_inbound "$remark" vless tcp "$payload" "" vless || true
}

create_trojan_tls() {
    local remark port stream payload
    remark="$(inbound_remark "RU-03-TROJAN-TLS")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-03-TROJAN-TLS")"
    [[ "$TLS_TRUSTED" == true ]] || { skip_profile "$remark" trojan "TRUSTED CERTIFICATE UNAVAILABLE"; return; }
    port="$(find_free_port tcp)" || { skip_profile "$remark" trojan "NO FREE TCP PORT"; return; }
    stream="$(trusted_tls_stream tcp '{"acceptProxyProtocol":false,"header":{"type":"none"}}')"
    payload="$(base_inbound_payload "$remark" "$port" trojan '{"clients":[],"fallbacks":[]}' "$stream" 3)"
    ensure_inbound "$remark" trojan tcp "$payload" "" none || true
}

create_vmess_tls_ws() {
    local remark port path transport stream payload
    remark="$(inbound_remark "RU-10-VMESS-TLS-WS")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-10-VMESS-TLS-WS")"
    [[ "$TLS_TRUSTED" == true ]] || { skip_profile "$remark" vmess "TRUSTED CERTIFICATE UNAVAILABLE"; return; }
    port="$(find_free_port tcp)" || { skip_profile "$remark" vmess "NO FREE TCP PORT"; return; }
    path="$(generate_random_path)"
    transport="$(jq -cn --arg path "$path" --arg host "$XUI_DOMAIN" '{acceptProxyProtocol:false,path:$path,host:$host,headers:{},heartbeatPeriod:0}')"
    stream="$(trusted_tls_stream ws "$transport")"
    payload="$(base_inbound_payload "$remark" "$port" vmess '{"clients":[]}' "$stream" 10)"
    ensure_inbound "$remark" vmess tcp "$payload" "" none || true
}

create_shadowsocks() {
    local remark port server_key settings stream payload
    remark="$(inbound_remark "RU-04-SHADOWSOCKS")"
    [[ "$REGION_PROFILE" == RU ]] || remark="$(inbound_remark "GENERIC-04-SHADOWSOCKS")"
    port="$(find_free_dual_port)" || { skip_profile "$remark" shadowsocks "NO FREE TCP+UDP PORT"; return; }
    server_key="$(openssl rand -base64 32 | tr -d '\n')"
    settings="$(jq -cn --arg key "$server_key" '{method:"2022-blake3-aes-256-gcm",password:$key,network:"tcp,udp",clients:[],ivCheck:false}')"
    stream='{"network":"tcp","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}},"security":"none"}'
    payload="$(base_inbound_payload "$remark" "$port" shadowsocks "$settings" "$stream" 4)"
    ensure_inbound "$remark" shadowsocks both "$payload" "" none || true
}

create_wireguard() {
    local remark port secret settings payload
    remark="$(inbound_remark "COMPAT-WIREGUARD")"
    protocol_supported wireguard || { skip_profile "$remark" wireguard "PROTOCOL NOT ADVERTISED BY LIVE OPENAPI"; return; }
    port="$(find_free_port udp)" || { skip_profile "$remark" wireguard "NO FREE UDP PORT"; return; }
    secret="$(openssl rand -base64 32 | tr -d '\n')"
    settings="$(jq -cn --arg secret "$secret" '{mtu:1420,secretKey:$secret,peers:[],clients:[],noKernelTun:false,subnetIp:"10.0.0.0",subnetCidr:24}')"
    payload="$(base_inbound_payload "$remark" "$port" wireguard "$settings" '{}' 50)"
    ensure_inbound "$remark" wireguard udp "$payload" "" none || true
}

create_profiles() {
    protocol_supported vless || die "Live panel does not advertise VLESS"
    generate_reality_keys
    select_reality_destination

    create_reality_vision || true
    create_vless_xhttp_tls || true
    create_trojan_tls || true
    create_shadowsocks || true
    create_hysteria2 || true
}

optimize_udp_buffers() {
    local target=16777216 current_r current_w changed=false file=/etc/sysctl.d/99-3xui-bootstrap.conf
    current_r="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
    current_w="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"
    {
        printf 'net.core.rmem_max=%s\n' "$current_r"
        printf 'net.core.wmem_max=%s\n' "$current_w"
    } > "$RUN_BACKUP_DIR/sysctl-udp-before.txt"
    local new_r="$current_r" new_w="$current_w"
    (( current_r < target )) && { new_r="$target"; changed=true; }
    (( current_w < target )) && { new_w="$target"; changed=true; }
    if [[ "$changed" == true ]]; then
        {
            printf '# Managed by install-3xui-full.sh; never lowers existing values.\n'
            printf 'net.core.rmem_max = %s\n' "$new_r"
            printf 'net.core.wmem_max = %s\n' "$new_w"
        } > "$file"
        chmod 644 "$file"
        sysctl -p "$file" >/dev/null || { rm -f -- "$file"; warn "UDP sysctl apply failed; file rolled back"; return; }
        ok "UDP socket buffers raised where required"
    else
        info "UDP socket buffers already meet the minimum"
    fi
}

configure_bbr() {
    is_true "$ENABLE_BBR" || { info "BBR disabled by environment"; return; }
    local current available file=/etc/sysctl.d/99-3xui-bbr.conf
    current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    [[ "$current" == bbr ]] && { info "BBR is already enabled"; return; }
    modprobe tcp_bbr 2>/dev/null || true
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    grep -qw bbr <<<"$available" || { skip "BBR is not available in the running kernel"; return; }
    printf 'net.ipv4.tcp_congestion_control = bbr\n' > "$file"
    chmod 644 "$file"
    if sysctl -p "$file" >/dev/null 2>&1 && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == bbr ]]; then
        printf 'net.ipv4.tcp_congestion_control=%s\n' "$current" > "$RUN_BACKUP_DIR/sysctl-bbr-before.txt"
        ok "BBR enabled and verified"
    else
        rm -f -- "$file"
        [[ -n "$current" ]] && sysctl -w "net.ipv4.tcp_congestion_control=${current}" >/dev/null 2>&1 || true
        warn "BBR verification failed; previous congestion control restored"
    fi
}

detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -qi active; then
        printf ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; then
        printf firewalld
    elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
        printf nftables
    else
        printf none
    fi
}

prepare_acme_firewall() {
    local fw tuple family table chain port="$XUI_ACME_HTTP_PORT"
    reserve_port tcp "$port"
    fw="$(detect_firewall)"
    case "$fw" in
        ufw)
            ufw allow "${port}/tcp" comment '3xui-bootstrap' >/dev/null
            ok "UFW allows ACME renewal traffic on tcp/${port}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            ok "firewalld allows ACME renewal traffic on tcp/${port}"
            ;;
        nftables)
            tuple="$(nft -j list ruleset 2>/dev/null | jq -r '
              [.nftables[].chain | select(.hook=="input") | select(.policy=="drop" or .policy=="reject")][0]
              | if . == null then empty else [.family,.table,.name]|@tsv end' || true)"
            if [[ -n "$tuple" ]]; then
                IFS=$'\t' read -r family table chain <<<"$tuple"
                NFT_FAMILY="$family"; NFT_TABLE="$table"; NFT_CHAIN="$chain"
                if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "3xui-bootstrap-tcp-${port}"; then
                    nft insert rule "$family" "$table" "$chain" tcp dport "$port" ct state new accept comment "3xui-bootstrap-tcp-${port}"
                fi
                ok "nftables allows ACME renewal traffic on tcp/${port}"
            else
                warn "Could not identify an nftables input chain; make external tcp/80 reachable for ACME"
            fi
            ;;
        none) info "No active host firewall blocks the ACME listener" ;;
    esac
}

configure_nftables() {
    local family table chain proto port tuple
    nft list ruleset > "$RUN_BACKUP_DIR/nftables-before.conf"
    tuple="$(nft -j list ruleset 2>/dev/null | jq -r '
      [.nftables[].chain | select(.hook=="input") | select(.policy=="drop" or .policy=="reject")][0]
      | if . == null then empty else [.family,.table,.name]|@tsv end' || true)"
    if [[ -z "$tuple" ]]; then
        warn "nftables has no detectable input base chain with drop/reject policy; rules were not guessed"
        return 0
    fi
    IFS=$'\t' read -r family table chain <<<"$tuple"
    NFT_FAMILY="$family"; NFT_TABLE="$table"; NFT_CHAIN="$chain"
    while IFS=: read -r proto port; do
        [[ -n "$proto" && -n "$port" ]] || continue
        if nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "3xui-bootstrap-${proto}-${port}"; then continue; fi
        nft insert rule "$family" "$table" "$chain" "$proto" dport "$port" ct state new accept comment "3xui-bootstrap-${proto}-${port}"
    done <<<"$FIREWALL_PORTS"
    ok "Necessary rules inserted into nftables ${family}/${table}/${chain}"
}

configure_firewall() {
    local fw proto port
    reserve_port tcp "$XUI_PANEL_PORT"
    [[ -n "$SUB_PORT" ]] && reserve_port tcp "$SUB_PORT"
    fw="$(detect_firewall)"
    FIREWALL_KIND="$fw"
    case "$fw" in
        ufw)
            while IFS=: read -r proto port; do
                [[ -n "$proto" && -n "$port" ]] || continue
                ufw allow "${port}/${proto}" comment '3xui-bootstrap' >/dev/null
            done <<<"$FIREWALL_PORTS"
            ok "UFW rules added without changing its policy"
            ;;
        firewalld)
            while IFS=: read -r proto port; do
                [[ -n "$proto" && -n "$port" ]] || continue
                firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
            done <<<"$FIREWALL_PORTS"
            firewall-cmd --reload >/dev/null
            ok "firewalld rules added"
            ;;
        nftables) configure_nftables ;;
        none) info "No active host firewall detected; no firewall state changed" ;;
    esac
    install -d -m 700 "$MANAGER_CONFIG_DIR"
    {
        printf 'FIREWALL_KIND=%q\n' "$FIREWALL_KIND"
        printf 'MANAGED_FIREWALL_PORTS=%q\n' "$FIREWALL_PORTS"
        printf 'NFT_FAMILY=%q\n' "$NFT_FAMILY"
        printf 'NFT_TABLE=%q\n' "$NFT_TABLE"
        printf 'NFT_CHAIN=%q\n' "$NFT_CHAIN"
    } > "$FIREWALL_STATE"
    chmod 600 "$FIREWALL_STATE"
}

configure_subscription_server() {
    local response settings changed=false host_for_url scheme sub_domain raw_enabled json_enabled clash_enabled desired_host
    response="$(api_request POST /setting/all)" || { warn "Cannot read subscription settings"; return 1; }
    settings="$(jq -c '.obj' <<<"$response")"
    if [[ "$(jq -r '.remarkTemplate // empty' <<<"$settings")" != '{{INBOUND}}' ]]; then
        settings="$(jq -c '.remarkTemplate="{{INBOUND}}"' <<<"$settings")"
        changed=true
    fi
    if ! jq -e '.subEnable == true and .subJsonEnable == true and .subClashEnable == true' >/dev/null <<<"$settings"; then
        settings="$(jq -c '.subEnable=true | .subJsonEnable=true | .subClashEnable=true' <<<"$settings")"
        changed=true
    fi
    if [[ "$TLS_TRUSTED" == true ]]; then
        desired_host="${XUI_DOMAIN:-$PUBLIC_HOST}"
        if ! jq -e --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" --arg host "$desired_host" \
            '.subCertFile == $cert and .subKeyFile == $key and .subDomain == $host' >/dev/null <<<"$settings"; then
            settings="$(jq -c --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" --arg host "$desired_host" '
              .subCertFile=$cert | .subKeyFile=$key | .subDomain=$host |
              .subURI="" | .subJsonURI="" | .subClashURI=""' <<<"$settings")"
            changed=true
        fi
    fi
    if [[ "$changed" == true ]]; then
        if api_request POST /setting/update "$settings" >/dev/null; then
            systemctl restart x-ui
            wait_for_panel
            response="$(api_request POST /setting/all)" || return 1
            settings="$(jq -c '.obj' <<<"$response")"
            if [[ "$(jq -r '.remarkTemplate // empty' <<<"$settings")" != '{{INBOUND}}' ]]; then
                warn "Panel did not save the subscription remark template {{INBOUND}}"
                return 1
            fi
            if [[ "$TLS_TRUSTED" == true ]]; then
                ok "Raw, JSON, and Clash subscriptions configured with TLS; remark template is {{INBOUND}}"
            else
                ok "Raw, JSON, and Clash subscription formats configured; remark template is {{INBOUND}}"
            fi
        else
            warn "Could not update subscription server settings"
            return 1
        fi
    fi
    SUB_PORT="$(jq -r '.subPort // 2096' <<<"$settings")"
    SUB_PATH="$(jq -r '.subPath // "/sub/"' <<<"$settings")"
    SUB_JSON_PATH="$(jq -r '.subJsonPath // "/json/"' <<<"$settings")"
    SUB_CLASH_PATH="$(jq -r '.subClashPath // "/clash/"' <<<"$settings")"
    sub_domain="$(jq -r '.subDomain // empty' <<<"$settings")"
    host_for_url="${sub_domain:-$SHARE_HOST}"
    [[ "$host_for_url" == *:* && "$host_for_url" != \[*\] ]] && host_for_url="[${host_for_url}]"
    scheme=http
    if [[ -n "$(jq -r '.subCertFile // empty' <<<"$settings")" && -n "$(jq -r '.subKeyFile // empty' <<<"$settings")" ]]; then scheme=https; fi
    local configured_uri configured_json configured_clash
    configured_uri="$(jq -r '.subURI // empty' <<<"$settings")"
    configured_json="$(jq -r '.subJsonURI // empty' <<<"$settings")"
    configured_clash="$(jq -r '.subClashURI // empty' <<<"$settings")"
    local raw_base json_base clash_base
    raw_base="${configured_uri:-${scheme}://${host_for_url}:${SUB_PORT}${SUB_PATH}}"
    json_base="${configured_json:-${scheme}://${host_for_url}:${SUB_PORT}${SUB_JSON_PATH}}"
    clash_base="${configured_clash:-${scheme}://${host_for_url}:${SUB_PORT}${SUB_CLASH_PATH}}"
    [[ "$raw_base" == */ ]] || raw_base+="/"
    [[ "$json_base" == */ ]] || json_base+="/"
    [[ "$clash_base" == */ ]] || clash_base+="/"
    raw_enabled="$(jq -r '.subEnable == true' <<<"$settings")"
    json_enabled="$(jq -r '.subJsonEnable == true' <<<"$settings")"
    clash_enabled="$(jq -r '.subClashEnable == true' <<<"$settings")"
    [[ "$raw_enabled" == true ]] && SUBSCRIPTION_URL="${raw_base}${SUB_ID}"
    [[ "$json_enabled" == true ]] && SUBSCRIPTION_JSON_URL="${json_base}${SUB_ID}"
    [[ "$clash_enabled" == true ]] && SUBSCRIPTION_CLASH_URL="${clash_base}${SUB_ID}"
    [[ "$changed" == true ]] || info "Subscription formats and TLS are configured; remark template is {{INBOUND}}"
}

verify_subscription() {
    local scheme code body decoded link_count
    [[ -n "$SUBSCRIPTION_URL" && -n "$SUB_PORT" && -n "$SUB_PATH" ]] || {
        warn "Subscription URL is unavailable because panel subscription settings could not be read"
        return 1
    }
    scheme="${SUBSCRIPTION_URL%%:*}"
    if [[ "$TLS_TRUSTED" == true && "$scheme" != https ]]; then
        warn "A trusted certificate exists, but the subscription URL is not HTTPS"
        return 1
    fi
    body="$(mktemp /tmp/3xui-subscription.XXXXXX)"
    decoded="$(mktemp /tmp/3xui-subscription-decoded.XXXXXX)"
    code="$(curl --silent --insecure --output "$body" --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1 \
        -H "Host: ${SHARE_HOST}" -A 'v2rayN' \
        "${scheme}://127.0.0.1:${SUB_PORT}${SUB_PATH}${SUB_ID}" || true)"
    if [[ "$code" != 200 ]]; then
        rm -f -- "$body" "$decoded"
        warn "Subscription local probe returned HTTP ${code:-transport-error}"
        return 1
    fi
    if ! tr -d '\r\n ' < "$body" | base64 -d > "$decoded" 2>/dev/null; then
        rm -f -- "$body" "$decoded"
        warn "Subscription returned HTTP 200 but is not valid Base64"
        return 1
    fi
    link_count="$(grep -Ec '^(vless|vmess|trojan|ss|hysteria2|tuic|vpn|wg)://' "$decoded" || true)"
    rm -f -- "$body" "$decoded"
    if [[ "$link_count" =~ ^[0-9]+$ ]] && (( link_count > 0 )); then
        pass "Subscription returned HTTP 200, valid Base64, and ${link_count} client links"
        return 0
    fi
    warn "Subscription decoded successfully but contained no supported client links"
    return 1
}

collect_links() {
    local links_file="${RESULT_DIR}/links.txt" xhttp_file="${RESULT_DIR}/xhttp-links.txt"
    local i email id remark response link owned_ids_json
    : > "$links_file"
    : > "$xhttp_file"
    for ((i=0; i<${#OWNED_IDS[@]}; i++)); do
        id="${OWNED_IDS[$i]}"
        email="${OWNED_EMAILS[$i]}"
        response="$(api_request GET "/inbounds/get/${id}" 2>/dev/null || true)"
        remark="$(jq -r '.obj.remark // empty' <<<"${response:-{}}" 2>/dev/null || true)"
        [[ -n "$remark" ]] || continue
        response="$(api_request GET "/clients/links/$(urlencode "$email")" 2>/dev/null || true)"
        printf '[%s]\n' "$remark" >> "$links_file"
        if [[ -n "$response" ]]; then
            while IFS= read -r link; do
                # 3X-UI v3.8.5 hard-codes allow_insecure=0 in the direct TUIC URL even
                # when a managed host advertises a self-signed endpoint. Preserve the
                # official generated credentials and fields, correcting only that flag.
                if [[ "$TLS_TRUSTED" != true && "$link" == tuic://* ]]; then
                    link="${link/allow_insecure=0/allow_insecure=1}"
                fi
                printf '%s\n' "$link" >> "$links_file"
                [[ "$link" == vless://* && "$link" == *"type=xhttp"* ]] || continue
                printf '[%s]\n%s\n\n' "$remark" "$link" >> "$xhttp_file"
            done < <(jq -r '.obj[]? // empty' <<<"$response")
        fi
        printf '\n' >> "$links_file"
    done
    chmod 600 "$links_file" "$xhttp_file"

    local all
    all="$(api_request GET /inbounds/list)" || return 1
    owned_ids_json="$(printf '%s\n' "${OWNED_IDS[@]}" | jq -R 'select(length > 0) | tonumber' | jq -s '.')"
    jq --argjson ids "$owned_ids_json" '[.obj[] | select(.id as $id | ($ids | index($id)) != null)]' \
        <<<"$all" > "${RESULT_DIR}/inbounds.json"
    chmod 600 "${RESULT_DIR}/inbounds.json"
}

first_link_for() {
    local label="$1"
    awk -v header="[${label}]" '
      $0==header {found=1; next}
      found && /^\[/ {exit}
      found && NF {print; exit}
    ' "${RESULT_DIR}/links.txt"
}

decode_amneziawg_config() {
    local link encoded padding output="${RESULT_DIR}/amneziawg-client.conf"
    link="$(first_link_for "$(inbound_remark "RU-05-AMNEZIAWG-3.1")")"
    [[ -z "$link" ]] && link="$(first_link_for "$(inbound_remark "GENERIC-05-AMNEZIAWG-3.1")")"
    [[ "$link" == vpn://* ]] || return 1
    encoded="${link#vpn://}"
    encoded="$(printf '%s' "$encoded" | tr '_-' '/+')"
    padding=$(( (4 - ${#encoded} % 4) % 4 ))
    while (( padding > 0 )); do encoded+="="; padding=$((padding - 1)); done
    printf '%s' "$encoded" | base64 -d > "$output" 2>/dev/null || { rm -f -- "$output"; return 1; }
    chmod 600 "$output"
}

write_subscriptions() {
    local raw_url="${SUBSCRIPTION_URL:-UNAVAILABLE — inspect panel subscription settings}"
    local json_url="${SUBSCRIPTION_JSON_URL:-UNAVAILABLE — inspect panel subscription settings}"
    local clash_url="${SUBSCRIPTION_CLASH_URL:-UNAVAILABLE — inspect panel subscription settings}"
    {
        printf 'RAW / V2RAY (User-Agent auto-detection)\n%s\n\n' "$raw_url"
        printf 'XRAY JSON / SING-BOX IMPORT SOURCE\n%s\n\n' "$json_url"
        printf 'CLASH / MIHOMO\n%s\n\n' "$clash_url"
        printf 'Notes:\n'
        printf -- '- The raw endpoint can auto-select output by User-Agent in current 3X-UI.\n'
        printf -- '- Not every format can express XHTTP or Hysteria2 options; use direct links/configs when an importer omits a profile.\n'
    } > "${RESULT_DIR}/subscriptions.txt"
    chmod 600 "${RESULT_DIR}/subscriptions.txt"
}

generate_client_compatibility_report() {
    cat > "${RESULT_DIR}/client-compatibility.txt" <<'EOF'
CLIENT COMPATIBILITY — conservative matrix
Baseline checked: 2026-09-29; 3X-UI v3.8.5; Xray-core v26.9.9.

Statuses describe current import/core capability, not guaranteed reachability in a particular network.
Always confirm the app version and selected core. "VERSION DEPENDENT" is intentional when public
documentation does not guarantee the exact link fields used by this server.

VLESS + REALITY + Vision
Xray-core clients                 SUPPORTED
v2rayNG / v2rayN with Xray        SUPPORTED
Happ / Shadowrocket / Streisand   VERSION DEPENDENT
sing-box clients                  LIMITED / VERSION DEPENDENT

VLESS + XHTTP + TLS
Requires an XHTTP-capable client core and trusted server certificate.

Hysteria2
Hysteria2 native, sing-box, Mihomo and current Xray clients: generally SUPPORTED.
Certificate pin support is required when this report accompanies a no-domain installation.

Trojan + TLS
Broadly supported by current proxy clients; this profile requires a trusted certificate.

Shadowsocks 2022
SUPPORTED only by clients that implement 2022-blake3-aes-256-gcm multi-user keys.
Legacy-only Shadowsocks clients are UNSUPPORTED for this profile.

Important: "server supports" does not mean a particular GUI can import the share link. If import
fails, use the raw/JSON/Clash subscription appropriate for that client's core, or use the Reality
Vision fallback.
EOF
    chmod 600 "${RESULT_DIR}/client-compatibility.txt"
}

generate_russia_diagnostics() {
    cat > "${RESULT_DIR}/russia-diagnostics.txt" <<EOF
RUSSIAN NETWORK DIAGNOSTICS

SERVER CONFIGURATION is tested locally on the VPS. RUSSIAN NETWORK ACCESS is NOT VERIFIED because
this installer did not originate traffic from the user's Russian operator/network.

Failure classes:

PROTOCOL BLOCK
  One transport is classified or reset. Switch among VLESS REALITY Vision, VLESS XHTTP TLS, Trojan TLS,
  Shadowsocks, and Hysteria2.

IP BLOCK
  Every protocol to this VPS fails. Test the IP from another provider/ASN; deploy another node in a
  different provider, ASN, address range, and preferably location.

UDP BLOCK / QUIC BLOCK
  Hysteria2 fails while TCP profiles work. Use VLESS XHTTP TLS, VLESS REALITY Vision, or Trojan TLS.

FOREIGN TRAFFIC THROTTLING
  Connections establish but throughput collapses. Compare at several times and with another ASN.

WHITELIST MODE
  If the operator allows only approved IPs/resources, a foreign VPS may be unreachable regardless of
  XHTTP, REALITY, Hysteria2, Trojan TLS, or Shadowsocks. This is not evidence that one protocol is broken.

DNS ISSUE
  Domain profiles fail but direct-IP REALITY works. Check A/AAAA, stale caches, DNS interception, and
  whether the client resolves IPv4/IPv6 differently.

CLIENT CORE ISSUE
  Import succeeds but the profile does not connect. Confirm the actual selected core and its version;
  XHTTP specifically requires client support and its mode/extra fields must survive import.

Recommended redundancy: at least 2-3 nodes with different providers, ASNs and address ranges.
Node public host for this installation: ${SHARE_HOST}
EOF
    chmod 600 "${RESULT_DIR}/russia-diagnostics.txt"
}

save_result_env() {
    local scheme panel_host panel_url reality_vision xhttp_tls trojan_tls shadowsocks_link hysteria_link
    scheme=http
    [[ "${XUI_ACCESS_URL:-}" == https://* ]] && scheme=https
    panel_host="$SHARE_HOST"
    [[ "$panel_host" == *:* && "$panel_host" != \[*\] ]] && panel_host="[${panel_host}]"
    panel_url="${scheme}://${panel_host}:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}"
    reality_vision="$(first_link_for "$(inbound_remark "RU-01-VLESS-REALITY-VISION")")"
    [[ -z "$reality_vision" ]] && reality_vision="$(first_link_for "$(inbound_remark "GENERIC-01-VLESS-REALITY-VISION")")"
    xhttp_tls="$(first_link_for "$(inbound_remark "RU-02-VLESS-XHTTP-TLS")")"
    [[ -z "$xhttp_tls" ]] && xhttp_tls="$(first_link_for "$(inbound_remark "GENERIC-02-VLESS-XHTTP-TLS")")"
    trojan_tls="$(first_link_for "$(inbound_remark "RU-03-TROJAN-TLS")")"
    [[ -z "$trojan_tls" ]] && trojan_tls="$(first_link_for "$(inbound_remark "GENERIC-03-TROJAN-TLS")")"
    shadowsocks_link="$(first_link_for "$(inbound_remark "RU-04-SHADOWSOCKS")")"
    [[ -z "$shadowsocks_link" ]] && shadowsocks_link="$(first_link_for "$(inbound_remark "GENERIC-04-SHADOWSOCKS")")"
    hysteria_link="$(first_link_for "$(inbound_remark "RU-05-HYSTERIA2")")"
    [[ -z "$hysteria_link" ]] && hysteria_link="$(first_link_for "$(inbound_remark "GENERIC-05-HYSTERIA2")")"
    {
        printf 'INSTALLER_VERSION=%q\n' "$INSTALLER_VERSION"
        printf 'INBOUND_NAME=%q\n' "$XUI_INBOUND_NAME"
        printf 'INBOUND_REMARK_MODE=%q\n' "$XUI_INBOUND_REMARK_MODE"
        printf 'PANEL_URL=%q\n' "$panel_url"
        printf 'PANEL_USERNAME=%q\n' "$XUI_USERNAME"
        printf 'PANEL_PASSWORD=%q\n' "$XUI_PASSWORD"
        printf 'PANEL_PORT=%q\n' "$XUI_PANEL_PORT"
        printf 'PANEL_WEB_PATH=%q\n' "$XUI_WEB_BASE_PATH"
        printf 'PUBLIC_IPV4=%q\n' "$PUBLIC_IPV4"
        printf 'PUBLIC_IPV6=%q\n' "$PUBLIC_IPV6"
        printf 'API_TOKEN=%q\n' "$XUI_API_TOKEN"
        printf 'SUBSCRIPTION_URL=%q\n' "$SUBSCRIPTION_URL"
        printf 'SUBSCRIPTION_JSON_URL=%q\n' "$SUBSCRIPTION_JSON_URL"
        printf 'SUBSCRIPTION_CLASH_URL=%q\n' "$SUBSCRIPTION_CLASH_URL"
        printf 'REALITY_VISION_LINK=%q\n' "$reality_vision"
        printf 'XHTTP_TLS_LINK=%q\n' "$xhttp_tls"
        printf 'TROJAN_TLS_LINK=%q\n' "$trojan_tls"
        printf 'SHADOWSOCKS_LINK=%q\n' "$shadowsocks_link"
        printf 'HYSTERIA2_LINK=%q\n' "$hysteria_link"
    } > "${RESULT_DIR}/result.env"
    chmod 600 "${RESULT_DIR}/result.env"
}

save_access_report() {
    local panel_url
    panel_url="$(root_env_value "${RESULT_DIR}/result.env" PANEL_URL || true)"
    {
        printf '3X-UI — АКТУАЛЬНЫЙ ДОСТУП\n'
        printf 'Обновлено: %s\n' "$(timestamp)"
        printf 'Панель: %s\n' "${panel_url:-unavailable}"
        printf 'Логин: %s\n' "$XUI_USERNAME"
        printf 'Пароль: %s\n' "$XUI_PASSWORD"
        printf 'API-ключ: %s\n' "$XUI_API_TOKEN"
        printf 'Подписка: %s\n' "${SUBSCRIPTION_URL:-unavailable}"
    } > "${RESULT_DIR}/current-access.txt"
    chmod 600 "${RESULT_DIR}/current-access.txt"
    if [[ "$PANEL_UPDATE" == "true" ]]; then
        install -m 600 "${RESULT_DIR}/current-access.txt" "${RESULT_DIR}/access-after-panel-update.txt"
    fi
}

html_escape() {
    printf '%s' "${1-}" | sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}

dashboard_value_row() {
    local label="$1" value="${2:-unavailable}" openable="${3:-false}"
    local safe_label safe_value
    safe_label="$(html_escape "$label")"
    safe_value="$(html_escape "$value")"
    printf '<div class="data-row"><div class="data-label">%s</div><code>%s</code><div class="actions">' "$safe_label" "$safe_value"
    printf '<button type="button" data-copy="%s" onclick="copyValue(this)">Копировать</button>' "$safe_value"
    if [[ "$openable" == "true" && "$value" == http*://* ]]; then
        printf '<a href="%s" target="_blank" rel="noopener noreferrer">Открыть</a>' "$safe_value"
    fi
    printf '</div></div>\n'
}

generate_local_dashboard() {
    local result_file="${RESULT_DIR}/result.env" panel_url panel_user panel_password api_token
    local subscription subscription_json subscription_clash generated link link_number=0
    [[ -r "$result_file" ]] || { warn "Dashboard was not generated: ${result_file} is unavailable"; return 1; }
    panel_url="$(root_env_value "$result_file" PANEL_URL || true)"
    panel_user="$(root_env_value "$result_file" PANEL_USERNAME || true)"
    panel_password="$(root_env_value "$result_file" PANEL_PASSWORD || true)"
    api_token="$(root_env_value "$result_file" API_TOKEN || true)"
    subscription="$(root_env_value "$result_file" SUBSCRIPTION_URL || true)"
    subscription_json="$(root_env_value "$result_file" SUBSCRIPTION_JSON_URL || true)"
    subscription_clash="$(root_env_value "$result_file" SUBSCRIPTION_CLASH_URL || true)"
    generated="$(timestamp)"

    {
        cat <<'HTML_HEAD'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <title>3X-UI — локальная карточка сервера</title>
  <style>
    :root{color-scheme:dark;--bg:#08111f;--panel:#101c2e;--panel2:#15243a;--line:#263b57;--text:#e9f1fb;--muted:#9db0c7;--accent:#48d7a4;--accent2:#6bb7ff;--danger:#ffbd6b}
    *{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at top right,#143154 0,#08111f 46%);color:var(--text);font:15px/1.55 Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;min-height:100vh}
    .wrap{width:min(1120px,calc(100% - 28px));margin:0 auto;padding:34px 0 60px}.top{display:flex;gap:22px;align-items:flex-start;justify-content:space-between;margin-bottom:24px}.eyebrow{color:var(--accent);font-weight:800;letter-spacing:.12em;text-transform:uppercase;font-size:12px}.title{font-size:clamp(29px,5vw,52px);line-height:1.06;margin:8px 0 12px}.lead{color:var(--muted);max-width:720px;margin:0}.privacy{border:1px solid #2f705f;background:#102c29;color:#8ff0cd;border-radius:999px;padding:8px 13px;white-space:nowrap;font-weight:700}
    .grid{display:grid;grid-template-columns:repeat(12,1fr);gap:18px}.card{grid-column:span 12;background:linear-gradient(180deg,rgba(21,36,58,.96),rgba(13,25,42,.96));border:1px solid var(--line);border-radius:18px;padding:20px;box-shadow:0 18px 55px rgba(0,0,0,.22)}.half{grid-column:span 6}.card h2{margin:0 0 15px;font-size:20px}.data-row{display:grid;grid-template-columns:145px minmax(0,1fr) auto;gap:12px;align-items:center;padding:11px 0;border-top:1px solid var(--line)}.data-row:first-of-type{border-top:0}.data-label{color:var(--muted);font-weight:700}.data-row code{overflow-wrap:anywhere;color:#dfffee;background:#091523;padding:8px 10px;border-radius:9px}.actions{display:flex;gap:7px;flex-wrap:wrap}button,a.button,.actions a{appearance:none;border:1px solid #3d5d7e;background:#162c47;color:var(--text);padding:8px 11px;border-radius:9px;text-decoration:none;cursor:pointer;font-weight:700;font:inherit}.actions a{color:#cce7ff}button:hover,a.button:hover,.actions a:hover{border-color:var(--accent2);transform:translateY(-1px)}button.copied{border-color:var(--accent);color:var(--accent)}
    .steps{counter-reset:item;margin:0;padding:0;list-style:none}.steps li{counter-increment:item;position:relative;padding:0 0 15px 42px}.steps li:before{content:counter(item);position:absolute;left:0;top:0;width:27px;height:27px;border-radius:50%;display:grid;place-items:center;background:#193e52;color:var(--accent);font-weight:900}.steps li:last-child{padding-bottom:0}.note{border-left:3px solid var(--danger);background:#2a241d;padding:12px 14px;border-radius:8px;color:#f6d7af}.commands{display:grid;gap:9px}.command{display:flex;align-items:center;gap:10px;background:#091523;border:1px solid var(--line);border-radius:10px;padding:10px}.command code{flex:1;overflow-wrap:anywhere}.links-list{max-height:450px;overflow:auto;padding-right:5px}details{border-top:1px solid var(--line);padding:14px 0}details:first-of-type{border-top:0}summary{cursor:pointer;font-weight:800;color:#d8eaff}.footer{color:var(--muted);font-size:13px;margin-top:22px;text-align:center}
    @media(max-width:800px){.half{grid-column:span 12}.top{display:block}.privacy{display:inline-block;margin-top:16px}.data-row{grid-template-columns:1fr}.actions{justify-content:flex-start}}
  </style>
</head>
<body><main class="wrap">
  <header class="top"><div><div class="eyebrow">Private local dashboard</div><h1 class="title">3X-UI: карточка сервера</h1><p class="lead">Данные встроены в этот автономный HTML-файл. Страница не загружает шрифты, скрипты, аналитику или другие ресурсы из интернета.</p></div><div class="privacy">● Только локально</div></header>
  <section class="grid">
    <article class="card"><h2>Доступ к панели</h2>
HTML_HEAD
        dashboard_value_row "URL панели" "$panel_url" true
        dashboard_value_row "Логин" "$panel_user"
        dashboard_value_row "Пароль" "$panel_password"
        dashboard_value_row "API-ключ" "$api_token"
        cat <<'HTML_SUBS'
    </article>
    <article class="card"><h2>Подписки</h2>
HTML_SUBS
        dashboard_value_row "Основная" "$subscription" true
        dashboard_value_row "JSON" "$subscription_json" true
        dashboard_value_row "Clash" "$subscription_clash" true
        cat <<'HTML_GUIDE'
    </article>
    <article class="card half"><h2>Краткая настройка</h2><ol class="steps">
      <li>Скопируйте основную ссылку подписки и импортируйте её в приложение.</li>
      <li>Обновите подписку в клиенте и сначала проверьте профили <strong>#1</strong> и <strong>#2</strong>.</li>
      <li>Если TCP ограничен, проверьте Hysteria2 <strong>#5</strong>; для совместимости также доступны Trojan TLS и Shadowsocks.</li>
      <li>Сохраните эту страницу в защищённом месте: она содержит пароль и API-ключ.</li>
    </ol></article>
    <article class="card half"><h2>Основные команды</h2><div class="commands">
      <div class="command"><code>sudo dns</code><button data-copy="sudo dns" onclick="copyValue(this)">Копировать</button></div>
      <div class="command"><code>sudo dns settings</code><button data-copy="sudo dns settings" onclick="copyValue(this)">Копировать</button></div>
      <div class="command"><code>sudo dns panel-update</code><button data-copy="sudo dns panel-update" onclick="copyValue(this)">Копировать</button></div>
      <div class="command"><code>sudo dns recreate-inbounds</code><button data-copy="sudo dns recreate-inbounds" onclick="copyValue(this)">Копировать</button></div>
      <div class="command"><code>sudo dns repair</code><button data-copy="sudo dns repair" onclick="copyValue(this)">Копировать</button></div>
    </div></article>
    <article class="card"><h2>Полная инструкция</h2>
      <details open><summary>1. Вход и безопасность</summary><p>Откройте URL панели, войдите указанными выше данными и сохраните пароль в менеджере паролей. Не публикуйте этот HTML-файл и не размещайте его в общедоступном web-root.</p></details>
      <details><summary>2. Подключение клиента</summary><p>Используйте основную подписку для v2rayN/v2rayNG и совместимых клиентов. JSON и Clash применяйте только в клиентах, поддерживающих соответствующий формат. После импорта обновите подписку и проверьте несколько разных технологий.</p></details>
      <details><summary>3. Выбор профиля</summary><p>#1 — VLESS + REALITY + Vision, #2 — VLESS + XHTTP + TLS, #3 — Trojan + TLS, #4 — Shadowsocks, #5 — Hysteria2. Доступность зависит от поддержки протокола в клиенте и сети оператора.</p></details>
      <details><summary>4. Обслуживание</summary><p><code>sudo dns panel-update</code> обновляет панель с резервной копией базы. <code>sudo dns add-inbounds</code> добавляет отсутствующие профили, не удаляя существующих клиентов. <code>sudo dns recreate-inbounds</code> после явного подтверждения предлагает новое имя и формат примечаний и пересоздаёт только управляемые профили; их порты, клиенты и ссылки изменятся. <code>sudo dns repair</code> повторяет проверки и восстанавливает управляемую конфигурацию.</p></details>
      <details><summary>5. Диагностика</summary><p>Журнал установщика: <code>/root/3x-ui-bootstrap/install.log</code>. Сервис: <code>systemctl status x-ui --no-pager</code>. Журнал панели: <code>journalctl -u x-ui -n 100 --no-pager</code>.</p></details>
      <p class="note">Кнопка «Открыть» выполняет переход только после вашего нажатия. Сама страница не отправляет данные наружу.</p>
    </article>
    <article class="card"><h2>Прямые ссылки подключений</h2><div class="links-list">
HTML_GUIDE
        if [[ -r "${RESULT_DIR}/links.txt" ]]; then
            while IFS= read -r link; do
                [[ "$link" == *://* ]] || continue
                ((link_number+=1))
                dashboard_value_row "Профиль ${link_number}" "$link"
            done < "${RESULT_DIR}/links.txt"
        fi
        (( link_number > 0 )) || printf '<p class="lead">Прямые ссылки пока отсутствуют. Используйте подписку выше.</p>\n'
        cat <<HTML_FOOT
    </div></article>
  </section>
  <div class="footer">Сгенерировано локально: $(html_escape "$generated") · Installer $(html_escape "$INSTALLER_VERSION") · Файл доступен только root</div>
</main>
<script>
async function copyValue(button){
  const value=button.dataset.copy||'';
  try{if(navigator.clipboard&&window.isSecureContext){await navigator.clipboard.writeText(value);}else{const t=document.createElement('textarea');t.value=value;t.style.position='fixed';t.style.opacity='0';document.body.appendChild(t);t.select();document.execCommand('copy');t.remove();}button.classList.add('copied');const old=button.textContent;button.textContent='Скопировано';setTimeout(()=>{button.textContent=old;button.classList.remove('copied');},1200);}catch(e){button.textContent='Не удалось';}
}
</script></body></html>
HTML_FOOT
    } > "$DASHBOARD_FILE"
    chmod 600 "$DASHBOARD_FILE"
    ok "Private local dashboard generated: ${DASHBOARD_FILE}"
}

serve_local_dashboard() {
    local port="$DASHBOARD_PORT" public_ip
    require_integer DASHBOARD_PORT "$port"
    (( port >= 1024 && port <= 65535 )) || die "DASHBOARD_PORT must be between 1024 and 65535"
    command -v python3 >/dev/null 2>&1 || die "python3 is required for the local dashboard server"
    port_is_listening tcp "$port" && die "Local dashboard port ${port} is already in use; choose another DASHBOARD_PORT"
    [[ -r "$DASHBOARD_FILE" ]] || generate_local_dashboard || die "Could not generate the local dashboard"
    public_ip="$(root_env_value "${RESULT_DIR}/result.env" PUBLIC_IPV4 || true)"
    printf '\nЛокальная страница готова: http://127.0.0.1:%s/\n' "$port"
    printf 'Она слушает только 127.0.0.1 и не публикуется в интернете.\n\n'
    if [[ -n "$public_ip" ]]; then
        printf 'На своём компьютере создайте SSH-туннель:\n'
        printf '  ssh -L %s:127.0.0.1:%s root@%s\n' "$port" "$port" "$public_ip"
        printf 'Затем откройте в браузере: http://127.0.0.1:%s/\n\n' "$port"
    fi
    printf 'Остановить локальный сервер: Ctrl+C\n'
    python3 - "$port" "$DASHBOARD_FILE" <<'PY'
import http.server
import pathlib
import sys

port = int(sys.argv[1])
page = pathlib.Path(sys.argv[2]).read_bytes()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] not in ("/", "/dashboard.html"):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, fmt, *args):
        return

http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
}

present_dashboard() {
    local public_ip
    public_ip="$(root_env_value "${RESULT_DIR}/result.env" PUBLIC_IPV4 || true)"
    printf '\nЛОКАЛЬНАЯ ВЕБ-СТРАНИЦА\n'
    printf '%s\n' '------------------------------------------------------------'
    printf 'Файл: %s\n' "$DASHBOARD_FILE"
    printf '1. На сервере: sudo dns web\n'
    if [[ -n "$public_ip" ]]; then
        printf '2. На своём компьютере, во втором терминале: ssh -L %s:127.0.0.1:%s root@%s\n' \
            "$DASHBOARD_PORT" "$DASHBOARD_PORT" "$public_ip"
        printf '3. В браузере: http://127.0.0.1:%s/\n' "$DASHBOARD_PORT"
    fi
    printf 'Страница не публикуется во внешнюю сеть.\n'
    if [[ -n "${DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
        xdg-open "file://${DASHBOARD_FILE}" >/dev/null 2>&1 || true
    fi
}

print_access_after_panel_update() {
    [[ "$PANEL_UPDATE" == "true" ]] || return 0
    printf '\nАКТУАЛЬНЫЙ ДОСТУП ПОСЛЕ ОБНОВЛЕНИЯ ПАНЕЛИ\n'
    printf '%s\n' '------------------------------------------------------------'
    sed -n '3,$p' "${RESULT_DIR}/access-after-panel-update.txt"
    printf 'Сохранено: %s/access-after-panel-update.txt\n' "$RESULT_DIR"
}

save_summary() {
    local row status remark proto port test_result
    {
        printf '3X-UI Universal RU Installer v%s\n' "$INSTALLER_VERSION"
        printf 'Generated: %s\n\n' "$(timestamp)"
        printf 'Panel: %s\nXray: %s\nIPv4: %s\nIPv6: %s\n\n' "$PANEL_VERSION" "$XRAY_VERSION" "${PUBLIC_IPV4:-unavailable}" "${PUBLIC_IPV6:-unavailable}"
        printf 'SERVER CONFIGURATION VERIFIED per-profile below.\n'
        printf 'RUSSIAN NETWORK ACCESS NOT VERIFIED.\n\n'
        printf '%-9s %-46s %-14s %-6s %s\n' STATUS PROFILE PROTOCOL PORT TEST
        for row in "${RESULT_ROWS[@]}"; do
            IFS='|' read -r status remark proto port test_result <<<"$row"
            printf '%-9s %-46s %-14s %-6s %s\n' "$status" "$remark" "$proto" "$port" "$test_result"
        done
        printf '\nCreated: %d\nPassed: %d\nFailed: %d\nSkipped: %d\n' "$CREATED_COUNT" "$PASSED_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT"
    } > "${RESULT_DIR}/summary.txt"
    chmod 600 "${RESULT_DIR}/summary.txt"
}

secure_result_files() {
    find "$RESULT_DIR" -maxdepth 1 -type f -exec chmod 600 {} +
    chmod 700 "$RESULT_DIR" "$RESULT_DIR/backups" "$RESULT_DIR/certs"
}

print_summary() {
    local scheme panel_host panel_url row status remark proto port test_result
    scheme=http; [[ "${XUI_ACCESS_URL:-}" == https://* ]] && scheme=https
    panel_host="$SHARE_HOST"; [[ "$panel_host" == *:* && "$panel_host" != \[*\] ]] && panel_host="[${panel_host}]"
    panel_url="${scheme}://${panel_host}:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}"
    printf '\n============================================================\n'
    printf '             3X-UI INSTALLATION COMPLETE\n'
    printf '============================================================\n\n'
    printf 'SERVER\n------------------------------------------------------------\n'
    printf 'IPv4:       %s\nIPv6:       %s\n\n' "${PUBLIC_IPV4:-unavailable}" "${PUBLIC_IPV6:-unavailable}"
    printf '3X-UI PANEL\n------------------------------------------------------------\n'
    printf 'URL:        %s\nUsername:   %s\nPassword:   %s\nAPI key:    %s\n\n' "$panel_url" "$XUI_USERNAME" "$XUI_PASSWORD" "$XUI_API_TOKEN"
    printf 'SUBSCRIPTION\n------------------------------------------------------------\n%s\n\n' "$SUBSCRIPTION_URL"
    printf 'CONNECTIONS\n------------------------------------------------------------\n'
    for row in "${RESULT_ROWS[@]}"; do
        IFS='|' read -r status remark proto port test_result <<<"$row"
        printf '[%-7s] %-43s %s/%s  %s\n' "$status" "$remark" "$proto" "$port" "$test_result"
    done
    printf '\nTEST RESULTS\n------------------------------------------------------------\n'
    printf 'Server configuration: per-profile above\nRussian network access: NOT VERIFIED\n'
    printf 'Created: %d  Passed: %d  Failed: %d  Skipped: %d\n\n' "$CREATED_COUNT" "$PASSED_COUNT" "$FAILED_COUNT" "$SKIPPED_COUNT"
    printf 'FILES\n------------------------------------------------------------\n'
    printf 'Credentials:    %s/result.env\n' "$RESULT_DIR"
    printf 'Links:          %s/links.txt\n' "$RESULT_DIR"
    printf 'XHTTP:          %s/xhttp-links.txt\n' "$RESULT_DIR"
    printf 'Subscriptions:  %s/subscriptions.txt\n' "$RESULT_DIR"
    printf 'Compatibility:  %s/client-compatibility.txt\n' "$RESULT_DIR"
    printf 'Diagnostics:    %s/russia-diagnostics.txt\n' "$RESULT_DIR"
    printf '============================================================\n'
}

mandatory_profiles_passed() {
    local required row suffix expected prefix="RU"
    [[ "$REGION_PROFILE" == "GENERIC" ]] && prefix="GENERIC"
    required=$'01-VLESS-REALITY-VISION\n02-VLESS-XHTTP-TLS\n03-TROJAN-TLS\n04-SHADOWSOCKS\n05-HYSTERIA2'
    while IFS= read -r suffix; do
        expected="$(inbound_remark "${prefix}-${suffix}")"
        local found=false
        for row in "${RESULT_ROWS[@]}"; do
            [[ "$row" == "PASS|${expected}|"* ]] && { found=true; break; }
        done
        [[ "$found" == true ]] || return 1
    done <<<"$required"
    return 0
}

main() {
    parse_args "$@"
    check_root
    auto_update_manager_on_start
    if [[ "$MANAGER_UPDATED" == "true" ]]; then
        exec "$MANAGER_PATH" "$@"
    fi
    if running_as_installed_manager; then install_dns_shortcut || true; fi
    [[ "$ACTION" == "manage" ]] && management_menu
    case "$ACTION" in
        settings) show_installed_settings; exit 0 ;;
        web) serve_local_dashboard; exit 0 ;;
        check-update)
            if print_update_status true; then exit 0; else exit 1; fi
            ;;
        update) update_manager_command manual; exit 0 ;;
        uninstall) uninstall_completely; exit 0 ;;
        panel-update)
            require_existing_panel
            confirm_panel_update
            PANEL_UPDATE="true"
            FORCE_REINSTALL="true"
            INSTALLER_NONINTERACTIVE="true"
            load_manager_config
            source_root_env "$INSTALL_RESULT" || true
            XUI_VERSION=""
            ;;
        add-inbounds)
            require_active_panel
            INBOUNDS_ONLY="true"
            load_manager_config
            ;;
        recreate-inbounds)
            require_active_panel
            confirm_recreate_inbounds
            INBOUNDS_ONLY="true"
            RECREATE_INBOUNDS="true"
            load_manager_config
            RECREATE_OLD_INBOUND_NAME="$XUI_INBOUND_NAME"
            RECREATE_OLD_REMARK_MODE="$XUI_INBOUND_REMARK_MODE"
            RECREATE_OLD_REGION_PROFILE="$REGION_PROFILE"
            ;;
        reinstall)
            confirm_reinstall
            FORCE_REINSTALL="true"
            INSTALLER_NONINTERACTIVE="true"
            load_manager_config
            source_root_env "$INSTALL_RESULT" || true
            ;;
        reinstall-clean)
            prepare_clean_reinstall
            ;;
        repair)
            INSTALLER_NONINTERACTIVE="true"
            load_manager_config
            ;;
        install) ;;
        *) die "Unknown action: ${ACTION}" ;;
    esac
    info "3X-UI Universal RU Installer v${INSTALLER_VERSION}"
    select_interactive_mode
    if [[ "$RECREATE_INBOUNDS" == "true" ]]; then
        if [[ "$INTERACTIVE_MODE" == "true" ]]; then
            interactive_inbound_naming
        else
            [[ -z "$RECREATE_INBOUND_NAME_OVERRIDE" ]] || XUI_INBOUND_NAME="$RECREATE_INBOUND_NAME_OVERRIDE"
            [[ -z "$RECREATE_REMARK_MODE_OVERRIDE" ]] || XUI_INBOUND_REMARK_MODE="$RECREATE_REMARK_MODE_OVERRIDE"
            info "Non-interactive recreation will use the supplied or saved inbound naming"
        fi
    elif [[ "$INBOUNDS_ONLY" == "true" ]]; then
        interactive_add_inbounds_configuration
    else
        interactive_configuration
    fi
    if [[ "$CLEAN_REINSTALL_PENDING" == "true" ]]; then
        execute_clean_reinstall
    fi
    initialize_result_dir
    setup_quiet_output
    show_progress 2
    validate_environment
    show_progress 5
    detect_os
    detect_arch
    show_progress 10
    install_dependencies
    check_resource_limits
    show_progress 20
    detect_public_ipv4
    detect_public_ipv6
    normalize_server_host
    [[ -n "$XUI_DOMAIN" || -n "$PUBLIC_IPV4" ]] || die "A public IPv4 address is required for Let's Encrypt IP certificates"
    detect_webserver
    prepare_acme_firewall
    show_progress 28
    install_3xui
    show_progress 40
    load_install_result
    wait_for_panel
    show_progress 46
    test_api
    reserve_existing_inbound_ports || warn "Could not reserve every existing inbound port"
    detect_3xui_capabilities
    show_progress 52
    backup_existing_config
    delete_managed_inbounds_for_recreation
    load_or_create_state
    find_xray_binary
    configure_tls
    show_progress 60
    optimize_udp_buffers
    configure_bbr
    show_progress 66
    create_profiles
    show_progress 84
    configure_subscription_server || true
    show_progress 89
    configure_firewall
    verify_subscription || true
    show_progress 93
    collect_links
    decode_amneziawg_config || true
    write_subscriptions
    generate_client_compatibility_report
    generate_russia_diagnostics
    show_progress 96
    save_result_env
    save_access_report
    generate_local_dashboard || true
    save_summary
    secure_result_files
    save_manager_config
    install_manager_command
    show_progress 100
    restore_console_output
    print_summary
    print_access_after_panel_update
    present_dashboard
    if ! mandatory_profiles_passed; then
        printf 'Mandatory core profiles did not all pass. See %s/failed-inbounds.json\n' "$RESULT_DIR" >&2
        exit 2
    fi
}

dispatch_product() {
    local product="${INSTALLER_PRODUCT:-auto}" arg remnawave_script="" choice="" staged="" checksum_file=""
    local expected_hash="" actual_hash="" rc=0
    local -a forwarded=()
    while (( $# > 0 )); do
        arg="$1"
        case "$arg" in
            --product)
                (( $# >= 2 )) || die "--product requires 3x-ui or remnawave"
                product="$2"; shift 2; continue
                ;;
            --product=*) product="${arg#*=}" ;;
            remnawave) product="remnawave" ;;
            *) forwarded+=("$arg") ;;
        esac
        shift
    done
    product="$(printf '%s' "$product" | tr '[:upper:]' '[:lower:]')"
    if [[ "$product" == auto ]]; then
        if (( ${#forwarded[@]} == 0 )) && tty_available && ! is_true "$INSTALLER_NONINTERACTIVE"; then
            printf '\nС какой панелью работаем?\n  1) 3X-UI\n  2) Remnawave\n' >/dev/tty
            prompt_line choice "Выбор" 1
            case "$choice" in 1) product="3x-ui" ;; 2) product="remnawave" ;; *) die "Unknown product choice" ;; esac
        else
            product="3x-ui"
        fi
    fi
    case "$product" in
        3x-ui|3xui|x-ui) main "${forwarded[@]}" ;;
        remnawave|remna)
            for remnawave_script in \
                "${REMNAWAVE_SCRIPT:-}" \
                "$(dirname -- "${BASH_SOURCE[0]}")/remnawave-manager.sh" \
                "$REMNAWAVE_INSTALLED_PATH"; do
                [[ -n "$remnawave_script" && -f "$remnawave_script" ]] || continue
                exec bash "$remnawave_script" "${forwarded[@]}"
            done
            command -v curl >/dev/null 2>&1 || die "remnawave-manager.sh is absent and curl is unavailable"
            staged="$(mktemp /tmp/remnawave-manager.XXXXXX)"
            checksum_file="$(mktemp /tmp/remnawave-manager-sha256.XXXXXX)"
            if ! curl -fsSL --proto '=https' --tlsv1.2 "$REMNAWAVE_DOWNLOAD_URL" -o "$staged" || \
               ! curl -fsSL --proto '=https' --tlsv1.2 "$REMNAWAVE_CHECKSUM_URL" -o "$checksum_file"; then
                rm -f -- "$staged" "$checksum_file"
                die "Failed to download the Remnawave companion and its checksum"
            fi
            expected_hash="$(awk '$2 == "remnawave-manager.sh" || $2 == "*remnawave-manager.sh" {print $1; exit}' "$checksum_file")"
            [[ "$expected_hash" =~ ^[a-fA-F0-9]{64}$ ]] || {
                rm -f -- "$staged" "$checksum_file"
                die "Published Remnawave checksum has an invalid format"
            }
            if command -v sha256sum >/dev/null 2>&1; then
                actual_hash="$(sha256sum "$staged" | awk '{print $1}')"
            elif command -v shasum >/dev/null 2>&1; then
                actual_hash="$(shasum -a 256 "$staged" | awk '{print $1}')"
            else
                rm -f -- "$staged" "$checksum_file"
                die "sha256sum or shasum is required to verify the Remnawave companion"
            fi
            [[ "$actual_hash" == "$expected_hash" ]] || {
                rm -f -- "$staged" "$checksum_file"
                die "Remnawave companion checksum mismatch"
            }
            bash -n "$staged" || {
                rm -f -- "$staged" "$checksum_file"
                die "Downloaded Remnawave companion failed Bash syntax validation"
            }
            rm -f -- "$checksum_file"
            chmod 700 "$staged"
            if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
                install -d -m 755 "$(dirname -- "$REMNAWAVE_INSTALLED_PATH")"
                install -m 700 "$staged" "$REMNAWAVE_INSTALLED_PATH"
                rm -f -- "$staged"
                exec bash "$REMNAWAVE_INSTALLED_PATH" "${forwarded[@]}"
            fi
            bash "$staged" "${forwarded[@]}" || rc=$?
            rm -f -- "$staged"
            exit "$rc"
            ;;
        *) die "INSTALLER_PRODUCT/--product must be 3x-ui or remnawave" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    dispatch_product "$@"
fi
