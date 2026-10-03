#!/usr/bin/env bash
# Publish a validated, immutable installer release and an atomic "latest" copy.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLER_SOURCE="${1:-${SCRIPT_DIR}/install-3xui-full.sh}"
REMNAWAVE_SOURCE="${REMNAWAVE_SOURCE:-${SCRIPT_DIR}/remnawave-manager.sh}"
REMNAWAVE_WEB_SOURCE="${REMNAWAVE_WEB_SOURCE:-${SCRIPT_DIR}/remnawave-web.py}"
PUBLISH_ROOT="${PUBLISH_ROOT:-/var/www/3xui-installer}"
PUBLISH_BASE_URL="${PUBLISH_BASE_URL:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }

[[ -f "$INSTALLER_SOURCE" ]] || die "installer not found: ${INSTALLER_SOURCE}"
[[ -r "$INSTALLER_SOURCE" ]] || die "installer is not readable: ${INSTALLER_SOURCE}"
[[ -r "$REMNAWAVE_SOURCE" ]] || die "Remnawave companion is not readable: ${REMNAWAVE_SOURCE}"
[[ -r "$REMNAWAVE_WEB_SOURCE" ]] || die "Remnawave web companion is not readable: ${REMNAWAVE_WEB_SOURCE}"
bash -n "$INSTALLER_SOURCE" || die "installer failed bash syntax validation"
bash -n "$REMNAWAVE_SOURCE" || die "Remnawave companion failed bash syntax validation"
python3 -m py_compile "$REMNAWAVE_WEB_SOURCE" || die "Remnawave web companion failed Python syntax validation"
if [[ -d "${SCRIPT_DIR}/tests" ]]; then
    python3 -m unittest discover -s "${SCRIPT_DIR}/tests" -v || die "Remnawave web tests failed"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$INSTALLER_SOURCE" "$REMNAWAVE_SOURCE" || die "ShellCheck reported errors"
    info "ShellCheck passed"
else
    info "ShellCheck is not installed; bash -n passed"
fi

