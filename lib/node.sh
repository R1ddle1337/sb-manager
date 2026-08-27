#!/usr/bin/env bash
# shellcheck shell=bash

node_protocol_label() {
  case "$1" in
    vmess-ws-cf) printf 'VMess-WS-CF' ;;
    shadowsocks) printf 'Shadowsocks 2022' ;;
    anytls) printf 'AnyTLS' ;;
    hysteria2) printf 'Hysteria2' ;;
    *) printf '%s' "$1" ;;
  esac
}

node_port_in_state() {
  local kind=$1 port=$2 state=${3:-$SBM_STATE} node k
  while IFS= read -r node; do
    while IFS= read -r k; do [[ "$k" == "$kind" && $(jq -r '.port' <<<"$node") == "$port" ]] && return 0; done < <(node_transport_kinds "$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$state")
  return 1
}

node_choose_port() {
  local kind=$1 i port
  for ((i=0; i<200; i++)); do
    port=$((20000 + RANDOM % 35000))
    if ! node_port_in_state "$kind" "$port"; then printf '%s\n' "$port"; return 0; fi
  done
  die "无法自动选择空闲端口。"
}

host_port_in_use() {
  local kind=$1 port=$2
  command_exists ss || return 1
  if [[ "$kind" == tcp ]]; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|\]|:)$port$|:$port$"
  else
    ss -H -lun 2>/dev/null | awk '{print $5 " " $4}' | grep -Eq "(^|\]|:)$port$|:$port$"
  fi
}

node_list() {
  local json=${1:-0}
  if [[ "$json" == "1" ]]; then jq '.nodes' "$SBM_STATE"; return; fi
  printf '%-18s %-18s %-8s %-10s %-24s %s\n' 'ID' '协议' '状态' '端口' '域名/地址' '名称'
  printf '%-18s %-18s %-8s %-10s %-24s %s\n' '------------------' '------------------' '--------' '----------' '------------------------' '----'
  local node id p enabled port endpoint name
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node"); p=$(jq -r '.protocol' <<<"$node"); enabled=$(jq -r 'if .enabled then "启用" else "停用" end' <<<"$node")
    port=$(jq -r '.port' <<<"$node"); endpoint=$(jq -r '(.domain // .server_address // "-")' <<<"$node"); name=$(jq -r '.name' <<<"$node")
    printf '%-18s %-18s %-8s %-10s %-24s %s\n' "$id" "$(node_protocol_label "$p")" "$enabled" "$port" "$endpoint" "$name"
  done < <(state_list_nodes)
}

node_show() {
  local id=$1 node secret
  node=$(state_get_node "$id")
  [[ -n "$node" ]] || die "节点不存在：$id"
  secret=$(state_get_secret "$id")
  printf '%s\n' "$node" | jq .
  printf '凭据：'
  case $(jq -r '.protocol' <<<"$node") in
    vmess-ws-cf) printf 'UUID %s\n' "$(mask_secret "$(jq -r '.uuid' <<<"$secret")")" ;;
    *) printf '密码 %s\n' "$(mask_secret "$(jq -r '.password' <<<"$secret")")" ;;
  esac
}

