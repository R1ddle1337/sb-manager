#!/usr/bin/env bash
# shellcheck shell=bash

SBM_ACME_HOME="${SBM_ACME_HOME:-$SBM_VAR/acme/home}"
SBM_ACME_CONFIG="${SBM_ACME_CONFIG:-$SBM_VAR/acme/config}"
SBM_ACME_CERT_HOME="${SBM_ACME_CERT_HOME:-$SBM_VAR/acme/internal-certs}"
SBM_ACME_BIN="${SBM_ACME_BIN:-$SBM_ACME_HOME/acme.sh}"
SBM_CF_DNS_ENV="${SBM_CF_DNS_ENV:-$SBM_SECRETS/dns-cloudflare.env}"

acme_install() {
  [[ -x "$SBM_ACME_BIN" ]] && return 0
  local json url tmpdir source email=${1:-}
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  [[ -n "$email" ]] || die "首次安装 acme.sh 需要邮箱地址。"
  json=$(github_api 'https://api.github.com/repos/acmesh-official/acme.sh/releases/latest')
  url=$(jq -r '.tarball_url' <<<"$json")
  [[ -n "$url" && "$url" != null ]] || die "无法获取 acme.sh 官方 Release。"
  tmpdir=$(mktemp -d "$SBM_CACHE/acme.XXXXXX")
  curl -fL --retry 3 "$url" -o "$tmpdir/acme.tar.gz"
  mkdir -p "$tmpdir/src"; tar -xzf "$tmpdir/acme.tar.gz" -C "$tmpdir/src" --strip-components=1
  source="$tmpdir/src/acme.sh"; [[ -x "$source" ]] || chmod +x "$source"
  mkdir -p "$SBM_ACME_HOME" "$SBM_ACME_CONFIG" "$SBM_ACME_CERT_HOME"
  "$source" --install --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" --accountemail "$email" --nocron --noprofile
  rm -rf "$tmpdir"
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 安装失败。"
  log_ok "acme.sh 已安装。"
}

cert_setup_cloudflare() {
  local token=${1:-} zone_id=${2:-} email=${3:-} candidate tmp
  [[ -n "$token" ]] || prompt_secret token 'Cloudflare API Token'
  [[ -n "$zone_id" ]] || { [[ -t 0 ]] && prompt_value zone_id 'Cloudflare Zone ID（可留空，由 acme.sh 自动查询）' ''; }
  [[ -n "$email" ]] || { [[ -t 0 ]] && prompt_value email 'ACME 账户邮箱' "$(jq -r '.settings.acme_email // ""' "$SBM_STATE")"; }
  [[ -n "$token" ]] || die "API Token 不能为空。"
  [[ -n "$email" ]] || die "邮箱不能为空。"
  tmp=$(mktemp "$SBM_SECRETS/.dns-cloudflare.XXXXXX")
  {
    printf 'CF_Token=%q\n' "$token"
    [[ -n "$zone_id" ]] && printf 'CF_Zone_ID=%q\n' "$zone_id"
  } >"$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$SBM_CF_DNS_ENV"
  candidate=$(state_candidate)
  jq --arg e "$email" '.settings.acme_email=$e | .settings.acme_dns_provider="dns_cf"' "$SBM_STATE" >"$candidate"
  with_lock apply_candidate_state "$candidate" acme-settings
  rm -f "$candidate"
  acme_install "$email"
  log_ok "Cloudflare DNS-01 凭据已保存（不会在面板中回显）。"
}

cert_load_cloudflare_env() {
  [[ -s "$SBM_CF_DNS_ENV" ]] || die "尚未配置 Cloudflare DNS API Token。运行：sb cert setup-cloudflare"
  set -a
  # shellcheck disable=SC1090
  source "$SBM_CF_DNS_ENV"
  set +a
}

cert_hook() {
  local domain=$1 dir="$SBM_CERTS/$domain"
  [[ -s "$dir/fullchain.pem" && -s "$dir/key.pem" ]] || return 1
  chmod 0644 "$dir/fullchain.pem"
  chmod 0640 "$dir/key.pem"
  set_group_if_exists "$SBM_SERVICE_USER" "$dir"; set_group_if_exists "$SBM_SERVICE_USER" "$dir/key.pem"
  chmod 0750 "$dir"
  if [[ "$SBM_SKIP_SYSTEMD" != "1" ]] && service_exists "$SBM_SERVICE"; then systemctl try-reload-or-restart "$SBM_SERVICE" >/dev/null 2>&1 || true; fi
}