INSTALLER_VERSION="$(sed -n 's/^readonly INSTALLER_VERSION="\([^"]*\)"$/\1/p' "$INSTALLER_SOURCE" | head -1)"
[[ "$INSTALLER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || \
    die "cannot read a valid INSTALLER_VERSION from ${INSTALLER_SOURCE}"

if command -v sha256sum >/dev/null 2>&1; then
    SOURCE_SHA256="$(sha256sum "$INSTALLER_SOURCE" | awk '{print $1}')"
    REMNAWAVE_SHA256="$(sha256sum "$REMNAWAVE_SOURCE" | awk '{print $1}')"
    REMNAWAVE_WEB_SHA256="$(sha256sum "$REMNAWAVE_WEB_SOURCE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    SOURCE_SHA256="$(shasum -a 256 "$INSTALLER_SOURCE" | awk '{print $1}')"
    REMNAWAVE_SHA256="$(shasum -a 256 "$REMNAWAVE_SOURCE" | awk '{print $1}')"
    REMNAWAVE_WEB_SHA256="$(shasum -a 256 "$REMNAWAVE_WEB_SOURCE" | awk '{print $1}')"
else
    die "sha256sum or shasum is required"
fi

install -d -m 755 "$PUBLISH_ROOT" "$PUBLISH_ROOT/releases"
RELEASE_DIR="${PUBLISH_ROOT}/releases/${INSTALLER_VERSION}"
RELEASE_FILE="${RELEASE_DIR}/install-3xui-full.sh"

if [[ -f "$RELEASE_FILE" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
        PUBLISHED_SHA256="$(sha256sum "$RELEASE_FILE" | awk '{print $1}')"
    else
        PUBLISHED_SHA256="$(shasum -a 256 "$RELEASE_FILE" | awk '{print $1}')"
    fi
    [[ "$PUBLISHED_SHA256" == "$SOURCE_SHA256" ]] || \
        die "release ${INSTALLER_VERSION} already exists with different content; bump INSTALLER_VERSION"
    info "Immutable release ${INSTALLER_VERSION} already matches the source"
else
    install -d -m 755 "$RELEASE_DIR"
    install -m 644 "$INSTALLER_SOURCE" "$RELEASE_FILE"
fi
if [[ -f "${RELEASE_DIR}/remnawave-manager.sh" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
        PUBLISHED_REMNAWAVE_SHA256="$(sha256sum "${RELEASE_DIR}/remnawave-manager.sh" | awk '{print $1}')"
    else
        PUBLISHED_REMNAWAVE_SHA256="$(shasum -a 256 "${RELEASE_DIR}/remnawave-manager.sh" | awk '{print $1}')"
    fi
    [[ "$PUBLISHED_REMNAWAVE_SHA256" == "$REMNAWAVE_SHA256" ]] || \
        die "release ${INSTALLER_VERSION} companion exists with different content; bump INSTALLER_VERSION"
else
    install -m 644 "$REMNAWAVE_SOURCE" "${RELEASE_DIR}/remnawave-manager.sh"
fi
if [[ -f "${RELEASE_DIR}/remnawave-web.py" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
        PUBLISHED_REMNAWAVE_WEB_SHA256="$(sha256sum "${RELEASE_DIR}/remnawave-web.py" | awk '{print $1}')"
    else
        PUBLISHED_REMNAWAVE_WEB_SHA256="$(shasum -a 256 "${RELEASE_DIR}/remnawave-web.py" | awk '{print $1}')"
    fi
    [[ "$PUBLISHED_REMNAWAVE_WEB_SHA256" == "$REMNAWAVE_WEB_SHA256" ]] || \
        die "release ${INSTALLER_VERSION} web companion exists with different content; bump INSTALLER_VERSION"
else
    install -m 644 "$REMNAWAVE_WEB_SOURCE" "${RELEASE_DIR}/remnawave-web.py"
fi

printf '%s  %s\n' "$SOURCE_SHA256" 'install-3xui-full.sh' > "${RELEASE_DIR}/install-3xui-full.sh.sha256"
printf '%s  %s\n' "$REMNAWAVE_SHA256" 'remnawave-manager.sh' > "${RELEASE_DIR}/remnawave-manager.sh.sha256"
printf '%s  %s\n' "$REMNAWAVE_WEB_SHA256" 'remnawave-web.py' > "${RELEASE_DIR}/remnawave-web.py.sha256"
chmod 644 "${RELEASE_DIR}/install-3xui-full.sh.sha256"
chmod 644 "${RELEASE_DIR}/remnawave-manager.sh.sha256"
chmod 644 "${RELEASE_DIR}/remnawave-web.py.sha256"

STAGING_DIR="$(mktemp -d "${PUBLISH_ROOT}/.publish.XXXXXX")"
cleanup() { rm -rf -- "$STAGING_DIR"; }
trap cleanup EXIT
install -m 644 "$INSTALLER_SOURCE" "${STAGING_DIR}/install-3xui-full.sh"
install -m 644 "$REMNAWAVE_SOURCE" "${STAGING_DIR}/remnawave-manager.sh"
install -m 644 "$REMNAWAVE_WEB_SOURCE" "${STAGING_DIR}/remnawave-web.py"
printf '%s  %s\n%s  %s\n%s  %s\n' \
    "$SOURCE_SHA256" 'install-3xui-full.sh' \
    "$REMNAWAVE_SHA256" 'remnawave-manager.sh' \
    "$REMNAWAVE_WEB_SHA256" 'remnawave-web.py' > "${STAGING_DIR}/SHA256SUMS"
printf '%s  %s\n' "$SOURCE_SHA256" 'install-3xui-full.sh' > "${STAGING_DIR}/install-3xui-full.sh.sha256"
printf '%s  %s\n' "$REMNAWAVE_SHA256" 'remnawave-manager.sh' > "${STAGING_DIR}/remnawave-manager.sh.sha256"
printf '%s  %s\n' "$REMNAWAVE_WEB_SHA256" 'remnawave-web.py' > "${STAGING_DIR}/remnawave-web.py.sha256"
chmod 644 "${STAGING_DIR}/SHA256SUMS"
chmod 644 "${STAGING_DIR}/install-3xui-full.sh.sha256"
chmod 644 "${STAGING_DIR}/remnawave-manager.sh.sha256"
chmod 644 "${STAGING_DIR}/remnawave-web.py.sha256"
mv -f -- "${STAGING_DIR}/install-3xui-full.sh" "${PUBLISH_ROOT}/install-3xui-full.sh"
mv -f -- "${STAGING_DIR}/remnawave-manager.sh" "${PUBLISH_ROOT}/remnawave-manager.sh"
mv -f -- "${STAGING_DIR}/remnawave-web.py" "${PUBLISH_ROOT}/remnawave-web.py"
mv -f -- "${STAGING_DIR}/SHA256SUMS" "${PUBLISH_ROOT}/SHA256SUMS"
mv -f -- "${STAGING_DIR}/install-3xui-full.sh.sha256" "${PUBLISH_ROOT}/install-3xui-full.sh.sha256"
mv -f -- "${STAGING_DIR}/remnawave-manager.sh.sha256" "${PUBLISH_ROOT}/remnawave-manager.sh.sha256"
mv -f -- "${STAGING_DIR}/remnawave-web.py.sha256" "${PUBLISH_ROOT}/remnawave-web.py.sha256"

printf '%s\n' "$INSTALLER_VERSION" > "${PUBLISH_ROOT}/VERSION.tmp"
chmod 644 "${PUBLISH_ROOT}/VERSION.tmp"
mv -f -- "${PUBLISH_ROOT}/VERSION.tmp" "${PUBLISH_ROOT}/VERSION"

info "Published installer ${INSTALLER_VERSION}"
info "SHA-256: ${SOURCE_SHA256}"
info "Release: ${RELEASE_FILE}"
info "Latest:  ${PUBLISH_ROOT}/install-3xui-full.sh"
info "Companion: ${PUBLISH_ROOT}/remnawave-manager.sh"
info "Web companion: ${PUBLISH_ROOT}/remnawave-web.py"

if [[ -n "$PUBLISH_BASE_URL" ]]; then
    PUBLISH_BASE_URL="${PUBLISH_BASE_URL%/}"
    printf '\nDownload URLs\n'
    printf '  %s/install-3xui-full.sh\n' "$PUBLISH_BASE_URL"
    printf '  %s/install-3xui-full.sh.sha256\n' "$PUBLISH_BASE_URL"
    printf '  %s/remnawave-manager.sh\n' "$PUBLISH_BASE_URL"
    printf '  %s/remnawave-manager.sh.sha256\n' "$PUBLISH_BASE_URL"
    printf '  %s/remnawave-web.py\n' "$PUBLISH_BASE_URL"
    printf '  %s/remnawave-web.py.sha256\n' "$PUBLISH_BASE_URL"
    printf '  %s/releases/%s/install-3xui-full.sh\n' "$PUBLISH_BASE_URL" "$INSTALLER_VERSION"
else
    printf '\nSet PUBLISH_BASE_URL=https://your.example/path to print public URLs.\n'
fi

if command -v nginx >/dev/null 2>&1; then
    info "nginx detected; make sure its document root or an alias exposes ${PUBLISH_ROOT}"
elif command -v caddy >/dev/null 2>&1; then
    info "Caddy detected; make sure a file_server route exposes ${PUBLISH_ROOT}"
elif command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
    info "Apache detected; make sure an Alias or DocumentRoot exposes ${PUBLISH_ROOT}"
else
    info "No nginx/Caddy/Apache binary detected; files were published locally only"
fi