_node_add() {
  local type=$1; shift
  local id='' name='' port='' domain='' address='' path='' method='2022-blake3-aes-128-gcm' network='tcp' mux=true enabled=true obfs='' masquerade=''
  while (($#)); do
    case "$1" in
      --id) id=${2:?}; shift 2;; --name) name=${2:?}; shift 2;; --port) port=${2:?}; shift 2;;
      --domain) domain=${2:?}; shift 2;; --address) address=${2:?}; shift 2;; --path) path=${2:?}; shift 2;;
      --method) method=${2:?}; shift 2;; --network) network=${2:?}; shift 2;; --no-mux) mux=false; shift;;
      --obfs) obfs=${2:?}; shift 2;; --masquerade) masquerade=${2:?}; shift 2;; --disabled) enabled=false; shift;;
      *) die "未知参数：$1";;
    esac
  done
  local protocol base transport secret node candidate secret_path default_address
  default_address=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
  case "$type" in
    vmess|vmess-ws-cf)
      protocol=vmess-ws-cf; base=vmess-cf; transport=tcp
      [[ -n "$port" ]] || port=$(node_choose_port tcp)
      [[ -n "$path" ]] || path="/$(random_hex 16)-vm"
      path=$(normalize_ws_path "$path")
      [[ -n "$name" ]] || name='VMess WS Cloudflare'
      [[ -n "$address" ]] || address=$domain
      secret=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}')
      ;;
    ss|shadowsocks)
      protocol=shadowsocks; base=ss; transport=tcp
      [[ -n "$port" ]] || port=8388
      [[ -n "$name" ]] || name='Shadowsocks 2022'
      [[ -n "$address" ]] || address=$default_address
      case "$method" in 2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;; *) die "仅支持 Shadowsocks 2022 方法。";; esac
      [[ "$network" == tcp ]] || die "首个版本仅启用推荐的 Shadowsocks TCP + multiplex 模式。"
      secret=$(jq -n --arg password "$(ss2022_key "$method")" '{password:$password}')
      ;;
    anytls)
      protocol=anytls; base=anytls; transport=tcp
      [[ -n "$port" ]] || port=443
      [[ -n "$domain" ]] || die "AnyTLS 必须指定 --domain。"
      validate_domain "$domain" || die "无效域名：$domain"
      [[ -n "$name" ]] || name='AnyTLS'
      [[ -n "$address" ]] || address=${default_address:-$domain}
      secret=$(jq -n --arg password "$(random_password 24)" '{password:$password}')
      ;;
    hy2|hysteria2)
      protocol=hysteria2; base=hy2; transport=udp
      [[ -n "$port" ]] || port=443
      [[ -n "$domain" ]] || die "Hysteria2 必须指定 --domain。"
      validate_domain "$domain" || die "无效域名：$domain"
      [[ -n "$name" ]] || name='Hysteria2'
      [[ -n "$address" ]] || address=${default_address:-$domain}
      if [[ -n "$obfs" && "$obfs" != salamander ]]; then die "当前只支持 salamander 混淆。"; fi
      secret=$(jq -n --arg password "$(random_password 24)" --arg obfs_password "$([[ -n "$obfs" ]] && random_password 18 || true)" '{password:$password,obfs_password:$obfs_password}')
      ;;
    *) die "不支持的协议：$type";;
  esac
  validate_port "$port" || die "无效端口：$port"
  [[ -n "$id" ]] || id=$(state_unique_id "$base")
  validate_node_id "$id" || die "节点 ID 只能包含小写字母、数字、点、下划线和连字符。"
  state_node_exists "$id" && die "节点已存在：$id"
  if [[ "$enabled" == true ]] && host_port_in_use "$transport" "$port"; then
    die "系统已有程序监听 ${port}/${transport^^}；请换端口或先停用冲突服务。"
  fi

  case "$protocol" in
    vmess-ws-cf)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg path "$path" --arg domain "$domain" --arg address "$address" --arg now "$(now_iso)" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"vmess-ws-cf",enabled:$enabled,listen:"127.0.0.1",port:$port,ws_path:$path,domain:$domain,client_address:$address,created_at:$now}')
      ;;
    shadowsocks)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg network "$network" --arg method "$method" --arg address "$address" --arg now "$(now_iso)" --argjson mux "$mux" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"shadowsocks",enabled:$enabled,listen:"::",port:$port,network:$network,method:$method,multiplex:$mux,server_address:$address,created_at:$now}')
      ;;
    anytls)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg now "$(now_iso)" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"anytls",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,created_at:$now}')
      ;;
    hysteria2)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg obfs "$obfs" --arg masquerade "$masquerade" --arg now "$(now_iso)" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"hysteria2",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,obfs:(if $obfs=="" then {} else {type:$obfs} end),masquerade:$masquerade,created_at:$now}')
      ;;
  esac
  secret_path=$(state_secret_path "$id")
  state_write_secret "$id" "$secret"
  candidate=$(state_candidate)
  jq --argjson node "$node" '.nodes += [$node]' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "add-$id"; then rm -f "$candidate" "$secret_path"; return 1; fi
  rm -f "$candidate"
  log_ok "已添加节点：$id ($(node_protocol_label "$protocol"))"
  [[ "$enabled" == true ]] || log_warn "节点当前为停用状态。"
}
node_add() { with_lock _node_add "$@"; }

