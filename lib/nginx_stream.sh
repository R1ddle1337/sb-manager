#!/usr/bin/env bash
# shellcheck shell=bash

nginx_stream_state_enabled() {
  [[ $(jq -r '.nginx_stream.enabled // false' "$1") == true ]]
}

nginx_stream_route_for_node() {
  local state=$1 node_id=$2
  jq -c --arg id "$node_id" '.nginx_stream.routes[]? | select(.node_id==$id)' "$state"
}

nginx_stream_supported_node() {
  local node=$1 protocol network security
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    anytls|trojan|shadowtls) return 0 ;;
    vless)
      security=$(jq -r '.security // ""' <<<"$node")
      [[ "$security" == tls || "$security" == reality ]]
      ;;
    naive)
      network=$(jq -r '.network // "tcp"' <<<"$node")
      [[ "$network" == tcp ]]
      ;;
    *) return 1 ;;
  esac
}

nginx_stream_node_sni() {
  local node=$1 protocol
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    shadowtls) jq -r '.handshake_server // ""' <<<"$node" ;;
    anytls|trojan|vless|naive) jq -r '.domain // ""' <<<"$node" ;;
    *) return 1 ;;
  esac
}

nginx_stream_effective_node() {
  local state=$1 node=$2 node_id route backend
  node_id=$(jq -r '.id' <<<"$node")
  if nginx_stream_state_enabled "$state"; then
    route=$(nginx_stream_route_for_node "$state" "$node_id")
    if [[ -n "$route" ]]; then
      backend=$(jq -r '.backend_port' <<<"$route")
      jq --argjson port "$backend" '.listen="127.0.0.1" | .port=$port' <<<"$node"
      return 0
    fi
  fi
  printf '%s\n' "$node"
}

nginx_stream_public_node() {
  local state=${2:-$SBM_STATE} node=$1 node_id route port
  node_id=$(jq -r '.id' <<<"$node")
  if nginx_stream_state_enabled "$state"; then
    route=$(nginx_stream_route_for_node "$state" "$node_id")
    if [[ -n "$route" ]]; then
      port=$(jq -r '.nginx_stream.port' "$state")
      jq --argjson port "$port" '.port=$port' <<<"$node"
      return 0
    fi
  fi
  printf '%s\n' "$node"
}

