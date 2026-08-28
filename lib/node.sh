#!/usr/bin/env bash
# shellcheck shell=bash

node_protocol_label() {
  case "$1" in
    vmess-ws-cf) printf 'VMess-WS-CF' ;;
    shadowsocks) printf 'Shadowsocks 2022' ;;
    anytls) printf 'AnyTLS' ;;
    hysteria2) printf 'Hysteria2' ;;
    trojan) printf 'Trojan TLS' ;;
    tuic) printf 'TUIC' ;;
    vless) printf 'VLESS' ;;
    naive) printf 'NaiveProxy' ;;
    shadowtls) printf 'ShadowTLS v3' ;;
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
    if ! node_port_in_state "$kind" "$port" && ! host_port_in_use "$kind" "$port"; then printf '%s\n' "$port"; return 0; fi
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

singbox_port_in_use() {
  local kind=$1 port=$2 flags
  command_exists ss || return 1
  [[ "$kind" == tcp ]] && flags=-ltnp || flags=-lunp
  ss -H "$flags" 2>/dev/null | awk -v p="$port" '
    $0 ~ /sing-box/ {
      address = ($1 == "udp" || $1 == "tcp") ? $5 : $4
      if (address ~ (":" p "$")) found=1
    }
    END {exit !found}
  '
}

node_list() {
  local json=${1:-0}
  if [[ "$json" == "1" ]]; then jq '.nodes' "$SBM_STATE"; return; fi
  printf '%-18s %-18s %-8s %-10s %-24s %s\n' 'ID' '协议' '状态' '端口' '域名/地址' '名称'
  printf '%-18s %-18s %-8s %-10s %-24s %s\n' '------------------' '------------------' '--------' '----------' '------------------------' '----'
  local node id p enabled port endpoint name route public_port
  public_port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node"); p=$(jq -r '.protocol' <<<"$node"); enabled=$(jq -r 'if .enabled then "启用" else "停用" end' <<<"$node")
    port=$(jq -r '.port' <<<"$node"); endpoint=$(jq -r '(.domain // .server_address // "-")' <<<"$node"); name=$(jq -r '.name' <<<"$node")
    if declare -F nginx_stream_route_for_node >/dev/null 2>&1 && nginx_stream_state_enabled "$SBM_STATE"; then
      route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
      [[ -z "$route" ]] || port="${public_port}→$(jq -r '.backend_port' <<<"$route")"
    fi
    printf '%-18s %-18s %-8s %-10s %-24s %s\n' "$id" "$(node_protocol_label "$p")" "$enabled" "$port" "$endpoint" "$name"
  done < <(state_list_nodes)
}

node_show() {
  local id=$1 node
  node=$(state_get_node "$id")
  [[ -n "$node" ]] || die "节点不存在：$id"
  printf '%s\n' "$node" | jq .
  if declare -F nginx_stream_route_for_node >/dev/null 2>&1; then
    local route
    route=$(nginx_stream_route_for_node "$SBM_STATE" "$id")
    [[ -z "$route" ]] || printf 'Nginx Stream：%s\n' "$(jq -c . <<<"$route")"
  fi
  printf '用户：%s 个，启用 %s 个\n' "$(jq '.users|length' <<<"$node")" "$(jq '[.users[]|select(.enabled)]|length' <<<"$node")"
}

