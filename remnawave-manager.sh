#!/usr/bin/env bash
# Remnawave installer/manager companion for install-3xui-full.sh.
# It follows https://docs.rw/ and deliberately does not hard-code private API payloads.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly REMNAWAVE_MANAGER_VERSION="1.1.0"
readonly PANEL_DIR="${REMNAWAVE_PANEL_DIR:-/opt/remnawave}"
readonly NODE_DIR="${REMNAWAVE_NODE_DIR:-/opt/remnanode}"
readonly CADDY_DIR="${REMNAWAVE_CADDY_DIR:-${PANEL_DIR}/caddy}"
readonly STATE_DIR="${REMNAWAVE_STATE_DIR:-/etc/remnawave-installer}"
readonly STATE_FILE="${STATE_DIR}/config.env"
readonly PANEL_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
readonly PANEL_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"
readonly TEMPLATE_INDEX_URL="https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/xray-core-templates-list.json"
readonly OPENAPI_URL="https://cdn.docs.rw/docs/openapi.json"
readonly WEB_APP_PATH="/usr/local/lib/3xui-installer/remnawave-web.py"
readonly WEB_APP_VERSION="2.2.0"
readonly WEB_APP_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/remnawave-web.py"
readonly WEB_APP_CHECKSUM_URL="https://github.com/thefuckerguy/3xui-installer/releases/latest/download/remnawave-web.py.sha256"
readonly WEB_SERVICE_FILE="/etc/systemd/system/remnawave-node-web.service"
readonly WEB_ENV_FILE="${STATE_DIR}/web.env"
readonly WEB_API_TOKEN_FILE="${STATE_DIR}/web-api-token"
readonly WEB_STATE_DIR="/var/lib/remnawave-web"
readonly WEB_USER="remnawave-web"

ACTION="manage"
PANEL_DOMAIN="${REMNAWAVE_PANEL_DOMAIN:-}"
NODE_COMPOSE_FILE="${REMNAWAVE_NODE_COMPOSE_FILE:-}"
PANEL_SOURCE_CIDR="${REMNAWAVE_PANEL_SOURCE_CIDR:-}"
NONINTERACTIVE="${INSTALLER_NONINTERACTIVE:-auto}"
ADMIN_USERNAME="${REMNAWAVE_ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${REMNAWAVE_ADMIN_PASSWORD:-}"
PROFILE_NAME="${REMNAWAVE_PROFILE_NAME:-Managed-Profile}"
NODE_NAME="${REMNAWAVE_NODE_NAME:-}"
NODE_ADDRESS="${REMNAWAVE_NODE_ADDRESS:-}"
NODE_PORT="${REMNAWAVE_NODE_PORT:-2222}"
WEB_PORT="${REMNAWAVE_WEB_PORT:-8787}"
WEB_API_TOKEN="${REMNAWAVE_API_TOKEN:-}"
SELECTED_TEMPLATE_NAME=""

info() { printf 'INFO: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [[ -z "${TMP_DIR:-}" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Remnawave installer/manager

Usage:
  sudo bash remnawave-manager.sh [command]
  sudo bash install-3xui-full.sh --product remnawave [command]

Commands:
  menu, manage        Interactive management menu (default).
  install             Install/update the Panel and configure Caddy + TLS.
  status              Show containers, health, domain, and useful paths.
  update              Pull and recreate official Panel/Caddy containers.
  profile             Download an official Remnawave Xray template for UI import.
  configure           Create admin/login, Config Profile, node, and Node Compose bundle.
  web-install         Install/start the local node provisioning web console.
  web-url             Print the SSH tunnel command and authenticated local URL.
  web-status          Show web console service status.
  web-stop            Stop the web console service.
  node-guide          Show the safe Panel -> Node creation workflow.
  node-install FILE   Install Panel-generated docker-compose.yml on this node server.
  help                Show this help.

Non-interactive install requires REMNAWAVE_PANEL_DOMAIN.
Node firewall restriction can use REMNAWAVE_PANEL_SOURCE_CIDR (an IP or CIDR).
The web console binds only to 127.0.0.1 and must be opened through an SSH tunnel.
EOF
}

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

tty_available() { [[ -c /dev/tty ]] && (: </dev/tty) 2>/dev/null; }
interactive_mode() {
    if is_true "$NONINTERACTIVE"; then return 1; fi
    if [[ "$(printf '%s' "$NONINTERACTIVE" | tr '[:upper:]' '[:lower:]')" == "false" ]]; then
        tty_available || die "Interactive mode requires a terminal"
        return 0
    fi
    tty_available
}

prompt_line() {
    local __name="$1" label="$2" default="${3:-}" value=""
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$label" "$default" >/dev/tty
    else
        printf '%s: ' "$label" >/dev/tty
    fi
    IFS= read -r value </dev/tty || die "Input interrupted"
    [[ -n "$value" ]] || value="$default"
    printf -v "$__name" '%s' "$value"
}

prompt_yes_no() {
    local __name="$1" label="$2" default="$3" answer=""
    while true; do
        [[ "$default" == "yes" ]] && printf '%s [Y/n]: ' "$label" >/dev/tty || printf '%s [y/N]: ' "$label" >/dev/tty
        IFS= read -r answer </dev/tty || die "Input interrupted"
        answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
        [[ -n "$answer" ]] || answer="$default"
        case "$answer" in
            y|yes|д|да) printf -v "$__name" true; return 0 ;;
            n|no|н|нет) printf -v "$__name" false; return 0 ;;
            *) printf 'Введите y/да или n/нет.\n' >/dev/tty ;;
        esac
    done
}

prompt_secret() {
    local __name="$1" label="$2" value="" tty_state
    printf '%s: ' "$label" >/dev/tty
    tty_state="$(stty -g </dev/tty)" || die "Cannot read terminal settings"
    stty -echo </dev/tty
    if ! IFS= read -r value </dev/tty; then
        stty "$tty_state" </dev/tty || true
        die "Input interrupted"
    fi
    stty "$tty_state" </dev/tty || true
    printf '\n' >/dev/tty
    printf -v "$__name" '%s' "$value"
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+([A-Za-z]{2,}|xn--[A-Za-z0-9-]{2,})$ ]]
}

