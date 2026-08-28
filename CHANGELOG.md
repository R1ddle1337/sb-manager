# Changelog

## 0.1.0-alpha.9

- Fix an ACME deployment deadlock caused by the reload hook re-entering `state_init` while certificate issuance held the manager lock.
- Fix strict-shell expansion in `cert hook` and `cert inspect`, and add bounded issue/install/cron timeouts with transactional rollback.
- Add remote Debian regression coverage for a reload hook invoked while the manager lock is held and for ACME timeout handling.

## 0.1.0-alpha.8

- Add optional Debian/systemd Nginx Stream SNI passthrough for sharing one public TCP port across AnyTLS, Trojan, VLESS TLS/Reality, Naive TCP, and ShadowTLS v3.
- Move routed sing-box listeners to unique loopback backends while preserving their direct ports for lossless disable/rollback and publishing the mux port in links and client exports.
- Add CLI/panel management, strict SNI/route validation, unknown-SNI rejection, systemd sandboxing, diagnostics, backup compatibility, and transactional activation rollback.
- Validate real SNI routing, TLS passthrough, service restart, failure rollback, and disable restoration on the designated Debian 13 server.

## 0.1.0-alpha.7

- Add Trojan TLS, TUIC, VLESS TLS/Reality, NaiveProxy, and ShadowTLS v3 protocol modules with per-user credentials and validated client exports.
- Add schema-v2 state migration, transactional rollback across state/config/secrets/certificates/subscriptions, hardened restore checks, and optional age-encrypted backups.
- Add loopback-only expiring subscriptions, gated sing-box 1.14 API/Dashboard support, complete mixed/TUN exports, public-address source tracking, and `sb probe` network diagnostics.
- Pin remote bootstrap installs to an explicit immutable ref and add release provenance, checksum, and optional GPG signature artifacts.
- Validate all changes on the designated Debian 13 test server against official sing-box 1.13.19 and 1.14.0-rc.1 binaries.

## 0.1.0-alpha.6

- Retry all core download failures with bounded backoff instead of relying on curl's limited default retry classes.
- Stop immediately after a failed or empty download and remove partial files before checksum or extraction steps.
- Validate GitHub Release API responses and propagate lookup failures without silently converting `latest` into an invalid version.
- Add deterministic retry/fail-fast coverage while retaining the real first-download smoke test.

## 0.1.0-alpha.5

- Allow `AF_NETLINK` in the hardened systemd address-family policy so sing-box can subscribe to Linux route updates during startup.
- Add a real transient systemd startup preflight using the rendered sing-box configuration; the previous `version` check could not detect route-monitor failures.
- Extend `sb doctor` with an explicit AF_NETLINK policy check and extend `sb repair` with the real startup preflight.
- Add unit and real PID-1 systemd regressions that start an actual sing-box inbound under the production sandbox.

## 0.1.0-alpha.4

- Fix systemd `203/EXEC` / `Permission denied` failures caused by stale sing-box file capabilities left by an OpenRC-style installation or migration.
- Make sing-box capability handling backend-specific: systemd receives `CAP_NET_BIND_SERVICE` only through the unit, while OpenRC keeps the minimal file capability.
- Add a transient systemd sandbox preflight before starting the permanent service, using the same critical user, capability and hardening properties.
- Stop an existing restart loop before replacing service definitions and limit repeated systemd startup failures to five attempts per minute.
- Extend `sb doctor` and `sb repair` to detect, explain and safely repair file-capability, path-permission, mount and systemd sandbox execution problems.
- Ensure core download, update, switch and rollback all normalize executable permissions and capabilities for the active service backend.
- Add Debian/systemd regression coverage for capability cleanup and sandbox preflight.

## 0.1.0-alpha.3

- Add Alpine Linux 3.21-3.24 support with the native OpenRC service manager and `apk` dependency installation, including `gcompat` for the official sing-box Linux core.
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
