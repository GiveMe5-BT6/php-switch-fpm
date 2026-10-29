#!/usr/bin/env bash
# php-switch - PHP version switcher and installer (CLI + Apache2 FPM)
# Copyright (c) 2026 GiveMe5-BT6
# SPDX-License-Identifier: MIT
# https://github.com/GiveMe5-BT6/php-switch-fpm
#
# php-switch - PHP-Version für Linux-Console (CLI) und Apache2 (FPM) umstellen
#            + fehlende PHP-Versionen (inkl. FPM) nachinstallieren
#
# Verwendung:
#   php-switch                       -> interaktives Menü
#   php-switch 8.5                   -> auf PHP 8.5 umstellen (CLI + FPM)
#   php-switch --list                -> installierte Versionen anzeigen
#   php-switch --available           -> installierbare vs. installierte Versionen
#   php-switch --ensure-repo         -> Sury-Repo einbinden/aktualisieren (falls fehlend)
#   php-switch --update              -> Patch-Updates + neue Minor-Versionen installieren
#   php-switch --update --patches-only -> nur Patch-Updates (keine neuen Versionen)
#   php-switch --update --dry-run    -> nur anzeigen, nichts installieren
#   php-switch --install 7.4         -> PHP 7.4 (CLI + FPM + Standard-Extensions) installieren
#   php-switch --install 7.4 --minimal  -> nur php7.4-fpm (bringt cli, common, opcache, json mit)
#   php-switch --install 7.4 --switch   -> installieren und direkt aktivieren
#   php-switch --cli 5.6             -> nur CLI umstellen
#   php-switch --fpm 8.5             -> nur Apache/FPM umstellen
#   php-switch --stop-others         -> beim FPM-Wechsel andere FPM stoppen
#   php-switch --yes                 -> keine Rückfrage (für --install)
#
# Benötigt: root-Rechte

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
        err "Dieses Script muss als root ausgeführt werden (sudo)."
        exit 1
    fi
}

# ---------- Hilfe ----------
show_help() {
    awk '/^set -euo pipefail$/{exit} {print}' "$0"
}

# ---------- Versionserkennung ----------
# Installierte PHP-Versionen (aus /etc/php/*/fpm/pool.d/www.conf)
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

# Installierbare PHP-Versionen aus apt
available_apt_versions() {
    apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null \
        | awk '{print $1}' \
        | sed -E 's/^php([0-9]+\.[0-9]+)-fpm$/\1/' \
        | sort -V
}

is_installed() {
    [ -d "/etc/php/$1/fpm" ] && systemctl list-unit-files 2>/dev/null | grep "php$1-fpm" >/dev/null 2>&1
}

# ---------- Update-Helpers ----------
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

installed_php_packages() {
    dpkg-query -W -f='${Package}\\n' "php${1}-*" 2>/dev/null || true
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

# ---------- Sury-Repo sicherstellen ----------
SUPPORTED_CODENAMES="xenial bionic focal jammy noble buster bullseye bookworm trixie"

ensure_sury_repo() {
    # Prüfen, ob Sury bereits konfiguriert ist
    if grep -rh "packages.sury.org/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep "packages.sury.org/php" >/dev/null 2>&1; then
        return 0
    fi

    log "Sury-Repo nicht gefunden - wird eingebunden ..."

    # GPG-Key sicherstellen
    if [ ! -f /etc/apt/trusted.gpg.d/sury-php.gpg ]; then
        if ! command -v curl >/dev/null 2>&1; then
            err "curl nicht gefunden - kann GPG-Key nicht herunterladen."
            return 1
        fi
        if ! command -v gpg >/dev/null 2>&1; then
            err "gpg nicht gefunden - kann GPG-Key nicht verarbeiten."
            return 1
        fi
        if ! curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/sury-php.gpg 2>/dev/null; then
            err "GPG-Key konnte nicht heruntergeladen/verarbeitet werden."
            return 1
        fi
        log "GPG-Key installiert."
    fi

    # Codename bestimmen (Fallback auf noble, da Sury neuere Codenames noch nicht unterstützt)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || true)
    if [ -z "$codename" ]; then
        codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-noble}")
    fi
    if ! echo " $SUPPORTED_CODENAMES " | grep -q " $codename "; then
        warn "Codename '$codename' nicht von Sury unterstützt - nutze 'noble' als Fallback."
        codename="noble"
    fi

    echo "deb https://packages.sury.org/php/ $codename main" > /etc/apt/sources.list.d/sury-php.list
    log "Sury-Repo eingebunden (Codename: $codename)."

    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update fehlgeschlagen (siehe $INSTALL_LOG)."
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
    echo "(keine)"
}

