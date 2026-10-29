# php-switch-fpm

**English** | [Deutsch](README.de.md)

[![shellcheck](https://github.com/GiveMe5-BT6/php-switch-fpm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/GiveMe5-BT6/php-switch-fpm/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Debian%2FUbuntu-orange)](#compatibility)

Bash-Script zum Umschalten und Installieren von PHP-Versionen (CLI + Apache2 FPM).

## Requirements

- root privileges (`sudo`)
- Debian/Ubuntu (or derivative) with `apt`/`dpkg`
- `systemd`
- Apache2 (`a2enconf`/`a2disconf`) for FPM switching
- `curl`, `gpg`, `lsb_release`, `update-alternatives`

## Installation

```bash
sudo cp php-switch.sh /usr/local/bin/php-switch
sudo chmod +x /usr/local/bin/php-switch
```

The script ships in two languages: `php-switch.sh` (German) and `php-switch.en.sh`
(English). They are functionally identical - pick the one you prefer.

Or, from a clone:

```bash
git clone https://github.com/GiveMe5-BT6/php-switch-fpm.git
cd php-switch
sudo install -m 0755 php-switch.sh /usr/local/bin/php-switch
```

## Usage

```bash
php-switch                       # Help + interactive menu
php-switch 8.5                   # Switch to PHP 8.5 (CLI + FPM)
php-switch --list                # Show installed versions
php-switch --available           # Installed vs. installable versions
php-switch --ensure-repo         # Bind/update Sury repo if missing
php-switch --update              # Patch updates + new minor versions
php-switch --update --patches-only # Patch updates only
php-switch --update --dry-run    # Show only, change nothing
php-switch --install 7.4         # Install PHP 7.4 (CLI + FPM + standard extensions)
php-switch --install 7.4 --minimal  # Only php7.4-fpm
php-switch --install 7.4 --switch   # Install and activate immediately
php-switch --cli 5.6             # Switch CLI only
php-switch --fpm 8.5             # Switch Apache/FPM only
php-switch --stop-others         # Stop other FPMs on switch
php-switch --yes                 # No prompts (for --install/--update)
```

In the interactive menu, enter `0` to abort.

## What it changes

- `/etc/php/<version>/` (installs packages via apt)
- `/etc/apache2/conf-enabled/php*-fpm.conf` (via `a2enconf`/`a2disconf`)
- CLI alternative via `update-alternatives --set php`
- FPM services via `systemctl`
- `/etc/apt/sources.list.d/sury-php.list` and the Sury GPG key (only if missing)

No version is activated automatically by `--install`/`--update`; switching stays explicit.

## Uninstall

```bash
sudo rm -f /usr/local/bin/php-switch
# Optional: remove installed PHP versions
# sudo apt-get remove --purge 'php7.4-*'
```

## Compatibility

Tested on Ubuntu 26.04 (resolute) with PHP 5.6, 7.4 and 8.5.

See [Compatibility](#compatibility) below. The script depends on Debian/Ubuntu
infrastructure (`apt`/`dpkg`, `systemd`, Apache2, Debian PHP layout, Sury repo).

### Runs without problems

Debian 11 (bullseye), 12 (bookworm), 13 (trixie) and Ubuntu 18.04-24.04
(bionic, focal, jammy, noble) with systemd + Apache2 + root privileges.
Derivatives (Linux Mint, Pop!_OS, elementary OS, Zorin OS, KDE neon,
Raspberry Pi OS) work as long as they inherit this base.

### Runs with limitations

- **Ubuntu 25.04/25.10/26.04** (plucky/questing/resolute): codename not in the
  support list -> fallback to `noble`. Tested on Ubuntu 26.04 (resolute): patch
  updates and installation of already-supported minors (5.6, 7.4, 8.5) work.
  Brand-new minors such as 8.6 may fail on missing dependencies
  (e.g. libicu74/libzip4t64) because their builds target noble.
- **Debian testing/sid**: wrong codename fallback to `noble` -> not recommended.
- **WSL2**: only with systemd enabled (`systemd=true` in `/etc/wsl.conf`).
- **nginx only**: CLI switching and installation work, FPM switching fails.
- **Containers without systemd** (Docker/LXC): `--switch`/`--update` fail.

### Does not run

RHEL/Fedora/CentOS/Rocky/Alma, Arch/Manjaro, openSUSE, Alpine, Gentoo,
macOS, FreeBSD, Windows (native).

### Note on PHP 5.6

PHP 5.6 is fully supported (CLI + FPM in Apache). Availability depends on the
Sury build matrix for the respective distribution; `php-switch --available`
shows the actually installable versions.

## Safety notes

- Requires root; review the script before running.
- `--update --yes` may install new minor versions unattended.
- Unknown codenames fall back to `noble` (see limitations).

## Automated updates (Cron / systemd)

Unattended runs should use **`--patches-only`** so only patch updates are applied;
new minor versions are installed explicitly after review.

Cron (`/etc/cron.d/php-switch`):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=root
30 3 * * 0 root flock -n /run/php-switch-update.lock /usr/local/bin/php-switch --update --patches-only --yes >> /var/log/php-switch-update.log 2>&1
```

systemd timer (recommended) — `/etc/systemd/system/php-switch-update.service`:

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

Enable with `systemctl daemon-reload && systemctl enable --now php-switch-update.timer`.

Notes: Sury upgrades restart the affected FPM services (brief downtime); set up
logrotate for `/var/log/php-switch-update.log`; run `--update --dry-run` first.

## Related projects

There are several older scripts with overlapping goals. `php-switch` differs from them in a few ways:

| Project | Approach | Difference |
|---|---|---|
| [rapidwebltd/php-switch-scripts](https://github.com/rapidwebltd/php-switch-scripts) | `setup.sh` + one `switch-to-php-X.Y.sh` per version, PPA `ondrej/php` | Widely used but dated (up to 8.0), generated per-version scripts, no `--update`, Ubuntu-only, no dry-run |
| [svilborg/php-switch](https://github.com/svilborg/php-switch) | `add-repo`, `info`, `install`, `uninstall`, `to`, `ver` | Closest command set, but Ubuntu-only, unmaintained, no FPM handling, no patch updates |
| [tschallacka/bash-switch-php](https://github.com/tschallacka/bash-switch-php) | Switching only, versions must be pre-installed | No install/update, no FPM config handling |
| [mobihack/phpswitch.sh](https://github.com/mobihack/phpswitch.sh) | Switching via `a2enmod`/`a2dismod` (mod_php) | Uses mod_php instead of FPM, no install/update |
| [nafiesl/apache-php-switcher](https://github.com/nafiesl/apache-php-switcher) | Fork of rapidwebltd scripts | Same limitations as above |
| [phpbrew/phpbrew](https://github.com/phpbrew/phpbrew), [phpenv/phpenv](https://github.com/phpenv/phpenv), [asdf-php](https://github.com/asdf-community/asdf-php) | Per-user source builds or shims | Different model: no system Apache FPM, no apt/Sury integration |

What `php-switch-fpm` adds on top: automatic Sury repo setup (GPG key + codename fallback),
a full lifecycle (`--list`/`--install`/`--switch`/`--update`/`--dry-run`), separate CLI/FPM
switching, PHP 5.6 support, and a ShellCheck CI pipeline.

## License

MIT - see [LICENSE](LICENSE).
EOF