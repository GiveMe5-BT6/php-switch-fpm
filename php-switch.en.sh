#!/usr/bin/env bash
# php-switch - PHP version switcher and installer (CLI + Apache2 FPM)
# Copyright (c) 2026 GiveMe5-BT6
# SPDX-License-Identifier: MIT
# https://github.com/GiveMe5-BT6/php-switch-fpm
#
# php-switch - Switch the PHP version for the Linux console (CLI) and Apache2 (FPM)
#            + install missing PHP versions (including FPM)
#
# Usage:
#   php-switch                       -> interactive menu
#   php-switch 8.5                   -> switch to PHP 8.5 (CLI + FPM)
#   php-switch --list                -> show installed versions
#   php-switch --available           -> installable vs. installed versions
#   php-switch --ensure-repo         -> bind/update Sury repo if missing
#   php-switch --update              -> patch updates + new minor versions
#   php-switch --update --patches-only -> patch updates only (no new versions)
#   php-switch --update --dry-run    -> show only, change nothing
#   php-switch --install 7.4         -> install PHP 7.4 (CLI + FPM + standard extensions)
#   php-switch --install 7.4 --minimal  -> only php7.4-fpm
#   php-switch --install 7.4 --switch   -> install and activate immediately
#   php-switch --cli 5.6             -> switch CLI only
#   php-switch --fpm 8.5             -> switch Apache/FPM only
#   php-switch --stop-others         -> stop other FPMs on switch
#   php-switch --yes                 -> no prompts (for --install/--update)
#
# Requires: root privileges

set -euo pipefail

PHP_ETC="/etc/php"
APACHE_CONF_AVAIL="/etc/apache2/conf-available"
APACHE_CONF_ENABLED="/etc/apache2/conf-enabled"
INSTALL_LOG="/var/log/php-switch-install.log"

DEFAULT_EXTENSIONS="mysql mbstring xml curl gd zip bcmath intl"

# ---------- Helpers ----------
log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

# ---------- Help ----------
show_help() {
    awk '/^set -euo pipefail$/{exit} {print}' "$0"
}

