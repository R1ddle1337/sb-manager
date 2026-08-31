# Architecture

## Data flow

```text
state.json + secret files + certificates
             │
             ▼
      protocol renderers
             │
             ▼
  complete candidate config.json
             │
             ▼
       sing-box check
             │
             ▼
 snapshot → atomic replace → service reconcile → health check
                                      │
                                      └─ failure: rollback
```

The generated sing-box configuration is never treated as the source of truth. Users edit state only through `sb`; protocol modules render the complete configuration every time.

## Traffic control plane

```text
state.json: nodes[].traffic                 /var/lib/sb-manager/traffic-usage.json
              │                                           │
              └──────────────┬────────────────────────────┘
                             ▼
                 candidate nftables transaction
                             │
                             ▼
                inet sb_manager_traffic (owned table)
                  ├─ input:  client → listener (upload)
                  └─ output: listener → client (download)
```

The traffic subsystem is separate from sing-box rendering but participates in the same manager lock, snapshots, state transitions, backup/restore, and rollback. Node state holds policy (`quota_bytes`, `quota_mode`, reset day, and directional bit rates); the protected runtime journal holds only cycle IDs and accumulated counters. Before replacing rules, live named counters are checkpointed and used as the initial values of the new atomic nftables transaction. A systemd lifecycle unit restores rules at boot and checkpoints at shutdown; a timer checkpoints and processes UTC billing-cycle rollover every five minutes without rebuilding an already-correct table. OpenRC uses an equivalent boot service and, when `dcron` is installed, a 15-minute periodic job.

Rules match the effective listener returned by the Nginx Stream topology layer. Direct nodes therefore match their public listener, routed nodes match the unique loopback backend, and Tunnel-backed VMess matches its loopback origin. Loopback listeners are matched on the `output` hook in both destination (client/Tunnel → sing-box) and source (sing-box → client/Tunnel) directions; direct listeners use `input` for upload and `output` for download. Each rule includes the protocol transport, so TCP and UDP nodes may retain the same numeric port without sharing counters.

The implementation deliberately does not install `tc` qdiscs. Rate enforcement uses nftables named byte-rate limits as a policer, which avoids replacing an operator's root qdisc and works uniformly for IPv4, IPv6, TCP, UDP, and loopback traffic. The owned table is not persisted in the host firewall configuration and never adds allow rules; boot reconciliation rebuilds it from manager state.

## Explicit host-firewall setup

The firewall panel keeps host-security changes separate from proxy state. `sb firewall fail2ban` installs (when needed) and writes the manager-owned SSH jail at `SBM_FAIL2BAN_CONFIG`, with `findtime=180`, `maxretry=5`, and `bantime=-1`; it discovers effective SSH ports from the current connection, `sshd -T`, and listening sockets before validating and enabling/restarting Fail2ban. The action snapshots current iptables and the prior jail before replacement. `sb firewall ufw` first displays a dry-run plan, then snapshots current iptables and UFW status, idempotently allows detected SSH ports, TCP `22`, `80`, `443`, and every enabled protocol listener before enabling UFW. Neither action runs during ordinary installation, and neither removes unrelated rules or packages. Package installation uses the detected apk/apt/dnf/yum/pacman/zypper backend.

## Status, notification, and health control plane

`sb status --json` composes one machine-readable view from state, protected traffic usage, service-manager status, live listeners, certificate validity, firewall components, and health findings. It never parses generated sing-box configuration back into state. Human `sb status` renders the same object, keeping CLI and panel results consistent.

Traffic checkpoints evaluate configured percentage thresholds and write successful-delivery keys to `notification-events.json`, so retries occur after failures but delivered alerts are not repeated within a billing cycle. The notification provider secret is isolated in `secrets/notifications.json`; state contains only the provider name, enabled bit, and thresholds. Telegram, WeCom, and generic JSON Webhooks share this delivery layer.

The optional health timer runs every 15 minutes on systemd/OpenRC and no-ops while `health.enabled` is false. It checks expected service/listener state, certificate expiry, UFW, Fail2ban, and the owned nftables traffic table. `health-events.json` tracks active issue codes so only changes and recoveries trigger notifications; `health-report.json` stores the latest protected report.

Resource health metrics use portable `/proc`, `df`, systemd, and Fail2ban interfaces. Thresholds live in `health.resources`; metrics are informational warnings and never trigger firewall, SSH, sysctl, or routing changes. `sb doctor --repair-safe` performs only permission/configuration/owned-rule recovery and a controlled restart of a service that is expected to be active but is stopped.

Configuration previews render a candidate state and compare both state and generated config after redacting secret-shaped keys. Dry-run paths do not call `state_install_candidate`, do not write credentials or traffic journals, and do not reconcile services.

## Service backends

```text
                    ┌─ systemd units + timers + journald
sb service API ─────┤
                    └─ OpenRC supervise-daemon + optional dcron periodic jobs + files
```

