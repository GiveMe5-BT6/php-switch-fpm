# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-10-29

### Added
- Initial release.
- Switch PHP version for CLI and Apache2 FPM (`php-switch <version>`).
- `--list`, `--available`, `--install`, `--minimal`, `--switch`, `--cli`, `--fpm`,
  `--stop-others`, `--yes`.
- `--ensure-repo`: bind Sury PHP repository automatically (GPG key + codename fallback).
- `--update`: patch updates for installed versions plus installation of newer minor
  versions (with confirmation unless `--yes`).
- `--patches-only`, `--dry-run`.
- Interactive menu with `0` to abort.
- PHP 5.6 support (CLI + FPM).
EOF