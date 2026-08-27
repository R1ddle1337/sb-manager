# Changelog

## 0.1.0-alpha.2

- Fix first installation requiring a second run: download progress logs no longer contaminate the binary path captured by command substitution.
- Validate generated sing-box/cloudflared symlink targets before installation continues.
- Repair non-traversable core directories so the low-privilege `sbmanager` account can execute the cores.
- Treat an inactive sing-box service as normal when no nodes are enabled; the first enabled node starts it automatically.
- Fix `sb doctor` exiting at its first warning/failure under `set -e`, and add detailed permission/service diagnostics plus `--repair`.
- Add interactive normal and full-uninstall options, plus `--yes` automation.
- Add first-download, service lifecycle, doctor completion, and Debian 13 CI regressions.

## 0.1.0-alpha.1

Initial alpha release.

- State-driven sing-box configuration generation
- VMess-WS with Cloudflare Tunnel
- Shadowsocks 2022
- AnyTLS
- Hysteria2
- acme.sh Cloudflare DNS-01 certificate management
- Core update and rollback
- Interactive `sb` panel and CLI
- Backup, restore, export, logs, and diagnostics