All lifecycle operations use a shared service abstraction: existence, enable/disable, start/stop/restart, active-state checks, logs, repair, and failure reporting. Logical names retain their systemd suffix for state compatibility; the OpenRC backend maps `sb-sing-box.service` to `/etc/init.d/sb-sing-box` and `sb-cloudflared.service` to `/etc/init.d/sb-cloudflared`.

On OpenRC, sing-box (and, when explicitly installed, cloudflared) run under the `sbmanager` account through `supervise-daemon`. The sing-box binary receives only the `cap_net_bind_service` file capability so the unprivileged process can bind ports below 1024. OpenRC logs are stored under `/var/log/sb-manager/`; the Cloudflared directory and logs are created only when the optional component is installed.

## Minimal installation and optional dependencies

The default installer uses the `minimal` profile. It installs the manager's small command-line base, the sing-box core and the Alpine `gcompat`/OpenRC runtime, but does not download Cloudflared or install Python, nftables, kmod, dcron or Nginx. Feature modules call the dependency resolver immediately before use (`subscription`, `traffic`, `bbr`, `probe`, `scheduler`, and `logrotate`). This keeps the first boot suitable for a roughly 1GB disk while preserving the full feature set for larger hosts.

## Exposure model

```text
Cloudflare edge → cloudflared → 127.0.0.1:<VMess WS port>

Internet → TCP/TLS <AnyTLS port>
Internet → UDP/QUIC <Hysteria2 port>
Internet → TCP <Shadowsocks 2022 port>
Internet → TCP <Snell v5 port>
```

VMess-WS-CF never listens on a public interface. AnyTLS and Hysteria2 can share the same numeric port because one is TCP and the other UDP.

### Optional Nginx Stream SNI passthrough

```text
Internet :443/TCP
        │
        ▼
sb-nginx-stream (ssl_preread; no TLS termination)
        ├─ SNI trojan.example.com → 127.0.0.1:20000 → Trojan
        ├─ SNI vless.example.com  → 127.0.0.1:20001 → VLESS
        └─ unknown/missing SNI     → reject backend
```

The feature is off by default. On systemd it uses a hardened unit; on OpenRC it uses a foreground `supervise-daemon` service and a persistent copy of the Nginx binary with only `cap_net_bind_service`. State retains each node's direct listen port and stores separate route backend ports. Rendering substitutes loopback backends only while the mux is enabled; exports substitute the public mux port. Transition order is stop mux → validate/install candidate → restart sing-box → validate/start mux. Any failure restores the previous state, sing-box configuration, and service topology.

## Trust boundaries

- `state.json`: topology and non-secret settings, mode `0600`.
- `secrets/`: credentials and API tokens, directory mode `0700`/`0710` as required.
- `generated/config.json`: contains runtime credentials and is readable only by root and the `sbmanager` service group.
- `certs/`: certificate key mode `0640`, readable by the service group.
- `exports/` and backups: mode `0600`; both contain credentials.
- `traffic-usage.json`: runtime billing-cycle counters, mode `0600`; included in snapshots and backups.
- `notification-events.json`, `health-events.json`, and `health-report.json`: protected runtime alert/health journals, mode `0600`.
- OpenRC service scripts contain only paths and arguments; Tunnel tokens remain in a protected file.

## Update model

Each sing-box version is kept under `cores/sing-box/<version>/`. `/usr/local/bin/sing-box` is an atomic symlink. A candidate binary must validate the current configuration before the symlink is switched. Service failure restores the previous target. On OpenRC, the capability required for low ports is applied to every candidate before activation.

Every switch records a known-good core/config/secret/certificate snapshot in
`/var/lib/sb-manager/backups/snapshots/` and appends a paired entry to
`core-history/sing-box.tsv`. If an older core rejects the current configuration,
rollback restores that paired snapshot before switching, so the binary and
configuration remain compatible.

## Protected control plane

Subscription profiles are materialized under `/var/lib/sb-manager/subscriptions`
with SHA-256 token filenames. The Python service runs as `sbmanager`, binds only
to loopback, refuses expired/revoked tokens, and never logs bearer paths. The
optional sing-box 1.14 API/Dashboard is version-gated, loopback-only, and uses a
separate secret file; stable 1.13 configurations never contain its `services`
or `http_clients` fields.

The optional sing-box 1.14 `hysteria-realm` service is rendered alongside the
API service from the top-level `realm` state object. Its bearer token is kept in
`secrets/realm.json`, never in `state.json` or generated client metadata. A
Hysteria2 node references a Realm slot by `realm_id`; rendering resolves the
current token at transaction time so rotating the Realm token cannot leave
stale node credentials behind. Realm disable is refused while an enabled node
still references it, preserving an atomic reachable configuration.

## Release provenance

`build-release.sh` emits the offline installer, `SHA256SUMS`,
`RELEASE-MANIFEST.json`, and `PROVENANCE-SHA256SUMS`. Set
`SBM_RELEASE_SIGNING_KEY` with a local GPG key to emit detached signatures for
the manifest and checksums. Remote bootstrap installs require an immutable
`SBM_INSTALL_REF` (tag or commit) and can enforce a source archive SHA-256.
