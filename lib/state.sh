#!/usr/bin/env bash
# shellcheck shell=bash

state_default_json() {
  jq -n \
    --arg version "$SBM_VERSION" \
    --arg now "$(now_iso)" \
    '{
      schema_version: 2,
      manager_version: $version,
      created_at: $now,
      updated_at: $now,
      settings: {
        log_level: "info",
        default_server_address: "",
        default_server_address_source: "auto",
        public_ipv4: "",
        public_ipv6: "",
        public_ip_detected_at: null,
        outbound_ip_strategy: "prefer_ipv4",
        dns_optimistic: false,
        dns_optimistic_timeout: "3d",
        dns_timeout: "10s",
        core_channel: "stable",
        core_update_policy: "notify",
        cloudflared_update_policy: "notify"
      },
      tunnel: {
        mode: "none",
        node_id: null,
        domain: null,
        client_address: null,
        protocol: "http2"
      },
      api: {
        enabled: false,
        listen: "127.0.0.1",
        port: 9090,
        dashboard: false
      },
      nginx_stream: {
        enabled: false,
        listen: "::",
        port: 443,
        routes: []
      },
      notifications: {
        enabled: false,
        provider: "none",
        traffic_thresholds: [80, 90, 100]
      },
      health: {
        enabled: false,
        certificate_warn_days: 21,
        resources: {
          disk_min_free_percent: 10,
          inode_max_percent: 90,
          memory_max_percent: 90,
          cpu_load_per_core_max: 2,
          file_descriptors_max_percent: 80,
          fail2ban_banned_warn: 10,
          service_restart_warn: 3
        }
      },
      node_templates: [],
      certificates: [],
      nodes: []
    }'
}

state_init_dirs() {
  mkdir -p "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_SECRETS/nodes" "$SBM_SECRETS/users" "$SBM_CERTS" "$SBM_VAR" "$SBM_BACKUPS" "$SBM_EXPORTS" "$SBM_CACHE" "$SBM_RUN"
  chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" 2>/dev/null || true
  chmod 0700 "$SBM_SECRETS/nodes" "$SBM_SECRETS/users" 2>/dev/null || true
  if group_exists "$SBM_SERVICE_USER"; then
    chown root:"$SBM_SERVICE_USER" "$SBM_SECRETS" 2>/dev/null || true
    chmod 0710 "$SBM_SECRETS" 2>/dev/null || true
  else
    chmod 0700 "$SBM_SECRETS" 2>/dev/null || true
  fi
  chmod 0750 "$SBM_VAR" "$SBM_BACKUPS" "$SBM_EXPORTS" "$SBM_CACHE" 2>/dev/null || true
}

_state_init() {
  state_init_dirs
  if [[ ! -s "$SBM_STATE" ]]; then
    local tmp
    tmp=$(mktemp "$SBM_ETC/.state.XXXXXX")
    state_default_json >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$SBM_STATE"
  fi
  state_migrate
  state_validate "$SBM_STATE"
}
state_init() { with_lock _state_init; }

state_migrate() {
  local version backup
  version=$(jq -r '.schema_version // empty' "$SBM_STATE" 2>/dev/null || true)
  case "$version" in
    2) state_normalize_v2; return 0 ;;
    1)
      backup=$(snapshot_create schema-v1)
      if ! state_migrate_v1_to_v2; then
        snapshot_restore "$backup" || true
        die "状态 schema v1 → v2 迁移失败；已尝试恢复快照：$backup"
      fi
      log_ok "状态已从 schema v1 迁移到 v2；迁移前快照：$backup"
      ;;
    '') die "状态文件缺少 schema_version，无法自动迁移：$SBM_STATE" ;;
    *) die "不支持的状态版本 $version；当前管理器仅支持 schema_version 1/2。" ;;
  esac
}