# ---------- CLI umstellen ----------
switch_cli() {
    local v="$1"
    if [ ! -x "/usr/bin/php${v}" ]; then
        err "CLI-Binary /usr/bin/php${v} nicht gefunden."
        return 1
    fi
    if command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --set php "/usr/bin/php${v}" >/dev/null
    else
        ln -sfn "/usr/bin/php${v}" /usr/bin/php
    fi
    log "CLI auf PHP ${v} umgestellt (php -v: $(php -r 'echo PHP_VERSION;'))"
}

# ---------- FPM/Apache umstellen ----------
switch_fpm() {
    local v="$1"
    local stop_others="${2:-0}"

    if [ ! -f "$APACHE_CONF_AVAIL/php${v}-fpm.conf" ]; then
        err "Apache-Config $APACHE_CONF_AVAIL/php${v}-fpm.conf nicht gefunden."
        return 1
    fi
    if ! systemctl list-unit-files 2>/dev/null | grep "php${v}-fpm" >/dev/null 2>&1; then
        err "FPM-Service php${v}-fpm nicht installiert."
        return 1
    fi

    # Alle php*-fpm Confs deaktivieren
    local f
    for f in "$APACHE_CONF_ENABLED"/php*-fpm.conf; do
        [ -e "$f" ] || continue
        a2disconf "$(basename "$f" .conf)" >/dev/null 2>&1 || true
    done

    # Neue Conf aktivieren
    a2enconf "php${v}-fpm" >/dev/null
    log "Apache-Conf php${v}-fpm aktiviert."

    # FPM-Services
    if [ "$stop_others" = "1" ]; then
        local svc
        for svc in $(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do
            [ "$svc" = "php${v}-fpm.service" ] && continue
            systemctl stop "$svc" 2>/dev/null || true
        done
    fi
    systemctl enable "php${v}-fpm" >/dev/null 2>&1 || true
    systemctl restart "php${v}-fpm"
    log "FPM-Service php${v}-fpm gestartet."

    # Apache neu laden
    if systemctl is-active --quiet apache2 2>/dev/null; then
        systemctl reload apache2
        log "Apache2 neu geladen."
    else
        warn "Apache2 läuft nicht - kein Reload."
    fi
}

# ---------- Status ----------
show_status() {
    echo "Verfügbare PHP-Versionen: $(available_versions | tr '\n' ' ')"
    echo "Aktuell CLI:  $(current_cli_version)"
    echo "Aktuell FPM:  $(current_fpm_version)"
}

# ---------- Install ----------
install_php() {
    local v="$1"
    local minimal="$2"
    local switch_after="$3"
    local assume_yes="${4:-0}"

    # Versionsformat prüfen
    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        err "Ungültiges Versionsformat: '$v' (erwartet z.B. 7.4)"
        return 1
    fi

    # Bereits installiert?
    if is_installed "$v"; then
        warn "PHP $v ist bereits installiert."
        if [ "$switch_after" = "1" ]; then
            switch_cli "$v"
            switch_fpm "$v" "$STOP_OTHERS"
        fi
        return 0
    fi

    # Sury-Repo sicherstellen (falls nicht vorhanden)
    if ! ensure_sury_repo; then
        err "Sury-Repo konnte nicht eingebunden werden."
        return 1
    fi

    # Im Repo verfügbar?
    if ! apt-cache show "php${v}-fpm" >/dev/null 2>&1; then
        err "php${v}-fpm ist in den konfigurierten Repositories nicht verfügbar."
        err "Prüfe das Sury-Repo: deb https://packages.sury.org/php/ <distro> main"
        return 1
    fi

    echo "=> Installiere PHP ${v}"
    echo "   Basis: php${v}-fpm (bringt cli, common, opcache, json mit)"

    # Paketliste aufbauen
    local pkgs="php${v}-fpm"
    local ext
    if [ "$minimal" != "1" ]; then
        echo "   Standard-Extensions: $DEFAULT_EXTENSIONS"
        for ext in $DEFAULT_EXTENSIONS; do
            if apt-cache show "php${v}-${ext}" >/dev/null 2>&1; then
                pkgs="$pkgs php${v}-${ext}"
            else
                warn "Extension php${v}-${ext} nicht verfügbar, überspringe."
            fi
        done
    fi

    if [ "$YES" != "1" ] && [ "$assume_yes" != "1" ]; then
        echo
        echo "Folgende Pakete werden installiert:"
        echo "  $pkgs"
        printf 'Fortfahren? [j/N]: '
        read -r confirm
        case "$confirm" in
            j|J|y|Y|yes|ja) ;;
            *) err "Abgebrochen."; return 1 ;;
        esac
    fi

    export DEBIAN_FRONTEND=noninteractive
    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update fehlgeschlagen (siehe $INSTALL_LOG)."
        return 1
    fi

    log "apt-get install -y $pkgs ..."
    if ! apt-get install -y $pkgs 2>&1 | tee -a "$INSTALL_LOG"; then
        err "Installation fehlgeschlagen (siehe $INSTALL_LOG)."
        return 1
    fi

    # Service aktivieren und starten
    systemctl enable "php${v}-fpm" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "php${v}-fpm" 2>/dev/null; then
        systemctl restart "php${v}-fpm" 2>/dev/null || true
    else
        systemctl start "php${v}-fpm" 2>/dev/null || true
    fi

    log "PHP ${v} installiert (FPM-Service gestartet)."
    echo "   Apache-Conf: $APACHE_CONF_AVAIL/php${v}-fpm.conf (mit 'php-switch --fpm ${v}' aktivieren)"

    if [ "$switch_after" = "1" ]; then
        switch_cli "$v"
        switch_fpm "$v" "$STOP_OTHERS"
    fi
}

