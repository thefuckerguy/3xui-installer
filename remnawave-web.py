#!/usr/bin/env python3
"""Local-only Remnawave node provisioning console.

The service is intentionally dependency-free.  It talks to the local
Remnawave API, bootstraps an SSH key with sshpass over a dedicated file
descriptor, and then provisions a clean Debian/Ubuntu node over OpenSSH.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.cookies
import http.server
import io
import ipaddress
import json
import os
import re
import secrets
import shlex
import socket
import subprocess
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


APP_VERSION = "2.2.0"
STATE_DIR = Path(os.environ.get("REMNAWAVE_WEB_STATE_DIR", "/var/lib/remnawave-web"))
KNOWN_HOSTS = STATE_DIR / "known_hosts"
SSH_KEY = STATE_DIR / "id_ed25519"
API_BASE = os.environ.get("REMNAWAVE_API_BASE", "http://127.0.0.1:3000").rstrip("/")
API_TOKEN_FILE = os.environ.get("REMNAWAVE_API_TOKEN_FILE", "")
if API_TOKEN_FILE:
    try:
        API_TOKEN = Path(API_TOKEN_FILE).read_text(encoding="utf-8").strip()
    except OSError:
        API_TOKEN = ""
else:
    API_TOKEN = os.environ.get("REMNAWAVE_API_TOKEN", "")
ACCESS_TOKEN = os.environ.get("REMNAWAVE_WEB_ACCESS_TOKEN", "")
CSRF_TOKEN = os.environ.get("REMNAWAVE_WEB_CSRF_TOKEN", "")
PANEL_SOURCE_CIDR = os.environ.get("REMNAWAVE_PANEL_SOURCE_CIDR", "")
LISTEN_PORT = int(os.environ.get("REMNAWAVE_WEB_PORT", "8787"))
MAX_BODY = 16 * 1024
NODE_PORT = 2222
CERT_KEY_PATH = "/etc/letsencrypt/live/{domain}/privkey.pem"
CERT_CHAIN_PATH = "/etc/letsencrypt/live/{domain}/fullchain.pem"

NAME_RE = re.compile(r"^[^\x00-\x1f\x7f]{3,30}$")
PROFILE_SAFE_RE = re.compile(r"[^A-Za-z0-9_-]+")
COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
HOST_KEY_RE = re.compile(r"^(\[[^\]]+\]:\d+|[^\s]+)\s+(ssh-ed25519)\s+([A-Za-z0-9+/=]+)$")
SAFE_LOG_REPLACEMENTS = (
    re.compile(r"(?i)(password|secret[_ -]?key|authorization|bearer)(\s*[:=]\s*)(\S+)"),
)


REMOTE_INSTALL_SCRIPT = r'''#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "remote installer must run as root"
[[ -r /opt/remnanode/node.env ]] || die "missing /opt/remnanode/node.env"

while IFS='=' read -r key value; do
    case "$key" in
        NODE_DOMAIN) NODE_DOMAIN="$value" ;;
        PANEL_SOURCE_CIDR) PANEL_SOURCE_CIDR="$value" ;;
        SSH_PORT) SSH_PORT="$value" ;;
        NODE_PORT) NODE_PORT="$value" ;;
        PORT_REALITY) PORT_REALITY="$value" ;;
        PORT_XHTTP) PORT_XHTTP="$value" ;;
        PORT_TROJAN) PORT_TROJAN="$value" ;;
        PORT_SHADOWSOCKS) PORT_SHADOWSOCKS="$value" ;;
        PORT_HYSTERIA2) PORT_HYSTERIA2="$value" ;;
    esac
done </opt/remnanode/node.env

[[ "${NODE_DOMAIN:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]] || die "invalid node domain"
[[ "${PANEL_SOURCE_CIDR:-}" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || die "invalid panel source CIDR"
for value in "${SSH_PORT:-}" "${NODE_PORT:-}" "${PORT_REALITY:-}" "${PORT_XHTTP:-}" "${PORT_TROJAN:-}" "${PORT_SHADOWSOCKS:-}" "${PORT_HYSTERIA2:-}"; do
    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || die "invalid port in node.env"
done

[[ -r /etc/os-release ]] || die "unsupported operating system"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
    debian:11|debian:12|debian:13|ubuntu:22|ubuntu:24|ubuntu:26) ;;
    *) die "supported systems are Debian 11+ and Ubuntu 22.04+" ;;
esac

export DEBIAN_FRONTEND=noninteractive
info "installing base packages"
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl ufw certbot openssl iproute2

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    info "installing Docker from the official installer"
    docker_script="$(mktemp /tmp/get-docker.XXXXXX)"
    trap 'rm -f -- "${docker_script:-}"' EXIT
    curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o "$docker_script"
    [[ -s "$docker_script" ]] || die "Docker installer download is empty"
    sh "$docker_script"
    rm -f -- "$docker_script"
    trap - EXIT
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable"

for port in "$PORT_REALITY" "$PORT_XHTTP" "$PORT_TROJAN" "$PORT_SHADOWSOCKS" "$PORT_HYSTERIA2" "$NODE_PORT"; do
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        die "TCP port ${port} became occupied during installation"
    fi
done
if ss -H -lun "sport = :${PORT_SHADOWSOCKS}" 2>/dev/null | grep -q . || \
   ss -H -lun "sport = :${PORT_HYSTERIA2}" 2>/dev/null | grep -q .; then
    die "a required UDP port became occupied during installation"
fi

if [[ ! -s "/etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem" || ! -s "/etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem" ]]; then
    if ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .; then
        die "TCP port 80 is occupied; Certbot HTTP-01 cannot run"
    fi
    info "requesting a trusted TLS certificate for ${NODE_DOMAIN}"
    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email --preferred-challenges http -d "$NODE_DOMAIN"
fi
[[ -s "/etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem" ]] || die "TLS certificate was not issued"
[[ -s "/etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem" ]] || die "TLS private key was not issued"

install -d -m 700 /var/log/remnanode
install -d -m 755 /opt/remnanode/html

info "validating and starting the Remnawave node"
docker compose --project-directory /opt/remnanode config --quiet
docker compose --project-directory /opt/remnanode pull
docker compose --project-directory /opt/remnanode up -d

cat >/etc/letsencrypt/renewal-hooks/deploy/remnawave-node <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/remnanode
docker compose restart remnanode remnawave-nginx
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/remnawave-node

cat >/etc/sysctl.d/99-remnawave-node.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
SYSCTL
sysctl --system >/dev/null 2>&1 || true

info "configuring UFW"
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'ACME HTTP-01' >/dev/null
ufw allow "${PORT_REALITY}/tcp" comment 'VLESS REALITY Vision' >/dev/null
ufw allow "${PORT_XHTTP}/tcp" comment 'VLESS XHTTP TLS' >/dev/null
ufw allow "${PORT_TROJAN}/tcp" comment 'Trojan TLS' >/dev/null
ufw allow "${PORT_SHADOWSOCKS}/tcp" comment 'Shadowsocks TCP' >/dev/null
ufw allow "${PORT_SHADOWSOCKS}/udp" comment 'Shadowsocks UDP' >/dev/null
ufw allow "${PORT_HYSTERIA2}/udp" comment 'Hysteria2 QUIC' >/dev/null
ufw allow proto tcp from "$PANEL_SOURCE_CIDR" to any port "$NODE_PORT" comment 'Remnawave Panel' >/dev/null
ufw --force enable >/dev/null
ufw reload >/dev/null

for _attempt in $(seq 1 45); do
    if docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true && \
       docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null | grep -qx true; then
        break
    fi
    sleep 2
done
docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null | grep -qx true || die "remnanode container is not running"
docker inspect -f '{{.State.Running}}' remnawave-nginx 2>/dev/null | grep -qx true || die "reverse-proxy container is not running"
docker compose --project-directory /opt/remnanode ps
info "remote node installation completed"
'''


BOOTSTRAP_SCRIPT_TEMPLATE = r'''#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "root SSH login is required" >&2; exit 10; }
[[ -r /etc/os-release ]] || { echo "missing /etc/os-release" >&2; exit 11; }
. /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
    debian:11|debian:12|debian:13|ubuntu:22|ubuntu:24|ubuntu:26) ;;
    *) echo "supported systems are Debian 11+ and Ubuntu 22.04+" >&2; exit 12 ;;
esac
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
authorized_key=__AUTHORIZED_KEY__
grep -Fqx -- "$authorized_key" /root/.ssh/authorized_keys || printf '%s\n' "$authorized_key" >>/root/.ssh/authorized_keys
'''


PREFLIGHT_SCRIPT = r'''#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "root SSH login is required" >&2; exit 10; }
[[ ! -e /opt/remnanode ]] || { echo "an existing /opt/remnanode path was found" >&2; exit 20; }
if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    echo "an existing remnanode container was found" >&2
    exit 21
fi
df -Pk / | awk 'NR==2 { if ($4 < 2097152) { print "at least 2 GiB of free disk space is required" > "/dev/stderr"; exit 22 } }'
if command -v ss >/dev/null 2>&1; then
    ss -H -lntu 2>/dev/null || true
fi
'''


class UserVisibleError(RuntimeError):
    """Expected failure that is safe to show in the web UI."""


class ApiError(UserVisibleError):
    pass


def sanitize_log(value: str, secrets_to_hide: tuple[str, ...] = ()) -> str:
    text = value.replace("\x00", "").strip()
    for secret in secrets_to_hide:
        if secret:
            text = text.replace(secret, "[REDACTED]")
    for pattern in SAFE_LOG_REPLACEMENTS:
        text = pattern.sub(lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]", text)
    return text[-1600:]


def require_runtime_configuration() -> None:
    missing = []
    if not API_TOKEN:
        missing.append("REMNAWAVE_API_TOKEN or REMNAWAVE_API_TOKEN_FILE")
    if not ACCESS_TOKEN:
        missing.append("REMNAWAVE_WEB_ACCESS_TOKEN")
    if not CSRF_TOKEN:
        missing.append("REMNAWAVE_WEB_CSRF_TOKEN")
    if not PANEL_SOURCE_CIDR:
        missing.append("REMNAWAVE_PANEL_SOURCE_CIDR")
    if missing:
        raise SystemExit("Missing required environment values: " + ", ".join(missing))
    try:
        ipaddress.ip_network(PANEL_SOURCE_CIDR, strict=False)
    except ValueError as exc:
        raise SystemExit("REMNAWAVE_PANEL_SOURCE_CIDR is invalid") from exc
    if not 1024 <= LISTEN_PORT <= 65535:
        raise SystemExit("REMNAWAVE_WEB_PORT must be between 1024 and 65535")


def normalize_domain(value: str) -> str:
    value = value.strip().rstrip(".").lower()
    try:
        ascii_domain = value.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise UserVisibleError("Некорректный домен ноды") from exc
    if len(ascii_domain) > 253 or not re.fullmatch(
        r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}", ascii_domain
    ):
        raise UserVisibleError("Укажите полный домен ноды, например node.example.com")
    return ascii_domain


def validate_payload(data: dict[str, Any]) -> dict[str, Any]:
    name = str(data.get("server_name", "")).strip()
    if not NAME_RE.fullmatch(name):
        raise UserVisibleError("Название сервера должно содержать 3–30 печатных символов")
    try:
        node_ip_obj = ipaddress.ip_address(str(data.get("node_ip", "")).strip())
    except ValueError as exc:
        raise UserVisibleError("Некорректный IP-адрес ноды") from exc
    if node_ip_obj.version != 4 or node_ip_obj.is_unspecified or node_ip_obj.is_multicast or node_ip_obj.is_loopback:
        raise UserVisibleError("Сейчас мастер поддерживает обычный IPv4-адрес ноды")
    try:
        ssh_port = int(data.get("ssh_port", 22))
    except (TypeError, ValueError) as exc:
        raise UserVisibleError("SSH-порт должен быть числом") from exc
    if not 1 <= ssh_port <= 65535:
        raise UserVisibleError("SSH-порт должен быть в диапазоне 1–65535")
    country = str(data.get("country_code", "XX")).strip().upper() or "XX"
    if not COUNTRY_RE.fullmatch(country):
        raise UserVisibleError("Код страны должен состоять из двух латинских букв")
    return {
        "server_name": name,
        "node_ip": str(node_ip_obj),
        "node_domain": normalize_domain(str(data.get("node_domain", ""))),
        "ssh_port": ssh_port,
        "country_code": country,
    }


def verify_dns(domain: str, node_ip: str) -> None:
    try:
        answers = {
            info[4][0]
            for info in socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
        }
    except socket.gaierror as exc:
        raise UserVisibleError(f"Домен {domain} пока не имеет A-записи") from exc
    if node_ip not in answers:
        shown = ", ".join(sorted(answers)) or "нет адресов"
        raise UserVisibleError(f"A-запись {domain} указывает на {shown}, а должна указывать на {node_ip}")


def profile_safe_name(name: str, suffix: str) -> str:
    cleaned = PROFILE_SAFE_RE.sub("-", name.encode("ascii", "ignore").decode()).strip("-") or "Node"
    return f"{cleaned[:20]}-{suffix}"[:30]


def select_ports(used: set[int]) -> dict[str, int]:
    required_fixed = {"reality": 443}
    if 80 in used:
        raise UserVisibleError("TCP-порт 80 уже занят на ноде; он нужен для выпуска TLS-сертификата")
    if 443 in used:
        raise UserVisibleError("TCP-порт 443 уже занят на ноде")
    selected = dict(required_fixed)
    if NODE_PORT not in used:
        selected["node"] = NODE_PORT
    candidates = list(range(20000, 61000))
    secrets.SystemRandom().shuffle(candidates)
    for key in (("node",) if "node" not in selected else ()) + ("xhttp", "trojan", "shadowsocks", "hysteria2"):
        while candidates:
            candidate = candidates.pop()
            if candidate not in used and candidate not in selected.values():
                selected[key] = candidate
                break
        else:
            raise UserVisibleError("Не удалось подобрать свободные порты")
    return selected


def build_profile(
    server_name: str,
    domain: str,
    ports: dict[str, int],
    reality_private_key: str,
    short_id: str,
    xhttp_path: str,
    shadowsocks_key: str,
    tag_prefix: str,
) -> dict[str, Any]:
    cert_key = CERT_KEY_PATH.format(domain=domain)
    cert_chain = CERT_CHAIN_PATH.format(domain=domain)
    sniffing = {"enabled": True, "destOverride": ["http", "tls", "quic"]}
    tls_common = {
        "serverName": domain,
        "certificates": [{"keyFile": cert_key, "certificateFile": cert_chain}],
    }
    tags = {
        "reality": f"{tag_prefix}-VLESS-REALITY-VISION",
        "xhttp": f"{tag_prefix}-VLESS-XHTTP-TLS",
        "trojan": f"{tag_prefix}-TROJAN-TLS",
        "shadowsocks": f"{tag_prefix}-SHADOWSOCKS-2022",
        "hysteria2": f"{tag_prefix}-HYSTERIA2",
    }
    inbounds: list[dict[str, Any]] = [
        {
            "tag": tags["reality"],
            "listen": "0.0.0.0",
            "port": ports["reality"],
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none", "flow": "xtls-rprx-vision"},
            "sniffing": sniffing,
            "streamSettings": {
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "xver": 1,
                    "target": "/dev/shm/nginx.sock",
                    "spiderX": "",
                    "minClientVer": "0.0.0",
                    "shortIds": [short_id],
                    "privateKey": reality_private_key,
                    "serverNames": [domain],
                },
            },
        },
        {
            "tag": tags["xhttp"],
            "listen": "0.0.0.0",
            "port": ports["xhttp"],
            "protocol": "vless",
            "settings": {"clients": [], "decryption": "none"},
            "sniffing": sniffing,
            "streamSettings": {
                "network": "xhttp",
                "security": "tls",
                "xhttpSettings": {"path": xhttp_path, "host": domain, "mode": "auto"},
                "tlsSettings": {**tls_common, "alpn": ["h2", "http/1.1"]},
            },
        },
        {
            "tag": tags["trojan"],
            "listen": "0.0.0.0",
            "port": ports["trojan"],
            "protocol": "trojan",
            "settings": {"clients": [], "fallbacks": []},
            "sniffing": sniffing,
            "streamSettings": {
                "network": "raw",
                "security": "tls",
                "rawSettings": {"acceptProxyProtocol": False, "header": {"type": "none"}},
                "tlsSettings": {**tls_common, "alpn": ["h2", "http/1.1"]},
            },
        },
        {
            "tag": tags["shadowsocks"],
            "listen": "0.0.0.0",
            "port": ports["shadowsocks"],
            "protocol": "shadowsocks",
            "settings": {
                "method": "2022-blake3-aes-256-gcm",
                "password": shadowsocks_key,
                "network": "tcp,udp",
                "clients": [],
            },
            "sniffing": sniffing,
        },
        {
            "tag": tags["hysteria2"],
            "listen": "0.0.0.0",
            "port": ports["hysteria2"],
            "protocol": "hysteria",
            "settings": {"clients": [], "version": 2},
            "streamSettings": {
                "network": "hysteria",
                "security": "tls",
                "finalmask": {"quicParams": {"debug": False, "congestion": "bbr"}},
                "tlsSettings": {**tls_common, "alpn": ["h3"]},
                "hysteriaSettings": {"version": 2},
            },
        },
    ]
    return {
        "log": {"loglevel": "warning"},
        "dns": {"queryStrategy": "UseIPv4", "servers": ["1.1.1.1", "1.0.0.1"]},
        "inbounds": inbounds,
        "outbounds": [
            {"tag": "DIRECT", "protocol": "freedom"},
            {"tag": "BLOCK", "protocol": "blackhole"},
        ],
        "routing": {
            "rules": [
                {"ip": ["geoip:private"], "outboundTag": "BLOCK"},
                {"domain": ["geosite:private"], "outboundTag": "BLOCK"},
                {"protocol": ["bittorrent"], "outboundTag": "BLOCK"},
            ]
        },
    }


def render_compose(secret_key: str, domain: str, node_port: int = NODE_PORT) -> str:
    secret_json = json.dumps(secret_key)
    return f'''x-common: &common
  restart: always
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "5"

services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: *common
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
      - ./html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: *common
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      NODE_PORT: "{node_port}"
      SECRET_KEY: {secret_json}
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
'''


def render_nginx(domain: str) -> str:
    return f'''server_names_hash_bucket_size 64;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

server {{
    server_name {domain};
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;
    ssl_certificate "/etc/letsencrypt/live/{domain}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/{domain}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/{domain}/fullchain.pem";
    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
}}

server {{
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}}
'''


def render_node_env(domain: str, ssh_port: int, ports: dict[str, int]) -> str:
    return "\n".join(
        [
            f"NODE_DOMAIN={domain}",
            f"PANEL_SOURCE_CIDR={PANEL_SOURCE_CIDR}",
            f"SSH_PORT={ssh_port}",
            f"NODE_PORT={ports['node']}",
            f"PORT_REALITY={ports['reality']}",
            f"PORT_XHTTP={ports['xhttp']}",
            f"PORT_TROJAN={ports['trojan']}",
            f"PORT_SHADOWSOCKS={ports['shadowsocks']}",
            f"PORT_HYSTERIA2={ports['hysteria2']}",
            "",
        ]
    )


def build_payload_archive(secret_key: str, domain: str, ssh_port: int, ports: dict[str, int]) -> bytes:
    files: dict[str, tuple[str, int]] = {
        "opt/remnanode/docker-compose.yml": (render_compose(secret_key, domain, ports["node"]), 0o600),
        "opt/remnanode/nginx.conf": (render_nginx(domain), 0o600),
        "opt/remnanode/node.env": (render_node_env(domain, ssh_port, ports), 0o600),
        "opt/remnanode/html/index.html": (
            "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Welcome</title>"
            "<meta name=\"robots\" content=\"noindex,nofollow\"><style>body{font:16px system-ui;"
            "display:grid;place-items:center;min-height:100vh;background:#0b1220;color:#dbeafe}</style>"
            "<main><h1>Welcome</h1><p>This service is available.</p></main></html>\n",
            0o644,
        ),
        "opt/remnanode/.managed-by-remnawave-web": (APP_VERSION + "\n", 0o600),
        "usr/local/sbin/remnawave-node-install": (REMOTE_INSTALL_SCRIPT, 0o700),
    }
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for path, (content, mode) in files.items():
            raw = content.encode()
            info = tarfile.TarInfo(path)
            info.size = len(raw)
            info.mode = mode
            info.uid = 0
            info.gid = 0
            info.mtime = 0
            archive.addfile(info, io.BytesIO(raw))
    return output.getvalue()


class RemnawaveApi:
    def __init__(self, base: str = API_BASE, token: str = API_TOKEN, timeout: int = 30):
        parsed = urllib.parse.urlparse(base)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("invalid API base")
        self.base = base
        self.token = token
        self.timeout = timeout

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        body = None
        headers = {"Accept": "application/json", "Authorization": f"Bearer {self.token}"}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read(2 * 1024 * 1024)
                if response.status == 204 or not raw:
                    return {}
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raw = exc.read(64 * 1024)
            message = ""
            try:
                decoded = json.loads(raw)
                detail = decoded.get("message") or decoded.get("error") or decoded.get("errorCode")
                if isinstance(detail, list):
                    detail = "; ".join(str(item) for item in detail[:4])
                if detail:
                    message = f": {detail}"
            except (ValueError, AttributeError):
                pass
            raise ApiError(f"Remnawave API: HTTP {exc.code}{message}") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ApiError("Локальный Remnawave API недоступен или вернул некорректный ответ") from exc

    def delete_quietly(self, path: str) -> None:
        try:
            self.request("DELETE", path)
        except ApiError:
            pass


def _run(args: list[str], *, data: bytes | None = None, timeout: int = 60) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(args, input=data, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UserVisibleError(f"Не удалось выполнить {args[0]}") from exc


def ensure_ssh_key() -> str:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)
    if not SSH_KEY.exists():
        result = _run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "remnawave-web@panel", "-f", str(SSH_KEY)],
            timeout=30,
        )
        if result.returncode != 0:
            raise UserVisibleError("Не удалось создать служебный SSH-ключ")
    os.chmod(SSH_KEY, 0o600)
    public_key = SSH_KEY.with_suffix(".pub").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+ remnawave-web@panel", public_key):
        raise UserVisibleError("Служебный SSH-ключ имеет неожиданный формат")
    return public_key


def scan_host_key(host: str, port: int) -> dict[str, str]:
    result = _run(["ssh-keyscan", "-T", "8", "-p", str(port), "-t", "ed25519", host], timeout=12)
    lines = []
    for raw_line in result.stdout.decode("utf-8", "replace").splitlines():
        line = raw_line.strip()
        match = HOST_KEY_RE.fullmatch(line)
        if match:
            lines.append((line, match.group(2), match.group(3)))
    if not lines:
        raise UserVisibleError("Не удалось получить ED25519 host key; проверьте IP, SSH-порт и firewall")
    line, key_type, key_blob = lines[0]
    fingerprint_raw = base64.b64encode(hashlib.sha256(base64.b64decode(key_blob)).digest()).decode().rstrip("=")
    return {"line": line, "key_type": key_type, "key_blob": key_blob, "fingerprint": f"SHA256:{fingerprint_raw}"}


def pin_host_key(expected_line: str, current: dict[str, str]) -> None:
    expected = HOST_KEY_RE.fullmatch(expected_line.strip())
    if not expected or expected.group(2) != current["key_type"] or expected.group(3) != current["key_blob"]:
        raise UserVisibleError("SSH host key изменился после проверки; установка остановлена")
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    existing_lines = KNOWN_HOSTS.read_text(encoding="utf-8").splitlines() if KNOWN_HOSTS.exists() else []
    host_marker = current["line"].split(None, 1)[0]
    matching_host = [line for line in existing_lines if line.split(None, 1)[0] == host_marker]
    if matching_host and current["line"] not in matching_host:
        raise UserVisibleError(
            "Для этого адреса уже закреплён другой SSH host key. Проверьте переустановку сервера вручную."
        )
    if current["line"] not in existing_lines:
        with KNOWN_HOSTS.open("a", encoding="utf-8") as handle:
            handle.write(current["line"] + "\n")
    os.chmod(KNOWN_HOSTS, 0o600)


def ssh_base(host: str, port: int) -> list[str]:
    return [
        "ssh",
        "-i",
        str(SSH_KEY),
        "-p",
        str(port),
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=12",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=4",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={KNOWN_HOSTS}",
        "-o",
        "IdentitiesOnly=yes",
        f"root@{host}",
    ]


def bootstrap_key_with_password(host: str, port: int, password: bytearray, public_key: str) -> None:
    authorized_key = f'restrict,from="{PANEL_SOURCE_CIDR}" {public_key}'
    script = BOOTSTRAP_SCRIPT_TEMPLATE.replace("__AUTHORIZED_KEY__", shlex.quote(authorized_key)).encode()
    read_fd, write_fd = os.pipe()
    try:
        args = [
            "sshpass",
            "-d",
            str(read_fd),
            "ssh",
            "-p",
            str(port),
            "-o",
            "ConnectTimeout=12",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={KNOWN_HOSTS}",
            "-o",
            "PubkeyAuthentication=no",
            "-o",
            "PreferredAuthentications=password,keyboard-interactive",
            f"root@{host}",
            "bash -s",
        ]
        process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(read_fd,))
        os.close(read_fd)
        read_fd = -1
        os.write(write_fd, bytes(password) + b"\n")
        os.close(write_fd)
        write_fd = -1
        stdout, stderr = process.communicate(input=script, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as exc:
        try:
            process.kill()  # type: ignore[possibly-undefined]
        except (NameError, OSError):
            pass
        raise UserVisibleError("Не удалось выполнить первичную SSH-аутентификацию") from exc
    finally:
        if read_fd >= 0:
            os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)
        for index in range(len(password)):
            password[index] = 0
    if process.returncode != 0:
        detail = sanitize_log(stderr.decode("utf-8", "replace"))
        raise UserVisibleError("SSH-вход root по паролю не выполнен" + (f": {detail}" if detail else ""))
    probe = _run(ssh_base(host, port) + ["true"], timeout=20)
    if probe.returncode != 0:
        raise UserVisibleError("SSH-ключ был отправлен, но вход по ключу не работает")


def run_ssh(host: str, port: int, remote_command: str, data: bytes | None = None, timeout: int = 120) -> str:
    result = _run(ssh_base(host, port) + [remote_command], data=data, timeout=timeout)
    if result.returncode != 0:
        detail = sanitize_log(result.stderr.decode("utf-8", "replace"))
        raise UserVisibleError("Удалённая команда завершилась с ошибкой" + (f": {detail}" if detail else ""))
    return result.stdout.decode("utf-8", "replace")


def parse_used_ports(ss_output: str) -> set[int]:
    used: set[int] = set()
    for line in ss_output.splitlines():
        parts = line.split()
        if not parts:
            continue
        for address_field in reversed(parts):
            match = re.search(r":(\d+)$", address_field)
            if match:
                used.add(int(match.group(1)))
                break
    return used


def host_payload(
    profile_uuid: str,
    inbound_uuid: str,
    node_uuid: str,
    remark: str,
    domain: str,
    port: int,
    *,
    path: str | None = None,
    host: str | None = None,
    sni: str | None = None,
    alpn: str | None = None,
    security_layer: str = "DEFAULT",
) -> dict[str, Any]:
    return {
        "inbound": {"configProfileUuid": profile_uuid, "configProfileInboundUuid": inbound_uuid},
        "remark": remark[:100],
        "address": domain,
        "port": port,
        "path": path,
        "sni": sni,
        "host": host,
        "alpn": alpn,
        "fingerprint": "chrome" if sni else None,
        "isDisabled": False,
        "securityLayer": security_layer,
        "nodes": [node_uuid],
    }


@dataclass
class Job:
    id: str
    status: str = "queued"
    progress: int = 0
    messages: list[dict[str, Any]] = field(default_factory=list)
    result: dict[str, Any] | None = None
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def emit(self, progress: int, message: str) -> None:
        with self.lock:
            self.progress = max(self.progress, min(progress, 100))
            self.messages.append({"time": int(time.time()), "message": sanitize_log(message)})
            self.messages = self.messages[-120:]

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return {
                "id": self.id,
                "status": self.status,
                "progress": self.progress,
                "messages": list(self.messages),
                "result": self.result,
                "error": self.error,
            }


JOBS: dict[str, Job] = {}
JOBS_LOCK = threading.Lock()
ACTIVE_JOB_LOCK = threading.Lock()


def _extract_response(data: dict[str, Any], key: str | None = None) -> Any:
    response = data.get("response")
    if key is None:
        return response
    if not isinstance(response, dict) or key not in response:
        raise ApiError(f"Remnawave API не вернул поле {key}")
    return response[key]


def provision_job(job: Job, values: dict[str, Any], password: bytearray, expected_host_key: str) -> None:
    api = RemnawaveApi()
    created: list[tuple[str, str]] = []
    remote_started = False
    payload_uploaded = False
    secret_key = ""
    reality_private_key = ""
    shadowsocks_key = ""
    try:
        with ACTIVE_JOB_LOCK:
            job.status = "running"
            job.emit(3, "Проверяю DNS и SSH host key")
            verify_dns(values["node_domain"], values["node_ip"])
            current_key = scan_host_key(values["node_ip"], values["ssh_port"])
            pin_host_key(expected_host_key, current_key)

            job.emit(10, "Однократно подключаюсь по root-паролю и устанавливаю служебный SSH-ключ")
            public_key = ensure_ssh_key()
            bootstrap_key_with_password(values["node_ip"], values["ssh_port"], password, public_key)
            password = bytearray()

            job.emit(18, "Проверяю ОС, свободное место и занятые порты")
            preflight = run_ssh(values["node_ip"], values["ssh_port"], "bash -s", PREFLIGHT_SCRIPT.encode(), 45)
            ports = select_ports(parse_used_ports(preflight))

            job.emit(25, "Проверяю доступ к Remnawave API")
            profiles = api.request("GET", "/api/config-profiles")
            if not isinstance(_extract_response(profiles), dict):
                raise ApiError("Remnawave API token не даёт доступ к Config Profiles")

            suffix = secrets.token_hex(3).upper()
            profile_name = profile_safe_name(values["server_name"], suffix)
            tag_prefix = f"AUTO-{suffix}"
            short_id = secrets.token_hex(8)
            xhttp_path = "/" + secrets.token_urlsafe(18)
            shadowsocks_key = base64.b64encode(secrets.token_bytes(32)).decode()

            job.emit(31, "Генерирую отдельные ключи профиля")
            x25519 = api.request("GET", "/api/system/tools/x25519/generate")
            x_response = _extract_response(x25519)
            if not isinstance(x_response, dict) or not x_response.get("keypairs"):
                raise ApiError("Remnawave API не вернул X25519 keypair")
            reality_private_key = str(x_response["keypairs"][0].get("privateKey", ""))
            if len(reality_private_key) < 20:
                raise ApiError("Remnawave API вернул некорректный X25519 private key")

            profile_config = build_profile(
                values["server_name"], values["node_domain"], ports, reality_private_key,
                short_id, xhttp_path, shadowsocks_key, tag_prefix,
            )
            job.emit(38, "Создаю Config Profile с пятью протоколами")
            profile_response = api.request(
                "POST", "/api/config-profiles", {"name": profile_name, "config": profile_config}
            )
            profile = _extract_response(profile_response)
            if not isinstance(profile, dict) or not profile.get("uuid") or not profile.get("inbounds"):
                raise ApiError("Remnawave API вернул неполный Config Profile")
            profile_uuid = str(profile["uuid"])
            created.append(("profile", profile_uuid))
            inbound_by_tag = {str(item["tag"]): str(item["uuid"]) for item in profile["inbounds"]}
            expected_tags = [str(item["tag"]) for item in profile_config["inbounds"]]
            if any(tag not in inbound_by_tag for tag in expected_tags):
                raise ApiError("Remnawave API не создал все пять inbound")
            inbound_uuids = [inbound_by_tag[tag] for tag in expected_tags]

            job.emit(45, "Создаю Internal Squad и включаю все inbound")
            squad_name = profile_safe_name(values["server_name"], "Squad-" + suffix)[:30]
            squad_response = api.request(
                "POST", "/api/internal-squads", {"name": squad_name, "inbounds": inbound_uuids}
            )
            squad_uuid = str(_extract_response(squad_response, "uuid"))
            created.append(("squad", squad_uuid))

            key_response = api.request("GET", "/api/keygen")
            secret_key = str(_extract_response(key_response, "secretKey"))
            if len(secret_key) < 20:
                raise ApiError("Remnawave API вернул некорректный Node SECRET_KEY")

            job.emit(52, "Регистрирую ноду в панели")
            node_response = api.request(
                "POST",
                "/api/nodes",
                {
                    "name": values["server_name"],
                    "address": values["node_ip"],
                    "port": ports["node"],
                    "countryCode": values["country_code"],
                    "consumptionMultiplier": 1.0,
                    "configProfile": {
                        "activeConfigProfileUuid": profile_uuid,
                        "activeInbounds": inbound_uuids,
                    },
                },
            )
            node_uuid = str(_extract_response(node_response, "uuid"))
            created.append(("node", node_uuid))

            job.emit(59, "Создаю Hosts для подписок")
            host_specs = [
                (expected_tags[0], ports["reality"], None, None, values["node_domain"], None, "DEFAULT"),
                (expected_tags[1], ports["xhttp"], xhttp_path, values["node_domain"], values["node_domain"], "h2,http/1.1", "TLS"),
                (expected_tags[2], ports["trojan"], None, None, values["node_domain"], "h2,http/1.1", "TLS"),
                (expected_tags[3], ports["shadowsocks"], None, None, None, None, "NONE"),
                (expected_tags[4], ports["hysteria2"], None, None, values["node_domain"], "h3", "TLS"),
            ]
            host_uuids: list[str] = []
            for tag, host_port, path, host_header, sni, alpn, layer in host_specs:
                payload = host_payload(
                    profile_uuid, inbound_by_tag[tag], node_uuid, f"{values['server_name']} · {tag.split('-', 2)[-1]}",
                    values["node_domain"], host_port, path=path, host=host_header, sni=sni, alpn=alpn,
                    security_layer=layer,
                )
                response = api.request("POST", "/api/hosts", payload)
                host_uuid = str(_extract_response(response, "uuid"))
                host_uuids.append(host_uuid)
                created.append(("host", host_uuid))

            job.emit(66, "Передаю root-only конфигурацию на ноду")
            archive = build_payload_archive(secret_key, values["node_domain"], values["ssh_port"], ports)
            run_ssh(
                values["node_ip"], values["ssh_port"],
                "umask 077; mkdir -p /opt/remnanode /usr/local/sbin; tar -xzf - -C /",
                archive, 90,
            )
            payload_uploaded = True

            job.emit(73, "Устанавливаю Docker, TLS, firewall и запускаю контейнеры")
            run_ssh(
                values["node_ip"], values["ssh_port"],
                "/usr/local/sbin/remnawave-node-install", timeout=900,
            )
            remote_started = True

            job.emit(91, "Ожидаю соединение ноды с панелью")
            connected = False
            last_message = ""
            for _attempt in range(45):
                nodes = _extract_response(api.request("GET", "/api/nodes"))
                if isinstance(nodes, list):
                    current = next((item for item in nodes if str(item.get("uuid")) == node_uuid), None)
                    if current and current.get("isConnected") is True:
                        connected = True
                        break
                    if current and current.get("lastStatusMessage"):
                        last_message = sanitize_log(str(current["lastStatusMessage"]))
                time.sleep(2)
            if not connected:
                suffix_message = f" Последний статус: {last_message}" if last_message else ""
                raise UserVisibleError(
                    "Контейнеры запущены, но панель не увидела ноду за 90 секунд. API-объекты сохранены для диагностики."
                    + suffix_message
                )

            job.result = {
                "node_uuid": node_uuid,
                "profile_uuid": profile_uuid,
                "squad_uuid": squad_uuid,
                "host_uuids": host_uuids,
                "domain": values["node_domain"],
                "ports": ports,
                "protocols": [
                    "VLESS + REALITY + Vision",
                    "VLESS + XHTTP + TLS",
                    "Trojan + TLS",
                    "Shadowsocks 2022 TCP/UDP",
                    "Hysteria2 QUIC",
                ],
            }
            job.progress = 100
            job.status = "complete"
            job.emit(100, "Нода установлена, подключена и добавлена в Remnawave")
    except Exception as exc:  # The boundary converts unexpected failures to a safe job error.
        if not remote_started:
            if payload_uploaded:
                try:
                    run_ssh(
                        values["node_ip"], values["ssh_port"],
                        "if [ -f /opt/remnanode/.managed-by-remnawave-web ]; then "
                        "cd /opt/remnanode; docker compose down >/dev/null 2>&1 || true; "
                        "rm -f docker-compose.yml nginx.conf node.env .managed-by-remnawave-web html/index.html; "
                        "rmdir html /opt/remnanode 2>/dev/null || true; "
                        "rm -f /usr/local/sbin/remnawave-node-install "
                        "/etc/letsencrypt/renewal-hooks/deploy/remnawave-node; fi",
                        timeout=60,
                    )
                except UserVisibleError:
                    pass
            for resource_type, resource_uuid in reversed(created):
                path = {
                    "host": f"/api/hosts/{resource_uuid}",
                    "node": f"/api/nodes/{resource_uuid}",
                    "squad": f"/api/internal-squads/{resource_uuid}",
                    "profile": f"/api/config-profiles/{resource_uuid}",
                }[resource_type]
                api.delete_quietly(path)
        job.status = "failed"
        if isinstance(exc, UserVisibleError):
            job.error = sanitize_log(str(exc), (secret_key, reality_private_key, shadowsocks_key))
        else:
            job.error = "Внутренняя ошибка мастера; подробности доступны в journalctl службы"
        job.emit(job.progress, job.error)
    finally:
        for index in range(len(password)):
            password[index] = 0
        secret_key = ""
        reality_private_key = ""
        shadowsocks_key = ""


def render_page() -> str:
    nonce = secrets.token_urlsafe(18)
    page = r'''<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Remnawave · новая нода</title>
<style nonce="__NONCE__">
:root{color-scheme:dark;--bg:#07101f;--card:#101c30;--line:#263854;--text:#e7eef9;--muted:#91a4c1;--accent:#5eead4;--danger:#fb7185}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 Inter,system-ui,sans-serif;background:radial-gradient(circle at 20% 0,#12345a 0,transparent 35%),var(--bg);color:var(--text)}
main{width:min(920px,calc(100% - 32px));margin:40px auto}.hero{margin-bottom:24px}.hero h1{font-size:clamp(30px,5vw,52px);line-height:1.05;margin:0 0 10px}.hero p{color:var(--muted);max-width:720px}.badge{display:inline-block;padding:5px 10px;border:1px solid #2dd4bf55;border-radius:999px;color:var(--accent);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
.card{background:#0f1a2bd9;border:1px solid var(--line);border-radius:18px;padding:24px;box-shadow:0 24px 80px #0007;backdrop-filter:blur(10px)}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.full{grid-column:1/-1}label{display:block;color:#bfd0e8;margin-bottom:6px}input{width:100%;border:1px solid #334964;background:#091321;color:var(--text);border-radius:10px;padding:12px 13px;font:inherit}input:focus{outline:2px solid #2dd4bf66;border-color:var(--accent)}.hint{font-size:12px;color:var(--muted);margin-top:5px}.actions{display:flex;gap:12px;flex-wrap:wrap;margin-top:20px}button{border:0;border-radius:10px;padding:12px 18px;font:600 14px system-ui;cursor:pointer;background:var(--accent);color:#06221d}button.secondary{background:#243751;color:#dbeafe}button:disabled{opacity:.45;cursor:not-allowed}.fingerprint{margin-top:18px;padding:15px;border:1px solid #36506f;border-radius:12px;background:#091321;display:none}.fingerprint code{display:block;word-break:break-all;color:#fde68a;margin:8px 0}.check{display:flex;gap:10px;align-items:flex-start}.check input{width:auto;margin-top:5px}.progress{display:none;margin-top:24px}.bar{height:9px;background:#091321;border-radius:99px;overflow:hidden}.bar span{display:block;height:100%;width:0;background:linear-gradient(90deg,#2dd4bf,#60a5fa);transition:width .25s}.log{margin-top:14px;background:#07101f;border-radius:12px;padding:14px;min-height:120px;max-height:300px;overflow:auto;font:13px/1.55 ui-monospace,monospace;color:#b9c9dd}.error{color:var(--danger)}.result{margin-top:16px;padding:16px;border:1px solid #2dd4bf66;border-radius:12px;display:none}.protocols{display:flex;flex-wrap:wrap;gap:8px}.protocols span{padding:5px 8px;border-radius:7px;background:#18324a;color:#bfdbfe;font-size:12px}@media(max-width:680px){main{margin:22px auto}.grid{grid-template-columns:1fr}.card{padding:18px}}
</style></head><body><main><section class="hero"><span class="badge">localhost only · v__VERSION__</span><h1>Подключить новую ноду</h1><p>Мастер закрепит SSH host key, заменит вход по паролю служебным ключом, создаст профиль из пяти протоколов, установит ноду и проверит соединение с панелью.</p></section>
<section class="card"><form id="form" autocomplete="off"><div class="grid">
<div><label for="server_name">Название сервера</label><input id="server_name" maxlength="30" required placeholder="Moscow-01"></div>
<div><label for="country_code">Код страны</label><input id="country_code" maxlength="2" value="RU" required></div>
<div><label for="node_ip">IPv4 сервера ноды</label><input id="node_ip" inputmode="decimal" required placeholder="203.0.113.10"></div>
<div><label for="ssh_port">SSH-порт</label><input id="ssh_port" type="number" min="1" max="65535" value="22" required></div>
<div class="full"><label for="node_domain">Домен ноды</label><input id="node_domain" required placeholder="node.example.com"><div class="hint">A-запись должна напрямую указывать на IP ноды. Домен нужен для XHTTP/Trojan/Hysteria2 TLS и SelfSteal.</div></div>
<div class="full"><label for="root_password">Пароль root</label><input id="root_password" type="password" required autocomplete="new-password"><div class="hint">Не записывается на диск и удаляется из задания сразу после установки SSH-ключа.</div></div>
</div><div class="actions"><button type="button" class="secondary" id="scan">1. Проверить SSH-ключ</button><button type="submit" id="install" disabled>2. Установить и добавить ноду</button></div>
<div class="fingerprint" id="fingerprint"><strong>ED25519 fingerprint сервера</strong><code id="fp"></code><label class="check"><input type="checkbox" id="confirmed"><span>Я сверил fingerprint с консолью провайдера сервера и подтверждаю, что сервер чистый: существующая Remnawave Node не будет заменена.</span></label></div></form>
<section class="progress" id="progress"><div class="bar"><span id="bar"></span></div><p id="status">Подготовка…</p><div class="log" id="log"></div><div class="result" id="result"></div></section></section></main>
<script nonce="__NONCE__">
const csrf=__CSRF__;let hostKey='',scannedSignature='',timer=null;
const $=id=>document.getElementById(id);const fields=['server_name','country_code','node_ip','ssh_port','node_domain'];
const signature=()=>fields.map(id=>$(id).value.trim()).join('|');
fields.forEach(id=>$(id).addEventListener('input',()=>{if(signature()!==scannedSignature){hostKey='';$('confirmed').checked=false;$('fingerprint').style.display='none';$('install').disabled=true}}));
$('confirmed').addEventListener('change',()=>{$('install').disabled=!($('confirmed').checked&&hostKey)});
async function api(path,body){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Remnawave-CSRF':csrf},body:JSON.stringify(body)});const j=await r.json();if(!r.ok)throw new Error(j.error||'Ошибка запроса');return j}
$('scan').addEventListener('click',async()=>{try{$('scan').disabled=true;const j=await api('/api/host-key',{server_name:$('server_name').value,country_code:$('country_code').value,node_ip:$('node_ip').value,ssh_port:$('ssh_port').value,node_domain:$('node_domain').value});hostKey=j.line;scannedSignature=signature();$('fp').textContent=j.fingerprint;$('fingerprint').style.display='block'}catch(e){alert(e.message)}finally{$('scan').disabled=false}});
$('form').addEventListener('submit',async e=>{e.preventDefault();if(!hostKey||!$('confirmed').checked)return;const body={server_name:$('server_name').value,country_code:$('country_code').value,node_ip:$('node_ip').value,ssh_port:$('ssh_port').value,node_domain:$('node_domain').value,root_password:$('root_password').value,expected_host_key:hostKey,host_key_confirmed:true};$('root_password').value='';$('install').disabled=true;$('scan').disabled=true;$('progress').style.display='block';try{const j=await api('/api/provision',body);poll(j.job_id)}catch(err){$('status').innerHTML='<span class="error">'+escapeHtml(err.message)+'</span>'}});
function escapeHtml(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function poll(id){try{const r=await fetch('/api/jobs/'+encodeURIComponent(id),{cache:'no-store'});const j=await r.json();$('bar').style.width=j.progress+'%';$('status').textContent=j.status==='complete'?'Готово':j.status==='failed'?'Ошибка':`Выполняется · ${j.progress}%`;$('log').innerHTML=j.messages.map(x=>'<div>'+escapeHtml(x.message)+'</div>').join('');$('log').scrollTop=$('log').scrollHeight;if(j.status==='complete'){const p=j.result.protocols.map(x=>'<span>'+escapeHtml(x)+'</span>').join('');$('result').style.display='block';$('result').innerHTML='<strong>Нода подключена</strong><p>'+escapeHtml(j.result.domain)+'</p><div class="protocols">'+p+'</div>';return}if(j.status==='failed'){$('status').innerHTML='<span class="error">'+escapeHtml(j.error)+'</span>';return}timer=setTimeout(()=>poll(id),1500)}catch(e){timer=setTimeout(()=>poll(id),3000)}}
</script></body></html>'''
    return page.replace("__NONCE__", nonce).replace("__VERSION__", APP_VERSION).replace("__CSRF__", json.dumps(CSRF_TOKEN))


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "RemnawaveWeb/" + APP_VERSION

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _host_allowed(self) -> bool:
        host = self.headers.get("Host", "").lower()
        bare = host.rsplit(":", 1)[0] if not host.startswith("[") else host.split("]", 1)[0] + "]"
        return bare in {"127.0.0.1", "localhost", "[::1]"}

    def _cookie_authorized(self) -> bool:
        if not self._host_allowed():
            return False
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        value = cookie.get("rw_session")
        return value is not None and hmac.compare_digest(value.value, ACCESS_TOKEN)

    def _csrf_authorized(self) -> bool:
        return self._cookie_authorized() and hmac.compare_digest(
            self.headers.get("X-Remnawave-CSRF", ""), CSRF_TOKEN
        )

    def _headers(self, status: int, content_type: str, length: int, extra: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        self._headers(status, "application/json; charset=utf-8", len(raw))
        self.wfile.write(raw)

    def _read_json(self) -> dict[str, Any]:
        if self.headers.get_content_type() != "application/json":
            raise UserVisibleError("Ожидается application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise UserVisibleError("Некорректный Content-Length") from exc
        if length < 1 or length > MAX_BODY:
            raise UserVisibleError("Некорректный размер запроса")
        try:
            value = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            raise UserVisibleError("Некорректный JSON") from exc
        if not isinstance(value, dict):
            raise UserVisibleError("JSON должен быть объектом")
        return value

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/" and not self._cookie_authorized():
            supplied = urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
            if self._host_allowed() and supplied and hmac.compare_digest(supplied, ACCESS_TOKEN):
                raw = b""
                self._headers(
                    303, "text/plain", 0,
                    {"Location": "/", "Set-Cookie": f"rw_session={ACCESS_TOKEN}; HttpOnly; SameSite=Strict; Path=/"},
                )
                if raw:
                    self.wfile.write(raw)
                return
            self._json(403, {"error": "Откройте URL, который вывела команда web-install"})
            return
        if not self._cookie_authorized():
            self._json(403, {"error": "Доступ запрещён"})
            return
        if parsed.path == "/":
            raw = render_page().encode()
            self._headers(200, "text/html; charset=utf-8", len(raw))
            self.wfile.write(raw)
            return
        if parsed.path.startswith("/api/jobs/"):
            job_id = parsed.path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                self._json(404, {"error": "Задание не найдено"})
                return
            self._json(200, job.snapshot())
            return
        self._json(404, {"error": "Не найдено"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._csrf_authorized():
            self._json(403, {"error": "Доступ запрещён"})
            return
        try:
            data = self._read_json()
            values = validate_payload(data)
            if self.path == "/api/host-key":
                verify_dns(values["node_domain"], values["node_ip"])
                scanned = scan_host_key(values["node_ip"], values["ssh_port"])
                self._json(200, {"line": scanned["line"], "fingerprint": scanned["fingerprint"]})
                return
            if self.path == "/api/provision":
                if data.get("host_key_confirmed") is not True:
                    raise UserVisibleError("Подтвердите SSH fingerprint")
                password_text = str(data.pop("root_password", ""))
                if not password_text or len(password_text) > 1024 or "\x00" in password_text:
                    raise UserVisibleError("Введите root-пароль")
                expected = str(data.get("expected_host_key", ""))
                if not HOST_KEY_RE.fullmatch(expected.strip()):
                    raise UserVisibleError("Сначала проверьте SSH host key")
                with JOBS_LOCK:
                    if any(job.status in {"queued", "running"} for job in JOBS.values()):
                        raise UserVisibleError("Другая установка уже выполняется")
                    job = Job(id=uuid.uuid4().hex)
                    JOBS[job.id] = job
                    if len(JOBS) > 20:
                        oldest = sorted(JOBS.values(), key=lambda item: item.created_at)[:-20]
                        for old_job in oldest:
                            if old_job.status not in {"queued", "running"}:
                                JOBS.pop(old_job.id, None)
                password = bytearray(password_text.encode("utf-8"))
                password_text = ""
                thread = threading.Thread(
                    target=provision_job, args=(job, values, password, expected.strip()), daemon=True,
                    name=f"provision-{job.id[:8]}",
                )
                thread.start()
                self._json(202, {"job_id": job.id})
                return
            self._json(404, {"error": "Не найдено"})
        except UserVisibleError as exc:
            self._json(400, {"error": sanitize_log(str(exc))})
        except Exception:
            self._json(500, {"error": "Внутренняя ошибка мастера"})


def main() -> None:
    require_runtime_configuration()
    ensure_ssh_key()
    api = RemnawaveApi()
    response = api.request("GET", "/api/config-profiles")
    if not isinstance(response.get("response"), dict):
        raise SystemExit("Configured API token cannot read Config Profiles")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Handler)
    server.daemon_threads = True
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
