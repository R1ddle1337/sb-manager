#!/usr/bin/env bash
# shellcheck shell=bash

SBM_SUBSTORE_DIR="${SBM_SUBSTORE_DIR:-$SBM_VAR/substore}"
SBM_SUBSTORE_SECRET="${SBM_SUBSTORE_SECRET:-$SBM_SECRETS/substore.json}"
SBM_SUBSTORE_SERVICE="${SBM_SUBSTORE_SERVICE:-sb-substore.service}"
SBM_SUBSTORE_NODE="${SBM_SUBSTORE_NODE:-/usr/bin/node}"

substore_validate_state() {
  jq -e '(.substore // {enabled:false,port:3001,version:"",frontend_version:""}) |
    (.enabled|type=="boolean") and (.port|type=="number" and floor==. and .>=1024 and .<=65535) and
    (.version|type=="string" and test("^[0-9A-Za-z._-]*$")) and (.frontend_version|type=="string" and test("^[0-9A-Za-z._-]*$"))' "$1" >/dev/null
}

substore_access_path() {
  jq -er '.api_path|select(type=="string" and test("^/[a-f0-9]{48}$"))' "$SBM_SUBSTORE_SECRET"
}

substore_download_asset() {
  local repo=$1 version=$2 asset=$3 output=$4 release tag url digest
  [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || usage_die '组件版本无效。'
  if [[ "$version" == latest ]]; then release=$(github_api "https://api.github.com/repos/$repo/releases/latest") || return 1
  else release=$(github_api "https://api.github.com/repos/$repo/releases/tags/$version") || return 1; fi
  tag=$(jq -er '.tag_name|select(test("^[0-9A-Za-z._-]+$"))' <<<"$release") || return 1
  jq -e --arg asset "$asset" '.assets[]|select(.name==$asset)|.size<=134217728' <<<"$release" >/dev/null || return 1
  url=$(jq -er --arg asset "$asset" '.assets[]|select(.name==$asset)|.browser_download_url' <<<"$release") || return 1
  digest=$(jq -er --arg asset "$asset" '.assets[]|select(.name==$asset)|.digest' <<<"$release") || return 1
  [[ "$url" == "https://github.com/$repo/releases/download/$tag/$asset" && "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || { log_error '组件下载地址或 SHA-256 摘要无效。'; return 1; }
  download_file_with_retries "$url" "$output" "$repo/$asset" || return 1
  verify_asset_digest "$output" "$digest" || { log_error 'Sub-Store 下载校验失败。'; return 1; }
  jq -n --arg version "$tag" --arg url "$url" --arg sha256 "${digest#sha256:}" '{version:$version,url:$url,sha256:$sha256}'
}

substore_write_service() {
  local port=$1 node jqbin launcher="$SBM_SUBSTORE_DIR/run.sh" unit
  node=$(command -v "$SBM_SUBSTORE_NODE") || return 1
  jqbin=$(command -v jq) || return 1
  substore_access_path >/dev/null || return 1
  cat >"$launcher" <<EOF_LAUNCH
#!/bin/sh
set -eu
export SUB_STORE_BACKEND_API_HOST=127.0.0.1
export SUB_STORE_BACKEND_API_PORT=$port
export SUB_STORE_BACKEND_MERGE=true
export SUB_STORE_BACKEND_PREFIX=true
export SUB_STORE_FRONTEND_PATH="$SBM_SUBSTORE_DIR/app/frontend"
export SUB_STORE_DATA_BASE_PATH="$SBM_SUBSTORE_DIR/data"
SUB_STORE_FRONTEND_BACKEND_PATH=\$("$jqbin" -er '.api_path' "$SBM_SUBSTORE_SECRET")
export SUB_STORE_FRONTEND_BACKEND_PATH
cd "$SBM_SUBSTORE_DIR/data"
exec "$node" --max-old-space-size=192 "$SBM_SUBSTORE_DIR/app/sub-store.bundle.js"
EOF_LAUNCH
  chmod 0755 "$launcher" || return 1
  if [[ $(effective_init_system) == systemd ]]; then
    mkdir -p "$SBM_SYSTEMD_DIR" || return 1
    unit="$SBM_SYSTEMD_DIR/$SBM_SUBSTORE_SERVICE"
    cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager Sub-Store
After=network-online.target
Wants=network-online.target

[Service]
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStart=$launcher
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$SBM_SUBSTORE_DIR/data
MemoryMax=384M
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 0644 "$unit"
  else
    write_openrc_supervised_service "$SBM_OPENRC_DIR/${SBM_SUBSTORE_SERVICE%.service}" \
      'sb-manager Sub-Store' 'sb-manager Sub-Store' "$launcher" '' "$SBM_SERVICE_USER" \
      "$SBM_LOG_DIR/substore.log" "$SBM_LOG_DIR/substore.err.log" 'after firewall'
  fi
}

substore_permissions() {
  chmod 0750 "$SBM_SUBSTORE_DIR" || return 1
  set_group_if_exists "$SBM_SERVICE_USER" "$SBM_SUBSTORE_DIR" || return 1
  find "$SBM_SUBSTORE_DIR/app" -type d -exec chmod 0755 {} + || return 1
  find "$SBM_SUBSTORE_DIR/app" -type f -exec chmod 0644 {} + || return 1
  chmod 0700 "$SBM_SUBSTORE_DIR/data" || return 1
  if id "$SBM_SERVICE_USER" >/dev/null 2>&1; then chown -R "$SBM_SERVICE_USER:$SBM_SERVICE_USER" "$SBM_SUBSTORE_DIR/data" || return 1; fi
  chmod 0640 "$SBM_SUBSTORE_SECRET" && set_group_if_exists "$SBM_SERVICE_USER" "$SBM_SUBSTORE_SECRET"
}

substore_health() {
  local port=$1 path i
  [[ "$SBM_SKIP_INIT" == 1 ]] && return 0
  path=$(substore_access_path) || return 1
  for ((i=0;i<20;i++)); do
    if curl --fail --silent --max-time 2 --noproxy '*' "http://127.0.0.1:$port$path/api/subs" >/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

substore_reconcile() {
  local start=${1:-1} enabled port
  enabled=$(jq -r '.substore.enabled // false' "$SBM_STATE"); port=$(jq -r '.substore.port // 3001' "$SBM_STATE")
  if [[ "$enabled" == false ]]; then
    if [[ "$SBM_SKIP_INIT" != 1 && "$start" == 1 ]] && service_exists "$SBM_SUBSTORE_SERVICE"; then
      service_disable "$SBM_SUBSTORE_SERVICE" && service_stop "$SBM_SUBSTORE_SERVICE" || return 1
    fi
    return 0
  fi
  [[ -f "$SBM_SUBSTORE_DIR/app/manifest.json" ]] || { [[ "$enabled" == false ]]; return; }
  substore_permissions && substore_write_service "$port" || return 1
  [[ "$SBM_SKIP_INIT" == 1 || "$start" == 0 ]] && return 0
  service_reload_manager || return 1
  if [[ "$enabled" == true ]]; then
    service_enable "$SBM_SUBSTORE_SERVICE" && service_restart "$SBM_SUBSTORE_SERVICE" && substore_health "$port"
  else service_disable "$SBM_SUBSTORE_SERVICE" && service_stop "$SBM_SUBSTORE_SERVICE"; fi
}

substore_backup_payload() {
  local output=$1 active=0 rc=0
  [[ -d "$SBM_SUBSTORE_DIR/app" ]] || return 0
  if [[ "$SBM_SKIP_INIT" != 1 ]] && service_active "$SBM_SUBSTORE_SERVICE"; then
    active=1; service_stop "$SBM_SUBSTORE_SERVICE" || return 1
  fi
  mkdir -p "$output" && cp -a "$SBM_SUBSTORE_DIR/app" "$SBM_SUBSTORE_DIR/data" "$output/" || rc=$?
  if (( active )); then service_start "$SBM_SUBSTORE_SERVICE" || rc=1; fi
  return "$rc"
}

_substore_transaction() {
  local fn=$1 backup rc=0 existed=0 secret=0
  shift
  backup=$(mktemp -d "$SBM_RUN/substore-rollback.XXXXXX") || return 1
  if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_SUBSTORE_SERVICE"; then service_stop "$SBM_SUBSTORE_SERVICE" || return 1; fi
  if ! cp -p "$SBM_STATE" "$backup/state.json"; then substore_reconcile || true; rm -rf "$backup"; return 1; fi
  if [[ -d "$SBM_SUBSTORE_DIR" ]]; then
    existed=1
    if ! cp -a "$SBM_SUBSTORE_DIR" "$backup/store"; then substore_reconcile || true; rm -rf "$backup"; return 1; fi
  fi
  if [[ -f "$SBM_SUBSTORE_SECRET" ]]; then
    secret=1
    if ! cp -p "$SBM_SUBSTORE_SECRET" "$backup/access.json"; then substore_reconcile || true; rm -rf "$backup"; return 1; fi
  fi
  if ("$fn" "$@"); then rm -rf "$backup"; return 0; else rc=$?; fi
  log_error 'Sub-Store 操作失败，恢复原程序、数据与设置。'
  rm -rf "$SBM_SUBSTORE_DIR"
  [[ "$existed" == 0 ]] || cp -a "$backup/store" "$SBM_SUBSTORE_DIR" || return 1
  cp -p "$backup/state.json" "$SBM_STATE" || return 1
  if [[ "$secret" == 1 ]]; then cp -p "$backup/access.json" "$SBM_SUBSTORE_SECRET" || return 1; else rm -f "$SBM_SUBSTORE_SECRET"; fi
  if [[ "$existed" == 1 ]]; then substore_reconcile || { log_error "恢复服务失败，保留快照：$backup"; return 1; }
  else
    [[ "$SBM_SKIP_INIT" == 1 ]] || { service_disable "$SBM_SUBSTORE_SERVICE" || true; service_stop "$SBM_SUBSTORE_SERVICE" || true; }
    rm -f "$SBM_SYSTEMD_DIR/$SBM_SUBSTORE_SERVICE" "$SBM_OPENRC_DIR/${SBM_SUBSTORE_SERVICE%.service}"
    service_reload_manager || true
  fi
  rm -rf "$backup"
  return "$rc"
}

substore_save_settings() {
  local settings=$1 tmp
  tmp=$(state_candidate) || return 1
  jq --argjson settings "$settings" '.substore=$settings' "$SBM_STATE" >"$tmp" || return 1
  state_validate "$tmp" && state_update_timestamp "$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$SBM_STATE"
}

_substore_install_candidate() {
  local stage=$1 port=$2 settings
  mkdir -p "$SBM_SUBSTORE_DIR/data" || return 1
  rm -rf "$SBM_SUBSTORE_DIR/app"
  cp -a "$stage" "$SBM_SUBSTORE_DIR/app" || return 1
  if [[ ! -f "$SBM_SUBSTORE_SECRET" ]]; then
    jq -n --arg path "/$(random_hex 24)" '{api_path:$path}' >"$SBM_SUBSTORE_SECRET" || return 1
  fi
  settings=$(jq --argjson port "$port" '{enabled:true,port:$port,version:.backend.version,frontend_version:.frontend.version}' "$stage/manifest.json") || return 1
  substore_save_settings "$settings" && substore_reconcile
}

substore_install() {
  local version=${1:-latest} frontend=${2:-latest} port=${3:-3001} stage backend_meta frontend_meta rc=0
  [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] && (( port >= 1024 && port <= 65535 )) || usage_die 'Sub-Store 端口必须为 1024–65535。'
  dependency_require_feature substore || return 1
  stage=$(mktemp -d "$SBM_RUN/substore-download.XXXXXX") || return 1
  if ! backend_meta=$(substore_download_asset sub-store-org/Sub-Store "$version" sub-store.bundle.js "$stage/sub-store.bundle.js") ||
    ! frontend_meta=$(substore_download_asset sub-store-org/Sub-Store-Front-End "$frontend" dist.zip "$stage/frontend.zip") ||
    ! "$SBM_SUBSTORE_NODE" --check "$stage/sub-store.bundle.js" ||
    ! python3 "$SBM_LIB/libexec/component_archive.py" "$stage/frontend.zip" "$stage/extracted"; then rm -rf "$stage"; return 1; fi
  if [[ -f "$stage/extracted/index.html" ]]; then mv "$stage/extracted" "$stage/frontend" || return 1
  elif [[ -f "$stage/extracted/dist/index.html" ]]; then mv "$stage/extracted/dist" "$stage/frontend" || return 1
  else rm -rf "$stage"; log_error 'Sub-Store 前端缺少 index.html。'; return 1; fi
  rm -rf "$stage/extracted" "$stage/frontend.zip"
  jq -n --argjson backend "$backend_meta" --argjson frontend "$frontend_meta" '{backend:$backend,frontend:$frontend}' >"$stage/manifest.json" || return 1
  with_lock _substore_transaction _substore_install_candidate "$stage" "$port" || rc=$?
  rm -rf "$stage"
  (( rc == 0 )) && log_ok 'Sub-Store 已安装；运行 sb substore access 查看本机访问地址。'
  return "$rc"
}

_substore_enable() {
  local enabled=$1 settings
  [[ -f "$SBM_SUBSTORE_DIR/app/manifest.json" ]] || usage_die 'Sub-Store 尚未安装。'
  settings=$(jq --argjson enabled "$enabled" '.substore|.enabled=$enabled' "$SBM_STATE") || return 1
  substore_save_settings "$settings" && substore_reconcile
}

_substore_backup() {
  local output=$1 stage tmp enabled
  [[ -d "$SBM_SUBSTORE_DIR/app" ]] || usage_die 'Sub-Store 尚未安装。'
  mkdir -p "$(dirname "$output")" || return 1
  stage=$(mktemp -d "$SBM_RUN/substore-backup.XXXXXX") || return 1
  tmp=$(mktemp "$(dirname "$output")/.substore-backup.XXXXXX") || return 1
  enabled=$(jq -r '.substore.enabled' "$SBM_STATE")
  if [[ "$SBM_SKIP_INIT" != 1 && "$enabled" == true ]]; then service_stop "$SBM_SUBSTORE_SERVICE" || return 1; fi
  local rc=0
  cp -a "$SBM_SUBSTORE_DIR/app" "$SBM_SUBSTORE_DIR/data" "$stage/" &&
    cp -p "$SBM_SUBSTORE_SECRET" "$stage/access.json" && jq '.substore' "$SBM_STATE" >"$stage/settings.json" &&
    tar -C "$stage" -czf "$tmp" . && chmod 0600 "$tmp" && mv "$tmp" "$output" || rc=$?
  if [[ "$SBM_SKIP_INIT" != 1 && "$enabled" == true ]]; then service_restart "$SBM_SUBSTORE_SERVICE" || rc=1; fi
  rm -rf "$stage"; rm -f "$tmp"
  (( rc == 0 )) && log_ok "Sub-Store 备份已创建（包含凭据）：$output"
  return "$rc"
}

_substore_restore_candidate() {
  local stage=$1 settings
  settings=$(jq -c . "$stage/settings.json") || return 1
  rm -rf "$SBM_SUBSTORE_DIR/app" "$SBM_SUBSTORE_DIR/data"
  mkdir -p "$SBM_SUBSTORE_DIR" || return 1
  cp -a "$stage/app" "$stage/data" "$SBM_SUBSTORE_DIR/" && cp -p "$stage/access.json" "$SBM_SUBSTORE_SECRET" || return 1
  substore_save_settings "$settings" && substore_reconcile
}

substore_restore() {
  local archive=$1 stage rc=0 sha
  dependency_require_feature substore || return 1
  [[ -f "$archive" && $(wc -c <"$archive") -le 134217728 ]] || usage_die 'Sub-Store 备份不存在或超过 128 MiB。'
  stage=$(mktemp -d "$SBM_RUN/substore-restore.XXXXXX") || return 1
  if ! python3 "$SBM_LIB/libexec/component_archive.py" "$archive" "$stage" ||
    ! jq -e '.api_path|test("^/[a-f0-9]{48}$")' "$stage/access.json" >/dev/null ||
    ! "$SBM_SUBSTORE_NODE" --check "$stage/app/sub-store.bundle.js" ||
    [[ ! -f "$stage/app/frontend/index.html" || ! -d "$stage/data" ]]; then rm -rf "$stage"; return 1; fi
  sha=$(jq -er '.backend.sha256|select(test("^[a-f0-9]{64}$"))' "$stage/app/manifest.json") || { rm -rf "$stage"; return 1; }
  verify_asset_digest "$stage/app/sub-store.bundle.js" "sha256:$sha" || { rm -rf "$stage"; return 1; }
  with_lock _substore_transaction _substore_restore_candidate "$stage" || rc=$?
  rm -rf "$stage"
  return "$rc"
}

substore_api() {
  local method=$1 path=$2 body=${3:-} config url rc=0
  local -a args
  url="http://127.0.0.1:$(jq -r '.substore.port' "$SBM_STATE")$(substore_access_path)$path" || return 1
  config=$(mktemp "$SBM_RUN/substore-curl.XXXXXX") || return 1
  printf 'url = %s\n' "$(jq -Rn --arg url "$url" '$url')" >"$config"
  chmod 0600 "$config" || return 1
  args=(--fail --silent --show-error --max-time 15 --noproxy '*' --config "$config" -X "$method")
  [[ -z "$body" ]] || args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  curl "${args[@]}" || rc=$?
  rm -f "$config"
  return "$rc"
}

# Resource bodies contain subscription credentials; keep them out of status output.
substore_resource_list() {
  local resource=$1 response
  response=$(substore_api GET "/api/${resource}s") || return 1
  jq -e '.status=="success" and (.data|type=="array")' <<<"$response" >/dev/null || return 1
  jq '.data' <<<"$response"
}

substore_resource_write() {
  local resource=$1 name=$2 body=$3 exists=$4 response method=POST path="/api/${1}s"
  if [[ "$exists" == true ]]; then method=PATCH; path="/api/$resource/$name"; fi
  response=$(substore_api "$method" "$path" "$body") || return 1
  jq -e '.status=="success"' <<<"$response" >/dev/null
}

substore_resource_restore() {
  local resource=$1 name=$2 body=$3 current exists response
  current=$(substore_resource_list "$resource") || return 1
  exists=$(jq --arg name "$name" 'any(.[];.name==$name)' <<<"$current") || return 1
  if [[ $(jq -r 'type' "$body") == null ]]; then
    [[ "$exists" == true ]] || return 0
    response=$(substore_api DELETE "/api/$resource/$name") || return 1
    jq -e '.status=="success"' <<<"$response" >/dev/null
  else substore_resource_write "$resource" "$name" "$body" "$exists"; fi
}

substore_validate_source_url() {
  local url=$1
  [[ ${#url} -le 4096 && ! "$url" =~ [[:space:][:cntrl:]] ]] || return 1
  printf '%s' "$url" | python3 -c '
import sys
from urllib.parse import urlsplit
try:
    url = urlsplit(sys.stdin.read())
    valid = bool(url.hostname) and not url.username and not url.password and not url.fragment
    valid = valid and (url.port is None or 1 <= url.port <= 65535)
    valid = valid and (url.scheme == "https" or (url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}))
    sys.exit(0 if valid else 1)
except ValueError:
    sys.exit(1)
'
}

_substore_source_set() {
  local name=$1 url=$2 collection=${3:-sb-manager-all} subs collections stage existed col_existed rollback=0
  validate_node_id "$name" && validate_node_id "$collection" || usage_die '来源和组合名称须为有效 ID。'
  [[ $(jq -r '.substore.enabled // false' "$SBM_STATE") == true ]] || usage_die '请先启用 Sub-Store。'
  substore_validate_source_url "$url" || usage_die '请使用 HTTPS 订阅 URL（SSH 转发可用本机 HTTP），不带用户名、密码或 # 片段。'
  subs=$(substore_resource_list sub) && collections=$(substore_resource_list collection) || return 1
  stage=$(mktemp -d "$SBM_RUN/substore-source.XXXXXX") || return 1
  chmod 0700 "$stage" || return 1
  jq --arg name "$name" 'first(.[]|select(.name==$name)) // null' <<<"$subs" >"$stage/source.json" || return 1
  jq --arg name "$collection" 'first(.[]|select(.name==$name)) // null' <<<"$collections" >"$stage/collection.json" || return 1
  existed=$(jq '.!=null' "$stage/source.json"); col_existed=$(jq '.!=null' "$stage/collection.json")
  jq --arg name "$name" --arg url "$url#noCache" '(. // {}) + {name:$name,source:"remote",url:$url,content:""} | del(.mergeSources)' "$stage/source.json" >"$stage/new-source.json" || return 1
  jq --arg name "$collection" --arg source "$name" '(. // {}) | .name=$name | .subscriptions=((.subscriptions // []) | if index($source)==null then .+[$source] else . end)' "$stage/collection.json" >"$stage/new-collection.json" || return 1
  chmod 0600 "$stage"/*.json || return 1
  if substore_resource_write sub "$name" "$stage/new-source.json" "$existed" &&
    substore_resource_write collection "$collection" "$stage/new-collection.json" "$col_existed"; then
    rm -rf "$stage"
    log_ok "已接入来源 $name，加入组合 $collection；后续更新订阅时自动拉取。"
    return 0
  fi
  # A timed-out request may already have committed. Restore both resources.
  substore_resource_restore collection "$collection" "$stage/collection.json" || rollback=1
  substore_resource_restore sub "$name" "$stage/source.json" || rollback=1
  if (( rollback )); then log_error "接入失败，自动恢复未完成；原定义保留在 $stage。"
  else rm -rf "$stage"; log_error '接入失败，已恢复原来源和组合。'; fi
  return 1
}

substore_source_list() {
  local json=${1:-0} subs collections data
  subs=$(substore_resource_list sub) && collections=$(substore_resource_list collection) || return 1
  data=$(jq --argjson collections "$collections" '[.[] | . as $sub |
    {name,source,collections:[$collections[]|select((.subscriptions // [])|index($sub.name))|.name]}]' <<<"$subs") || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$data"
  else jq -r 'if length==0 then "暂无订阅来源。" else .[]|"\(.name)  \(.source)  组合：\(.collections|join(","))" end' <<<"$data"; fi
}

_substore_source_remove() {
  local name=$1 response
  validate_node_id "$name" || usage_die '来源名称无效。'
  response=$(substore_api DELETE "/api/sub/$name") || return 1
  jq -e '.status=="success"' <<<"$response" >/dev/null || return 1
  log_ok "已移除订阅来源：$name。原服务器的订阅令牌仍可单独撤销。"
}

substore_source_check() {
  local name=$1 response
  validate_node_id "$name" || usage_die '来源名称无效。'
  response=$(substore_api GET "/download/$name?target=JSON&noCache=true") || return 1
  jq -e 'type=="array"' <<<"$response" >/dev/null || { log_error '来源拉取或节点解析失败。'; return 1; }
  log_ok "来源 $name 可用，解析到 $(jq length <<<"$response") 个节点。"
}

_substore_sync() {
  local name=${1:-sb-manager} subs url token='' digest created='' meta
  validate_node_id "$name" || usage_die 'Sub-Store 订阅名称无效。'
  [[ $(jq -r '.substore.enabled // false' "$SBM_STATE") == true ]] || usage_die '请先启用 Sub-Store。'
  subs=$(substore_resource_list sub) || return 1
  url=$(jq -r --arg name "$name" 'first(.[]|select(.name==$name)|.url) // ""' <<<"$subs") || return 1
  if [[ "$url" == "http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/"* ]]; then
    token=${url#*/sub/}; token=${token%%\?*}
    digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
    meta="$SBM_SUBSCRIPTIONS/$digest.meta.json"
    if [[ ! -f "$meta" ]] || ! jq -e '.live==true and .expires_at_epoch==null' "$meta" >/dev/null; then token=''; fi
  fi
  if [[ -z "$token" ]]; then
    created=$(mktemp "$SBM_RUN/substore-live.XXXXXX") || return 1
    if ! _subscription_create never mixed true >"$created"; then rm -f "$created"; return 1; fi
    token=$(sed -n 's#^本机 URL：.*/sub/##p' "$created")
    rm -f "$created"
    [[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || return 1
  else subscription_refresh_live || return 1; fi
  url="http://127.0.0.1:$SBM_SUBSCRIPTION_PORT/sub/$token?format=substore"
  if ! _substore_source_set "$name" "$url"; then
    [[ -z "$created" ]] || _subscription_revoke "$token" >/dev/null
    return 1
  fi
  log_ok "本机节点已接入动态订阅：$name；节点变更后自动更新。"
}

substore_cli() {
  local action=${1:-status} version=latest frontend=latest port path
  (($# == 0)) || shift
  port=$(jq -r '.substore.port // 3001' "$SBM_STATE")
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die 'Sub-Store 命令不接受 --dry-run。'
  case "$action" in
    install|update)
      while (($#)); do
        [[ $# -ge 2 ]] || usage_die "参数 $1 缺少值"
        case "$1" in --version) version=$2;; --frontend-version) frontend=$2;; --port) port=$2;; *) usage_die "未知参数：$1";; esac
        shift 2
      done
      substore_install "$version" "$frontend" "$port";;
    enable|disable) [[ $# == 0 ]] || usage_die '参数过多'; [[ "$action" == enable ]] && action=true || action=false; with_lock _substore_transaction _substore_enable "$action";;
    status) [[ $# == 0 || ( $# == 1 && "$1" == --json ) ]] || usage_die '用法：sb substore status [--json]'; jq '.substore // {enabled:false,port:3001,version:"",frontend_version:""}' "$SBM_STATE";;
    access) [[ $# == 0 ]] || usage_die '参数过多'; path=$(substore_access_path) || return 1; printf '前端：http://127.0.0.1:%s/\n后端：http://127.0.0.1:%s%s\n' "$port" "$port" "$path";;
    backup) [[ $# == 1 ]] || usage_die '用法：sb substore backup FILE'; with_lock _substore_backup "$1";;
    restore) [[ $# == 1 ]] || usage_die '用法：sb substore restore FILE'; substore_restore "$1";;
    sync) [[ $# -le 1 ]] || usage_die '用法：sb substore sync [NAME]'; with_lock _substore_sync "${1:-sb-manager}";;
    source)
      case "${1:-list}" in
        list) [[ $# -le 2 && ${2:---json} == --json ]] || usage_die '用法：sb substore source list [--json]'; substore_source_list "$([[ ${2:-} == --json || ${SBM_OUTPUT_JSON:-0} == 1 ]] && echo 1 || echo 0)";;
        add) [[ $# == 3 || $# == 4 ]] || usage_die '用法：sb substore source add NAME URL [COLLECTION]'; with_lock _substore_source_set "$2" "$3" "${4:-sb-manager-all}";;
        remove) [[ $# == 2 ]] || usage_die '用法：sb substore source remove NAME'; with_lock _substore_source_remove "$2";;
        check) [[ $# == 2 ]] || usage_die '用法：sb substore source check NAME'; substore_source_check "$2";;
        *) usage_die '用法：sb substore source list|add|remove|check';;
      esac;;
    *) usage_die '用法：sb substore install|update|enable|disable|status|access|backup|restore|sync|source';;
  esac
}