_node_add() {
  local type=$1; shift
  local id='' name='' port='' domain='' address='' address_supplied=0 address_source=auto path='' method='2022-blake3-aes-128-gcm' network='tcp' mux=true enabled=true obfs='' masquerade='' security='tls' flow='' handshake_server='' handshake_port=443 congestion_control='cubic' strict_mode=true wildcard_sni='off'
  while (($#)); do
    case "$1" in
      --id) id=${2:?}; shift 2;; --name) name=${2:?}; shift 2;; --port) port=${2:?}; shift 2;;
      --domain) domain=${2:?}; shift 2;; --address) address=${2:?}; address_supplied=1; address_source=manual; shift 2;; --path) path=${2:?}; shift 2;;
      --method) method=${2:?}; shift 2;; --network) network=${2:?}; shift 2;; --no-mux) mux=false; shift;;
      --obfs) obfs=${2:?}; shift 2;; --masquerade) masquerade=${2:?}; shift 2;; --disabled) enabled=false; shift;;
      --security) security=${2:?}; shift 2;; --flow) flow=${2:?}; shift 2;;
      --handshake-server) handshake_server=${2:?}; shift 2;; --handshake-port) handshake_port=${2:?}; shift 2;;
      --congestion-control) congestion_control=${2:?}; shift 2;;
      --strict-mode) strict_mode=${2:?}; shift 2;; --wildcard-sni) wildcard_sni=${2:?}; shift 2;; --quic) network=udp; shift;;
      *) die "未知参数：$1";;
    esac
  done
  local protocol base transport secret node_secret='' node candidate user_secret_path default_address created_at reality_secret=''
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
    trojan)
      protocol=trojan; base=trojan; transport=tcp; port=${port:-443}; domain=${domain:?Trojan 必须指定 --domain。}; validate_domain "$domain" || die "无效域名：$domain"; name=${name:-Trojan}; address=${address:-${default_address:-$domain}}; secret=$(jq -n --arg password "$(random_password 24)" '{password:$password}')
      ;;
    tuic)
      protocol=tuic; base=tuic; transport=udp; port=${port:-443}; domain=${domain:?TUIC 必须指定 --domain。}; validate_domain "$domain" || die "无效域名：$domain"; name=${name:-TUIC}; address=${address:-${default_address:-$domain}}; case "$congestion_control" in cubic|new_reno|bbr) ;; *) die 'TUIC 拥塞控制必须是 cubic、new_reno 或 bbr。';; esac; secret=$(jq -n --arg uuid "$(random_uuid)" --arg password "$(random_password 24)" '{uuid:$uuid,password:$password}')
      ;;
    vless)
      protocol=vless; base=vless; transport=tcp; port=${port:-443}; domain=${domain:?VLESS 必须指定 --domain。}; name=${name:-VLESS}; address=${address:-${default_address:-$domain}}; flow=${flow:-xtls-rprx-vision}; [[ "$security" == tls || "$security" == reality ]] || die 'VLESS security 必须是 tls 或 reality。'; [[ "$security" != reality || -n "$handshake_server" ]] || die 'VLESS Reality 必须指定 --handshake-server。'; validate_domain "$domain" || die "无效域名：$domain"; validate_port "$handshake_port" || die "无效 Reality 握手端口：$handshake_port"; secret=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}'); [[ "$security" != reality ]] || reality_secret=$(protocol_vless_generate_reality_secret)
      ;;
    naive)
      protocol=naive; base=naive; [[ "$network" == tcp || "$network" == udp ]] || die 'Naive network 必须是 tcp 或 udp。'; transport=$network; port=${port:-443}; domain=${domain:?Naive 必须指定 --domain。}; validate_domain "$domain" || die "无效域名：$domain"; name=${name:-Naive}; address=${address:-${default_address:-$domain}}; secret=$(jq -n --arg username default --arg password "$(random_password 24)" '{username:$username,password:$password}')
      ;;
    shadowtls)
      protocol=shadowtls; base=shadowtls; transport=tcp; port=${port:-443}; handshake_server=${handshake_server:?ShadowTLS 必须指定 --handshake-server。}; validate_domain "$handshake_server" || die "无效握手域名：$handshake_server"; validate_port "$handshake_port" || die "无效握手端口：$handshake_port"; case "$strict_mode" in true|false) ;; *) die 'strict-mode 必须是 true 或 false。';; esac; case "$wildcard_sni" in off|authed|all) ;; *) die 'wildcard-sni 必须是 off、authed 或 all。';; esac; name=${name:-ShadowTLS}; address=${address:-${default_address:-$handshake_server}}; domain=$handshake_server; secret=$(jq -n --arg password "$(random_password 24)" '{password:$password}')
      ;;
    *) die "不支持的协议：$type";;
  esac
  if [[ "$protocol" != vmess-ws-cf && "$address_supplied" == 0 ]]; then
    address=$(settings_default_address)
    address_source=auto
  fi
  if [[ "$protocol" == hysteria2 ]]; then
    node_secret=$(jq -n --arg obfs_password "$(jq -r '.obfs_password // ""' <<<"$secret")" '{obfs_password:$obfs_password}')
    secret=$(jq '{password}' <<<"$secret")
  fi
  if [[ "$protocol" == vless && "$security" == reality ]]; then
    node_secret=$(jq -n --arg hs "$handshake_server" --argjson hp "$handshake_port" --argjson reality "$reality_secret" '$reality + {handshake_server:$hs,handshake_port:$hp}')
  fi
  validate_port "$port" || die "无效端口：$port"
  [[ -n "$id" ]] || id=$(state_unique_id "$base")
  validate_node_id "$id" || die "节点 ID 只能包含小写字母、数字、点、下划线和连字符。"
  state_node_exists "$id" && die "节点已存在：$id"
  if [[ "$enabled" == true ]] && host_port_in_use "$transport" "$port"; then
    die "系统已有程序监听 ${port}/${transport^^}；请换端口或先停用冲突服务。"
  fi
  created_at=$(now_iso)

  case "$protocol" in
    vmess-ws-cf)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg path "$path" --arg domain "$domain" --arg address "$address" --arg now "$created_at" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"vmess-ws-cf",enabled:$enabled,listen:"127.0.0.1",port:$port,ws_path:$path,domain:$domain,client_address:$address,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    shadowsocks)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg network "$network" --arg method "$method" --arg address "$address" --arg address_source "$address_source" --arg now "$created_at" --argjson mux "$mux" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"shadowsocks",enabled:$enabled,listen:"::",port:$port,network:$network,method:$method,multiplex:$mux,server_address:$address,server_address_source:$address_source,credential_mode:"legacy",created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    anytls)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg now "$created_at" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"anytls",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    hysteria2)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg obfs "$obfs" --arg masquerade "$masquerade" --arg now "$created_at" --argjson enabled "$enabled" \
        '{id:$id,name:$name,protocol:"hysteria2",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,obfs:(if $obfs=="" then {} else {type:$obfs} end),masquerade:$masquerade,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    trojan)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg now "$created_at" --argjson enabled "$enabled" '{id:$id,name:$name,protocol:"trojan",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    tuic)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg cc "$congestion_control" --arg now "$created_at" --argjson enabled "$enabled" '{id:$id,name:$name,protocol:"tuic",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,congestion_control:$cc,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    vless)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg security "$security" --arg flow "$flow" --arg hs "$handshake_server" --argjson hp "$handshake_port" --arg now "$created_at" --argjson enabled "$enabled" '{id:$id,name:$name,protocol:"vless",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,security:$security,flow:(if $flow=="" then null else $flow end),handshake_server:(if $hs=="" then null else $hs end),handshake_port:$hp,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    naive)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg domain "$domain" --arg address "$address" --arg network "$network" --arg cc "$congestion_control" --arg now "$created_at" --argjson enabled "$enabled" '{id:$id,name:$name,protocol:"naive",enabled:$enabled,listen:"::",port:$port,domain:$domain,server_address:$address,network:$network,quic_congestion_control:$cc,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
    shadowtls)
      node=$(jq -n --arg id "$id" --arg name "$name" --argjson port "$port" --arg address "$address" --arg hs "$handshake_server" --argjson hp "$handshake_port" --argjson strict "$strict_mode" --arg wildcard "$wildcard_sni" --arg now "$created_at" --argjson enabled "$enabled" '{id:$id,name:$name,protocol:"shadowtls",enabled:$enabled,listen:"::",port:$port,server_address:$address,handshake_server:$hs,handshake_port:$hp,strict_mode:$strict,wildcard_sni:$wildcard,created_at:$now,users:[{id:"default",name:$name,enabled:true,created_at:$now}]}')
      ;;
  esac
  if [[ "$protocol" != vmess-ws-cf ]]; then
    node=$(jq --arg source "$address_source" '.server_address_source=$source' <<<"$node")
  fi
  user_secret_path=$(state_user_secret_path "$id" default)
  state_write_user_secret "$id" default "$secret"
  [[ -z "$node_secret" ]] || state_write_secret "$id" "$node_secret"
  candidate=$(state_candidate)
  jq --argjson node "$node" '.nodes += [$node]' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "add-$id"; then rm -f "$candidate" "$user_secret_path"; return 1; fi
  rm -f "$candidate"
  log_ok "已添加节点：$id ($(node_protocol_label "$protocol"))"
  [[ "$enabled" == true ]] || log_warn "节点当前为停用状态。"
}
node_add() { with_state_transaction node-add _node_add "$@"; }

