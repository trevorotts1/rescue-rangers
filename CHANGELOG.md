# Changelog

## 2026-06-18
Part 2: added wait-and-retry on the bootout/bootstrap reload to fix the "Bootstrap failed: 5: Input/output error" race seen on fresh Track A installs (two Track A clients). Field guide updated to v20 with a matching retry note.

## 2026-06-19
Part 2: auto-uninstall existing connector on Track A re-run; detect "Invalid tunnel secret" and report bad token clearly (Jennifer Allen install).

## 2026-11-18
rescue-install-windows.ps1 v1.0: Windows 10/11 twin of rescue-install.sh. Built-in OpenSSH Server (PowerShell shell, key in administrators_authorized_keys, firewall local-only), cloudflared as the Cloudflared service with --token-file (never on the command line), restart on failure, sleep off on AC, 45s verify and SUMMARY. First client: Angeleen Harris.
