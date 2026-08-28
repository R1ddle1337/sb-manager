#!/usr/bin/env bash
# shellcheck shell=bash

SBM_ACME_HOME="${SBM_ACME_HOME:-$SBM_VAR/acme/home}"
SBM_ACME_CONFIG="${SBM_ACME_CONFIG:-$SBM_VAR/acme/config}"
SBM_ACME_CERT_HOME="${SBM_ACME_CERT_HOME:-$SBM_VAR/acme/internal-certs}"
SBM_ACME_BIN="${SBM_ACME_BIN:-$SBM_ACME_HOME/acme.sh}"
SBM_CF_DNS_ENV="${SBM_CF_DNS_ENV:-$SBM_SECRETS/dns-cloudflare.env}"
SBM_ACME_LEGACY_HOME="${SBM_ACME_LEGACY_HOME:-${HOME:-/root}/.acme.sh}"
SBM_ACME_VERSION="${SBM_ACME_VERSION:-3.1.4}"
SBM_ACME_COMMIT="${SBM_ACME_COMMIT:-3661fd86b6304115e42f43910e6dd452ab9866d6}"
SBM_ACME_SHA256="${SBM_ACME_SHA256:-9af3ad3d775a5782246df4cdd4b4e7b9b3179deb63c509b10e3ba0433093a884}"
SBM_ACME_ISSUE_TIMEOUT="${SBM_ACME_ISSUE_TIMEOUT:-600}"
SBM_ACME_INSTALL_TIMEOUT="${SBM_ACME_INSTALL_TIMEOUT:-120}"
SBM_ACME_CRON_TIMEOUT="${SBM_ACME_CRON_TIMEOUT:-900}"

acme_migrate_legacy_home() {
  local legacy=$SBM_ACME_LEGACY_HOME dir base tmp
  [[ "$legacy" != "$SBM_ACME_HOME" && -d "$legacy" ]] || return 0
  [[ -f "$legacy/account.conf" ]] || return 0
  mkdir -p "$SBM_ACME_HOME" "$SBM_ACME_CONFIG" "$SBM_ACME_CERT_HOME"
  if [[ -d "$legacy/ca" && ! -e "$SBM_ACME_CONFIG/ca" ]]; then
    cp -a "$legacy/ca" "$SBM_ACME_CONFIG/ca"
  fi
  if [[ -f "$legacy/account.conf" ]] && ! grep -q '^ACCOUNT_EMAIL=' "$SBM_ACME_CONFIG/account.conf" 2>/dev/null; then
    tmp=$(mktemp "$SBM_ACME_CONFIG/.account.XXXXXX")
    {
      cat "$SBM_ACME_CONFIG/account.conf" 2>/dev/null || true
      sed -n '/^ACCOUNT_EMAIL=/p' "$legacy/account.conf"
    } | awk '!seen[$0]++' >"$tmp"
    chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_ACME_CONFIG/account.conf"
  fi
  shopt -s nullglob
  for dir in "$legacy"/*; do
    [[ -d "$dir" ]] || continue
    base=${dir##*/}
    case "$base" in ca|deploy|dnsapi|notify|.??*) continue;; esac
    [[ -e "$SBM_ACME_CERT_HOME/$base" ]] || cp -a "$dir" "$SBM_ACME_CERT_HOME/$base"
  done
  shopt -u nullglob
}

