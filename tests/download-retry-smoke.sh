#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

export SBM_LIB="$PROJECT"
export SBM_PREFIX="$ROOT/usr/local"
export SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager"
export SBM_VAR="$ROOT/var/lib/sb-manager"
export SBM_RUN="$ROOT/run/sb-manager"
export SBM_CACHE="$SBM_VAR/cache"
export SBM_BACKUPS="$SBM_VAR/backups"
export SBM_EXPORTS="$SBM_VAR/exports"
export SBM_CORE_DIR="$ROOT/cores"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 NO_COLOR=1
export FAKE_CURL_COUNT="$ROOT/curl.count"

mkdir -p "$ROOT/fake-bin" "$SBM_CACHE" "$SBM_CORE_DIR"
cat >"$ROOT/fake-bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -u
out=''
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    --fail|--location|--silent|--show-error) shift ;;
    *) shift ;;
  esac
done
count=0
[[ ! -f "$FAKE_CURL_COUNT" ]] || count=$(cat "$FAKE_CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_CURL_COUNT"
printf 'partial' >"$out"
if [[ ${FAKE_CURL_ALWAYS_FAIL:-0} == 1 || $count -lt ${FAKE_CURL_SUCCEED_ON:-3} ]]; then
  exit 35
fi
printf 'complete' >"$out"
EOF_CURL
chmod 0755 "$ROOT/fake-bin/curl"
export PATH="$ROOT/fake-bin:$PATH"

# shellcheck source=lib/common.sh
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/service.sh"
source "$PROJECT/lib/core.sh"

sleep() { :; }

out="$ROOT/success.bin"
export FAKE_CURL_SUCCEED_ON=3 FAKE_CURL_ALWAYS_FAIL=0
download_file_with_retries 'https://example.invalid/core' "$out" test-core 5
[[ $(cat "$out") == complete ]]
[[ $(cat "$FAKE_CURL_COUNT") == 3 ]]

rm -f "$FAKE_CURL_COUNT"
out_fail="$ROOT/failure.bin"
export FAKE_CURL_ALWAYS_FAIL=1
if (download_file_with_retries 'https://example.invalid/core' "$out_fail" test-core 3 >/dev/null 2>&1); then
  echo 'permanent download failure was unexpectedly accepted' >&2
  exit 1
fi
[[ ! -e "$out_fail" ]]
[[ $(cat "$FAKE_CURL_COUNT") == 3 ]]

printf 'DOWNLOAD RETRY SMOKE PASSED\n'