# ---------- Update ----------
update_patches() {
    local v pkgs avail
    for v in $(available_versions); do
        avail=$(php_patches_available "$v")
        if [ -z "$avail" ]; then
            log "PHP ${v}: keine Patch-Updates verfügbar."
            continue
        fi
        echo "=> PHP ${v}: Patch-Updates verfügbar:"
        echo "$avail" | sed 's/^/   /'
        pkgs=$(installed_php_packages "$v")
        if [ -z "$pkgs" ]; then
            warn "Keine installierten Pakete für PHP ${v} gefunden."
            continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY-RUN: apt-get install --only-upgrade -y $pkgs"
            continue
        fi
        export DEBIAN_FRONTEND=noninteractive
        log "apt-get update ..."
        if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
            err "apt-get update fehlgeschlagen (siehe $INSTALL_LOG)."
            return 1
        fi
        log "apt-get install --only-upgrade -y $pkgs ..."
        if ! apt-get install --only-upgrade -y $pkgs 2>&1 | tee -a "$INSTALL_LOG"; then
            err "Patch-Update für PHP ${v} fehlgeschlagen (siehe $INSTALL_LOG)."
            return 1
        fi
        log "PHP ${v} Patch-Updates eingespielt."
    done
}

update_new_minors() {
    local versions v
    versions=$(newer_apt_versions)
    if [ -z "$versions" ]; then
        log "Keine neuen Minor-Versionen verfügbar."
        return 0
    fi
    echo "=> Neue Minor-Versionen verfügbar:"
    for v in $versions; do
        echo "   $v"
    done

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: keine Installation."
        return 0
    fi

    if [ "$YES" != "1" ]; then
        echo
        printf 'Diese Versionen installieren? [j/N]: '
        read -r confirm
        case "$confirm" in
            j|J|y|Y|yes|ja) ;;
            *) warn "Neue Minor-Versionen übersprungen."; return 0 ;;
        esac
    fi

    for v in $versions; do
        install_php "$v" "$MINIMAL" 0 1 || warn "Installation von PHP ${v} fehlgeschlagen - übersprungen."
    done
}

# ---------- Main ----------
need_root

# Merken, ob ohne Argumente aufgerufen
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
            if [ -z "$TARGET" ]; then TARGET="$1"; else err "Unbekanntes Argument: $1"; exit 1; fi
            shift ;;
    esac
done

