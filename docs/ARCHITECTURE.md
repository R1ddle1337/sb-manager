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

## Service backends

```text
                    ┌─ systemd units + timers + journald
sb service API ─────┤
                    └─ OpenRC supervise-daemon + dcron periodic jobs + files
```

All lifecycle operations use a shared service abstraction: existence, enable/disable, start/stop/restart, active-state checks, logs, repair, and failure reporting. Logical names retain their systemd suffix for state compatibility; the OpenRC backend maps `sb-sing-box.service` to `/etc/init.d/sb-sing-box` and `sb-cloudflared.service` to `/etc/init.d/sb-cloudflared`.

On OpenRC, sing-box and cloudflared run under the `sbmanager` account through `supervise-daemon`. The sing-box binary receives only the `cap_net_bind_service` file capability so the unprivileged process can bind ports below 1024. OpenRC logs are stored under `/var/log/sb-manager/`.

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

The feature is off by default and currently limited to Debian/systemd. State retains each node's direct listen port and stores separate route backend ports. Rendering substitutes loopback backends only while the mux is enabled; exports substitute the public mux port. Transition order is stop mux → validate/install candidate → restart sing-box → validate/start mux. Any failure restores the previous state, sing-box configuration, and service topology.

## Trust boundaries

- `state.json`: topology and non-secret settings, mode `0600`.
- `secrets/`: credentials and API tokens, directory mode `0700`/`0710` as required.
- `generated/config.json`: contains runtime credentials and is readable only by root and the `sbmanager` service group.
- `certs/`: certificate key mode `0640`, readable by the service group.
- `exports/` and backups: mode `0600`; both contain credentials.
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

## Release provenance

`build-release.sh` emits the offline installer, `SHA256SUMS`,
`RELEASE-MANIFEST.json`, and `PROVENANCE-SHA256SUMS`. Set
`SBM_RELEASE_SIGNING_KEY` with a local GPG key to emit detached signatures for
the manifest and checksums. Remote bootstrap installs require an immutable
`SBM_INSTALL_REF` (tag or commit) and can enforce a source archive SHA-256.