state_normalize_v2_file() {
  local file=$1 tmp
  tmp=$(mktemp "$(dirname "$file")/.state-normalize.XXXXXX")
  jq '
    .settings.default_server_address_source //= (if .settings.default_server_address=="" then "auto" else "manual" end)
    | .settings.public_ipv4 //= ""
    | .settings.public_ipv6 //= ""
    | .settings.public_ip_detected_at //= null
    | .settings.outbound_ip_strategy //= "prefer_ipv4"
    | .settings.dns_optimistic //= false
    | .settings.dns_optimistic_timeout //= "3d"
    | .settings.dns_timeout //= "10s"
    | .api //= {enabled:false,listen:"127.0.0.1",port:9090,dashboard:false}
    | .nginx_stream //= {enabled:false,listen:"::",port:443,routes:[]}
    | .notifications //= {enabled:false,provider:"none",traffic_thresholds:[80,90,100]}
    | .notifications.enabled //= false
    | .notifications.provider //= "none"
    | .notifications.traffic_thresholds //= [80,90,100]
    | .health //= {enabled:false,certificate_warn_days:21,resources:{}}
    | .health.enabled //= false
    | .health.certificate_warn_days //= 21
    | .health.resources //= {}
    | .health.resources.disk_min_free_percent //= 10
    | .health.resources.inode_max_percent //= 90
    | .health.resources.memory_max_percent //= 90
    | .health.resources.cpu_load_per_core_max //= 2
    | .health.resources.file_descriptors_max_percent //= 80
    | .health.resources.fail2ban_banned_warn //= 10
    | .health.resources.service_restart_warn //= 3
    | .node_templates //= []
    | .nodes |= map(
        .metadata //= {remark:"",region:"",purpose:"",line:"",tags:[]}
        | .metadata.remark //= ""
        | .metadata.region //= ""
        | .metadata.purpose //= ""
        | .metadata.line //= ""
        | .metadata.tags //= []
        | .traffic //= {}
        | .traffic.configured //= false
        | .traffic.enabled //= false
        | .traffic.quota_bytes //= null
        | .traffic.quota_mode //= "total"
        | .traffic.reset_day //= 1
        | .traffic.upload_rate_bps //= null
        | .traffic.download_rate_bps //= null
        | if .protocol == "hysteria2" then
            .obfs //= {}
            | .obfs.type //= ""
            | .disable_chrome_parrot //= false
          else . end
      )
  ' "$file" >"$tmp"
  chmod 0600 "$tmp"
  if cmp -s "$tmp" "$file"; then rm -f "$tmp"; else mv -f "$tmp" "$file"; fi
}

state_normalize_v2() { state_normalize_v2_file "$SBM_STATE"; }

