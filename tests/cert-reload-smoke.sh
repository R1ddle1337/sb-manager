#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$PROJECT" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_GENERATED_DIR="$SBM_ETC/generated" SBM_STATE="$SBM_ETC/state.json" SBM_CONFIG="$SBM_ETC/generated/config.json"
export SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs" SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache"
export SBM_CORE_DIR="$ROOT/cores" SBM_LOCK="$SBM_RUN/manager.lock" SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_MODE=1 NO_COLOR=1
export SBM_SING_BOX_BIN="${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}"
export SBM_ACME_BIN="$ROOT/bin/acme.sh" SBM_ACME_HOME="$ROOT/acme" SBM_CF_DNS_ENV="$SBM_SECRETS/dns-cloudflare.env"
export SBM_ACME_CONFIG="$ROOT/acme-config" SBM_ACME_CERT_HOME="$ROOT/acme-certs" SBM_ACME_LEGACY_HOME="$ROOT/legacy-acme"
export FAKE_ACME_ARGS_LOG="$ROOT/acme-args.log"

mkdir -p "$ROOT/bin" "$SBM_SECRETS" "$SBM_BIN_DIR"
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/state.sh"
source "$PROJECT/lib/nginx_stream.sh"
source "$PROJECT/protocols/vmess_ws_cf.sh"
source "$PROJECT/protocols/shadowsocks.sh"
source "$PROJECT/protocols/anytls.sh"
source "$PROJECT/protocols/hysteria2.sh"
source "$PROJECT/protocols/trojan.sh"
source "$PROJECT/protocols/tuic.sh"
source "$PROJECT/protocols/vless.sh"
source "$PROJECT/protocols/naive.sh"
source "$PROJECT/protocols/shadowtls.sh"
source "$PROJECT/lib/render.sh"
source "$PROJECT/lib/core.sh"
source "$PROJECT/lib/cert.sh"
state_init
printf 'CF_Token=test-token\n' >"$SBM_CF_DNS_ENV"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj '/CN=reload.example.com' \
  -addext 'subjectAltName=DNS:reload.example.com' \
  -keyout "$ROOT/source-key.pem" -out "$ROOT/source-fullchain.pem" >/dev/null 2>&1
cat >"$SBM_ACME_BIN" <<'EOF_ACME'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_ACME_ARGS_LOG"
if [[ " $* " == *' --version '* ]]; then echo 'https://github.com/acmesh-official/acme.sh acme.sh 3.1.4'; exit 0; fi
if [[ ${FAKE_ACME_HANG:-0} == 1 && " $* " == *' --issue '* ]]; then sleep 30; exit 0; fi
if [[ " $* " == *' --issue '* ]]; then exit "${FAKE_ACME_ISSUE_RC:-0}"; fi
if [[ " $* " == *' --install-cert '* ]]; then
  fullchain='' key='' reload=''
  while (($#)); do
    case "$1" in
      --fullchain-file) fullchain=$2; shift 2;;
      --key-file) key=$2; shift 2;;
      --reloadcmd) reload=$2; shift 2;;
      *) shift;;
    esac
  done
  cp "$FAKE_CERT" "$fullchain"; cp "$FAKE_KEY" "$key"
  eval "$reload"
  exit 0
fi
exit 0
EOF_ACME
chmod 0755 "$SBM_ACME_BIN"
export FAKE_CERT="$ROOT/source-fullchain.pem" FAKE_KEY="$ROOT/source-key.pem"
ln -sfn "$PROJECT/sb" "$SBM_BIN_DIR/sb"
mkdir -p "$SBM_ACME_LEGACY_HOME/ca/provider" "$SBM_ACME_LEGACY_HOME/legacy.example.com_ecc"
printf 'legacy-account-key\n' >"$SBM_ACME_LEGACY_HOME/ca/provider/account.key"
printf "ACCOUNT_EMAIL='legacy@example.com'\n" >"$SBM_ACME_LEGACY_HOME/account.conf"
printf "Le_Domain='legacy.example.com'\n" >"$SBM_ACME_LEGACY_HOME/legacy.example.com_ecc/legacy.example.com.conf"

cert_issue reload.example.com test@example.com & issue_pid=$!
for _ in {1..150}; do
  kill -0 "$issue_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$issue_pid" 2>/dev/null; then
  kill "$issue_pid" 2>/dev/null || true
  wait "$issue_pid" 2>/dev/null || true
  echo 'certificate reload hook deadlocked' >&2
  exit 1
fi
wait "$issue_pid"
jq -e '.certificates[]|select(.domain=="reload.example.com")' "$SBM_STATE" >/dev/null
[[ -s "$SBM_CERTS/reload.example.com/fullchain.pem" && -s "$SBM_CERTS/reload.example.com/key.pem" ]]
[[ -f "$SBM_ACME_CONFIG/ca/provider/account.key" ]]
[[ -f "$SBM_ACME_CERT_HOME/legacy.example.com_ecc/legacy.example.com.conf" ]]
grep -Fq -- "--home $SBM_ACME_HOME --config-home $SBM_ACME_CONFIG --cert-home $SBM_ACME_CERT_HOME" "$FAKE_ACME_ARGS_LOG"
export FAKE_ACME_ISSUE_RC=2
cert_issue reload.example.com test@example.com
unset FAKE_ACME_ISSUE_RC
state_before=$(sha256sum "$SBM_STATE" | awk '{print $1}')
export FAKE_ACME_HANG=1
if SBM_ACME_ISSUE_TIMEOUT=1 cert_issue timeout.example.com test@example.com; then
  echo 'certificate issue timeout unexpectedly succeeded' >&2
  exit 1
fi
unset FAKE_ACME_HANG
state_after=$(sha256sum "$SBM_STATE" | awk '{print $1}')
[[ "$state_before" == "$state_after" ]]
[[ ! -e "$SBM_CERTS/timeout.example.com" ]]
printf 'CERT RELOAD SMOKE PASSED\n'