nginx_stream_validate_state() {
  local state=$1 cfg enabled listen port routes route node node_id sni expected_sni backend protocol
  local route_count=0
  cfg=$(jq -c '.nginx_stream' "$state" 2>/dev/null) || return 1
  enabled=$(jq -r '.enabled // false' <<<"$cfg")
  listen=$(jq -r '.listen // ""' <<<"$cfg")
  port=$(jq -r '.port // 0' <<<"$cfg")
  routes=$(jq -c '.routes // []' <<<"$cfg")
  [[ "$enabled" == true || "$enabled" == false ]] || { log_error 'nginx_stream.enabled 必须是布尔值。'; return 1; }
  [[ "$listen" == '::' ]] || { log_error 'Nginx Stream 当前只支持监听 ::（双栈）。'; return 1; }
  validate_port "$port" || { log_error "Nginx Stream 公网端口无效：$port"; return 1; }
  if [[ "$enabled" == true && $(jq -r '.api.enabled // false' "$state") == true && $(jq -r '.api.port' "$state") == "$port" ]]; then
    log_error "Nginx Stream 公网端口与 API 端口冲突：$port/TCP"; return 1
  fi
  if [[ "$enabled" == true && "$SBM_SUBSCRIPTION_PORT" == "$port" ]]; then
    log_error "Nginx Stream 公网端口与订阅端口冲突：$port/TCP"; return 1
  fi
  [[ $(jq -r 'type' <<<"$routes") == array ]] || { log_error 'Nginx Stream routes 必须是数组。'; return 1; }
  declare -A seen_nodes=() seen_sni=() seen_backends=()
  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    route_count=$((route_count + 1))
    node_id=$(jq -r '.node_id // ""' <<<"$route")
    sni=$(jq -r '.sni // ""' <<<"$route")
    backend=$(jq -r '.backend_port // 0' <<<"$route")
    [[ -n "$node_id" && -z ${seen_nodes[$node_id]+x} ]] || { log_error "Nginx Stream 节点路由重复或缺少 node_id：$node_id"; return 1; }
    [[ -n "$sni" ]] || { log_error 'Nginx Stream 路由缺少 SNI。'; return 1; }
    validate_domain "$sni" || { log_error "Nginx Stream SNI 必须是完整域名：$sni"; return 1; }
    validate_port "$backend" || { log_error "Nginx Stream 后端端口无效：$backend"; return 1; }
    (( backend != port )) || { log_error "Nginx Stream 后端端口不能等于公网端口：$backend"; return 1; }
    [[ "$backend" != "$SBM_SUBSCRIPTION_PORT" ]] || { log_error "Nginx Stream 后端端口不能使用订阅端口：$backend"; return 1; }
    if [[ $(jq -r '.api.enabled // false' "$state") == true && $(jq -r '.api.port' "$state") == "$backend" ]]; then
      log_error "Nginx Stream 后端端口与 API 端口冲突：$backend"; return 1
    fi
    [[ -z ${seen_sni[$sni]+x} ]] || { log_error "Nginx Stream SNI 重复：$sni"; return 1; }
    [[ -z ${seen_backends[$backend]+x} ]] || { log_error "Nginx Stream 后端端口重复：$backend"; return 1; }
    node=$(jq -c --arg id "$node_id" '.nodes[]? | select(.id==$id)' "$state")
    [[ -n "$node" ]] || { log_error "Nginx Stream 路由引用了不存在的节点：$node_id"; return 1; }
    nginx_stream_supported_node "$node" || { log_error "协议不支持 Nginx Stream SNI 复用：$(jq -r '.protocol' <<<"$node")/$node_id"; return 1; }
    expected_sni=$(nginx_stream_node_sni "$node")
    [[ "${sni,,}" == "${expected_sni,,}" ]] || { log_error "节点 $node_id 的路由 SNI 必须与协议 server_name 一致：$expected_sni"; return 1; }
    if [[ "$enabled" == true && $(jq -r '.enabled' <<<"$node") != true ]]; then
      log_error "Nginx Stream 已启用，但节点未启用：$node_id"; return 1
    fi
    seen_nodes[$node_id]=1; seen_sni[$sni]=1; seen_backends[$backend]=1
  done < <(jq -c '.[]' <<<"$routes")
  if [[ "$enabled" == true && $route_count -eq 0 ]]; then
    log_error 'Nginx Stream 已启用，但没有任何 SNI 路由。'; return 1
  fi
  if [[ "$enabled" == true ]]; then
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      [[ $(jq -r '.enabled' <<<"$node") == true ]] || continue
      node_id=$(jq -r '.id' <<<"$node"); protocol=$(jq -r '.protocol' <<<"$node")
      if [[ -z ${seen_nodes[$node_id]+x} ]]; then
        case "$protocol" in
          vmess-ws-cf|anytls|trojan|shadowtls|vless|shadowsocks)
            [[ $(jq -r '.port' <<<"$node") != "$port" ]] || { log_error "节点 $node_id 占用 Nginx Stream 公网端口 ${port}/TCP。"; return 1; }
            ;;
          naive)
            [[ $(jq -r '.network' <<<"$node") != tcp || $(jq -r '.port' <<<"$node") != "$port" ]] || { log_error "节点 $node_id 占用 Nginx Stream 公网端口 ${port}/TCP。"; return 1; }
            ;;
        esac
      fi
    done < <(jq -c '.nodes[]?' "$state")
  fi
}

nginx_stream_module_path() {
  local path
  if [[ -n ${SBM_NGINX_STREAM_MODULE:-} && -f "$SBM_NGINX_STREAM_MODULE" ]]; then
    printf '%s\n' "$SBM_NGINX_STREAM_MODULE"; return 0
  fi
  for path in /usr/lib/nginx/modules/ngx_stream_module.so /usr/lib/nginx/modules/ngx_stream_module.so.*; do
    [[ -f "$path" ]] && { printf '%s\n' "$path"; return 0; }
  done
  return 1
}