state_migrate_v1_to_v2() {
  local staged candidate node id protocol old_secret user_dir user_secret node_secret
  staged="$SBM_SECRETS.migrate.$$"
  candidate=$(mktemp "$SBM_ETC/.state-v2.XXXXXX")
  rm -rf -- "$staged"
  cp -a "$SBM_SECRETS" "$staged"
  mkdir -p "$staged/users" "$staged/nodes"
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    old_secret="$SBM_SECRETS/nodes/$id.json"
    [[ -s "$old_secret" ]] || { rm -rf "$staged"; rm -f "$candidate"; return 1; }
    user_dir="$staged/users/$id"; user_secret="$user_dir/default.json"; node_secret="$staged/nodes/$id.json"
    mkdir -p "$user_dir"
    case "$protocol" in
      hysteria2)
        jq '{password}' "$old_secret" >"$user_secret"
        jq '{obfs_password:(.obfs_password // "")}' "$old_secret" >"$node_secret"
        ;;
      shadowsocks)
        jq '{password}' "$old_secret" >"$user_secret"
        rm -f "$node_secret"
        ;;
      *) cp -a "$old_secret" "$user_secret"; rm -f "$node_secret" ;;
    esac
    chmod 0600 "$user_secret"
    [[ ! -f "$node_secret" ]] || chmod 0600 "$node_secret"
  done < <(jq -c '.nodes[]?' "$SBM_STATE")
  jq '
    .schema_version=2
    | .settings.default_server_address_source=(if .settings.default_server_address=="" then "auto" else "manual" end)
    | .settings.public_ipv4=""
    | .settings.public_ipv6=""
    | .settings.public_ip_detected_at=null
    | .settings.outbound_ip_strategy="prefer_ipv4"
    | .settings.dns_optimistic=false
    | .settings.dns_optimistic_timeout="3d"
    | .settings.dns_timeout="10s"
    | .api={enabled:false,listen:"127.0.0.1",port:9090,dashboard:false}
    | .nginx_stream={enabled:false,listen:"::",port:443,routes:[]}
    | .notifications={enabled:false,provider:"none",traffic_thresholds:[80,90,100]}
    | .health={enabled:false,certificate_warn_days:21,resources:{disk_min_free_percent:10,inode_max_percent:90,memory_max_percent:90,cpu_load_per_core_max:2,file_descriptors_max_percent:80,fail2ban_banned_warn:10,service_restart_warn:3}}
    | .node_templates=[]
    | .nodes |= map(
        . as $node
        | .users=[{id:"default",name:$node.name,enabled:true,created_at:$node.created_at}]
        | .traffic={configured:false,enabled:false,quota_bytes:null,quota_mode:"total",reset_day:1,upload_rate_bps:null,download_rate_bps:null}
        | .metadata={remark:"",region:"",purpose:"",line:"",tags:[]}
        | if .protocol=="shadowsocks" then .credential_mode="legacy" else . end
      )
  ' "$SBM_STATE" >"$candidate"
  state_validate "$candidate"
  rm -rf -- "$SBM_SECRETS"
  mv -f "$staged" "$SBM_SECRETS"
  chmod 0700 "$SBM_SECRETS/users" "$SBM_SECRETS/nodes" 2>/dev/null || true
  mv -f "$candidate" "$SBM_STATE"
}

