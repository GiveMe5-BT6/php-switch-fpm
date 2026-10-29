# php-switch-fpm

[Deutsch](README.de.md) | **English** (see [README.md](README.md))

[![shellcheck](https://github.com/GiveMe5-BT6/php-switch-fpm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/GiveMe5-BT6/php-switch-fpm/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%2FUbuntu-orange)](#kompatibilität)

Bash-Script zum Umschalten und Installieren von PHP-Versionen (CLI + Apache2 FPM).

## Voraussetzungen

- root-Rechte (`sudo`)
- Debian/Ubuntu (oder Derivat) mit `apt`/`dpkg`
- `systemd`
- Apache2 (`a2enconf`/`a2disconf`) für FPM-Umschaltung
- `curl`, `gpg`, `lsb_release`, `update-alternatives`

## Installation

```bash
sudo cp php-switch.sh /usr/local/bin/php-switch
sudo chmod +x /usr/local/bin/php-switch
```

Das Script liegt in zwei Sprachen vor: `php-switch.sh` (Deutsch) und `php-switch.en.sh`
(Englisch). Beide sind funktional identisch - wähle die bevorzugte Variante.

Oder aus einem Clone:

```bash
git clone https://github.com/GiveMe5-BT6/php-switch-fpm.git
cd php-switch
sudo install -m 0755 php-switch.sh /usr/local/bin/php-switch
```

## Verwendung

```bash
php-switch                       # Hilfe + interaktives Menü
php-switch 8.5                   # Auf PHP 8.5 umstellen (CLI + FPM)
php-switch --list                # Installierte Versionen anzeigen
php-switch --available           # Installierte vs. installierbare Versionen
php-switch --ensure-repo         # Sury-Repo einbinden/aktualisieren (falls fehlend)
php-switch --update              # Patch-Updates + neue Minor-Versionen
php-switch --update --patches-only # Nur Patch-Updates
php-switch --update --dry-run    # Nur anzeigen, nichts ändern
php-switch --install 7.4         # PHP 7.4 installieren (CLI + FPM + Standard-Extensions)
php-switch --install 7.4 --minimal  # Nur php7.4-fpm
php-switch --install 7.4 --switch   # Installieren und sofort aktivieren
php-switch --cli 5.6             # Nur CLI umstellen
php-switch --fpm 8.5             # Nur Apache/FPM umstellen
php-switch --stop-others         # Andere FPMs beim Wechsel stoppen
php-switch --yes                 # Keine Rückfragen (für --install/--update)
```

Im interaktiven Menü `0` eingeben zum Abbrechen.

## Was das Script ändert

- `/etc/php/<version>/` (Pakete via apt)
- `/etc/apache2/conf-enabled/php*-fpm.conf` (via `a2enconf`/`a2disconf`)
- CLI-Alternative via `update-alternatives --set php`
- FPM-Services via `systemctl`
- `/etc/apt/sources.list.d/sury-php.list` und Sury-GPG-Key (nur falls fehlend)

`--install`/`--update` aktivieren keine Version automatisch; der Wechsel bleibt explizit.

## Deinstallation

```bash
sudo rm -f /usr/local/bin/php-switch
# Optional: installierte PHP-Versionen entfernen
# sudo apt-get remove --purge 'php7.4-*'
```

## Automatische Updates (Cron / systemd)

Unbeaufsichtigt nur `--patches-only` nutzen, damit nur Patch-Updates eingespielt werden;
neue Minor-Versionen erst nach Prüfung installieren.

Cron (`/etc/cron.d/php-switch`):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=root
30 3 * * 0 root flock -n /run/php-switch-update.lock /usr/local/bin/php-switch --update --patches-only --yes >> /var/log/php-switch-update.log 2>&1
```

systemd-Timer (empfohlen) – `/etc/systemd/system/php-switch-update.service`:

```ini
[Unit]
Description=php-switch patch updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/php-switch --update --patches-only --yes
```

`/etc/systemd/system/php-switch-update.timer`:

```ini
[Unit]
Description=Weekly php-switch patch updates

[Timer]
OnCalendar=Sun 03:30
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
```

Aktivieren: `systemctl daemon-reload && systemctl enable --now php-switch-update.timer`.

Hinweise: Sury-Upgrades starten die betroffenen FPM-Services neu (kurze Downtime);
Logrotate für `/var/log/php-switch-update.log` einrichten; erst `--update --dry-run` testen.

## Kompatibilität

Getestet auf Ubuntu 26.04 (resolute) mit PHP 5.6, 7.4 und 8.5.

### Läuft voraussichtlich ohne Probleme

Debian 11 (bullseye), 12 (bookworm), 13 (trixie) und Ubuntu 18.04–24.04
(bionic, focal, jammy, noble) mit systemd + Apache2 + root-Rechten.
Derivate (Linux Mint, Pop!_OS, elementary OS, Zorin OS, KDE neon, Raspberry Pi OS)
funktionieren, solange sie diese Basis erben.

### Läuft mit Einschränkungen

- **Ubuntu 25.04/25.10/26.04** (plucky/questing/resolute): Codename nicht in der
  Unterstützungsliste → Fallback auf `noble`. Auf Ubuntu 26.04 (resolute) getestet:
  Patch-Updates und Installation bereits unterstützter Minors (5.6, 7.4, 8.5) funktionieren.
  Brandneue Minors wie 8.6 können an fehlenden Abhängigkeiten (z. B. libicu74/libzip4t64)
  scheitern, weil ihre Builds auf noble zielen.
- **Debian testing/sid**: falscher Codename-Fallback auf `noble` → nicht empfohlen.
- **WSL2**: nur mit aktiviertem systemd (`systemd=true` in `/etc/wsl.conf`).
- **Nur nginx**: CLI-Umschaltung und Installation funktionieren, FPM-Umschaltung scheitert.
- **Container ohne systemd** (Docker/LXC): `--switch`/`--update` scheitern.

### Läuft nicht

RHEL/Fedora/CentOS/Rocky/Alma, Arch/Manjaro, openSUSE, Alpine, Gentoo,
macOS, FreeBSD, Windows (nativ).

### Hinweis zu PHP 5.6

PHP 5.6 wird zwingend unterstützt (CLI + FPM in Apache). Die Verfügbarkeit hängt von
der Sury-Build-Matrix für die jeweilige Distribution ab; `php-switch --available`
zeigt die tatsächlich installierbaren Versionen.

## Sicherheitshinweise

- Erfordert root; Script vor dem Einsatz prüfen.
- `--update --yes` kann neue Minor-Versionen unbeaufsichtigt installieren.
- Unbekannte Codenames fallen auf `noble` zurück (siehe Einschränkungen).

## Verwandte Projekte

- [rapidwebltd/php-switch-scripts](https://github.com/rapidwebltd/php-switch-scripts) – verbreitet, aber alt, kein `--update`, nur Ubuntu
- [svilborg/php-switch](https://github.com/svilborg/php-switch) – namensgleich, Ubuntu-only, unmaintained
- [tschallacka/bash-switch-php](https://github.com/tschallacka/bash-switch-php) – nur Umschalten
- [mobihack/phpswitch.sh](https://github.com/mobihack/phpswitch.sh) – mod_php statt FPM
- [phpbrew/phpbrew](https://github.com/phpbrew/phpbrew), [phpenv/phpenv](https://github.com/phpenv/phpenv), [asdf-php](https://github.com/asdf-community/asdf-php) – anderer Ansatz (Source/Shims)

`php-switch-fpm` ergänzt diese um automatische Sury-Einbindung, vollen Lifecycle
(`--list`/`--install`/`--switch`/`--update`/`--dry-run`), getrennte CLI/FPM-Umschaltung,
PHP-5.6-Support und ShellCheck-CI.

## Lizenz

MIT – siehe [LICENSE](LICENSE).
EOF