#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

mkdir -p "$ROOT/bin" "$ROOT/fixture"
tar -C "$PROJECT" -czf "$ROOT/fixture/source.tar.gz" \
  --exclude='./.git' --exclude='./sing-box-official-docs-cn' --exclude='./sing-box-official-docs-cn-*.zip' .
cat >"$ROOT/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url=${*: -1}
out=''
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$url" == *'/commits/main' ]]; then
  printf '%s\n' '{"sha":"1111111111111111111111111111111111111111","tree":{"sha":"2222222222222222222222222222222222222222"}}'
elif [[ "$url" == *'/archive/1111111111111111111111111111111111111111.tar.gz' ]]; then
  cp "$SBM_BOOTSTRAP_FIXTURE" "$out"
else
  echo "unexpected URL: $url" >&2
  exit 1
fi
EOF_CURL
chmod 0755 "$ROOT/bin/curl"

prefix="$ROOT/prefix"
export SBM_BOOTSTRAP_FIXTURE="$ROOT/fixture/source.tar.gz"
export PATH="$ROOT/bin:$PATH"
export SBM_TEST_MODE=1 SBM_TEST_SING_BOX="$REAL" SBM_INSTALL_ARCHIVE_URL=https://example.invalid/archive/1111111111111111111111111111111111111111.tar.gz
export SBM_PREFIX="$prefix" SBM_LIB="$prefix/lib/sb-manager" SBM_BIN_DIR="$prefix/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system" SBM_OPENRC_DIR="$ROOT/etc/init.d" SBM_PERIODIC_DIR="$ROOT/etc/periodic" SBM_LOG_DIR="$ROOT/var/log/sb-manager"
export SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_SERVICE_USER=daemon NO_COLOR=1
bash "$PROJECT/install.sh" --no-menu --no-start >/dev/null
[[ -x "$prefix/bin/sb" ]]
[[ $(find "$prefix/lib/sb-manager/protocols" -maxdepth 1 -type f -name '*.sh' | wc -l) == 9 ]]
printf 'BOOTSTRAP LATEST SMOKE PASSED\n'