acme_run_timed() {
  local label=$1 seconds=$2 allowed=$3 rc=0 code
  shift 3
  [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || { log_error "$label 超时设置无效：$seconds"; return 1; }
  if timeout --kill-after=15s "${seconds}s" "$SBM_ACME_BIN" "$@"; then
    return 0
  else
    rc=$?
  fi
  for code in $allowed; do
    [[ "$rc" == "$code" ]] && return 0
  done
  if [[ "$rc" == 124 || "$rc" == 137 ]]; then
    log_error "$label 超过 ${seconds} 秒，已终止并回滚；请检查 DNS API、域名 NS 和网络。"
  else
    log_error "$label 失败（退出码 $rc）。"
  fi
  return "$rc"
}

acme_install() {
  local email=${1:-} force=${2:-0} url tmpdir source actual
  if [[ -x "$SBM_ACME_BIN" && "$force" != 1 ]]; then
    acme_migrate_legacy_home
    return 0
  fi
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  [[ -n "$email" ]] || die "首次安装 acme.sh 需要邮箱地址。"
  url="https://github.com/acmesh-official/acme.sh/archive/${SBM_ACME_COMMIT}.tar.gz"
  tmpdir=$(mktemp -d "$SBM_CACHE/acme.XXXXXX")
  download_file_with_retries "$url" "$tmpdir/acme.tar.gz" "acme.sh $SBM_ACME_VERSION" 5
  actual=$(sha256sum "$tmpdir/acme.tar.gz" | awk '{print $1}')
  [[ "$actual" == "$SBM_ACME_SHA256" ]] || { rm -rf "$tmpdir"; die "acme.sh 下载摘要不匹配，已拒绝执行。"; }
  mkdir -p "$tmpdir/src"; tar -xzf "$tmpdir/acme.tar.gz" -C "$tmpdir/src" --strip-components=1
  source="$tmpdir/src/acme.sh"; [[ -x "$source" ]] || chmod +x "$source"
  mkdir -p "$SBM_ACME_HOME" "$SBM_ACME_CONFIG" "$SBM_ACME_CERT_HOME"
  (
    cd "$tmpdir/src"
    ./acme.sh --install --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" \
      --cert-home "$SBM_ACME_CERT_HOME" --accountemail "$email" --nocron --noprofile
  )
  rm -rf "$tmpdir"
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 安装失败。"
  "$SBM_ACME_BIN" --version 2>&1 | grep -Fq "$SBM_ACME_VERSION" || die "acme.sh 安装版本与固定版本 $SBM_ACME_VERSION 不一致。"
  acme_migrate_legacy_home
  artifact_record acme.sh "$SBM_ACME_VERSION" "$url" "sha256:$SBM_ACME_SHA256" "$SBM_ACME_BIN"
  log_ok "acme.sh $SBM_ACME_VERSION 已通过固定摘要安装。"
}

_cert_setup_cloudflare() {
  local token=${1:-} zone_id=${2:-} email=${3:-} candidate tmp
  [[ -n "$token" ]] || prompt_secret token 'Cloudflare API Token'
  [[ -n "$zone_id" ]] || { [[ -t 0 ]] && prompt_value zone_id 'Cloudflare Zone ID（可留空，由 acme.sh 自动查询）' ''; }
  [[ -n "$email" ]] || { [[ -t 0 ]] && prompt_value email 'ACME 账户邮箱' "$(jq -r '.settings.acme_email // ""' "$SBM_STATE")"; }
  [[ -n "$token" ]] || die "API Token 不能为空。"
  [[ -n "$email" ]] || die "邮箱不能为空。"
  acme_install "$email"
  tmp=$(mktemp "$SBM_SECRETS/.dns-cloudflare.XXXXXX")
  {
    printf 'CF_Token=%q\n' "$token"
    [[ -n "$zone_id" ]] && printf 'CF_Zone_ID=%q\n' "$zone_id"
  } >"$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$SBM_CF_DNS_ENV"
  candidate=$(state_candidate)
  jq --arg e "$email" '.settings.acme_email=$e | .settings.acme_dns_provider="dns_cf"' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" acme-settings; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "Cloudflare DNS-01 凭据已保存（不会在面板中回显）。"
}
cert_setup_cloudflare() { with_state_transaction cert-provider _cert_setup_cloudflare "$@"; }

cert_load_cloudflare_env() {
  [[ -s "$SBM_CF_DNS_ENV" ]] || die "尚未配置 Cloudflare DNS API Token。运行：sb cert setup-cloudflare"
  set -a
  # shellcheck disable=SC1090
  source "$SBM_CF_DNS_ENV"
  set +a
}

cert_hook() {
  local domain=$1 dir cert_pub key_pub
  dir="$SBM_CERTS/$domain"
  [[ -s "$dir/fullchain.pem" && -s "$dir/key.pem" ]] || return 1
  openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || { log_error "$domain 证书无效或已经过期。"; return 1; }
  openssl verify -purpose sslserver -CAfile "$dir/fullchain.pem" "$dir/fullchain.pem" >/dev/null 2>&1 || {
    log_error "$domain 证书链校验失败。"
    return 1
  }
  if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
    openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$domain" >/dev/null 2>&1 || { log_error "$domain 不在证书 SAN/CN 中。"; return 1; }
  fi
  cert_pub=$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$dir/key.pem" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { log_error "$domain 证书与私钥不匹配。"; return 1; }
  chmod 0644 "$dir/fullchain.pem"
  chmod 0640 "$dir/key.pem"
  set_group_if_exists "$SBM_SERVICE_USER" "$dir"; set_group_if_exists "$SBM_SERVICE_USER" "$dir/key.pem"
  chmod 0750 "$dir"
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_active "$SBM_SERVICE"; then
    service_restart "$SBM_SERVICE" >/dev/null 2>&1 || return 1
    service_wait_active "$SBM_SERVICE" 20 || return 1
  fi
}

_cert_record_state() {
  local domain=$1 candidate tmp
  candidate=$(state_candidate)
  jq --arg d "$domain" --arg now "$(now_iso)" --arg cert "$SBM_CERTS/$domain/fullchain.pem" --arg key "$SBM_CERTS/$domain/key.pem" '
    .certificates |= (map(select(.domain!=$d)) + [{domain:$d,provider:"acme.sh/dns_cf",key_type:"ec-256",certificate_path:$cert,key_path:$key,updated_at:$now}])
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "cert-$domain"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

_cert_issue() {
  local domain=$1 email=${2:-} dir reloadcmd
  validate_domain "$domain" || die "无效域名：$domain"
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  acme_install "$email"
  cert_load_cloudflare_env
  acme_migrate_legacy_home
  dir="$SBM_CERTS/$domain"; mkdir -p "$dir"; chmod 0750 "$dir"
  log_info "使用 Cloudflare DNS-01 为 $domain 签发 ECDSA 证书…"
  acme_run_timed "为 $domain 签发证书" "$SBM_ACME_ISSUE_TIMEOUT" '0 2' \
    --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
    --accountemail "$email" --issue --dns dns_cf -d "$domain" --server letsencrypt --keylength ec-256 || return $?
  reloadcmd="SBM_SKIP_STATE_INIT=1 $(printf '%q' "$SBM_BIN_DIR/sb") cert hook $(printf '%q' "$domain")"
  acme_run_timed "为 $domain 部署证书" "$SBM_ACME_INSTALL_TIMEOUT" '0' \
    --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
    --install-cert -d "$domain" --ecc \
    --fullchain-file "$dir/fullchain.pem" --key-file "$dir/key.pem" --reloadcmd "$reloadcmd" || return $?
  cert_hook "$domain" || return $?
  _cert_record_state "$domain" || return $?
  log_ok "证书已部署：$dir"
}
cert_issue() { with_state_transaction cert-issue _cert_issue "$@"; }

_cert_renew() {
  local quiet=${1:-0}
  [[ -x "$SBM_ACME_BIN" ]] || { [[ "$quiet" == 1 ]] || log_warn "acme.sh 尚未安装。"; return 0; }
  cert_load_cloudflare_env
  if [[ "$quiet" == 1 ]]; then
    acme_run_timed 'ACME 定时续签' "$SBM_ACME_CRON_TIMEOUT" '0' \
      --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
      --cron >/dev/null || return $?
  else
    acme_run_timed 'ACME 定时续签' "$SBM_ACME_CRON_TIMEOUT" '0' \
      --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
      --cron || return $?
  fi
  local d
  while IFS= read -r d; do cert_hook "$d" || return 1; done < <(jq -r '.certificates[].domain' "$SBM_STATE")
}
cert_renew() { with_state_transaction cert-renew _cert_renew "$@"; }

acme_update() {
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 尚未安装。"
  local email
  email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  with_lock acme_install "$email" 1
  log_ok "acme.sh 已更新到项目审核版本 $SBM_ACME_VERSION。"
}

cert_list() {
  local cert domain path end epoch now days subject
  printf '%-30s %-12s %-24s %s\n' '域名' '剩余天数' '到期时间' '状态'
  while IFS= read -r cert; do
    domain=$(jq -r '.domain' <<<"$cert"); path=$(jq -r '.certificate_path' <<<"$cert")
    if [[ ! -s "$path" ]]; then printf '%-30s %-12s %-24s %s\n' "$domain" '-' '-' '文件缺失'; continue; fi
    end=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2-)
    days=$(x509_days_remaining "$path" 2>/dev/null || echo -1)
    subject='正常'; (( days < 20 )) && subject='即将过期'; (( days < 7 )) && subject='危险'
    printf '%-30s %-12s %-24s %s\n' "$domain" "$days" "$end" "$subject"
  done < <(jq -c '.certificates[]?' "$SBM_STATE")
}

cert_inspect() {
  local domain=$1 path
  path="$SBM_CERTS/$domain/fullchain.pem"
  [[ -s "$path" ]] || die "证书不存在：$domain"
  openssl x509 -in "$path" -noout -subject -issuer -serial -dates -ext subjectAltName
}