nginx_stream_runtime_ready() {
  [[ -x "$SBM_NGINX_STREAM_BIN" ]] && nginx_stream_module_path >/dev/null
}

nginx_stream_install_dependencies() {
  local nginx_preexisting=0 mask_created=0 install_rc=0
  nginx_stream_runtime_ready && return 0
  [[ ${SBM_TEST_MODE:-0} == 1 ]] && { log_error '测试模式缺少 Nginx Stream 测试二进制或模块。'; return 1; }
  [[ $(init_system 2>/dev/null || true) == systemd ]] || { log_error 'Nginx Stream 复用目前只支持 Debian/systemd。'; return 1; }
  if command_exists apt-get; then
    if [[ -x "$SBM_NGINX_STREAM_BIN" ]] || systemctl cat nginx.service >/dev/null 2>&1; then nginx_preexisting=1; fi
    if [[ "$nginx_preexisting" == 0 ]]; then
      systemctl mask nginx.service >/dev/null 2>&1 && mask_created=1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || install_rc=$?
    if [[ "$install_rc" == 0 ]]; then apt-get install -y --no-install-recommends nginx-core libnginx-mod-stream || install_rc=$?; fi
    if [[ "$mask_created" == 1 ]]; then systemctl unmask nginx.service >/dev/null 2>&1 || true; fi
    if [[ "$nginx_preexisting" == 0 ]]; then
      systemctl disable --now nginx.service >/dev/null 2>&1 || true
    fi
    (( install_rc == 0 )) || return "$install_rc"
  else
    log_error '未发现 apt-get；请手动安装 nginx-core 和 libnginx-mod-stream。'
    return 1
  fi
  nginx_stream_runtime_ready || { log_error 'Nginx Stream 模块安装后仍未找到。'; return 1; }
}

nginx_stream_backend_name() {
  printf 'sbm_stream_%s\n' "${1//[^a-zA-Z0-9_]/_}"
}

nginx_stream_render_config() {
  local state=$1 output=$2 module route node_id sni backend name
  nginx_stream_validate_state "$state" || return 1
  module=$(nginx_stream_module_path) || { log_error '未找到 ngx_stream_module.so。'; return 1; }
  mkdir -p "$(dirname "$SBM_NGINX_STREAM_PID")" "$(dirname "$output")"
  {
    printf 'load_module %s;\n' "$module"
    printf 'pid %s;\nerror_log stderr notice;\nworker_processes 1;\nevents { worker_connections 4096; }\nstream {\n' "$SBM_NGINX_STREAM_PID"
    printf '    map $ssl_preread_server_name $sbm_stream_backend {\n        default sbm_stream_reject;\n'
    while IFS= read -r route; do
      [[ -n "$route" ]] || continue
      node_id=$(jq -r '.node_id' <<<"$route"); sni=$(jq -r '.sni' <<<"$route"); name=$(nginx_stream_backend_name "$node_id")
      printf '        %s %s;\n' "$sni" "$name"
    done < <(jq -c '.nginx_stream.routes[]' "$state")
    printf '    }\n    upstream sbm_stream_reject { server 127.0.0.1:1; }\n'
    while IFS= read -r route; do
      [[ -n "$route" ]] || continue
      node_id=$(jq -r '.node_id' <<<"$route"); backend=$(jq -r '.backend_port' <<<"$route"); name=$(nginx_stream_backend_name "$node_id")
      printf '    upstream %s { server 127.0.0.1:%s; }\n' "$name" "$backend"
    done < <(jq -c '.nginx_stream.routes[]' "$state")
    printf '    server { listen [::]:%s ipv6only=off; ssl_preread on; proxy_pass $sbm_stream_backend; proxy_connect_timeout 5s; proxy_timeout 1h; access_log off; }\n}\n' "$(jq -r '.nginx_stream.port' "$state")"
  } >"$output"
}

