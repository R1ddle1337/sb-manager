# Remote Debian 13 Acceptance Record

## Scope

Acceptance was run on `root@13.214.43.41` (Debian 13.6, systemd), using a
fresh checkout under `/root/sbmanager-test.Kz0YxF`. The existing installation
under `/etc/sb-manager` and `/usr/local/lib/sb-manager` was not used as test
state. No firewall or cloud security-group rule was changed.

The official sing-box archives were downloaded from GitHub Releases and
verified through each Release API asset digest:

| Core | Asset | SHA-256 |
|---|---|---|
| Stable | `sing-box-1.13.19-linux-amd64.tar.gz` | `ef88a9e577d474210867bd708933d042e9b70106529df2656182c9db90106aa1` |
| Preview | `sing-box-1.14.0-rc.1-linux-amd64.tar.gz` | `342f6e3b4ab79abe470d1516b35dced9bc8dfe62dc43a459a53d97960108afeb` |

The generic Linux archives were used for protocol tests because they include
the official `libcronet.so` companion required by Naive client outbounds.

## Passed checks

- State schema v2, v1 migration, locking, transaction rollback, restore safety,
  age encryption, and paired core rollback.
- VMess, Shadowsocks 2022, AnyTLS, Hysteria2, Trojan, TUIC, VLESS TLS/Reality,
  Naive, and ShadowTLS server/client configuration checks against 1.13.19.
- Real TCP/UDP listeners, mixed/TUN exports, subscription expiry/revocation,
  loopback API/Dashboard on 1.14 RC, public-address tracking, and `sb probe`.
- systemd/OpenRC lifecycle abstractions, sandbox execution, low-disk and
  service-crash rollback injection, ACME pinning, download retry, installer
  rollback, and latest-bootstrap commit resolution.
- An isolated systemd unit remained enabled and listening after a real host
  reboot; it was then removed and the production unit restored to its prior
  `enabled/inactive` state.

Cross-distribution acceptance is intentionally outside the current Debian-only
scope; the implementation retains separate OpenRC/Alpine tests for a future
dedicated host.
