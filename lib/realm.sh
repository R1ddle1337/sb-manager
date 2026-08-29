#!/usr/bin/env bash
# shellcheck shell=bash

SBM_REALM_SECRET="${SBM_REALM_SECRET:-$SBM_SECRETS/realm.json}"

realm_secret_read() {
  [[ -r "$SBM_REALM_SECRET" ]] || die "Hysteria Realm 密钥文件缺失：$SBM_REALM_SECRET"
  jq -c . "$SBM_REALM_SECRET"
}

realm_secret_token() { realm_secret_read | jq -r '.token'; }

realm_validate_url() {
  local url=$1
  [[ "$url" =~ ^https?://[^/[:space:]]+$ ]] || die "无效 Realm 公网 URL：$url"
}

_realm_enable() {
  local port=$1 public_url=$2 listen=${3:-"::"} tls_domain=${4:-} max_realms=${5:-0} candidate token scheme
  validate_port "$port" || die "无效 Realm 端口：$port"
  realm_validate_url "$public_url"
  [[ "$max_realms" =~ ^[0-9]+$ ]] && (( max_realms <= 1000000 )) || die 'Realm max_realms 必须是 0-1000000 的整数。'
  [[ -n "$listen" ]] || die 'Realm listen 地址不能为空。'
  scheme=${public_url%%:*}
  if [[ -n "$tls_domain" ]]; then
    validate_domain "$tls_domain" || die "无效 Realm TLS 域名：$tls_domain"
    [[ "$scheme" == https ]] || die '配置 TLS 域名时 Realm 公网 URL 必须使用 https。'
    [[ -s "$SBM_CERTS/$tls_domain/fullchain.pem" && -s "$SBM_CERTS/$tls_domain/key.pem" ]] || die "Realm 缺少证书：$SBM_CERTS/$tls_domain/{fullchain.pem,key.pem}"
  elif [[ "$scheme" == https ]]; then
    die 'Realm 使用 https 时必须指定 --tls-domain 并准备证书。'
  elif [[ "$listen" != 127.0.0.1 && "$listen" != ::1 ]]; then
    log_warn 'Realm 当前使用明文 HTTP；公网部署建议配置 TLS。'
  fi
  version_ge "$(core_current_version)" 1.14.0-rc.1 || die 'Hysteria Realm 需要 sing-box 1.14.0-rc.1 或更高版本核心。'
  token=$(random_password 32)
  mkdir -p "$SBM_SECRETS"
  printf '%s\n' "$(jq -n --arg token "$token" '{token:$token}')" >"$SBM_REALM_SECRET"
  chmod 0600 "$SBM_REALM_SECRET"
  candidate=$(state_candidate)
  jq --arg listen "$listen" --argjson port "$port" --arg url "$public_url" --arg domain "$tls_domain" --arg name default --argjson max "$max_realms" \
    '.realm={enabled:true,listen:$listen,port:$port,public_url:$url,tls_domain:$domain,user_name:$name,max_realms:$max}' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" realm-enable; then rm -f "$candidate" "$SBM_REALM_SECRET"; return 1; fi
  rm -f "$candidate"
  log_ok "Hysteria Realm 已启用：$public_url"
}
realm_enable() { with_state_transaction realm-enable _realm_enable "$@"; }

_realm_disable() {
  local candidate
  if jq -e '.nodes[]? | select(.protocol=="hysteria2" and .realm_enabled==true and .enabled==true)' "$SBM_STATE" >/dev/null; then
    die '仍有启用的 Hysteria2 Realm 节点；请先停用或移除这些节点。'
  fi
  candidate=$(state_candidate)
  jq '.realm.enabled=false' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" realm-disable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate" "$SBM_REALM_SECRET"
  log_ok 'Hysteria Realm 已停用。'
}
realm_disable() { with_state_transaction realm-disable _realm_disable; }

realm_status() {
  if [[ ${1:-0} == 1 ]]; then jq '.realm' "$SBM_STATE"; return; fi
  jq -r '"Hysteria Realm：" + (if .realm.enabled then "启用" else "停用" end) + "\n监听：\(.realm.listen):\(.realm.port)\n公网 URL：\(.realm.public_url // "-")\nTLS 域名：\(.realm.tls_domain // "-")\n最大 Realm 数：\(.realm.max_realms // 0)"' "$SBM_STATE"
}

realm_show_token() {
  [[ $(jq -r '.realm.enabled // false' "$SBM_STATE") == true ]] || die 'Hysteria Realm 未启用。'
  realm_secret_token
}