check_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)"; }

require_commands() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
    done
}

install_base_dependencies() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl
    else
        require_commands curl jq openssl
    fi
}

install_docker_if_needed() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then return 0; fi
    require_commands curl
    TMP_DIR="$(mktemp -d /tmp/remnawave-docker.XXXXXX)"
    curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o "${TMP_DIR}/get-docker.sh"
    [[ -s "${TMP_DIR}/get-docker.sh" ]] || die "Docker installer download is empty"
    sh "${TMP_DIR}/get-docker.sh"
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable after installation"
}

set_env_value() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v wanted="$key" -v replacement="$value" '
        BEGIN { found=0 }
        $0 ~ "^" wanted "=" { print wanted "=" replacement; found=1; next }
        { print }
        END { if (!found) print wanted "=" replacement }
    ' "$file" >"$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f -- "$tmp" "$file"
}

load_state() {
    [[ -r "$STATE_FILE" ]] || return 0
    local line key value
    while IFS= read -r line; do
        [[ "$line" =~ ^[A-Z0-9_]+= ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in PANEL_DOMAIN) PANEL_DOMAIN="$value" ;; esac
    done <"$STATE_FILE"
}

save_state() {
    install -d -m 700 "$STATE_DIR"
    printf 'PANEL_DOMAIN=%s\n' "$PANEL_DOMAIN" >"$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

resolve_domain() {
    load_state
    if interactive_mode; then
        while true; do
            prompt_line PANEL_DOMAIN "Домен панели (A/AAAA уже указывает на VPS)" "$PANEL_DOMAIN"
            PANEL_DOMAIN="$(printf '%s' "$PANEL_DOMAIN" | tr '[:upper:]' '[:lower:]')"
            valid_domain "$PANEL_DOMAIN" && break
            printf 'Некорректный домен. Пример: panel.example.com\n' >/dev/tty
        done
    fi
    valid_domain "$PANEL_DOMAIN" || die "Set REMNAWAVE_PANEL_DOMAIN to a valid domain"
    if ! getent ahosts "$PANEL_DOMAIN" >/dev/null 2>&1; then
        die "${PANEL_DOMAIN} does not resolve yet; create A/AAAA records before installation"
    fi
}

port_available() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then return 1; fi
        return 0
    else
        return 0
    fi
}

prepare_panel_files() {
    local postgres_password
    install -d -m 700 "$PANEL_DIR"
    if [[ -e "${PANEL_DIR}/docker-compose.yml" || -e "${PANEL_DIR}/.env" ]]; then
        [[ -s "${PANEL_DIR}/docker-compose.yml" && -s "${PANEL_DIR}/.env" ]] || \
            die "Partial installation exists in ${PANEL_DIR}; repair it manually before retrying"
        info "Existing Panel files found; preserving local configuration"
        return 0
    fi
    curl -fsSL --proto '=https' --tlsv1.2 "$PANEL_COMPOSE_URL" -o "${PANEL_DIR}/docker-compose.yml"
    curl -fsSL --proto '=https' --tlsv1.2 "$PANEL_ENV_URL" -o "${PANEL_DIR}/.env"
    chmod 600 "${PANEL_DIR}/.env"
    postgres_password="$(openssl rand -hex 24)"
    set_env_value "${PANEL_DIR}/.env" APP_SECRET "$(openssl rand -hex 64)"
    set_env_value "${PANEL_DIR}/.env" METRICS_PASS "$(openssl rand -hex 32)"
    set_env_value "${PANEL_DIR}/.env" WEBHOOK_SECRET_HEADER "$(openssl rand -hex 32)"
    set_env_value "${PANEL_DIR}/.env" POSTGRES_PASSWORD "$postgres_password"
    set_env_value "${PANEL_DIR}/.env" DATABASE_URL "\"postgresql://postgres:${postgres_password}@remnawave-db:5432/postgres\""
    set_env_value "${PANEL_DIR}/.env" PANEL_DOMAIN "$PANEL_DOMAIN"
    set_env_value "${PANEL_DIR}/.env" FRONT_END_DOMAIN "$PANEL_DOMAIN"
    set_env_value "${PANEL_DIR}/.env" SUB_PUBLIC_DOMAIN "${PANEL_DOMAIN}/api/sub"
}

prepare_caddy_files() {
    install -d -m 700 "$CADDY_DIR"
    if [[ ! -f "${CADDY_DIR}/Caddyfile" ]]; then
        sed "s/REPLACE_WITH_YOUR_DOMAIN/${PANEL_DOMAIN}/g" >"${CADDY_DIR}/Caddyfile" <<'EOF'
https://REPLACE_WITH_YOUR_DOMAIN {
    encode
    reverse_proxy * http://remnawave:3000
}

:443 {
    tls internal
    respond 204
}
EOF
    fi
    if [[ ! -f "${CADDY_DIR}/docker-compose.yml" ]]; then
        install -m 600 /dev/null "${CADDY_DIR}/docker-compose.yml"
        printf '%s\n' \
            'services:' \
            '  caddy:' \
            '    image: caddy:2.9' \
            '    container_name: caddy' \
            '    hostname: caddy' \
            '    restart: always' \
            '    ports:' \
            "      - '0.0.0.0:80:80'" \
            "      - '0.0.0.0:443:443'" \
            '    networks:' \
            '      - remnawave-network' \
            '    volumes:' \
            '      - ./Caddyfile:/etc/caddy/Caddyfile:ro' \
            '      - caddy-ssl-data:/data' \
            'networks:' \
            '  remnawave-network:' \
            '    name: remnawave-network' \
            '    external: true' \
            'volumes:' \
            '  caddy-ssl-data:' \
            '    name: caddy-ssl-data' >"${CADDY_DIR}/docker-compose.yml"
    fi
}