_node_set_enabled() {
  local id=$1 value=$2 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" --argjson value "$value" '(.nodes[] | select(.id==$id) | .enabled)=$value' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "${value}-$(printf '%s' "$id")"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}
node_enable() { with_state_transaction node-enable _node_set_enabled "$1" true; }
node_disable() { with_state_transaction node-disable _node_set_enabled "$1" false; }

_node_delete() {
  local id=$1 candidate
  state_node_exists "$id" || die "节点不存在：$id"
  candidate=$(state_candidate)
  jq --arg id "$id" '.nodes |= map(select(.id!=$id))
    | .nginx_stream.routes |= map(select(.node_id!=$id))
    | if .nginx_stream.enabled == true and (.nginx_stream.routes|length)==0 then .nginx_stream.enabled=false else . end
    | if .tunnel.node_id==$id then .tunnel={mode:"none",node_id:null,domain:null,client_address:null,protocol:"http2"} else . end' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "delete-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate" "$(state_secret_path "$id")"
  rm -rf -- "$(state_user_secret_dir "$id")"
  log_ok "已删除节点：$id"
}
node_delete() { with_state_transaction node-delete _node_delete "$1"; }

_node_rotate() {
  local id=$1 user_id=${2:-default} node protocol path old new candidate backup
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  state_user_exists "$id" "$user_id" || die "用户不存在：$id/$user_id"
  protocol=$(jq -r '.protocol' <<<"$node"); path=$(state_user_secret_path "$id" "$user_id"); backup=$(mktemp "$SBM_RUN/secret.backup.XXXXXX"); cp -a "$path" "$backup"
  case "$protocol" in
    vmess-ws-cf) new=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}') ;;
    shadowsocks) new=$(jq -n --arg password "$(ss2022_key "$(jq -r '.method' <<<"$node")")" '{password:$password}') ;;
    anytls) new=$(jq -n --arg password "$(random_password 24)" '{password:$password}') ;;
    hysteria2)
      new=$(jq -n --arg password "$(random_password 24)" '{password:$password}') ;;
    trojan) new=$(jq -n --arg password "$(random_password 24)" '{password:$password}') ;;
    tuic) new=$(jq -n --arg uuid "$(random_uuid)" --arg password "$(random_password 24)" '{uuid:$uuid,password:$password}') ;;
    vless) new=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}') ;;
    naive) new=$(jq -n --arg username "$user_id" --arg password "$(random_password 24)" '{username:$username,password:$password}') ;;
    shadowtls) new=$(jq -n --arg password "$(random_password 24)" '{password:$password}') ;;
  esac
  state_write_user_secret "$id" "$user_id" "$new"
  candidate=$(state_candidate); cp "$SBM_STATE" "$candidate"
  if ! apply_candidate_state "$candidate" "rotate-$id"; then cp -a "$backup" "$path"; rm -f "$candidate" "$backup"; return 1; fi
  rm -f "$candidate" "$backup"
  log_ok "已轮换用户凭据：$id/$user_id。旧分享链接立即失效。"
}
node_rotate() { with_state_transaction node-rotate _node_rotate "$@"; }

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
      --address) validate_address "$value" || die "无效地址"; tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)) |= if .protocol=="vmess-ws-cf" then .client_address=$v else .server_address=$v | .server_address_source="manual" end' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --domain) validate_domain "$value" || die "无效域名：$value"; tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)|.domain)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      --path) value=$(normalize_ws_path "$value"); tmp=$(mktemp "$SBM_RUN/edit.XXXXXX"); jq --arg id "$id" --arg v "$value" '(.nodes[]|select(.id==$id)|.ws_path)=$v' "$candidate" >"$tmp"; mv "$tmp" "$candidate";;
      *) rm -f "$candidate"; die "不支持的修改参数：$key";;
    esac
  done
  protocol=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.protocol' "$candidate")
  [[ "$protocol" == vmess-ws-cf || -n $(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.server_address // ""' "$candidate") ]] || log_warn "节点尚未设置客户端服务器地址。"
  if ! apply_candidate_state "$candidate" "edit-$id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}
node_set() { local id=$1; shift; with_state_transaction node-edit _node_set "$id" "$@"; }

node_user_generate_secret() {
  local node=$1 user_id=${2:-default} protocol
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}' ;;
    shadowsocks) jq -n --arg password "$(ss2022_key "$(jq -r '.method' <<<"$node")")" '{password:$password}' ;;
    anytls|hysteria2|trojan) jq -n --arg password "$(random_password 24)" '{password:$password}' ;;
    tuic) jq -n --arg uuid "$(random_uuid)" --arg password "$(random_password 24)" '{uuid:$uuid,password:$password}' ;;
    vless) jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}' ;;
    naive) jq -n --arg username "$user_id" --arg password "$(random_password 24)" '{username:$username,password:$password}' ;;
    shadowtls) jq -n --arg password "$(random_password 24)" '{password:$password}' ;;
    *) die "协议暂不支持多用户：$protocol" ;;
  esac
}