# ---------- Version detection ----------
# Installed PHP versions (from /etc/php/*/fpm/pool.d/www.conf)
available_versions() {
    local d v
    for d in "$PHP_ETC"/*/; do
        [ -d "$d" ] || continue
        v=$(basename "$d")
        if [ -f "$d/fpm/pool.d/www.conf" ]; then
            if systemctl list-unit-files 2>/dev/null | grep "php${v}-fpm" >/dev/null 2>&1; then
                echo "$v"
            fi
        fi
    done
}

# Installable PHP versions from apt
available_apt_versions() {
    apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null \
        | awk '{print $1}' \
        | sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' \
        | sort -V
}

is_installed() {
    [ -d "/etc/php/$1/fpm" ] && systemctl list-unit-files 2>/dev/null | grep "php$1-fpm" >/dev/null 2>&1
}

# ---------- Sury repo ----------
SUPPORTED_CODENAMES="xenial bionic focal jammy noble buster bullseye bookworm trixie"

ensure_sury_repo() {
    # Check whether Sury is already configured
    if grep -rh "packages.sury.org/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep "packages.sury.org/php" >/dev/null 2>&1; then
        return 0
    fi

    log "Sury repo not found - binding it ..."

    # Ensure GPG key
    if [ ! -f /etc/apt/trusted.gpg.d/sury-php.gpg ]; then
        if ! command -v curl >/dev/null 2>&1; then
            err "curl not found - cannot download GPG key."
            return 1
        fi
        if ! command -v gpg >/dev/null 2>&1; then
            err "gpg not found - cannot process GPG key."
            return 1
        fi
        if ! curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg 2>/dev/null; then
            err "GPG key could not be downloaded/processed."
            return 1
        fi
        log "GPG key installed."
    fi

    # Determine codename (fall back to noble, since Sury does not yet support newer codenames)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || true)
    if [ -z "$codename" ]; then
        codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-noble}")
    fi
    if ! echo " $SUPPORTED_CODENAMES " | grep -q " $codename "; then
        warn "Codename '$codename' is not supported by Sury - using 'noble' as fallback."
        codename="noble"
    fi

    echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/sury-php.list
    log "Sury repo bound (codename: $codename)."

    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update failed (see $INSTALL_LOG)."
        return 1
    fi
    return 0
}

current_cli_version() {
    if command -v php >/dev/null 2>&1; then
        php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true
    fi
}

current_fpm_version() {
    local f
    for f in "$APACHE_CONF_ENABLED"/php*-fpm.conf; do
        [ -e "$f" ] || continue
        basename "$f" | sed -E 's/^php([0-9.]+)-fpm\.conf$/\1/'
        return 0
    done
    echo "(none)"
}

# ---------- Switch CLI ----------
switch_cli() {
    local v="$1"
    if [ ! -x "/usr/bin/php${v}" ]; then
        err "CLI binary /usr/bin/php${v} not found."
        return 1
    fi
    if command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --set php "/usr/bin/php${v}" >/dev/null
    else
        ln -sfn "/usr/bin/php${v}" /usr/bin/php
    fi
    log "CLI switched to PHP ${v} (php -v: $(php -r 'echo PHP_VERSION;'))"
}

# ---------- Switch FPM/Apache ----------
switch_fpm() {
    local v="$1"
    local stop_others="${2:-0}"

    if [ ! -f "$APACHE_CONF_AVAIL/php${v}-fpm.conf" ]; then
        err "Apache config $APACHE_CONF_AVAIL/php${v}-fpm.conf not found."
        return 1
    fi
    if ! systemctl list-unit-files 2>/dev/null | grep "php${v}-fpm" >/dev/null 2>&1; then
        err "FPM service php${v}-fpm not installed."
        return 1
    fi

    # Disable all php*-fpm confs
    local f
    for f in "$APACHE_CONF_ENABLED"/php*-fpm.conf; do
        [ -e "$f" ] || continue
        a2disconf "$(basename "$f" .conf)" >/dev/null 2>&1 || true
    done

    # Enable new conf
    a2enconf "php${v}-fpm" >/dev/null
    log "Apache conf php${v}-fpm enabled."

    # FPM services
    if [ "$stop_others" = "1" ]; then
        local svc
        for svc in $(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do
            [ "$svc" = "php${v}-fpm.service" ] && continue
            systemctl stop "$svc" 2>/dev/null || true
        done
    fi
    systemctl enable "php${v}-fpm" >/dev/null 2>&1 || true
    systemctl restart "php${v}-fpm"
    log "FPM service php${v}-fpm started."

    # Reload Apache
    if systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl reload apache2
        log "Apache2 reloaded."
    else
        warn "Apache2 is not running - no reload."
    fi
}

# ---------- Status ----------
show_status() {
    echo "Available PHP versions: $(available_versions | tr '\n' ' ')"
    echo "Current CLI:  $(current_cli_version)"
    echo "Current FPM:  $(current_fpm_version)"
}

# ---------- Install ----------
install_php() {
    local v="$1"
    local minimal="$2"
    local switch_after="$3"
    local assume_yes="${4:-0}"

    # Validate version format
    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        err "Invalid version format: '$v' (expected e.g. 7.4)"
        return 1
    fi

    # Already installed?
    if is_installed "$v"; then
        warn "PHP $v is already installed."
        if [ "$switch_after" = "1" ]; then
            switch_cli "$v"
            switch_fpm "$v" "$STOP_OTHERS"
        fi
        return 0
    fi

    # Ensure Sury repo (if missing)
    if ! ensure_sury_repo; then
        err "Sury repo could not be bound."
        return 1
    fi

    # Available in repo?
    if ! apt-cache show "php${v}-fpm" >/dev/null 2>&1; then
        err "php${v}-fpm is not available in the configured repositories."
        err "Check the Sury repo: deb https://packages.sury.org/php/ <distro> main"
        return 1
    fi

    echo "=> Installing PHP ${v}"
    echo "   Base: php${v}-fpm (brings cli, common, opcache, json)"

    # Build package list
    local pkgs="php${v}-fpm"
    local ext
    if [ "$minimal" != "1" ]; then
        echo "   Standard extensions: $DEFAULT_EXTENSIONS"
        for ext in $DEFAULT_EXTENSIONS; do
            if apt-cache show "php${v}-${ext}" >/dev/null 2>&1; then
                pkgs="$pkgs php${v}-${ext}"
            else
                warn "Extension php${v}-${ext} not available, skipping."
            fi
        done
    fi

    if [ "$YES" != "1" ] && [ "$assume_yes" != "1" ]; then
        echo
        echo "The following packages will be installed:"
        echo "  $pkgs"
        printf 'Proceed? [y/N]: '
        read -r confirm
        case "$confirm" in
            y|Y|yes|j|J|ja) ;;
            *) err "Aborted."; return 1 ;;
        esac
    fi

    export DEBIAN_FRONTEND=noninteractive
    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update failed (see $INSTALL_LOG)."
        return 1
    fi

    log "apt-get install -y $pkgs ..."
    if ! apt-get install -y $pkgs 2>&1 | tee -a "$INSTALL_LOG"; then
        err "Installation failed (see $INSTALL_LOG)."
        return 1
    fi

    # Enable and start service
    systemctl enable "php${v}-fpm" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
        systemctl restart "php${v}-fpm" 2>/dev/null || true
    else
        systemctl start "php${v}-fpm" 2>/dev/null || true
    fi

    log "PHP ${v} installed (FPM service started)."
    echo "   Apache conf: $APACHE_CONF_AVAIL/php${v}-fpm.conf (activate with 'php-switch --fpm ${v}')"

    if [ "$switch_after" = "1" ]; then
        switch_cli "$v"
        switch_fpm "$v" "$STOP_OTHERS"
    fi
}

# ---------- Update helpers ----------
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

installed_php_packages() {
    dpkg-query -W -f='${Package}\n' "php${1}-*" 2>/dev/null || true
}

php_patches_available() {
    apt list --upgradable 2>/dev/null | awk -F/ '{print $1}' | grep -E "^php${1}-" || true
}

newer_apt_versions() {
    local max v
    max=$(available_versions | sort -V | tail -1)
    [ -z "$max" ] && return 0
    for v in $(available_apt_versions); do
        is_installed "$v" && continue
        if version_gt "$v" "$max"; then
            echo "$v"
        fi
    done
}

# ---------- Update ----------
update_patches() {
    local v pkgs avail
    for v in $(available_versions); do
        avail=$(php_patches_available "$v")
        if [ -z "$avail" ]; then
            log "PHP ${v}: no patch updates available."
            continue
        fi
        echo "=> PHP ${v}: patch updates available:"
        echo "$avail" | sed 's/^/   /'
        pkgs=$(installed_php_packages "$v")
        if [ -z "$pkgs" ]; then
            warn "No installed packages found for PHP ${v}."
            continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY-RUN: apt-get install --only-upgrade -y $pkgs"
            continue
        fi
        export DEBIAN_FRONTEND=noninteractive
        log "apt-get update ..."
        if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
            err "apt-get update failed (see $INSTALL_LOG)."
            return 1
        fi
        log "apt-get install --only-upgrade -y $pkgs ..."
        if ! apt-get install --only-upgrade -y $pkgs 2>&1 | tee -a "$INSTALL_LOG"; then
            err "Patch update for PHP ${v} failed (see $INSTALL_LOG)."
            return 1
        fi
        log "PHP ${v} patch updates applied."
    done
}

update_new_minors() {
    local versions v
    versions=$(newer_apt_versions)
    if [ -z "$versions" ]; then
        log "No new minor versions available."
        return 0
    fi
    echo "=> New minor versions available:"
    for v in $versions; do
        echo "   $v"
    done

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: no installation."
        return 0
    fi

    if [ "$YES" != "1" ]; then
        echo
        printf 'Install these versions? [y/N]: '
        read -r confirm
        case "$confirm" in
            y|Y|yes|j|J|ja) ;;
            *) warn "New minor versions skipped."; return 0 ;;
        esac
    fi

    for v in $versions; do
        install_php "$v" "$MINIMAL" 0 1 || warn "Installation of PHP ${v} failed - skipped."
    done
}

# ---------- Main ----------
need_root

# Remember whether called without arguments
NO_ARGS=0
if [ $# -eq 0 ]; then
    NO_ARGS=1
fi

MODE="both"
TARGET=""
CLI_ONLY=0
FPM_ONLY=0
STOP_OTHERS=0
LIST=0
SHOW_AVAILABLE=0
ENSURE_REPO=0
DO_UPDATE=0
PATCHES_ONLY=0
DRY_RUN=0
INSTALL_VERSION=""
MINIMAL=0
SWITCH_AFTER=0
YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1; shift ;;
        --available) SHOW_AVAILABLE=1; shift ;;
        --ensure-repo) ENSURE_REPO=1; shift ;;
        --update) DO_UPDATE=1; shift ;;
        --patches-only) PATCHES_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --install) INSTALL_VERSION="${2:-}"; shift 2 ;;
        --minimal) MINIMAL=1; shift ;;
        --switch) SWITCH_AFTER=1; shift ;;
        --yes) YES=1; shift ;;
        --cli) CLI_ONLY=1; MODE="cli"; TARGET="${2:-}"; shift 2 ;;
        --fpm) FPM_ONLY=1; MODE="fpm"; TARGET="${2:-}"; shift 2 ;;
        --stop-others) STOP_OTHERS=1; shift ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            if [ -z "$TARGET" ]; then TARGET="$1"; else err "Unknown argument: $1"; exit 1; fi
            shift ;;
    esac
done

# --available
if [ "$SHOW_AVAILABLE" = "1" ]; then
    ensure_sury_repo >/dev/null 2>&1 || true
    echo "Installed versions:"
    for local_v in $(available_versions); do
        echo "  $local_v (installed)"
    done
    echo "Installable (not installed) versions:"
    for local_v in $(available_apt_versions); do
        if ! is_installed "$local_v"; then
            echo "  $local_v"
        fi
    done
    exit 0
fi

# --ensure-repo
if [ "$ENSURE_REPO" = "1" ]; then
    if ensure_sury_repo; then
        log "Sury repo ready."
    else
        err "Sury repo could not be bound."
        exit 1
    fi
    exit 0
fi

# --update
if [ "$DO_UPDATE" = "1" ]; then
    if ! ensure_sury_repo; then
        err "Sury repo could not be bound."
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update failed (see $INSTALL_LOG)."
        exit 1
    fi

    update_patches

    if [ "$PATCHES_ONLY" != "1" ]; then
        update_new_minors
    fi

    echo
    show_status
    echo
    log "Update finished. Active version was not changed."
    echo "   Hint: switch with 'php-switch <version>' (e.g. php-switch 8.6)."
    exit 0
fi

# --install
if [ -n "$INSTALL_VERSION" ]; then
    if [ -z "$INSTALL_VERSION" ]; then
        err "Please specify a version, e.g. --install 7.4"
        exit 1
    fi
    install_php "$INSTALL_VERSION" "$MINIMAL" "$SWITCH_AFTER"
    exit $?
fi

VERSIONS=()
while IFS= read -r _v; do
    [ -n "$_v" ] && VERSIONS+=("$_v")
done < <(available_versions)

if [ ${#VERSIONS[@]} -eq 0 ]; then
    err "No PHP versions with FPM found (/etc/php/*/fpm)."
    err "Hint: install one with 'php-switch --install 7.4'."
    exit 1
