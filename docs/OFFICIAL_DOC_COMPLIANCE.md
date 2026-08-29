# Official sing-box Compliance Matrix

## Reference Set

Development uses the supplied `sing-box-official-docs-cn-2026-08-27.zip`. Its complete `sing-box-official-docs-cn/` extraction contains 89 files; all 88 files listed by `MANIFEST.md` pass SHA-256 verification. The primary tested runtime baseline is `1.14.0-rc.2`; 1.13-compatible output remains covered by the compatibility suite.

Every generated server configuration includes the official `$schema` URL and must pass `sing-box check` using the target binary. A documented type is enabled only when its required version, build tag, companion library, operating system, and permissions are present.

## Implemented Mappings

| Manager feature | Reference chapters | Required verification |
|---|---|---|
| VMess WS + Tunnel | `05-入站/Shadowsocks-VMess-VLESS-Trojan.md`, Cloudflare model in project docs | loopback listener, WS path, outbound check |
| Shadowsocks 2022 | inbound/outbound Shadowsocks chapters | key length, legacy and multi-user formats |
| AnyTLS | `05/06-*/Naive-ShadowTLS-AnyTLS-Snell.md` | 1.12+, TLS certificate and outbound check |
| Hysteria2 | `05/06-*/Hysteria-Hysteria2-TUIC.md` | `with_quic`, UDP listener, TLS, obfs |
| Trojan TLS | `05/06-*/Shadowsocks-VMess-VLESS-Trojan.md` | TLS certificate, per-user password |
| TUIC | `05/06-*/Hysteria-Hysteria2-TUIC.md` | `with_quic`, UDP, supported congestion control, 0-RTT disabled |
| VLESS TLS/Reality | VLESS chapters and `02-配置基础/TLS-ECH-Reality-uTLS.md` | UUID, Vision flow, Reality keypair/Short ID, `with_utls` |
| Naive | Naive chapters and build-tag matrix | TLS/QUIC mode; client requires `with_naive_outbound` and `libcronet.so` |
| ShadowTLS v3 | ShadowTLS chapters | v3 users, handshake target, strict/wildcard SNI values |
| Snell v5 | `05/06-*/Naive-ShadowTLS-AnyTLS-Snell.md` | 1.14+ only; server v5, client v4, PSK/userkey, optional HTTP obfs |
| Nginx Stream passthrough | Official rule that duplicate listeners require an explicit reuse layer; Nginx `ssl_preread` semantics | unique exact SNI, loopback backends, no TLS termination, unknown-SNI rejection, transactional rollback |

## Configuration and Security Rules

- Public listeners require authentication; VMess Tunnel origins stay on loopback.
- TLS certificate names, keys, expiry, and permissions are validated before reload.
- TCP and UDP may share a numeric port; equal transport kinds may not.
- Services run as `sbmanager` with the minimum low-port capability.
- Secrets, exports, and backups remain outside generated topology state.
- Updates preserve a known-good core/config pair and do not automatically cross a minor version.
- Host firewall and cloud security-group changes remain explicit operator actions. The firewall panel can explicitly install/configure UFW and Fail2ban; installation itself does not enable either component.
- Optional Nginx Stream multiplexing never makes sing-box inbounds share a socket directly; only the Nginx frontend owns the public TCP port.

## Version Gates

The following supplied-document features are marked `1.14+` and must not appear in stable 1.13 output: top-level `certificate_providers`, `http_clients`, `network_namespaces`, the new API/Dashboard service, OpenConnect/OpenVPN endpoints, Hysteria Realm, Bridge outbound, and 1.14 DNS/TUN fields. They may be added only behind an explicit core-version gate and a separate 1.14 compatibility suite.

## Remote Acceptance

Acceptance runs only on the designated Debian 13 server. It includes schema validation, server and client config checks, real TCP/UDP listeners, systemd sandbox startup, user lifecycle, credential rotation, backup/migration fault injection, core upgrade/rollback, and external reachability where a real domain and cloud security-group rule are available.