state_validate() {
  local f=$1
  jq -e '
    def string: type == "string";
    def nonempty: string and length > 0;
    def timestamp: nonempty and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def port: type == "number" and floor == . and . >= 1 and . <= 65535;
    def traffic_value:
      (type == "number" and floor == . and . >= 1 and . <= 9000000000000000) or type == "null";
    def node_traffic:
      type == "object"
      and (.configured | type == "boolean")
      and (.enabled | type == "boolean")
      and (if .enabled then .configured else true end)
      and (.quota_bytes | traffic_value)
      and (.quota_mode | IN("total", "download"))
      and (.reset_day | type == "number" and floor == . and . >= 1 and . <= 28)
      and (.upload_rate_bps | traffic_value)
      and (.download_rate_bps | traffic_value);
    def node_common:
      type == "object"
      and (.id | string and test("^[a-z0-9][a-z0-9._-]{0,47}$"))
      and (.name | nonempty and (explode | all(.[]; . >= 32 and . != 127)))
      and (.protocol | IN("vmess-ws-cf", "shadowsocks", "anytls", "hysteria2", "trojan", "tuic", "vless", "naive", "shadowtls", "snell"))
      and (.enabled | type == "boolean")
      and (.listen | nonempty)
      and (.port | port)
      and (.created_at | timestamp);
    def node_metadata:
      type == "object"
      and (.remark | string and length <= 512 and (explode | all(.[]; . >= 32 and . != 127)))
      and (.region | string and length <= 128 and (explode | all(.[]; . >= 32 and . != 127)))
      and (.purpose | string and length <= 128 and (explode | all(.[]; . >= 32 and . != 127)))
      and (.line | string and length <= 128 and (explode | all(.[]; . >= 32 and . != 127)))
      and (.tags | type == "array" and length <= 32)
      and all(.tags[]; type == "string" and length > 0 and length <= 48 and test("^[^,[:cntrl:]]+$"));
    def node_protocol:
      if .protocol == "vmess-ws-cf" then
        (.listen == "127.0.0.1")
        and (.ws_path | nonempty and startswith("/"))
        and (.domain | string)
        and (.client_address | string)
      elif .protocol == "shadowsocks" then
        (.network == "tcp")
        and (.method | IN("2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"))
        and (.multiplex | type == "boolean")
        and (.server_address | string)
      elif .protocol == "anytls" then
        (.domain | nonempty) and (.server_address | string)
      elif .protocol == "hysteria2" then
        (.domain | nonempty)
        and (.server_address | string)
        and (.obfs | type == "object")
        and ((.obfs.type // "") | IN("", "salamander", "gecko"))
        and ((.obfs.min_packet_size // 512) | type == "number" and floor == . and . >= 64 and . <= 1500)
        and ((.obfs.max_packet_size // 1200) | type == "number" and floor == . and . >= 64 and . <= 1500)
        and ((.obfs.type // "") != "gecko" or ((.obfs.min_packet_size // 512) <= (.obfs.max_packet_size // 1200)))
        and ((.disable_chrome_parrot // false) | type == "boolean")
        and (.masquerade | string)
      elif .protocol == "trojan" then
        (.domain | nonempty) and (.server_address | string)
      elif .protocol == "tuic" then
        (.domain | nonempty) and (.server_address | string)
        and (.congestion_control | IN("cubic", "new_reno", "bbr"))
      elif .protocol == "vless" then
        (.domain | nonempty) and (.server_address | string)
        and (.security | IN("tls", "reality"))
        and ((.flow | type) == "string" or (.flow | type) == "null")
        and (if .security=="reality" then (.handshake_server | nonempty) and (.handshake_port | port) else true end)
      elif .protocol == "naive" then
        (.domain | nonempty) and (.server_address | string)
        and (.network | IN("tcp", "udp"))
        and (.quic_congestion_control | IN("cubic", "new_reno", "bbr"))
      elif .protocol == "shadowtls" then
        (.server_address | string) and (.handshake_server | nonempty)
        and (.handshake_port | port)
        and (.strict_mode | type == "boolean")
        and (.wildcard_sni | IN("off", "authed", "all"))
      elif .protocol == "snell" then
        (.server_address | string)
        and (.obfs_mode | IN("none", "http"))
        and (.obfs_host | nonempty)
      else false end;
    type == "object"
    and .schema_version == 2
    and (.manager_version | nonempty)
    and (.created_at | timestamp)
    and (.updated_at | timestamp)
    and (.settings | type == "object"
      and (.log_level | IN("trace", "debug", "info", "warn", "error", "fatal", "panic"))
      and (.default_server_address | string)
      and (.default_server_address_source | IN("auto", "manual"))
      and (.public_ipv4 | string)
      and (.public_ipv6 | string)
      and ((.public_ip_detected_at | type) == "string" or (.public_ip_detected_at | type) == "null")
      and (.outbound_ip_strategy | IN("prefer_ipv4", "prefer_ipv6", "ipv4_only"))
      and (.dns_optimistic | type == "boolean")
      and (.dns_optimistic_timeout | type == "string" and test("^[0-9]+(ms|s|m|h|d)$"))
      and (.dns_timeout | type == "string" and test("^[0-9]+(ms|s|m|h|d)$"))
      and (.core_channel | nonempty)
      and (.core_update_policy | IN("manual", "notify", "patch", "stable"))
      and (.cloudflared_update_policy | nonempty))
    and (.tunnel | type == "object"
      and (.mode | IN("none", "fixed", "quick"))
      and ((.node_id | type) == "string" or (.node_id | type) == "null")
      and ((.domain | type) == "string" or (.domain | type) == "null")
      and ((.client_address | type) == "string" or (.client_address | type) == "null")
      and (.protocol | nonempty))
    and (.api | type == "object"
      and (.enabled | type == "boolean")
      and .listen == "127.0.0.1"
      and (.port | port)
      and (.dashboard | type == "boolean"))
    and (.nginx_stream | type == "object"
      and (.enabled | type == "boolean")
      and (.listen | nonempty)
      and (.port | port)
      and (.routes | type == "array")
      and all(.routes[];
        type == "object"
        and (.node_id | string and test("^[a-z0-9][a-z0-9._-]{0,47}$"))
        and (.sni | nonempty)
        and (.backend_port | port)))
    and (.notifications | type == "object"
      and (.enabled | type == "boolean")
      and (.provider | IN("none", "telegram", "wecom", "webhook"))
      and (.traffic_thresholds | type == "array" and length > 0 and length <= 10)
      and all(.traffic_thresholds[]; type == "number" and floor == . and . >= 1 and . <= 100)
      and ((.traffic_thresholds | unique | length) == (.traffic_thresholds | length))
      and (if .enabled then .provider != "none" else true end))
    and (.health | type == "object"
      and (.enabled | type == "boolean")
      and (.certificate_warn_days | type == "number" and floor == . and . >= 1 and . <= 365)
      and (.resources | type == "object")
      and (.resources.disk_min_free_percent | type == "number" and floor == . and . >= 1 and . <= 99)
      and (.resources.inode_max_percent | type == "number" and floor == . and . >= 1 and . <= 100)
      and (.resources.memory_max_percent | type == "number" and floor == . and . >= 1 and . <= 100)
      and (.resources.cpu_load_per_core_max | type == "number" and . >= 0.1 and . <= 100)
      and (.resources.file_descriptors_max_percent | type == "number" and floor == . and . >= 1 and . <= 100)
      and (.resources.fail2ban_banned_warn | type == "number" and floor == . and . >= 1 and . <= 1000000)
      and (.resources.service_restart_warn | type == "number" and floor == . and . >= 1 and . <= 1000000))
    and (.node_templates | type == "array" and length <= 128)
    and all(.node_templates[];
      type == "object"
      and (.name | string and test("^[a-z0-9][a-z0-9._-]{0,47}$"))
      and (.protocol | IN("vmess-ws-cf", "shadowsocks", "anytls", "hysteria2", "trojan", "tuic", "vless", "naive", "shadowtls", "snell"))
      and (.defaults | type == "object"))
    and (.certificates | type == "array")
    and all(.certificates[];
      type == "object"
      and (.domain | nonempty)
      and (.provider | nonempty)
      and (.key_type | nonempty)
      and (.certificate_path | nonempty)
      and (.key_path | nonempty))
    and (.nodes | type == "array")
    and all(.nodes[];
      node_common and node_protocol
      and (.traffic | node_traffic)
      and (.metadata | node_metadata)
      and (.users | type == "array" and length > 0)
      and all(.users[];
        type == "object"
        and (.id | string and test("^[a-z0-9][a-z0-9._-]{0,47}$"))
        and (.name | nonempty and (explode | all(.[]; . >= 32 and . != 127)))
        and (.enabled | type == "boolean")
        and (.created_at | timestamp)))
  ' "$f" >/dev/null || die "状态文件结构无效或字段不符合 schema v2：$f"
}

state_candidate() {
  mktemp "$SBM_RUN/state.candidate.XXXXXX"
}

state_node_exists() { jq -e --arg id "$1" '.nodes[]? | select(.id==$id)' "$SBM_STATE" >/dev/null; }
state_get_node() { jq -c --arg id "$1" '.nodes[]? | select(.id==$id)' "$SBM_STATE"; }
state_list_nodes() { jq -c '.nodes[]?' "$SBM_STATE"; }
state_enabled_nodes() { jq -c '.nodes[]? | select(.enabled==true)' "$1"; }
state_enabled_count() {
  local state=${1:-$SBM_STATE}
  jq '[.nodes[]? | select(.enabled==true)] | length' "$state"
}
state_runtime_required() {
  local state=${1:-$SBM_STATE}
  (( $(state_enabled_count "$state") > 0 )) || [[ $(jq -r '.api.enabled // false' "$state") == true ]]
}

singbox_service_reconcile() {
  [[ "$SBM_SKIP_INIT" == "1" ]] && return 0
  service_exists "$SBM_SERVICE" || return 0
  service_reload_manager
  if ! state_runtime_required; then
    # Keep an empty installation dormant across reboots. Adding the first
    # enabled node will enable and start the unit again below.
    service_disable "$SBM_SERVICE"
    service_stop "$SBM_SERVICE"
    service_reset_failed "$SBM_SERVICE"
    return 0
  fi
  service_enable "$SBM_SERVICE" || true
  service_reset_failed "$SBM_SERVICE"
  if ! service_restart "$SBM_SERVICE"; then
    service_failure_report "$SBM_SERVICE"
    return 1
  fi
  if ! service_wait_active "$SBM_SERVICE" 20; then
    service_failure_report "$SBM_SERVICE"
    return 1
  fi
}
state_secret_path() { printf '%s/nodes/%s.json\n' "$SBM_SECRETS" "$1"; }
state_get_secret() {
  local id=$1 path
  path=$(state_secret_path "$id")
  [[ -r "$path" ]] || die "节点密钥文件不存在：$path"
  jq -c . "$path"
}

state_user_secret_dir() { printf '%s/users/%s\n' "$SBM_SECRETS" "$1"; }
state_user_secret_path() { printf '%s/users/%s/%s.json\n' "$SBM_SECRETS" "$1" "$2"; }
state_get_user_secret() {
  local node_id=$1 user_id=$2 path
  path=$(state_user_secret_path "$node_id" "$user_id")
  [[ -r "$path" ]] || die "用户密钥文件不存在：$path"
  jq -c . "$path"
}
state_write_user_secret() {
  local node_id=$1 user_id=$2 json=$3 dir path tmp
  dir=$(state_user_secret_dir "$node_id"); path=$(state_user_secret_path "$node_id" "$user_id")
  mkdir -p "$dir"; chmod 0700 "$dir"
  tmp=$(mktemp "$dir/.${user_id}.XXXXXX")
  printf '%s\n' "$json" | jq . >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$path"
}
state_get_user() { jq -c --arg nid "$1" --arg uid "$2" '.nodes[]? | select(.id==$nid) | .users[]? | select(.id==$uid)' "$SBM_STATE"; }
state_user_exists() { [[ -n $(state_get_user "$1" "$2") ]]; }
state_write_secret() {
  local id=$1 json=$2 path tmp
  path=$(state_secret_path "$id")
  tmp=$(mktemp "$SBM_SECRETS/nodes/.${id}.XXXXXX")
  printf '%s\n' "$json" | jq . >"$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$path"
}

state_unique_id() {
  local base=$1 i=1 candidate
  candidate=$base
  while state_node_exists "$candidate"; do ((i++)); candidate="${base}-${i}"; done
  printf '%s\n' "$candidate"
}

state_update_timestamp() {
  local file=$1 tmp
  tmp=$(mktemp "$SBM_RUN/state.ts.XXXXXX")
  jq --arg now "$(now_iso)" --arg v "$SBM_VERSION" '.updated_at=$now | .manager_version=$v' "$file" >"$tmp"
  mv "$tmp" "$file"
}

snapshot_create() {
  local reason=${1:-manual} stamp dir
  stamp=$(now_stamp)
  mkdir -p "$SBM_BACKUPS/snapshots"
  dir=$(mktemp -d "$SBM_BACKUPS/snapshots/${stamp}-${reason//[^a-zA-Z0-9._-]/_}.XXXXXX")
  if [[ "$SBM_SKIP_INIT" != "1" ]] && declare -F traffic_checkpoint_unlocked >/dev/null 2>&1 \
    && jq -e '.schema_version==2 and all(.nodes[]?; (.traffic.reset_day // 0) >= 1)' "$SBM_STATE" >/dev/null 2>&1; then
    traffic_checkpoint_unlocked || log_warn '创建快照前无法同步流量用量；快照中的用量可能稍旧。'
  fi
  [[ -f "$SBM_STATE" ]] && cp -a "$SBM_STATE" "$dir/state.json"
  [[ -f "$SBM_CONFIG" ]] && cp -a "$SBM_CONFIG" "$dir/config.json"
  [[ -d "$SBM_SECRETS" ]] && cp -a "$SBM_SECRETS" "$dir/secrets"
  [[ -d "$SBM_CERTS" ]] && cp -a "$SBM_CERTS" "$dir/certs"
  [[ -d "$SBM_SUBSCRIPTIONS" ]] && cp -a "$SBM_SUBSCRIPTIONS" "$dir/subscriptions"
  [[ -f "$SBM_TRAFFIC_USAGE" ]] && cp -a "$SBM_TRAFFIC_USAGE" "$dir/traffic-usage.json"
  printf '%s\n' "$dir"
}

snapshot_restore_payload() {
  local snapshot=$1 path tmp
  [[ -d "$snapshot" ]] || return 1
  if [[ -d "$snapshot/secrets" ]]; then
    tmp="$SBM_SECRETS.rollback.$$"
    rm -rf -- "$tmp"
    cp -a "$snapshot/secrets" "$tmp"
    rm -rf -- "$SBM_SECRETS"
    mv -f -- "$tmp" "$SBM_SECRETS"
  elif [[ -d "$snapshot/node-secrets" ]]; then
    tmp="$SBM_SECRETS.rollback.$$"
    rm -rf -- "$tmp"
    mkdir -p "$tmp"
    cp -a "$snapshot/node-secrets" "$tmp/nodes"
    rm -rf -- "$SBM_SECRETS"
    mv -f -- "$tmp" "$SBM_SECRETS"
  fi
  if [[ -d "$snapshot/certs" ]]; then
    tmp="$SBM_CERTS.rollback.$$"
    rm -rf -- "$tmp"
    cp -a "$snapshot/certs" "$tmp"
    rm -rf -- "$SBM_CERTS"
    mv -f -- "$tmp" "$SBM_CERTS"
  fi
  if [[ -d "$snapshot/subscriptions" ]]; then
    tmp="$SBM_SUBSCRIPTIONS.rollback.$$"
    rm -rf -- "$tmp"
    cp -a "$snapshot/subscriptions" "$tmp"
    rm -rf -- "$SBM_SUBSCRIPTIONS"
    mv -f -- "$tmp" "$SBM_SUBSCRIPTIONS"
  fi
  if [[ -f "$snapshot/traffic-usage.json" ]]; then
    install -m 0600 "$snapshot/traffic-usage.json" "$SBM_TRAFFIC_USAGE"
  else
    rm -f "$SBM_TRAFFIC_USAGE"
  fi
  state_init_dirs
  return 0
}

snapshot_restore() {
  local snapshot=$1
  [[ -d "$snapshot" ]] || return 1
  if [[ "$SBM_SKIP_INIT" != "1" ]] && declare -F nginx_stream_reconcile >/dev/null 2>&1 && service_exists "$SBM_NGINX_STREAM_SERVICE"; then
    service_stop "$SBM_NGINX_STREAM_SERVICE"
  fi
  [[ -f "$snapshot/state.json" ]] && cp -a "$snapshot/state.json" "$SBM_STATE"
  [[ -f "$snapshot/config.json" ]] && cp -a "$snapshot/config.json" "$SBM_CONFIG"
  snapshot_restore_payload "$snapshot" || return 1
  if [[ -f "$SBM_STATE" ]]; then
    state_migrate || return 1
    state_validate "$SBM_STATE"
  fi
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_exists "$SBM_SERVICE"; then
    singbox_service_reconcile || return 1
  fi
  if [[ "$SBM_SKIP_INIT" != "1" ]] && declare -F traffic_reconcile_unlocked >/dev/null 2>&1; then
    traffic_reconcile_unlocked 0 || return 1
  fi
  if declare -F nginx_stream_reconcile >/dev/null 2>&1; then
    nginx_stream_reconcile || return 1
  fi
  if declare -F subscription_reconcile >/dev/null 2>&1; then
    subscription_reconcile 1 || return 1
  fi
}

_state_transaction_run() {
  local reason=$1 fn=$2 backup rc=0
  shift 2
  backup=$(snapshot_create "pre-$reason")
  if (
    export SBM_OPERATION_SNAPSHOT="$backup"
    "$fn" "$@"
  ); then
    snapshot_prune 20
    return 0
  else
    rc=$?
  fi
  log_error "操作 $reason 失败，正在恢复完整状态。"
  snapshot_restore "$backup" || log_error "自动恢复未完成，请检查快照：$backup"
  if declare -F tunnel_reconcile_after_rollback >/dev/null 2>&1; then
    tunnel_reconcile_after_rollback || log_error "Tunnel 回滚后协调失败，请运行 sb doctor。"
  fi
  return "$rc"
}

with_state_transaction() {
  local reason=$1 fn=$2
  shift 2
  with_lock _state_transaction_run "$reason" "$fn" "$@"
}

snapshot_prune() {
  local keep=${1:-20}
  [[ -d "$SBM_BACKUPS/snapshots" ]] || return 0
  mapfile -t dirs < <(find "$SBM_BACKUPS/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
  local i
  for ((i=keep; i<${#dirs[@]}; i++)); do rm -rf -- "${dirs[$i]}"; done
}

state_install_candidate() {
  local candidate=$1 config=$2 reason=${3:-change} backup
  state_validate "$candidate"
  state_update_timestamp "$candidate"
  backup=${SBM_OPERATION_SNAPSHOT:-}
  [[ -n "$backup" && -d "$backup" ]] || backup=$(snapshot_create "$reason")

  local state_tmp config_tmp
  state_tmp="${SBM_STATE}.new.$$"; config_tmp="${SBM_CONFIG}.new.$$"
  if declare -F nginx_stream_prepare_transition >/dev/null 2>&1; then
    nginx_stream_prepare_transition "$candidate" || return 1
  fi
  if [[ "$SBM_SKIP_INIT" != "1" ]] && declare -F traffic_checkpoint_unlocked >/dev/null 2>&1; then
    traffic_checkpoint_unlocked || return 1
  fi
  install -m 0600 "$candidate" "$state_tmp"
  install -m 0640 "$config" "$config_tmp"
  set_group_if_exists "$SBM_SERVICE_USER" "$config_tmp"
  mv -f "$state_tmp" "$SBM_STATE"
  mv -f "$config_tmp" "$SBM_CONFIG"

  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_exists "$SBM_SERVICE"; then
    if ! singbox_service_reconcile; then
      log_error "新配置启动失败，正在回滚。"
      snapshot_restore "$backup" || log_error "自动回滚失败，请立即检查快照：$backup"
      return 1
    fi
  fi
  if [[ "$SBM_SKIP_INIT" != "1" ]] && declare -F traffic_reconcile_unlocked >/dev/null 2>&1; then
    if ! traffic_reconcile_unlocked 0; then
      log_error '流量控制规则应用失败，正在回滚。'
      snapshot_restore "$backup" || log_error '自动回滚失败，请立即检查快照。'
      return 1
    fi
  fi
  if declare -F nginx_stream_reconcile >/dev/null 2>&1; then
    if ! nginx_stream_reconcile; then
      log_error 'Nginx Stream 服务启动失败，正在回滚。'
      snapshot_restore "$backup" || log_error '自动回滚失败，请立即检查快照。'
      return 1
    fi
  fi
  snapshot_prune 20
  return 0
}