fi

# --list
if [ "$LIST" = "1" ]; then
    echo "Installed PHP versions:"
    for v in $(available_versions); do
        mark=""
        if [ "$v" = "$(current_cli_version)" ]; then mark=" (CLI)"; fi
        if [ "$v" = "$(current_fpm_version)" ]; then mark="${mark} (FPM)"; fi
        echo "  $v$mark"
    done
    exit 0
fi

# Without arguments: show help, then interactive menu
if [ "$NO_ARGS" = "1" ]; then
    show_help
    echo
fi

# Interactive menu if no target version given
if [ -z "$TARGET" ]; then
    echo "Available PHP versions:"
    echo "  0) Abort"
    i=1
    for v in "${VERSIONS[@]}"; do
        cur=""
        if [ "$v" = "$(current_cli_version)" ]; then cur+="CLI "; fi
        if [ "$v" = "$(current_fpm_version)" ]; then cur+="FPM "; fi
        if [ -n "$cur" ]; then cur="  <- current ($cur)"; fi
        printf '  %d) %s%s\n' "$i" "$v" "$cur"
        i=$((i+1))
    done
    printf 'Selection (0=abort, number or version): '
    read -r choice
    if [ "$choice" = "0" ]; then
        echo "Aborted."
        exit 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#VERSIONS[@]} ]; then
            err "Invalid selection."
            exit 1
        fi
        TARGET="${VERSIONS[$((choice-1))]}"
    else
        TARGET="$choice"
    fi
fi

# Validate target version (if not installed, give hint)
if ! printf '%s\n' "${VERSIONS[@]}" | grep -qx "$TARGET"; then
    # Maybe available in apt?
    if apt-cache show "php${TARGET}-fpm" >/dev/null 2>&1; then
        err "Version '$TARGET' is not installed, but available."
        err "Install with: php-switch --install $TARGET"
    else
        err "Version '$TARGET' is neither installed nor available."
    fi
    exit 1
fi

echo "=> Switching to PHP ${TARGET}"
echo "   Before: CLI=$(current_cli_version) FPM=$(current_fpm_version)"

if [ "$MODE" = "both" ] || [ "$CLI_ONLY" = "1" ]; then
    switch_cli "$TARGET"
fi
if [ "$MODE" = "both" ] || [ "$FPM_ONLY" = "1" ]; then
    switch_fpm "$TARGET" "$STOP_OTHERS"
fi

echo
show_status
log "Done."
