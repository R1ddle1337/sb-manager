#!/usr/bin/env bash
# shellcheck shell=bash

state_default_json() {
  jq -n \
    --arg version "$SBM_VERSION" \
    --arg now "$(now_iso)" \
    '{
      schema_version: 1,
      manager_version: $version,
      created_at: $now,
      updated_at: $now,
      settings: {
        log_level: "info",
        default_server_address: "",
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
      certificates: [],
      nodes: []
    }'
}

state_init_dirs() {
  mkdir -p "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_SECRETS/nodes" "$SBM_CERTS" "$SBM_VAR" "$SBM_BACKUPS" "$SBM_EXPORTS" "$SBM_CACHE" "$SBM_RUN"
  chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" 2>/dev/null || true
  chmod 0700 "$SBM_SECRETS/nodes" 2>/dev/null || true
  if getent group "$SBM_SERVICE_USER" >/dev/null 2>&1; then
    chown root:"$SBM_SERVICE_USER" "$SBM_SECRETS" 2>/dev/null || true
    chmod 0710 "$SBM_SECRETS" 2>/dev/null || true
  else
    chmod 0700 "$SBM_SECRETS" 2>/dev/null || true
  fi
  chmod 0750 "$SBM_VAR" "$SBM_BACKUPS" "$SBM_EXPORTS" "$SBM_CACHE" 2>/dev/null || true
}

state_init() {
  state_init_dirs
  if [[ ! -s "$SBM_STATE" ]]; then
    local tmp
    tmp=$(mktemp "$SBM_ETC/.state.XXXXXX")
    state_default_json >"$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$SBM_STATE"
  fi
  state_validate "$SBM_STATE"
}

state_validate() {
  local f=$1
  jq -e 'type=="object" and .schema_version==1 and (.nodes|type=="array") and (.certificates|type=="array")' "$f" >/dev/null || die "状态文件无效：$f"
}

state_candidate() {
  mktemp "$SBM_RUN/state.candidate.XXXXXX"
}

state_node_exists() { jq -e --arg id "$1" '.nodes[]? | select(.id==$id)' "$SBM_STATE" >/dev/null; }
state_get_node() { jq -c --arg id "$1" '.nodes[]? | select(.id==$id)' "$SBM_STATE"; }
state_list_nodes() { jq -c '.nodes[]?' "$SBM_STATE"; }
state_enabled_nodes() { jq -c '.nodes[]? | select(.enabled==true)' "$1"; }
state_secret_path() { printf '%s/nodes/%s.json\n' "$SBM_SECRETS" "$1"; }
state_get_secret() {
  local id=$1 path
  path=$(state_secret_path "$id")
  [[ -r "$path" ]] || die "节点密钥文件不存在：$path"
  jq -c . "$path"
}
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
  dir="$SBM_BACKUPS/snapshots/${stamp}-${reason//[^a-zA-Z0-9._-]/_}"
  mkdir -p "$dir"
  [[ -f "$SBM_STATE" ]] && cp -a "$SBM_STATE" "$dir/state.json"
  [[ -f "$SBM_CONFIG" ]] && cp -a "$SBM_CONFIG" "$dir/config.json"
  [[ -d "$SBM_SECRETS/nodes" ]] && cp -a "$SBM_SECRETS/nodes" "$dir/node-secrets"
  printf '%s\n' "$dir"
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
  backup=$(snapshot_create "$reason")

  local state_tmp config_tmp
  state_tmp="${SBM_STATE}.new.$$"; config_tmp="${SBM_CONFIG}.new.$$"
  install -m 0600 "$candidate" "$state_tmp"
  install -m 0640 "$config" "$config_tmp"
  set_group_if_exists "$SBM_SERVICE_USER" "$config_tmp"
  mv -f "$state_tmp" "$SBM_STATE"
  mv -f "$config_tmp" "$SBM_CONFIG"

  if [[ "$SBM_SKIP_SYSTEMD" != "1" ]] && service_exists "$SBM_SERVICE"; then
    if ! service_restart "$SBM_SERVICE" || ! service_active "$SBM_SERVICE"; then
      log_error "新配置启动失败，正在回滚。"
      [[ -f "$backup/state.json" ]] && cp -a "$backup/state.json" "$SBM_STATE"
      [[ -f "$backup/config.json" ]] && cp -a "$backup/config.json" "$SBM_CONFIG"
      service_try_restart "$SBM_SERVICE" || true
      return 1
    fi
  fi
  snapshot_prune 20
  return 0
}