_node_set_enabled() {
  local id=$1 value=$2 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" --argjson value "$value" '(.nodes[] | select(.id==$id) | .enabled)=$value' "$SBM_STATE" >"$candidate"
  apply_candidate_state "$candidate" "${value}-$(printf '%s' "$id")"
  rm -f "$candidate"
}
node_enable() { with_lock _node_set_enabled "$1" true; }
node_disable() { with_lock _node_set_enabled "$1" false; }

_node_delete() {
  local id=$1 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" '.nodes |= map(select(.id!=$id)) | if .tunnel.node_id==$id then .tunnel={mode:"none",node_id:null,domain:null,client_address:null,protocol:"http2"} else . end' "$SBM_STATE" >"$candidate"
  apply_candidate_state "$candidate" "delete-$id"
  rm -f "$candidate" "$(state_secret_path "$id")"
  log_ok "已删除节点：$id"
}
node_delete() { with_lock _node_delete "$1"; }

_node_rotate() {
  local id=$1 node protocol path old new candidate backup
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  protocol=$(jq -r '.protocol' <<<"$node"); path=$(state_secret_path "$id"); backup=$(mktemp "$SBM_RUN/secret.backup.XXXXXX"); cp -a "$path" "$backup"
  case "$protocol" in
    vmess-ws-cf) new=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}') ;;
    shadowsocks) new=$(jq -n --arg password "$(ss2022_key "$(jq -r '.method' <<<"$node")")" '{password:$password}') ;;
    anytls) new=$(jq -n --arg password "$(random_password 24)" '{password:$password}') ;;
    hysteria2)
      new=$(jq -n --arg password "$(random_password 24)" --arg op "$([[ $(jq -r '.obfs.type // ""' <<<"$node") == salamander ]] && random_password 18 || true)" '{password:$password,obfs_password:$op}') ;;
  esac
  state_write_secret "$id" "$new"
  candidate=$(state_candidate); cp "$SBM_STATE" "$candidate"
  if ! apply_candidate_state "$candidate" "rotate-$id"; then cp -a "$backup" "$path"; rm -f "$candidate" "$backup"; return 1; fi
  rm -f "$candidate" "$backup"
  log_ok "已轮换节点凭据：$id。旧分享链接立即失效。"
}
node_rotate() { with_lock _node_rotate "$1"; }

_node_set() {
  local id=$1; shift
  local candidate tmp key value node protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  candidate=$(state_candidate); cp "$SBM_STATE" "$candidate"
  while (($#)); do
    key=$1; value=${2-}; shift 2
    case "$key" in
      --name) tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)|.name)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --port) validate_port "$value" || die "无效端口：$value"; tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --argjson v "$value" '(.nodes[]|select(.id==$id)|.port)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --address) validate_address "$value" || die "无效地址"; tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)) |= if .protocol=="vmess-ws-cf" then .client_address=$v else .server_address=$v end' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --domain) validate_domain "$value" || die "无效域名：$value"; tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)|.domain)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --path) value=$(normalize_ws_path "$value"); tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)|.ws_path)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      *) rm -f "$candidate"; die "不支持的修改参数：$key";;
    esac
  done
  protocol=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.protocol' "$candidate")
  [[ "$protocol" == vmess-ws-cf || -n $(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.server_address // ""' "$candidate") ]] || log_warn "节点尚未设置客户端服务器地址。"
  apply_candidate_state "$candidate" "edit-$id"
  rm -f "$candidate"
}
node_set() { local id=$1; shift; with_lock _node_set "$id" "$@"; }

settings_set_default_address() {
  local address=$1 candidate
  validate_address "$address" || die "无效地址：$address"
  candidate=$(state_candidate)
  jq --arg a "$address" '.settings.default_server_address=$a' "$SBM_STATE" >"$candidate"
  with_lock apply_candidate_state "$candidate" settings-address
  rm -f "$candidate"
}