_cert_record_state() {
  local domain=$1 candidate tmp
  candidate=$(state_candidate)
  jq --arg d "$domain" --arg now "$(now_iso)" --arg cert "$SBM_CERTS/$domain/fullchain.pem" --arg key "$SBM_CERTS/$domain/key.pem" '
    .certificates |= (map(select(.domain!=$d)) + [{domain:$d,provider:"acme.sh/dns_cf",key_type:"ec-256",certificate_path:$cert,key_path:$key,updated_at:$now}])
  ' "$SBM_STATE" >"$candidate"
  apply_candidate_state "$candidate" "cert-$domain"
  rm -f "$candidate"
}

_cert_issue() {
  local domain=$1 email=${2:-} dir reloadcmd
  validate_domain "$domain" || die "无效域名：$domain"
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  acme_install "$email"
  cert_load_cloudflare_env
  dir="$SBM_CERTS/$domain"; mkdir -p "$dir"; chmod 0750 "$dir"
  log_info "使用 Cloudflare DNS-01 为 $domain 签发 ECDSA 证书…"
  "$SBM_ACME_BIN" --issue --dns dns_cf -d "$domain" --server letsencrypt --keylength ec-256
  reloadcmd="$SBM_BIN_DIR/sb cert hook $(printf '%q' "$domain")"
  "$SBM_ACME_BIN" --install-cert -d "$domain" --ecc \
    --fullchain-file "$dir/fullchain.pem" --key-file "$dir/key.pem" --reloadcmd "$reloadcmd"
  cert_hook "$domain"
  _cert_record_state "$domain"
  log_ok "证书已部署：$dir"
}
cert_issue() { with_lock _cert_issue "$@"; }

_cert_renew() {
  local quiet=${1:-0}
  [[ -x "$SBM_ACME_BIN" ]] || { [[ "$quiet" == 1 ]] || log_warn "acme.sh 尚未安装。"; return 0; }
  cert_load_cloudflare_env
  if [[ "$quiet" == 1 ]]; then "$SBM_ACME_BIN" --cron --home "$SBM_ACME_HOME" >/dev/null; else "$SBM_ACME_BIN" --cron --home "$SBM_ACME_HOME"; fi
  local d
  while IFS= read -r d; do cert_hook "$d" || true; done < <(jq -r '.certificates[].domain' "$SBM_STATE")
}
cert_renew() { with_lock _cert_renew "$@"; }

acme_update() {
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 尚未安装。"
  with_lock "$SBM_ACME_BIN" --upgrade --auto-upgrade 0
  log_ok "acme.sh 更新检查完成。"
}

cert_list() {
  local cert domain path end epoch now days subject
  printf '%-30s %-12s %-24s %s\n' '域名' '剩余天数' '到期时间' '状态'
  while IFS= read -r cert; do
    domain=$(jq -r '.domain' <<<"$cert"); path=$(jq -r '.certificate_path' <<<"$cert")
    if [[ ! -s "$path" ]]; then printf '%-30s %-12s %-24s %s\n' "$domain" '-' '-' '文件缺失'; continue; fi
    end=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2-)
    epoch=$(date -d "$end" +%s 2>/dev/null || echo 0); now=$(date +%s); days=$(( (epoch-now)/86400 ))
    subject='正常'; (( days < 20 )) && subject='即将过期'; (( days < 7 )) && subject='危险'
    printf '%-30s %-12s %-24s %s\n' "$domain" "$days" "$end" "$subject"
  done < <(jq -c '.certificates[]?' "$SBM_STATE")
}

cert_inspect() {
  local domain=$1 path="$SBM_CERTS/$domain/fullchain.pem"
  [[ -s "$path" ]] || die "证书不存在：$domain"
  openssl x509 -in "$path" -noout -subject -issuer -serial -dates -ext subjectAltName
}