wait_for_panel() {
    local attempt
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if curl -fsS http://127.0.0.1:3001/health >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    docker compose --project-directory "$PANEL_DIR" logs --tail 80 >&2 || true
    die "Panel health endpoint did not become ready"
}

install_panel() {
    local proceed=true
    resolve_domain
    if interactive_mode; then
        printf '\nБудут установлены Remnawave Panel, PostgreSQL, Valkey и Caddy.\n' >/dev/tty
        printf 'Caddy займёт TCP 80/443 и автоматически выпустит TLS-сертификат.\n' >/dev/tty
        prompt_yes_no proceed "Продолжить?" yes
        [[ "$proceed" == true ]] || exit 0
    fi
    install_base_dependencies
    install_docker_if_needed
    if [[ ! -f "${CADDY_DIR}/docker-compose.yml" ]]; then
        port_available 80 || die "TCP port 80 is already occupied"
        port_available 443 || die "TCP port 443 is already occupied"
    fi
    prepare_panel_files
    docker compose --project-directory "$PANEL_DIR" config --quiet
    docker compose --project-directory "$PANEL_DIR" pull
    docker compose --project-directory "$PANEL_DIR" up -d
    wait_for_panel
    prepare_caddy_files
    docker compose --project-directory "$CADDY_DIR" config --quiet
    docker compose --project-directory "$CADDY_DIR" pull
    docker compose --project-directory "$CADDY_DIR" up -d
    save_state
    ok "Remnawave Panel is running: https://${PANEL_DOMAIN}"
    printf '\nОткройте https://%s и создайте первого super-admin.\n' "$PANEL_DOMAIN"
    printf 'Затем запустите: sudo bash %s profile\n' "${BASH_SOURCE[0]}"
}

panel_status() {
    load_state
    printf 'Remnawave manager: %s\n' "$REMNAWAVE_MANAGER_VERSION"
    printf 'Panel domain:      %s\n' "${PANEL_DOMAIN:-not configured}"
    printf 'Panel directory:   %s\n' "$PANEL_DIR"
    printf 'Node directory:    %s\n\n' "$NODE_DIR"
    if command -v docker >/dev/null 2>&1; then
        docker ps --filter 'name=remnawave' --filter 'name=caddy' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    else
        printf 'Docker is not installed.\n'
    fi
    curl -fsS http://127.0.0.1:3001/health 2>/dev/null && printf '\nLocal health: PASS\n' || printf '\nLocal health: unavailable\n'
}

update_panel() {
    [[ -s "${PANEL_DIR}/docker-compose.yml" && -s "${PANEL_DIR}/.env" ]] || die "Panel is not installed in ${PANEL_DIR}"
    docker compose --project-directory "$PANEL_DIR" pull
    docker compose --project-directory "$PANEL_DIR" up -d --remove-orphans
    if [[ -s "${CADDY_DIR}/docker-compose.yml" ]]; then
        docker compose --project-directory "$CADDY_DIR" pull
        docker compose --project-directory "$CADDY_DIR" up -d --remove-orphans
    fi
    wait_for_panel
    ok "Panel containers were updated and are healthy"
}