nginx_stream_test_config() {
  local config=$1 log="$SBM_RUN/nginx-stream-check.log"
  mkdir -p "$SBM_RUN"
  "$SBM_NGINX_STREAM_BIN" -t -q -c "$config" >"$log" 2>&1 || { sed -n '1,80p' "$log" >&2; return 1; }
}

nginx_stream_write_config() {
  local state=$1 tmp
  tmp=$(mktemp "$SBM_RUN/nginx-stream.conf.XXXXXX")
  nginx_stream_render_config "$state" "$tmp" || { rm -f "$tmp"; return 1; }
  nginx_stream_test_config "$tmp" || { rm -f "$tmp"; return 1; }
  install -m 0640 "$tmp" "$SBM_NGINX_STREAM_CONFIG"
  set_group_if_exists "$SBM_SERVICE_USER" "$SBM_NGINX_STREAM_CONFIG"
  rm -f "$tmp"
}

nginx_stream_write_service() {
  [[ $(init_system 2>/dev/null || true) == systemd ]] || return 1
  mkdir -p "$SBM_SYSTEMD_DIR"
  cat >"$SBM_SYSTEMD_DIR/$SBM_NGINX_STREAM_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager Nginx Stream SNI multiplexer
Documentation=https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html
After=network-online.target $SBM_SERVICE
Wants=network-online.target
Requires=$SBM_SERVICE

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStartPre=$SBM_NGINX_STREAM_BIN -t -q -c $SBM_NGINX_STREAM_CONFIG
ExecStart=$SBM_NGINX_STREAM_BIN -c $SBM_NGINX_STREAM_CONFIG -g 'daemon off;'
ExecReload=$SBM_NGINX_STREAM_BIN -s reload -c $SBM_NGINX_STREAM_CONFIG
Restart=on-failure
RestartSec=3s
RuntimeDirectory=sb-manager-nginx
RuntimeDirectoryMode=0750
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=$SBM_ETC $SBM_LIB
ReadWritePaths=$SBM_NGINX_STREAM_RUNTIME_DIR
UMask=0027

[Install]
WantedBy=multi-user.target
EOF_UNIT
  chmod 0644 "$SBM_SYSTEMD_DIR/$SBM_NGINX_STREAM_SERVICE"
}

nginx_stream_prepare_transition() {
  [[ ${SBM_SKIP_INIT:-0} == 1 ]] && return 0
  if nginx_stream_state_enabled "$SBM_STATE" && service_exists "$SBM_NGINX_STREAM_SERVICE"; then
    service_stop "$SBM_NGINX_STREAM_SERVICE"
  fi
}

nginx_stream_reconcile() {
  [[ ${SBM_SKIP_INIT:-0} == 1 ]] && return 0
  if ! nginx_stream_state_enabled "$SBM_STATE"; then
    if service_exists "$SBM_NGINX_STREAM_SERVICE"; then
      service_disable "$SBM_NGINX_STREAM_SERVICE" || true
      service_stop "$SBM_NGINX_STREAM_SERVICE" || true
    fi
    return 0
  fi
  [[ $(init_system 2>/dev/null || true) == systemd ]] || { log_error 'Nginx Stream 复用目前只支持 Debian/systemd。'; return 1; }
  nginx_stream_install_dependencies || return 1
  mkdir -p "$SBM_NGINX_STREAM_RUNTIME_DIR" "$(dirname "$SBM_NGINX_STREAM_CONFIG")"
  nginx_stream_write_service || return 1
  nginx_stream_write_config "$SBM_STATE" || return 1
  service_reload_manager
  service_enable "$SBM_NGINX_STREAM_SERVICE"
  if service_active "$SBM_NGINX_STREAM_SERVICE"; then service_restart "$SBM_NGINX_STREAM_SERVICE"; else service_start "$SBM_NGINX_STREAM_SERVICE"; fi
  service_wait_active "$SBM_NGINX_STREAM_SERVICE" 20 2 || { service_failure_report "$SBM_NGINX_STREAM_SERVICE"; return 1; }
}

nginx_stream_backend_port_used() {
  jq -e --argjson p "$2" '.nginx_stream.routes[]? | select(.backend_port==$p)' "$1" >/dev/null
}

