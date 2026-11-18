# Changelog

## 2026-06-18
Part 2: added wait-and-retry on the bootout/bootstrap reload to fix the "Bootstrap failed: 5: Input/output error" race seen on fresh Track A installs (two Track A clients). Field guide updated to v20 with a matching retry note.

## 2026-06-19
Part 2: auto-uninstall existing connector on Track A re-run; detect "Invalid tunnel secret" and report bad token clearly (Jennifer Allen install).

## 2026-11-18
rescue-install-windows.ps1 v1.0: Windows 10/11 twin of rescue-install.sh. Built-in OpenSSH Server (PowerShell shell, key in administrators_authorized_keys, firewall local-only), cloudflared as the Cloudflared service with --token-file (never on the command line), restart on failure, sleep off on AC, 45s verify and SUMMARY. First client: Angeleen Harris.
rescue-install-windows.ps1 v1.1 (same day, after independent review): SSH firewall restricted to this PC only (was local subnet); existing OpenSSH registry key never recreated; key file rewritten safely (no line-glue, no UTF-16 mixing); too-old cloudflared refused (--token-file needs 2025.4+); foreign Cloudflared service refused before any change; service update via CIM instead of sc.exe (PowerShell 5.1 quoting); install line safe for temp paths with spaces; 32-bit PowerShell refused; installer exit code checked and SHA256 logged; lid close ignored on AC.
