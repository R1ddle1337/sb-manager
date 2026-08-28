# State schema v2

Simplified example:

```json
{
  "schema_version": 2,
  "manager_version": "0.1.0-alpha.9",
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
  "nginx_stream": {
    "enabled": true,
    "listen": "::",
    "port": 443,
    "routes": [
      {"node_id": "any-main", "sni": "edge.example.com", "backend_port": 20000}
    ]
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

`nginx_stream.routes` separates the public frontend from sing-box's runtime listener. A node keeps its original direct `listen`/`port`; while the mux is enabled, rendering substitutes `127.0.0.1:<backend_port>` and exports substitute the shared public port. Node IDs, SNI values, and backend ports must each be unique. Older schema-v2 files without this section are normalized to a disabled empty configuration before validation.

Existing v1 installations migrate once, before rendering, with a pre-migration snapshot. Future changes must use explicit, one-way migration steps. Generated config files must never be parsed back into state.

Mutations hold the manager lock through candidate validation, rendering,
installation, and service reconciliation. A failed operation restores the
state/config pair plus secrets, certificates, subscriptions, and service
definitions from the operation snapshot. Core upgrades additionally retain a
known-good binary/config pair for compatibility-aware rollback.
