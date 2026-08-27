# State schema v1

Simplified example:

```json
{
  "schema_version": 1,
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
  "nodes": []
}
```

Protocol credentials are intentionally excluded from the state file and kept as one file per node under `secrets/nodes/<id>.json`.

Future schema changes must be implemented as explicit, one-way migration steps before rendering. Generated config files must never be parsed back into state.