nginx_stream_choose_backend_port() {
  local state=$1 p node protocol network
  for ((p=20000; p<=29999; p++)); do
    host_port_in_use tcp "$p" && continue
    nginx_stream_backend_port_used "$state" "$p" && continue
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      [[ $(jq -r '.enabled' <<<"$node") == true ]] || continue
      protocol=$(jq -r '.protocol' <<<"$node"); network=$(jq -r '.network // "tcp"' <<<"$node")
      case "$protocol" in
        hysteria2|tuic) continue ;;
        shadowsocks) [[ "$network" == tcp ]] || continue ;;
        naive) [[ "$network" == tcp ]] || continue ;;
      esac
      [[ $(jq -r '.port' <<<"$node") == "$p" ]] && continue 2
    done < <(jq -c '.nodes[]?' "$state")
    printf '%s\n' "$p"; return 0
  done
  return 1
}

_nginx_stream_route_add() {
  local node_id=$1 sni=$2 backend_port=${3:-} node route candidate expected_sni
  node=$(jq -c --arg id "$node_id" '.nodes[]? | select(.id==$id)' "$SBM_STATE")
  [[ -n "$node" ]] || { log_error "节点不存在：$node_id"; return 1; }
  [[ $(jq -r '.enabled' <<<"$node") == true ]] || { log_error "节点必须先启用才能加入 Nginx Stream：$node_id"; return 1; }
  nginx_stream_supported_node "$node" || { log_error "协议不支持 Nginx Stream SNI 复用：$(jq -r '.protocol' <<<"$node")"; return 1; }
  validate_domain "$sni" || { log_error "SNI 必须是完整域名：$sni"; return 1; }
  expected_sni=$(nginx_stream_node_sni "$node")
  [[ "${sni,,}" == "${expected_sni,,}" ]] || { log_error "SNI 必须与节点协议的 server_name 一致：$expected_sni"; return 1; }
  sni=${sni,,}
  route=$(jq -c --arg id "$node_id" '.nginx_stream.routes[]? | select(.node_id==$id)' "$SBM_STATE")
  [[ -z "$route" ]] || { log_error "节点已经存在 Nginx Stream 路由：$node_id"; return 1; }
  if jq -e --arg sni "$sni" '.nginx_stream.routes[]? | select(.sni==$sni)' "$SBM_STATE" >/dev/null; then
    log_error "SNI 已经被使用：$sni"; return 1
  fi
  if [[ -z "$backend_port" ]]; then backend_port=$(nginx_stream_choose_backend_port "$SBM_STATE") || { log_error '无法分配 Nginx Stream 后端端口。'; return 1; }; fi
  validate_port "$backend_port" || { log_error "后端端口无效：$backend_port"; return 1; }
  host_port_in_use tcp "$backend_port" && { log_error "后端端口已被系统占用：$backend_port/TCP"; return 1; }
  nginx_stream_backend_port_used "$SBM_STATE" "$backend_port" && { log_error "后端端口已被其他路由使用：$backend_port"; return 1; }
  candidate=$(state_candidate)
  jq --arg id "$node_id" --arg sni "$sni" --argjson p "$backend_port" '.nginx_stream.routes += [{node_id:$id,sni:$sni,backend_port:$p}]' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "nginx-route-add-$node_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已添加 Nginx Stream 路由：$node_id → $sni（后端 $backend_port）"
}

nginx_stream_route_add() { with_state_transaction nginx-route-add _nginx_stream_route_add "$@"; }

_nginx_stream_route_remove() {
  local node_id=$1 candidate
  jq -e --arg id "$node_id" '.nginx_stream.routes[]? | select(.node_id==$id)' "$SBM_STATE" >/dev/null || { log_error "Nginx Stream 路由不存在：$node_id"; return 1; }
  if nginx_stream_state_enabled "$SBM_STATE" && [[ $(jq '.nginx_stream.routes|length' "$SBM_STATE") == 1 ]]; then
    log_error '不能删除启用中的最后一条路由；请先执行 sb mux disable。'; return 1
  fi
  candidate=$(state_candidate)
  jq --arg id "$node_id" '.nginx_stream.routes |= map(select(.node_id!=$id))' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "nginx-route-remove-$node_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已删除 Nginx Stream 路由：$node_id"
}

