#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_CORE_DIR="$ROOT/cores"
export SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_LOCK="$SBM_RUN/manager.lock"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=sbmanager NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX to official sing-box 1.14+}"

source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/realm.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/node.sh"
source "$PROJECT/lib/export.sh"

version_ge "$(core_current_version)" 1.14.0-rc.1
state_init
realm_enable 19091 http://127.0.0.1:19091 127.0.0.1 '' 8

jq -e '.realm.enabled==true and .realm.max_realms==8' "$SBM_STATE" >/dev/null
jq -e '.services[0].type=="hysteria-realm" and .services[0].listen=="127.0.0.1" and .services[0].listen_port==19091 and .services[0].users[0].max_realms==8' "$SBM_CONFIG" >/dev/null
[[ -s "$SBM_REALM_SECRET" && $(stat -c %a "$SBM_REALM_SECRET") == 600 ]]

mkdir -p "$SBM_CERTS/edge.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=edge.example.com' \
  -keyout "$SBM_CERTS/edge.example.com/key.pem" -out "$SBM_CERTS/edge.example.com/fullchain.pem" >/dev/null 2>&1
node_add hy2 --id hy2-realm --name 'Realm test' --port 24543 --domain edge.example.com --address 192.0.2.1 \
  --realm-id slot1 --realm-ip-version 4 --realm-port-mapping

jq -e '.nodes[0].realm_enabled==true and .nodes[0].realm_id=="slot1" and .nodes[0].realm_ip_version==4 and .nodes[0].realm_port_mapping==true' "$SBM_STATE" >/dev/null
jq -e '.inbounds[0].realm.server_url=="http://127.0.0.1:19091" and .inbounds[0].realm.realm_id=="slot1" and .inbounds[0].realm.ip_version==4 and .inbounds[0].realm.port_mapping.enabled==true' "$SBM_CONFIG" >/dev/null
node_client_outbound hy2-realm | jq -e '.realm.server_url=="http://127.0.0.1:19091" and .realm.realm_id=="slot1" and (.server|not) and (.server_port|not)' >/dev/null
node_share_uri hy2-realm | grep -Fq 'realm-server=http%3A%2F%2F127.0.0.1%3A19091'
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"

node_disable hy2-realm
realm_disable
[[ $(jq -r '.realm.enabled' "$SBM_STATE") == false && ! -e "$SBM_REALM_SECRET" ]]

# HTTPS Realm service uses the managed certificate paths.
realm_enable 19092 https://realm.example.com :: edge.example.com 4
jq -e '.services[0].tls.enabled==true and .services[0].tls.server_name=="edge.example.com" and (.services[0].tls.certificate_path|endswith("/edge.example.com/fullchain.pem"))' "$SBM_CONFIG" >/dev/null
"$SBM_SING_BOX_BIN" check -c "$SBM_CONFIG"
realm_disable
printf 'HYSTERIA REALM PREVIEW SMOKE PASSED\n'
