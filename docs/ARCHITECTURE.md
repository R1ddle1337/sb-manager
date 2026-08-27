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
```

VMess-WS-CF never listens on a public interface. AnyTLS and Hysteria2 can share the same numeric port because one is TCP and the other UDP.

## Trust boundaries

- `state.json`: topology and non-secret settings, mode `0600`.
- `secrets/`: credentials and API tokens, directory mode `0700`/`0710` as required.
- `generated/config.json`: contains runtime credentials and is readable only by root and the `sbmanager` service group.
- `certs/`: certificate key mode `0640`, readable by the service group.
- `exports/` and backups: mode `0600`; both contain credentials.
- OpenRC service scripts contain only paths and arguments; Tunnel tokens remain in a protected file.

## Update model

Each sing-box version is kept under `cores/sing-box/<version>/`. `/usr/local/bin/sing-box` is an atomic symlink. A candidate binary must validate the current configuration before the symlink is switched. Service failure restores the previous target. On OpenRC, the capability required for low ports is applied to every candidate before activation.