node_user_list() {
  local node_id=$1 json=${2:-0} node
  node=$(state_get_node "$node_id"); [[ -n "$node" ]] || die "节点不存在：$node_id"
  if [[ "$json" == 1 ]]; then jq '.users' <<<"$node"; return; fi
  printf '%-18s %-8s %s\n' 'USER_ID' '状态' '名称'
  jq -r '.users[] | [.id,(if .enabled then "启用" else "停用" end),.name] | @tsv' <<<"$node" |
    while IFS=$'\t' read -r id enabled name; do printf '%-18s %-8s %s\n' "$id" "$enabled" "$name"; done
}

_node_user_add() {
  local node_id=$1 user_id=$2 name=${3:-$2} node protocol secret candidate node_secret
  validate_node_id "$user_id" || die "用户 ID 只能包含小写字母、数字、点、下划线和连字符。"
  node=$(state_get_node "$node_id"); [[ -n "$node" ]] || die "节点不存在：$node_id"
  state_user_exists "$node_id" "$user_id" && die "用户已存在：$node_id/$user_id"
  secret=$(node_user_generate_secret "$node" "$user_id")
  state_write_user_secret "$node_id" "$user_id" "$secret"
  candidate=$(state_candidate)
  jq --arg nid "$node_id" --arg uid "$user_id" --arg name "$name" --arg now "$(now_iso)" '
    (.nodes[] | select(.id==$nid) | .users) += [{id:$uid,name:$name,enabled:true,created_at:$now}]
  ' "$SBM_STATE" >"$candidate"
  protocol=$(jq -r '.protocol' <<<"$node")
  if [[ "$protocol" == shadowsocks && $(jq -r '.credential_mode // "legacy"' <<<"$node") == legacy ]]; then
    node_secret=$(jq -n --arg server_password "$(ss2022_key "$(jq -r '.method' <<<"$node")")" '{server_password:$server_password}')
    state_write_secret "$node_id" "$node_secret"
    jq --arg nid "$node_id" '(.nodes[] | select(.id==$nid) | .credential_mode)="multi"' "$candidate" >"$candidate.tmp"
    mv "$candidate.tmp" "$candidate"
    log_warn "Shadowsocks 节点已切换到 2022 多用户模式；原单用户分享链接需要重新导出。"
  fi
  if ! apply_candidate_state "$candidate" "user-add-$node_id-$user_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已添加用户：$node_id/$user_id"
}
node_user_add() { with_state_transaction user-add _node_user_add "$@"; }