download_profile_template() {
    local index choice count selected_url selected_name output_dir output_file
    require_commands curl jq
    TMP_DIR="$(mktemp -d /tmp/remnawave-profile.XXXXXX)"
    index="${TMP_DIR}/templates.json"
    curl -fsSL --proto '=https' --tlsv1.2 "$TEMPLATE_INDEX_URL" -o "$index"
    jq -e '.templates | type == "array" and length > 0' "$index" >/dev/null || die "Official template catalog has an unexpected format"
    count="$(jq '.templates | length' "$index")"
    printf 'Официальные/каталожные Xray-шаблоны Remnawave:\n'
    jq -r '.templates | to_entries[] | "  \(.key + 1)) \(.value.name) — \(.value.author)"' "$index"
    if interactive_mode; then
        prompt_line choice "Номер шаблона" 1
    else
        choice="${REMNAWAVE_TEMPLATE_NUMBER:-1}"
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then die "Template number must be 1..${count}"; fi
    selected_url="$(jq -r --argjson index "$((choice - 1))" '.templates[$index].url' "$index")"
    selected_name="$(jq -r --argjson index "$((choice - 1))" '.templates[$index].name' "$index")"
    [[ "$selected_url" == https://raw.githubusercontent.com/remnawave/templates/* ]] || die "Template URL is outside the official remnawave/templates repository"
    output_dir="${PANEL_DIR}/imports"
    output_file="${output_dir}/xray-template-$(date +%Y%m%d-%H%M%S).json"
    install -d -m 700 "$output_dir"
    curl -fsSL --proto '=https' --tlsv1.2 "$selected_url" -o "$output_file"
    jq -e 'type == "object" and (.inbounds | type == "array")' "$output_file" >/dev/null || die "Downloaded template is not a valid Xray profile"
    chmod 600 "$output_file"
    ok "Downloaded: ${selected_name}"
    printf 'File: %s\n\n' "$output_file"
    printf 'В панели: Config Profiles -> Create Config Profile -> Load from file/GitHub.\n'
    printf 'После импорта проверьте порты/SNI, сохраните профиль и включите его inbound в Internal Squad.\n'
    printf 'Скрипт не отправляет API payload: импорт выполняет сама панель актуальной версии.\n'
}

fetch_official_template() {
    local output_file="$1" index choice count selected_url
    index="${TMP_DIR}/templates.json"
    curl -fsSL --proto '=https' --tlsv1.2 "$TEMPLATE_INDEX_URL" -o "$index"
    jq -e '.templates | type == "array" and length > 0' "$index" >/dev/null || die "Official template catalog has an unexpected format"
    count="$(jq '.templates | length' "$index")"
    printf 'Официальные/каталожные Xray-шаблоны Remnawave:\n'
    jq -r '.templates | to_entries[] | "  \(.key + 1)) \(.value.name) — \(.value.author)"' "$index"
    if interactive_mode; then
        prompt_line choice "Номер шаблона" "${REMNAWAVE_TEMPLATE_NUMBER:-1}"
    else
        choice="${REMNAWAVE_TEMPLATE_NUMBER:-1}"
    fi
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then die "Template number must be 1..${count}"; fi
    selected_url="$(jq -r --argjson index "$((choice - 1))" '.templates[$index].url' "$index")"
    SELECTED_TEMPLATE_NAME="$(jq -r --argjson index "$((choice - 1))" '.templates[$index].name' "$index")"
    [[ "$selected_url" == https://raw.githubusercontent.com/remnawave/templates/* ]] || die "Template URL is outside the official remnawave/templates repository"
    curl -fsSL --proto '=https' --tlsv1.2 "$selected_url" -o "$output_file"
    jq -e 'type == "object" and (.inbounds | type == "array") and (.inbounds | length > 0)' "$output_file" >/dev/null || \
        die "Downloaded template is not a valid Xray profile with inbounds"
}

api_request() {
    local method="$1" path="$2" token="$3" payload_file="$4" output_file="$5" status header_file
    local -a args
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d /tmp/remnawave-api.XXXXXX)"
    header_file="$(mktemp "${TMP_DIR}/headers.XXXXXX")"
    printf 'Accept: application/json\n' >"$header_file"
    [[ -z "$token" ]] || printf 'Authorization: Bearer %s\n' "$token" >>"$header_file"
    chmod 600 "$header_file"
    args=(-sS -o "$output_file" -w '%{http_code}' -X "$method" "http://127.0.0.1:3000${path}" -H "@${header_file}")
    if [[ -n "$payload_file" ]]; then args+=(-H 'Content-Type: application/json' --data-binary "@${payload_file}"); fi
    status="$(curl "${args[@]}")" || { rm -f -- "$header_file"; die "API request failed: ${method} ${path}"; }
    rm -f -- "$header_file"
    printf '%s' "$status"
}

configure_profile_and_node() {
    local template_file openapi_file auth_payload response_file status access_token profile_payload profile_uuid
    local inbounds_file squad_name squad_payload squad_uuid key_file secret_key node_payload node_uuid bundle_dir bundle_file safe_node_name
    require_commands curl jq
    curl -fsS http://127.0.0.1:3001/health >/dev/null || die "Local Remnawave Panel is not healthy"
    TMP_DIR="$(mktemp -d /tmp/remnawave-configure.XXXXXX)"
    openapi_file="${TMP_DIR}/openapi.json"
    curl -fsSL --proto '=https' --tlsv1.2 "$OPENAPI_URL" -o "$openapi_file"
    jq -e '
        .openapi and
        .paths["/api/auth/register"].post and
        .paths["/api/auth/login"].post and
        .paths["/api/config-profiles"].post and
        .paths["/api/internal-squads"].post and
        .paths["/api/keygen"].get and
        .paths["/api/nodes"].post and
        (.components.schemas.CreateConfigProfileBodyDto.required | contains(["name", "config"])) and
        (.components.schemas.CreateInternalSquadBodyDto.required | contains(["name", "inbounds"])) and
        (.components.schemas.CreateNodeBodyDto.required | contains(["name", "address", "configProfile"]))
    ' "$openapi_file" >/dev/null || die "Live Remnawave OpenAPI is incompatible with this automation; use profile + node-guide fallback"
    template_file="${TMP_DIR}/profile.json"
    fetch_official_template "$template_file"

    if interactive_mode; then
        prompt_line ADMIN_USERNAME "Логин super-admin" "$ADMIN_USERNAME"
        prompt_secret ADMIN_PASSWORD "Пароль super-admin (для нового: >=24, A-Z/a-z/0-9)"
        prompt_line PROFILE_NAME "Имя Config Profile" "$PROFILE_NAME"
        prompt_line NODE_NAME "Имя ноды" "${NODE_NAME:-Node-1}"
        prompt_line NODE_ADDRESS "IP или домен ноды" "$NODE_ADDRESS"
        prompt_line NODE_PORT "Node Port" "$NODE_PORT"
    fi
    [[ -n "$ADMIN_USERNAME" && -n "$ADMIN_PASSWORD" ]] || die "Set REMNAWAVE_ADMIN_USERNAME and REMNAWAVE_ADMIN_PASSWORD"
    [[ "$PROFILE_NAME" =~ ^[A-Za-z0-9_\ -]{2,30}$ ]] || die "Profile name must be 2-30 safe ASCII characters"
    (( ${#NODE_NAME} >= 3 && ${#NODE_NAME} <= 30 )) || die "Node name must contain 3-30 characters"
    [[ -n "$NODE_ADDRESS" ]] || die "Set REMNAWAVE_NODE_ADDRESS"
    if [[ ! "$NODE_PORT" =~ ^[0-9]+$ ]] || (( NODE_PORT < 1 || NODE_PORT > 65535 )); then die "REMNAWAVE_NODE_PORT must be 1..65535"; fi

    auth_payload="${TMP_DIR}/auth.json"; response_file="${TMP_DIR}/auth-response.json"
    jq -n --arg username "$ADMIN_USERNAME" --arg password "$ADMIN_PASSWORD" '{username:$username,password:$password}' >"$auth_payload"
    status="$(api_request POST /api/auth/register '' "$auth_payload" "$response_file")"
    if [[ ! "$status" =~ ^2 ]]; then
        status="$(api_request POST /api/auth/login '' "$auth_payload" "$response_file")"
    fi
    [[ "$status" =~ ^2 ]] || die "Admin registration/login failed (HTTP ${status}); for a new admin use a 24+ character password with upper/lowercase and a digit"
    access_token="$(jq -er '.response.accessToken | strings | select(length > 20)' "$response_file")" || die "Auth response has no accessToken"

    profile_payload="${TMP_DIR}/profile-payload.json"; response_file="${TMP_DIR}/profile-response.json"
    jq -n --arg name "$PROFILE_NAME" --slurpfile config "$template_file" '{name:$name,config:$config[0]}' >"$profile_payload"
    status="$(api_request POST /api/config-profiles "$access_token" "$profile_payload" "$response_file")"
    [[ "$status" == 201 ]] || die "Config Profile creation failed (HTTP ${status}); choose a unique profile name"
    profile_uuid="$(jq -er '.response.uuid | strings' "$response_file")" || die "Profile response has no UUID"
    inbounds_file="${TMP_DIR}/inbounds.json"
    jq -ec '[.response.inbounds[].uuid] | select(length > 0)' "$response_file" >"$inbounds_file" || die "Profile response has no inbound UUIDs"

    squad_name="$(printf '%.30s' "${PROFILE_NAME}-Squad")"
    squad_payload="${TMP_DIR}/squad-payload.json"; response_file="${TMP_DIR}/squad-response.json"
    jq -n --arg name "$squad_name" --slurpfile inbounds "$inbounds_file" '{name:$name,inbounds:$inbounds[0]}' >"$squad_payload"
    status="$(api_request POST /api/internal-squads "$access_token" "$squad_payload" "$response_file")"
    [[ "$status" == 201 ]] || \
        die "Config Profile was created, but Internal Squad creation failed (HTTP ${status}); remove/rename the partial profile or create its squad manually"
    squad_uuid="$(jq -er '.response.uuid | strings' "$response_file")" || die "Internal Squad response has no UUID"

    key_file="${TMP_DIR}/key-response.json"
    status="$(api_request GET /api/keygen "$access_token" '' "$key_file")"
    [[ "$status" == 200 ]] || die "Node key generation failed (HTTP ${status})"
    secret_key="$(jq -er '.response.secretKey | strings | select(length > 10)' "$key_file")" || die "Keygen response has no secretKey"

    node_payload="${TMP_DIR}/node-payload.json"; response_file="${TMP_DIR}/node-response.json"
    jq -n --arg name "$NODE_NAME" --arg address "$NODE_ADDRESS" --argjson port "$NODE_PORT" \
        --arg profile "$profile_uuid" --slurpfile inbounds "$inbounds_file" \
        '{name:$name,address:$address,port:$port,configProfile:{activeConfigProfileUuid:$profile,activeInbounds:$inbounds[0]}}' >"$node_payload"
    status="$(api_request POST /api/nodes "$access_token" "$node_payload" "$response_file")"
    [[ "$status" == 201 ]] || die "Node creation failed (HTTP ${status}); choose a unique node name/address"
    node_uuid="$(jq -er '.response.uuid | strings' "$response_file")" || die "Node response has no UUID"

    safe_node_name="$(printf '%s' "$NODE_NAME" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
    [[ -n "$safe_node_name" ]] || safe_node_name="node"
    bundle_dir="${PANEL_DIR}/node-bundles"; bundle_file="${bundle_dir}/${safe_node_name}-docker-compose.yml"
    install -d -m 700 "$bundle_dir"
    {
        printf 'services:\n'
        printf '  remnanode:\n'
        printf '    container_name: remnanode\n'
        printf '    hostname: remnanode\n'
        printf '    image: remnawave/node:latest\n'
        printf '    network_mode: host\n'
        printf '    restart: always\n'
        printf '    ulimits:\n'
        printf '      nofile:\n'
        printf '        soft: 1048576\n'
        printf '        hard: 1048576\n'
        printf '    cap_add:\n'
        printf '      - NET_ADMIN\n'
        printf '    environment:\n'
        printf '      - NODE_PORT=%s\n' "$NODE_PORT"
        printf '      - SECRET_KEY=%s\n' "$secret_key"
    } >"$bundle_file"
    chmod 600 "$bundle_file"
    unset access_token secret_key ADMIN_PASSWORD
    ok "Created profile '${PROFILE_NAME}' from '${SELECTED_TEMPLATE_NAME}'"
    ok "Created Internal Squad '${squad_name}' (${squad_uuid}) and node '${NODE_NAME}' (${node_uuid})"
    printf 'Root-only Node bundle: %s\n' "$bundle_file"
    printf 'Скопируйте его на сервер ноды и запустите node-install. JWT и SECRET_KEY в терминал не выведены.\n'
    printf 'Назначьте пользователей Internal Squad "%s", иначе его inbound не попадёт в их подписки.\n' "$squad_name"
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "sha256sum or shasum is required"
    fi
}

resolve_web_companion() {
    local candidate staged checksum_file expected actual candidate_version
    for candidate in \
        "$(dirname -- "${BASH_SOURCE[0]}")/remnawave-web.py" \
        "$WEB_APP_PATH"; do
        [[ -r "$candidate" ]] || continue
        candidate_version="$(sed -n 's/^APP_VERSION = "\([^"]*\)"$/\1/p' "$candidate" | head -1)"
        [[ "$candidate_version" == "$WEB_APP_VERSION" ]] || continue
        python3 -m py_compile "$candidate" || die "Local remnawave-web.py failed Python syntax validation"
        printf '%s' "$candidate"
        return 0
    done

    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d /tmp/remnawave-web.XXXXXX)"
    staged="${TMP_DIR}/remnawave-web.py"
    checksum_file="${TMP_DIR}/remnawave-web.py.sha256"
    curl -fsSL --proto '=https' --tlsv1.2 "$WEB_APP_URL" -o "$staged" || die "Failed to download remnawave-web.py"
    curl -fsSL --proto '=https' --tlsv1.2 "$WEB_APP_CHECKSUM_URL" -o "$checksum_file" || die "Failed to download remnawave-web.py checksum"
    expected="$(awk '$2 == "remnawave-web.py" || $2 == "*remnawave-web.py" {print $1; exit}' "$checksum_file")"
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Published remnawave-web.py checksum has an invalid format"
    actual="$(file_sha256 "$staged")"
    [[ "$actual" == "$expected" ]] || die "remnawave-web.py checksum mismatch"
    candidate_version="$(sed -n 's/^APP_VERSION = "\([^"]*\)"$/\1/p' "$staged" | head -1)"
    [[ "$candidate_version" == "$WEB_APP_VERSION" ]] || die "Downloaded remnawave-web.py has an unexpected version"
    python3 -m py_compile "$staged" || die "Downloaded remnawave-web.py failed Python syntax validation"
    printf '%s' "$staged"
}

validate_web_openapi() {
    local openapi_file="${TMP_DIR}/openapi-web.json"
    curl -fsSL --proto '=https' --tlsv1.2 "$OPENAPI_URL" -o "$openapi_file"
    jq -e '
        .paths["/api/auth/login"].post and
        .paths["/api/tokens"].post and
        .paths["/api/config-profiles"].get and
        .paths["/api/config-profiles"].post and
        .paths["/api/config-profiles/{uuid}"].delete and
        .paths["/api/internal-squads"].post and
        .paths["/api/internal-squads/{uuid}"].delete and
        .paths["/api/system/tools/x25519/generate"].get and
        .paths["/api/keygen"].get and
        .paths["/api/nodes"].get and
        .paths["/api/nodes"].post and
        .paths["/api/nodes/{uuid}"].delete and
        .paths["/api/hosts"].post and
        .paths["/api/hosts/{uuid}"].delete and
        (.components.schemas.LoginBodyDto.required | contains(["username", "password"])) and
        (.components.schemas.CreateApiTokenBodyDto.required | contains(["name", "expiresInDays"])) and
        (.components.schemas.CreateApiTokenResponseDto.properties.response.required | contains(["token"])) and
        (.components.schemas.CreateConfigProfileBodyDto.required | contains(["name", "config"])) and
        (.components.schemas.CreateConfigProfileResponseDto.properties.response.required | contains(["uuid", "inbounds"])) and
        (.components.schemas.CreateInternalSquadBodyDto.required | contains(["name", "inbounds"])) and
        (.components.schemas.CreateNodeBodyDto.required | contains(["name", "address", "configProfile"])) and
        (.components.schemas.CreateNodeBodyDto.properties.configProfile.required | contains(["activeConfigProfileUuid", "activeInbounds"])) and
        (.components.schemas.CreateHostBodyDto.required | contains(["inbound", "remark", "address", "port"])) and
        (.components.schemas.CreateHostBodyDto.properties.nodes.type == "array") and
        (.components.schemas.GenerateX25519ResponseDto.properties.response.required | contains(["keypairs"])) and
        (.components.schemas.GetNodeSecretKeyResponseDto.properties.response.required | contains(["secretKey"])) and
        (.components.schemas.GetNodesResponseDto.properties.response.type == "array")
    ' "$openapi_file" >/dev/null || die "Live Remnawave OpenAPI is incompatible with the node web console"
}

validate_web_api_token() {
    local token="$1" response_file="${TMP_DIR}/token-check.json" status
    status="$(api_request GET /api/config-profiles "$token" '' "$response_file")"
    [[ "$status" == 200 ]] || return 1
    jq -e '.response.configProfiles | type == "array"' "$response_file" >/dev/null 2>&1
}

obtain_web_api_token() {
    local username="${REMNAWAVE_ADMIN_USERNAME:-}" password="${REMNAWAVE_ADMIN_PASSWORD:-}"
    local auth_payload response_file token_payload status login_token
    if [[ -n "$WEB_API_TOKEN" ]]; then
        validate_web_api_token "$WEB_API_TOKEN" || die "REMNAWAVE_API_TOKEN is invalid or lacks Config Profiles access"
        return 0
    fi
    interactive_mode || die "Set REMNAWAVE_API_TOKEN for non-interactive web-install"
    prompt_line username "Логин Remnawave super-admin" "$username"
    prompt_secret password "Пароль Remnawave super-admin (не сохраняется)"
    [[ -n "$username" && -n "$password" ]] || die "Remnawave credentials are required"

    auth_payload="${TMP_DIR}/web-auth.json"
    response_file="${TMP_DIR}/web-auth-response.json"
    jq -n --arg username "$username" --arg password "$password" '{username:$username,password:$password}' >"$auth_payload"
    status="$(api_request POST /api/auth/login '' "$auth_payload" "$response_file")"
    password=""; REMNAWAVE_ADMIN_PASSWORD=""
    [[ "$status" == 200 ]] || die "Remnawave admin login failed (HTTP ${status})"
    login_token="$(jq -er '.response.accessToken | strings | select(length > 20)' "$response_file")" || die "Login response has no accessToken"

    token_payload="${TMP_DIR}/web-token.json"
    response_file="${TMP_DIR}/web-token-response.json"
    jq -n --arg name "node-web-$(date +%Y%m%d-%H%M%S)" '{name:$name,expiresInDays:3650,scopes:["*"]}' >"$token_payload"
    status="$(api_request POST /api/tokens "$login_token" "$token_payload" "$response_file")"
    login_token=""
    [[ "$status" == 201 ]] || die "Could not create a dedicated Remnawave API token (HTTP ${status})"
    WEB_API_TOKEN="$(jq -er '.response.token | strings | select(length > 20)' "$response_file")" || die "Token response has no token"
    validate_web_api_token "$WEB_API_TOKEN" || die "Created API token failed validation"
}

detect_panel_source_cidr() {
    local detected="${PANEL_SOURCE_CIDR:-}"
    if [[ -z "$detected" ]]; then
        detected="$(curl -fsS4 --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ "$detected" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then detected="${detected}/32"; fi
    [[ "$detected" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || \
        die "Set REMNAWAVE_PANEL_SOURCE_CIDR to the public Panel IP/CIDR"
    PANEL_SOURCE_CIDR="$detected"
}

write_web_service() {
    cat >"$WEB_SERVICE_FILE" <<EOF
[Unit]
Description=Local Remnawave node provisioning console
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${WEB_USER}
Group=${WEB_USER}
EnvironmentFile=${WEB_ENV_FILE}
ExecStart=/usr/bin/python3 ${WEB_APP_PATH}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${WEB_STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$WEB_SERVICE_FILE"
}

web_console_url() {
    local access_token panel_host
    [[ -r "$WEB_ENV_FILE" ]] || die "Web console is not installed; run web-install"
    access_token="$(sed -n 's/^REMNAWAVE_WEB_ACCESS_TOKEN=//p' "$WEB_ENV_FILE" | head -1)"
    WEB_PORT="$(sed -n 's/^REMNAWAVE_WEB_PORT=//p' "$WEB_ENV_FILE" | head -1)"
    [[ "$access_token" =~ ^[a-fA-F0-9]{64}$ ]] || die "Stored web access token is invalid"
    [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "Stored web port is invalid"
    load_state
    panel_host="${PANEL_DOMAIN:-PANEL_SERVER_IP}"
    printf 'SSH tunnel (run on your computer):\n'
    printf '  ssh -N -L %s:127.0.0.1:%s root@%s\n\n' "$WEB_PORT" "$WEB_PORT" "$panel_host"
    printf 'Then open:\n'
    printf '  http://127.0.0.1:%s/?token=%s\n' "$WEB_PORT" "$access_token"
}

install_web_console() {
    local source_file access_token csrf_token
    curl -fsS http://127.0.0.1:3001/health >/dev/null || die "Local Remnawave Panel is not healthy"
    if [[ ! "$WEB_PORT" =~ ^[0-9]+$ ]] || (( WEB_PORT < 1024 || WEB_PORT > 65535 )); then
        die "REMNAWAVE_WEB_PORT must be 1024..65535"
    fi
    install_base_dependencies
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y python3 openssh-client sshpass
    else
        require_commands python3 ssh ssh-keygen ssh-keyscan sshpass
    fi
    TMP_DIR="$(mktemp -d /tmp/remnawave-web-install.XXXXXX)"
    validate_web_openapi
    if [[ -z "$WEB_API_TOKEN" && -r "$WEB_API_TOKEN_FILE" ]]; then
        WEB_API_TOKEN="$(tr -d '\r\n' <"$WEB_API_TOKEN_FILE")"
        validate_web_api_token "$WEB_API_TOKEN" || WEB_API_TOKEN=""
    fi
    obtain_web_api_token
    [[ -n "$WEB_API_TOKEN" && "$WEB_API_TOKEN" != *$'\n'* && ${#WEB_API_TOKEN} -le 4096 ]] || die "Remnawave API token has an unsupported format"
    detect_panel_source_cidr
    source_file="$(resolve_web_companion)"

    if ! id "$WEB_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$WEB_STATE_DIR" --create-home --shell /usr/sbin/nologin "$WEB_USER"
    fi
    install -d -o "$WEB_USER" -g "$WEB_USER" -m 700 "$WEB_STATE_DIR"
    install -d -m 755 "$(dirname -- "$WEB_APP_PATH")"
    install -m 755 "$source_file" "$WEB_APP_PATH"
    python3 -m py_compile "$WEB_APP_PATH"

    access_token="$(openssl rand -hex 32)"
    csrf_token="$(openssl rand -hex 32)"
    install -d -m 700 "$STATE_DIR"
    printf '%s\n' "$WEB_API_TOKEN" >"$WEB_API_TOKEN_FILE"
    chown root:"$WEB_USER" "$WEB_API_TOKEN_FILE"
    chmod 640 "$WEB_API_TOKEN_FILE"
    {
        printf 'REMNAWAVE_API_TOKEN_FILE=%s\n' "$WEB_API_TOKEN_FILE"
        printf 'REMNAWAVE_WEB_ACCESS_TOKEN=%s\n' "$access_token"
        printf 'REMNAWAVE_WEB_CSRF_TOKEN=%s\n' "$csrf_token"
        printf 'REMNAWAVE_PANEL_SOURCE_CIDR=%s\n' "$PANEL_SOURCE_CIDR"
        printf 'REMNAWAVE_WEB_PORT=%s\n' "$WEB_PORT"
        printf 'REMNAWAVE_WEB_STATE_DIR=%s\n' "$WEB_STATE_DIR"
    } >"$WEB_ENV_FILE"
    chown root:"$WEB_USER" "$WEB_ENV_FILE"
    chmod 640 "$WEB_ENV_FILE"
    WEB_API_TOKEN=""; access_token=""; csrf_token=""

    write_web_service
    systemctl daemon-reload
    systemctl enable --now remnawave-node-web.service
    if ! systemctl is-active --quiet remnawave-node-web.service; then
        systemctl --no-pager --full status remnawave-node-web.service >&2 || true
        die "Remnawave node web console failed to start"
    fi
    ok "Local Remnawave node web console is running on 127.0.0.1:${WEB_PORT}"
    web_console_url
}

node_guide() {
    load_state
    cat <<EOF
Безопасный поток добавления ноды:
  1. Откройте https://${PANEL_DOMAIN:-PANEL_DOMAIN} -> Nodes -> Management -> + Create new node.
  2. Укажите адрес ноды и Node Port. Скопируйте сгенерированный панелью docker-compose.yml.
  3. Перенесите файл на сервер ноды, например /root/remnanode-compose.yml.
  4. На сервере ноды выполните:
       sudo bash remnawave-manager.sh node-install /root/remnanode-compose.yml
  5. В панели нажмите Next, выберите Config Profile, включите inbound и завершите Create.

Node Port должен быть доступен только с IP/CIDR панели. Передайте его как REMNAWAVE_PANEL_SOURCE_CIDR.
EOF
}

configure_node_firewall() {
    local port="$1" source="$2"
    [[ -n "$source" ]] || { warn "Firewall was not changed: set REMNAWAVE_PANEL_SOURCE_CIDR and restrict Node Port to the Panel IP"; return 0; }
    if command -v ufw >/dev/null 2>&1 && ufw status | head -1 | grep -qi active; then
        ufw allow proto tcp from "$source" to any port "$port" comment 'Remnawave Panel to Node'
        ok "UFW allows Node Port ${port} only from ${source}"
    else
        warn "Active UFW was not detected. Restrict TCP ${port} to ${source} in the provider/system firewall"
    fi
}

install_node() {
    local source_file="$NODE_COMPOSE_FILE" rendered node_port
    [[ -n "$source_file" ]] || die "Usage: node-install /path/to/panel-generated-docker-compose.yml"
    [[ -r "$source_file" ]] || die "Cannot read ${source_file}"
    install_base_dependencies
    install_docker_if_needed
    TMP_DIR="$(mktemp -d /tmp/remnanode-compose.XXXXXX)"
    rendered="${TMP_DIR}/rendered.yml"
    docker compose -f "$source_file" config >"$rendered"
    grep -Eq 'image: .*remnawave/node:' "$rendered" || die "Compose does not use the official remnawave/node image"
    grep -Eq 'network_mode: .*host' "$rendered" || die "Compose must use network_mode: host as generated by the Panel"
    grep -Eq 'SECRET_KEY[:=]' "$rendered" || die "Compose has no SECRET_KEY; copy it from the Panel node wizard"
    node_port="$(awk '
        /NODE_PORT[:=]/ {
            value=$0; sub(/^.*NODE_PORT[:=][[:space:]]*/, "", value); gsub(/["[:space:]]/, "", value); print value; exit
        }
    ' "$rendered")"
    if [[ ! "$node_port" =~ ^[0-9]+$ ]] || (( node_port < 1 || node_port > 65535 )); then die "Cannot determine a valid NODE_PORT from Compose"; fi
    install -d -m 700 "$NODE_DIR"
    if [[ -e "${NODE_DIR}/docker-compose.yml" ]]; then
        install -m 600 "${NODE_DIR}/docker-compose.yml" "${NODE_DIR}/docker-compose.yml.backup.$(date +%Y%m%d-%H%M%S)"
    fi
    install -m 600 "$source_file" "${NODE_DIR}/docker-compose.yml"
    docker compose --project-directory "$NODE_DIR" pull
    docker compose --project-directory "$NODE_DIR" up -d
    configure_node_firewall "$node_port" "$PANEL_SOURCE_CIDR"
    docker compose --project-directory "$NODE_DIR" ps
    ok "Remnawave Node started; return to the Panel wizard and finish profile/inbound assignment"
}

management_menu() {
    tty_available || die "Menu requires a terminal"
    local choice
    printf '\nREMNAWAVE — ГЛАВНОЕ МЕНЮ\n\n' >/dev/tty
    printf '  1) Установить/настроить Panel + Caddy\n' >/dev/tty
    printf '  2) Статус\n' >/dev/tty
    printf '  3) Обновить контейнеры\n' >/dev/tty
    printf '  4) Выбрать Xray-шаблон для Config Profile/inbound\n' >/dev/tty
    printf '  5) Авто: Config Profile + inbound + нода + Compose-бандл\n' >/dev/tty
    printf '  6) Установить/открыть веб-мастер добавления нод\n' >/dev/tty
    printf '  7) Инструкция по ручному добавлению ноды\n' >/dev/tty
    printf '  8) Установить ноду из docker-compose.yml панели\n' >/dev/tty
    printf '  0) Выход\n' >/dev/tty
    prompt_line choice "Выбор" 1
    case "$choice" in
        1) ACTION=install ;;
        2) ACTION=status ;;
        3) ACTION=update ;;
        4) ACTION=profile ;;
        5) ACTION=configure ;;
        6) ACTION=web-install ;;
        7) ACTION=node-guide ;;
        8) prompt_line NODE_COMPOSE_FILE "Путь к docker-compose.yml" /root/remnanode-compose.yml; ACTION=node-install ;;
        0) exit 0 ;;
        *) die "Unknown menu choice" ;;
    esac
}

parse_args() {
    (( $# > 0 )) || { ACTION=manage; return 0; }
    while (( $# > 0 )); do
        case "$1" in
            --interactive) NONINTERACTIVE=false ;;
            --non-interactive) NONINTERACTIVE=true ;;
            menu|manage|--manage) ACTION=manage ;;
            install) ACTION=install ;;
            status|settings) ACTION=status ;;
            update) ACTION=update ;;
            profile|inbounds) ACTION=profile ;;
            configure|bootstrap) ACTION=configure ;;
            web|web-install) ACTION=web-install ;;
            web-url) ACTION=web-url ;;
            web-status) ACTION=web-status ;;
            web-stop) ACTION=web-stop ;;
            node-guide|node) ACTION=node-guide ;;
            node-install)
                ACTION=node-install
                if (( $# >= 2 )) && [[ "$2" != --* ]]; then NODE_COMPOSE_FILE="$2"; shift; fi
                ;;
            help|-h|--help) usage; exit 0 ;;
            *) die "Unknown command: ${1} (use help)" ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    check_root
    [[ "$ACTION" == manage ]] && management_menu
    case "$ACTION" in
        install) install_panel ;;
        status) panel_status ;;
        update) update_panel ;;
        profile) download_profile_template ;;
        configure) configure_profile_and_node ;;
        web-install) install_web_console ;;
        web-url) web_console_url ;;
        web-status) systemctl --no-pager --full status remnawave-node-web.service ;;
        web-stop) systemctl stop remnawave-node-web.service; ok "Remnawave node web console stopped" ;;
        node-guide) node_guide ;;
        node-install) install_node ;;
        *) die "Unknown action: ${ACTION}" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
