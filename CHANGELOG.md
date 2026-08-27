# Changelog

## 0.1.0-alpha.3

- Add Alpine Linux 3.21-3.24 support with the native OpenRC service manager and `apk` dependency installation.
- Add a systemd/OpenRC service abstraction for start, stop, enable, status, logs, repair, Tunnel management, and uninstall.
- Add OpenRC supervised services for sing-box and cloudflared, plus `dcron` periodic jobs for core updates, ACME renewal, and Quick Tunnel refresh.
- Keep sing-box unprivileged on OpenRC by applying only `cap_net_bind_service` to installed cores for low-port listeners.
- Add portable account/group, DNS lookup, and certificate-expiry helpers for musl/BusyBox environments.
- Add OpenRC lifecycle tests and Alpine 3.21/3.22/3.23/3.24 musl smoke jobs using the real official sing-box and cloudflared assets.

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