nginx_stream_route_remove() { with_state_transaction nginx-route-remove _nginx_stream_route_remove "$@"; }

_nginx_stream_enable() {
  local public_port=${1:-} candidate
  if [[ $(jq '.nginx_stream.routes|length' "$SBM_STATE") == 0 ]]; then
    log_error '请先添加至少一条 SNI 路由：sb mux route add NODE_ID SNI。'; return 1
  fi
  candidate=$(state_candidate)
  if [[ -n "$public_port" ]]; then
    validate_port "$public_port" || { rm -f "$candidate"; log_error "公网端口无效：$public_port"; return 1; }
    jq --argjson port "$public_port" '.nginx_stream.enabled=true | .nginx_stream.port=$port' "$SBM_STATE" >"$candidate"
  else
    jq '.nginx_stream.enabled=true' "$SBM_STATE" >"$candidate"
  fi
  if ! apply_candidate_state "$candidate" nginx-enable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "Nginx Stream 复用已启用（公网端口 $(jq -r '.nginx_stream.port' "$SBM_STATE")/TCP）。"
}

nginx_stream_enable() { with_state_transaction nginx-enable _nginx_stream_enable "$@"; }

_nginx_stream_disable() {
  local candidate
  candidate=$(state_candidate)
  jq '.nginx_stream.enabled=false' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" nginx-disable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok 'Nginx Stream 复用已停用；路由配置已保留。'
}

nginx_stream_disable() { with_state_transaction nginx-disable _nginx_stream_disable; }

nginx_stream_route_list() {
  jq '.nginx_stream.routes' "$SBM_STATE"
}

nginx_stream_status() {
  local enabled port routes backend
  enabled=$(jq -r '.nginx_stream.enabled // false' "$SBM_STATE")
  port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
  routes=$(jq '.nginx_stream.routes|length' "$SBM_STATE")
  backend=$(init_system 2>/dev/null || true)
  printf 'Nginx Stream 复用：%s，公网端口：%s/TCP，路由：%s 条\n' "$([[ "$enabled" == true ]] && echo '启用' || echo '停用')" "$port" "$routes"
  if [[ "$enabled" == true && "$SBM_SKIP_INIT" != 1 && "$backend" == systemd ]] && service_exists "$SBM_NGINX_STREAM_SERVICE"; then
    service_status_text "$SBM_NGINX_STREAM_SERVICE" || true
  fi
}

nginx_stream_doctor_check() {
  local enabled port routes
  enabled=$(jq -r '.nginx_stream.enabled // false' "$SBM_STATE")
  [[ "$enabled" == true ]] || return 0
  port=$(jq -r '.nginx_stream.port' "$SBM_STATE"); routes=$(jq '.nginx_stream.routes|length' "$SBM_STATE")
  if [[ "$(init_system 2>/dev/null || true)" != systemd ]]; then
    check_line FAIL 'Nginx Stream 复用已启用，但当前不是 systemd 后端'; failures=$((failures + 1)); return 0
  fi
  if ! nginx_stream_runtime_ready; then
    check_line FAIL 'Nginx Stream 复用已启用，但 nginx/ngx_stream_module 缺失'; failures=$((failures + 1)); return 0
  fi
  if ! service_exists "$SBM_NGINX_STREAM_SERVICE"; then
    check_line FAIL 'Nginx Stream 服务定义缺失'; failures=$((failures + 1)); return 0
  fi
  if service_active "$SBM_NGINX_STREAM_SERVICE"; then check_line PASS "Nginx Stream 正在运行（${routes} 条路由）"; else check_line FAIL 'Nginx Stream 服务未运行'; failures=$((failures + 1)); fi
  if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$|\]:${port}$"; then check_line PASS "Nginx Stream 端口可见：${port}/TCP"; else check_line FAIL "Nginx Stream 未监听 ${port}/TCP"; failures=$((failures + 1)); fi
}