# --available
if [ "$SHOW_AVAILABLE" = "1" ]; then
    ensure_sury_repo >/dev/null 2>&1 || true
    echo "Installierte Versionen:"
    for local_v in $(available_versions); do
        echo "  $local_v (installiert)"
    done
    echo "Installierbare (nicht installierte) Versionen:"
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
        log "Sury-Repo bereit."
    else
        err "Sury-Repo konnte nicht eingebunden werden."
        exit 1
    fi
    exit 0
fi

# --update
if [ "$DO_UPDATE" = "1" ]; then
    if ! ensure_sury_repo; then
        err "Sury-Repo konnte nicht eingebunden werden."
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    log "apt-get update ..."
    if ! apt-get update >>"$INSTALL_LOG" 2>&1; then
        err "apt-get update fehlgeschlagen (siehe $INSTALL_LOG)."
        exit 1
    fi

    update_patches

    if [ "$PATCHES_ONLY" != "1" ]; then
        update_new_minors
    fi

    echo
    show_status
    echo
    log "Update abgeschlossen. Aktive Version wurde nicht geändert."
    echo "   Tipp: Wechsel mit 'php-switch <version>' (z. B. php-switch 8.6)."
    exit 0
fi

# --install
if [ -n "$INSTALL_VERSION" ]; then
    if [ -z "$INSTALL_VERSION" ]; then
        err "Bitte Version angeben, z.B. --install 7.4"
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
    err "Keine PHP-Versionen mit FPM gefunden (/etc/php/*/fpm)."
    err "Tipp: mit 'php-switch --install 7.4' eine Version nachinstallieren."
    exit 1
fi

# --list
if [ "$LIST" = "1" ]; then
    echo "Installierte PHP-Versionen:"
    for v in $(available_versions); do
        mark=""
        if [ "$v" = "$(current_cli_version)" ]; then mark=" (CLI)"; fi
        if [ "$v" = "$(current_fpm_version)" ]; then mark="${mark} (FPM)"; fi
        echo "  $v$mark"
    done
    exit 0
fi

# Ohne Argumente: Hilfe anzeigen, dann interaktives Menü
if [ "$NO_ARGS" = "1" ]; then
    show_help
    echo
fi

# Interaktives Menü, falls keine Zielversion angegeben
if [ -z "$TARGET" ]; then
    echo "Verfügbare PHP-Versionen:"
    echo "  0) Abbrechen"
    i=1
    for v in "${VERSIONS[@]}"; do
        cur=""
        if [ "$v" = "$(current_cli_version)" ]; then cur+="CLI "; fi
        if [ "$v" = "$(current_fpm_version)" ]; then cur+="FPM "; fi
        if [ -n "$cur" ]; then cur="  <- aktuell ($cur)"; fi
        printf '  %d) %s%s\n' "$i" "$v" "$cur"
        i=$((i+1))
    done
    printf 'Auswahl (0=Abbrechen, Nummer oder Version): '
    read -r choice
    if [ "$choice" = "0" ]; then
        echo "Abgebrochen."
        exit 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -lt 1 ] || [ "$choice" -gt ${#VERSIONS[@]} ]; then
            err "Ungültige Auswahl."
            exit 1
        fi
        TARGET="${VERSIONS[$((choice-1))]}"
    else
        TARGET="$choice"
    fi
fi

# Zielversion validieren (falls nicht installiert, Hinweis)
if ! printf '%s\n' "${VERSIONS[@]}" | grep -qx "$TARGET"; then
    # Vielleicht in apt verfügbar?
    if apt-cache show "php${TARGET}-fpm" >/dev/null 2>&1; then
        err "Version '$TARGET' ist nicht installiert, aber verfügbar."
        err "Installiere mit: php-switch --install $TARGET"
    else
        err "Version '$TARGET' weder installiert noch verfügbar."
    fi
    exit 1
fi

echo "=> Wechsle auf PHP ${TARGET}"
echo "   Vorher: CLI=$(current_cli_version) FPM=$(current_fpm_version)"

if [ "$MODE" = "both" ] || [ "$CLI_ONLY" = "1" ]; then
    switch_cli "$TARGET"
fi
if [ "$MODE" = "both" ] || [ "$FPM_ONLY" = "1" ]; then
    switch_fpm "$TARGET" "$STOP_OTHERS"
fi

echo
show_status
log "Fertig."
