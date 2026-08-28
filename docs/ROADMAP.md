# sb-manager Improvement Roadmap

## Goal and Standards Baseline

The project will evolve from an alpha protocol installer into a dependable, state-driven sing-box server manager. The primary tested baseline is sing-box `1.14.0-rc.1`; 1.13-compatible configurations remain supported where the core permits. Configuration fields must follow the official sing-box documentation and JSON Schema, and every rendered configuration must pass the target core's `sing-box check`.

Opaque generated patches are not accepted as source changes. Work must be reviewable as normal commits, preserve least-privilege services, and keep `state.json` plus protected credentials as the source of truth.

## Phase 1 — State Safety and Recovery

- [x] Add strict state shape and semantic validation with a versioned schema.
- [x] Add explicit, one-way state migration infrastructure.
- [x] Hold the manager lock across every read-modify-write operation.
- [x] Make state, generated config, credentials, and certificates one recoverable transaction.
- [x] Harden backup restore against traversal, links, special files, and archive bombs.
- [x] Add encrypted backup support and restore failure-injection tests.

Acceptance: concurrent mutations cannot lose updates; any failed render, restart, credential rotation, certificate deployment, or restore returns all managed data and services to the previous working state.

## Phase 2 — Trusted Installation and Upgrades

- [x] Publish immutable releases with checksums and a signed provenance path.
- [x] Pin bootstrap installations to a tag or commit instead of mutable `main`.
- [x] Require verified sing-box, cloudflared, and acme.sh artifacts.
- [x] Record installed versions, URLs, digests, and build tags.
- [x] Treat minor/major core upgrades as compatibility migrations and retain an explicit known-good core/config pair.
- [x] Validate certificate SAN, chain, permissions, reload, and rollback after renewal.

Acceptance: executable code is never installed silently without provenance, and failed upgrades or renewals restore a verified working version.

## Phase 3 — Operations and Diagnostics

- [x] Add `sb probe NODE_ID` and `sb doctor --network` for DNS, listeners, TLS, UDP/QUIC, IPv4/IPv6 exposure, and firewall guidance.
- [x] Add log retention, disk usage checks, resource limits, and secret-safe diagnostics.
- [x] Test Debian 13 systemd and the OpenRC abstraction on the designated server.
- [x] Exercise interrupted download, no-network, low-disk, and service crash recovery.
- [x] Validate reboot persistence with an isolated systemd unit on the designated Debian 13 test server.

Acceptance: an operator can distinguish local configuration, host firewall, cloud security-group, DNS, certificate, and external reachability failures.

## Phase 4 — Protocol and User Model

- [x] Separate listeners/nodes from users so credentials can be added, disabled, rotated, and revoked independently.
- [x] Add VLESS Reality, Trojan TLS, and TUIC first; add ShadowTLS and Naive only after canonical core and client export tests pass.
- [x] Detect public addresses with explicit source tracking and preserve manual overrides.
- [x] Gate every field by core version and required build tag.

Acceptance: server configs, share URIs, and client outbounds validate against supported official cores, with real TCP/UDP listener and client handshake tests.

## Phase 5 — Export and Protected Control Plane

- [x] Export complete sing-box client profiles, subscriptions, DNS/routing templates, and optional compatible formats.
- [x] Add expiring subscription tokens without exposing root-managed state.
- [x] Evaluate the sing-box 1.14 API/Dashboard only on loopback or a protected tunnel with strong authentication and audit logging.

Acceptance: exported profiles validate and connect; control endpoints are never unauthenticated or directly exposed to the public Internet.

## Completion Gate

Completion requires all checkboxes above, updated architecture/schema/security documentation, clean static checks, and successful real-core integration, backup/upgrade fault injection, systemd lifecycle, and end-to-end validation on the designated remote Debian 13 test server. Local execution is not acceptance evidence. Production data and firewall rules must not be changed implicitly.

## Optional Nginx Stream Port Multiplexing

- [x] Add exact-SNI TCP passthrough without TLS termination.
- [x] Keep routed sing-box backends on unique loopback ports.
- [x] Preserve direct ports and restore them when multiplexing is disabled.
- [x] Integrate CLI, panel, systemd sandbox, diagnostics, exports, backup normalization, uninstall, and transaction rollback.
- [x] Reject unsupported protocols, duplicate/mismatched SNI, duplicate backends, unknown SNI, and occupied frontend ports.
- [x] Validate real TLS/Reality/ShadowTLS paths and service lifecycle on Debian 13 and Alpine/OpenRC.

## Node Traffic Accounting and Control

- [x] Keep traffic policy in node state and accumulated counters in a protected runtime journal.
- [x] Count TCP/UDP and IPv4/IPv6 upload/download traffic on effective direct, Tunnel, and Nginx Stream listeners.
- [x] Enforce total/download monthly quotas and independent directional rate ceilings in an owned nftables table.
- [x] Preserve counters across rule changes, backup/restore, clean shutdown, systemd reboot, and OpenRC startup.
- [x] Avoid taking over existing host qdiscs or implicitly opening firewall ports.

## Explicit Firewall Protection

- [x] Add panel/CLI setup for Fail2ban SSH protection with a 180-second window, five retries, and permanent bans.
- [x] Add panel/CLI UFW installation, idempotent TCP 22/80/443 allows, and active protocol-port allows before enablement.
- [x] Snapshot existing iptables/UFW status and Fail2ban jail configuration before these explicit host changes.

## Acceptance record (2026-08-28)

The complete smoke suite passed on Debian 13.6 using official sing-box
1.14.0-rc.1 assets whose GitHub Release API
SHA-256 digests were verified. It covered real TCP/UDP listeners, all protocol
exports, state migration/transactions, age backup, paired core rollback,
subscription systemd sandbox startup, API loopback gating, service lifecycle,
installer rollback injection, recovery fault injection, ACME pinning, network
probing, and reboot persistence. The existing production unit was restored to
its pre-test `enabled/inactive` state; its `/etc/sb-manager` and
`/usr/local/lib/sb-manager` data were not modified. Alpine/OpenRC coverage is
provided by the dedicated musl smoke suite; Ubuntu and RPM-family hosts remain
covered by the shared service and package-manager abstractions.