_node_user_set_enabled() {
  local node_id=$1 user_id=$2 value=$3 candidate
  state_user_exists "$node_id" "$user_id" || die "用户不存在：$node_id/$user_id"
  candidate=$(state_candidate)
  jq --arg nid "$node_id" --arg uid "$user_id" --argjson value "$value" '
    (.nodes[] | select(.id==$nid) | .users[] | select(.id==$uid) | .enabled)=$value
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "user-$value-$node_id-$user_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}
node_user_enable() { with_state_transaction user-enable _node_user_set_enabled "$1" "$2" true; }
node_user_disable() { with_state_transaction user-disable _node_user_set_enabled "$1" "$2" false; }

_node_user_delete() {
  local node_id=$1 user_id=$2 candidate
  state_user_exists "$node_id" "$user_id" || die "用户不存在：$node_id/$user_id"
  candidate=$(state_candidate)
  jq --arg nid "$node_id" --arg uid "$user_id" '
    (.nodes[] | select(.id==$nid) | .users) |= map(select(.id!=$uid))
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "user-delete-$node_id-$user_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate" "$(state_user_secret_path "$node_id" "$user_id")"
  log_ok "已删除用户：$node_id/$user_id"
}
node_user_delete() { with_state_transaction user-delete _node_user_delete "$@"; }

_settings_set_default_address() {
  local address=$1 candidate
  if [[ "$address" == auto ]]; then _settings_detect_public_ip; return; fi
  validate_address "$address" || die "无效地址：$address"
  candidate=$(state_candidate)
  jq --arg a "$address" '.settings.default_server_address=$a | .settings.default_server_address_source="manual"' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" settings-address; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}
settings_set_default_address() { with_state_transaction settings-address _settings_set_default_address "$@"; }

_settings_set_log_level() {
  local level=$1 candidate
  case "$level" in trace|debug|info|warn|error|fatal|panic) ;; *) die "无效日志级别：$level" ;; esac
  candidate=$(state_candidate)
  jq --arg v "$level" '.settings.log_level=$v' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" log-level; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}
settings_set_log_level() { with_state_transaction settings-log-level _settings_set_log_level "$@"; }

_settings_detect_public_ip() {
  local ipv4='' ipv6='' chosen candidate
  ipv4=$(detect_public_ipv4 || true); ipv6=$(detect_public_ipv6 || true); chosen=${ipv4:-$ipv6}
  [[ -n "$chosen" ]] || die '无法从多个独立 HTTPS 服务探测公网 IP。'
  candidate=$(state_candidate)
  jq --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" --arg chosen "$chosen" --arg now "$(now_iso)" '
    .settings.public_ipv4=$ipv4 | .settings.public_ipv6=$ipv6 |
    .settings.public_ip_detected_at=$now | .settings.default_server_address=$chosen |
    .settings.default_server_address_source="auto" |
    .nodes |= map(if (.server_address_source // "") == "auto" then .server_address=$chosen else . end)
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" settings-detect-ip; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "公网入口探测完成：IPv4=${ipv4:--} IPv6=${ipv6:--}"
}
settings_detect_public_ip() { with_state_transaction settings-detect-ip _settings_detect_public_ip; }

settings_default_address() {
  local address source
  address=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
  source=$(jq -r '.settings.default_server_address_source // "manual"' "$SBM_STATE")
  if [[ -z "$address" && "$source" == auto ]]; then
    _settings_detect_public_ip
    address=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
  fi
  [[ -n "$address" ]] || die '未配置服务器地址；请使用 sb settings detect-ip 或 sb settings address HOST。'
  printf '%s\n' "$address"
}

settings_show_addresses() {
  jq -r '"默认入口：\(.settings.default_server_address // "-")\n来源：\(.settings.default_server_address_source // "-")\n公网 IPv4：\(.settings.public_ipv4 // "-")\n公网 IPv6：\(.settings.public_ipv6 // "-")\n探测时间：\(.settings.public_ip_detected_at // "-")"' "$SBM_STATE"
}
