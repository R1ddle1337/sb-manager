#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL=${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX}

export SBM_TEST_MODE=1 SBM_SKIP_INIT=1 SBM_SKIP_SYSTEMD=1 SBM_TEST_SING_BOX="$REAL"
export SBM_PREFIX="$ROOT/usr/local" SBM_LIB="$ROOT/usr/local/lib/sb-manager" SBM_BIN_DIR="$ROOT/usr/local/bin"
export SBM_ETC="$ROOT/etc/sb-manager" SBM_VAR="$ROOT/var/lib/sb-manager" SBM_RUN="$ROOT/run/sb-manager"
export SBM_SYSTEMD_DIR="$ROOT/etc/systemd/system" SBM_OPENRC_DIR="$ROOT/etc/init.d" SBM_PERIODIC_DIR="$ROOT/etc/periodic"
export SBM_LOG_DIR="$ROOT/var/log/sb-manager" SBM_STATE="$SBM_ETC/state.json" SBM_GENERATED_DIR="$SBM_ETC/generated"
export SBM_CONFIG="$SBM_GENERATED_DIR/config.json" SBM_SECRETS="$SBM_ETC/secrets" SBM_CERTS="$SBM_ETC/certs"
export SBM_BACKUPS="$SBM_VAR/backups" SBM_EXPORTS="$SBM_VAR/exports" SBM_CACHE="$SBM_VAR/cache" SBM_CORE_DIR="$SBM_LIB/cores"
export SBM_LOCK="$SBM_RUN/manager.lock" SBM_SING_BOX_BIN="$SBM_BIN_DIR/sing-box" SBM_SERVICE_USER=root NO_COLOR=1

mkdir -p "$ROOT/bin" "$ROOT/fixture/payload/sb-manager"
tar -C "$PROJECT" -cf - \
  --exclude='./.git' --exclude='./tests' --exclude='./docs' --exclude='./sing-box-official-docs-cn' . \
  | tar -C "$ROOT/fixture/payload/sb-manager" -xf -
tar -C "$ROOT/fixture/payload" -czf "$ROOT/fixture/source.tar.gz" sb-manager
cat >"$ROOT/bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url=''; out=''
for arg in "$@"; do [[ "$arg" == https://* ]] && url=$arg; done
while (($#)); do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done
if [[ "$url" == *'/commits/main' ]]; then
  printf '%s\n' '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
elif [[ "$url" == *'/archive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar.gz' ]]; then
  cp "$SBM_UPDATE_FIXTURE" "$out"
else
  echo "unexpected URL: $url" >&2; exit 1
fi
EOF_CURL
chmod 0755 "$ROOT/bin/curl"
export PATH="$ROOT/bin:$PATH" SBM_UPDATE_FIXTURE="$ROOT/fixture/source.tar.gz"

bash "$PROJECT/setup.sh" --no-menu --no-start
printf '%s\n' old >"$SBM_LIB/INSTALL_COMMIT"
printf '%s\n' R1ddle1337/sb-manager >"$SBM_LIB/INSTALL_REPOSITORY"
"$SBM_BIN_DIR/sb" node add vmess --id keep-node --port 29131 --domain cdn.example.com --address cdn.example.com >/dev/null
before=$(readlink "$SBM_SING_BOX_BIN")
"$SBM_BIN_DIR/sb" update --check | grep -Fq '可更新至 commit：aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]
# Simulate a panel inherited from the installer: descriptor 8 still owns the
# setup lock when the panel starts a nested manager update.
exec 8>"$SBM_RUN/setup.lock"
flock -n 8
"$SBM_BIN_DIR/sb" update >/dev/null
flock -u 8
exec 8>&-
[[ $(jq '.nodes|length' "$SBM_STATE") == 1 ]]
[[ $(readlink "$SBM_SING_BOX_BIN") == "$before" ]]
[[ $(cat "$SBM_LIB/INSTALL_COMMIT") == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
printf 'UPDATE SMOKE PASSED\n'
