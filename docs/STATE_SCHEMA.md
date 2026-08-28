# State schema v2

Simplified example:

```json
{
  "schema_version": 2,
  "manager_version": "0.1.0-alpha.1",
  "settings": {
    "log_level": "info",
    "default_server_address": "edge.example.com",
    "core_channel": "stable",
    "core_update_policy": "notify"
  },
  "tunnel": {
    "mode": "fixed",
    "node_id": "vm-cf-main",
    "domain": "cdn.example.com",
    "client_address": "cdn.example.com",
    "protocol": "http2"
  },
  "certificates": [
    {
      "domain": "edge.example.com",
      "provider": "acme.sh/dns_cf",
      "key_type": "ec-256",
      "certificate_path": "/etc/sb-manager/certs/edge.example.com/fullchain.pem",
      "key_path": "/etc/sb-manager/certs/edge.example.com/key.pem"
    }
  ],
  "nodes": [
    {
      "id": "any-main",
      "protocol": "anytls",
      "users": [
        {"id": "default", "name": "AnyTLS", "enabled": true}
      ]
    }
  ]
}
```

Protocol credentials are excluded from the state file. User credentials live under `secrets/users/<node-id>/<user-id>.json`; protocol-level credentials live under `secrets/nodes/<node-id>.json`.

Existing v1 installations migrate once, before rendering, with a pre-migration snapshot. Future changes must use explicit, one-way migration steps. Generated config files must never be parsed back into state.

Mutations hold the manager lock through candidate validation, rendering,
installation, and service reconciliation. A failed operation restores the
state/config pair plus secrets, certificates, subscriptions, and service
definitions from the operation snapshot. Core upgrades additionally retain a
known-good binary/config pair for compatibility-aware rollback.
