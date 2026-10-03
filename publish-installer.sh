#!/usr/bin/env bash
# Publish a validated, immutable installer release and an atomic "latest" copy.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLER_SOURCE="${1:-${SCRIPT_DIR}/install-3xui-full.sh}"
PUBLISH_ROOT="${PUBLISH_ROOT:-/var/www/3xui-installer}"
PUBLISH_BASE_URL="${PUBLISH_BASE_URL:-}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf 'INFO: %s\n' "$*"; }

[[ -f "$INSTALLER_SOURCE" ]] || die "installer not found: ${INSTALLER_SOURCE}"
[[ -r "$INSTALLER_SOURCE" ]] || die "installer is not readable: ${INSTALLER_SOURCE}"
bash -n "$INSTALLER_SOURCE" || die "installer failed bash syntax validation"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$INSTALLER_SOURCE" || die "ShellCheck reported errors"
    info "ShellCheck passed"
else
    info "ShellCheck is not installed; bash -n passed"
fi

INSTALLER_VERSION="$(sed -n 's/^readonly INSTALLER_VERSION="\([^"]*\)"$/\1/p' "$INSTALLER_SOURCE" | head -1)"
[[ "$INSTALLER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || \
    die "cannot read a valid INSTALLER_VERSION from ${INSTALLER_SOURCE}"

if command -v sha256sum >/dev/null 2>&1; then
    SOURCE_SHA256="$(sha256sum "$INSTALLER_SOURCE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    SOURCE_SHA256="$(shasum -a 256 "$INSTALLER_SOURCE" | awk '{print $1}')"
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
printf '%s  %s\n' "$SOURCE_SHA256" 'install-3xui-full.sh' > "${RELEASE_DIR}/install-3xui-full.sh.sha256"
chmod 644 "${RELEASE_DIR}/install-3xui-full.sh.sha256"

STAGING_DIR="$(mktemp -d "${PUBLISH_ROOT}/.publish.XXXXXX")"
cleanup() { rm -rf -- "$STAGING_DIR"; }
trap cleanup EXIT
install -m 644 "$INSTALLER_SOURCE" "${STAGING_DIR}/install-3xui-full.sh"
printf '%s  %s\n' "$SOURCE_SHA256" 'install-3xui-full.sh' > "${STAGING_DIR}/SHA256SUMS"
printf '%s  %s\n' "$SOURCE_SHA256" 'install-3xui-full.sh' > "${STAGING_DIR}/install-3xui-full.sh.sha256"
chmod 644 "${STAGING_DIR}/SHA256SUMS"
chmod 644 "${STAGING_DIR}/install-3xui-full.sh.sha256"
mv -f -- "${STAGING_DIR}/install-3xui-full.sh" "${PUBLISH_ROOT}/install-3xui-full.sh"
mv -f -- "${STAGING_DIR}/SHA256SUMS" "${PUBLISH_ROOT}/SHA256SUMS"
mv -f -- "${STAGING_DIR}/install-3xui-full.sh.sha256" "${PUBLISH_ROOT}/install-3xui-full.sh.sha256"

printf '%s\n' "$INSTALLER_VERSION" > "${PUBLISH_ROOT}/VERSION.tmp"
chmod 644 "${PUBLISH_ROOT}/VERSION.tmp"
mv -f -- "${PUBLISH_ROOT}/VERSION.tmp" "${PUBLISH_ROOT}/VERSION"

info "Published installer ${INSTALLER_VERSION}"
info "SHA-256: ${SOURCE_SHA256}"
info "Release: ${RELEASE_FILE}"
info "Latest:  ${PUBLISH_ROOT}/install-3xui-full.sh"

if [[ -n "$PUBLISH_BASE_URL" ]]; then
    PUBLISH_BASE_URL="${PUBLISH_BASE_URL%/}"
    printf '\nDownload URLs\n'
    printf '  %s/install-3xui-full.sh\n' "$PUBLISH_BASE_URL"
    printf '  %s/install-3xui-full.sh.sha256\n' "$PUBLISH_BASE_URL"
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
