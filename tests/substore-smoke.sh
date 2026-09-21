#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
export SBM_SUBSTORE_NODE
SBM_SUBSTORE_NODE=$(command -v node)
dependency_require_feature() { return 0; }
substore_download_asset() {
  local repo=$1 version=$2 asset=$3 output=$4
  if [[ "$asset" == sub-store.bundle.js ]]; then printf 'console.log("fixture");\n' >"$output"
  else python3 - "$output" <<'PY_ZIP'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('dist/index.html', '<html>Sub-Store fixture</html>')
PY_ZIP
  fi
  jq -n --arg version "${version/latest/1.0.0}" --arg sha "$(sha256sum "$output"|awk '{print $1}')" '{version:$version,url:"https://example.com/fixture",sha256:$sha}'
}
substore_install 1.0.0 1.0.0 3001
printf '{"kept":true}\n' >"$SBM_SUBSTORE_DIR/data/test.json"
substore_install 1.0.1 1.0.1 3001
jq -e '.kept' "$SBM_SUBSTORE_DIR/data/test.json" >/dev/null
# The manager-wide backup also includes the optional component data.
backup_create "$ROOT/manager.tar.gz" >/dev/null
printf '{}\n' >"$SBM_SUBSTORE_DIR/data/test.json"
backup_restore "$ROOT/manager.tar.gz" 1 >/dev/null
jq -e '.kept' "$SBM_SUBSTORE_DIR/data/test.json" >/dev/null
[[ $(stat -c '%a' "$SBM_SUBSTORE_SECRET") == 640 && $(stat -c '%a' "$SBM_SUBSTORE_DIR/data") == 700 ]]
grep -Fq 'ProtectSystem=strict' "$SBM_SYSTEMD_DIR/$SBM_SUBSTORE_SERVICE"
SBM_TEST_INIT_BACKEND=openrc substore_write_service 3001
grep -Fq 'supervisor=supervise-daemon' "$SBM_OPENRC_DIR/sb-substore"
with_lock _substore_backup "$ROOT/store.tar.gz"
[[ $(stat -c '%a' "$ROOT/store.tar.gz") == 600 ]]
printf '{}\n' >"$SBM_SUBSTORE_DIR/data/test.json"
substore_restore "$ROOT/store.tar.gz"
jq -e '.kept' "$SBM_SUBSTORE_DIR/data/test.json" >/dev/null
# Failed service activation restores both version and mutable data.
cp "$SBM_STATE" "$ROOT/before.json"
substore_reconcile() { [[ $(jq -r '.substore.version' "$SBM_STATE") != 9.0.0 ]]; }
expect_failure substore_install 9.0.0 9.0.0 3001
cmp "$ROOT/before.json" "$SBM_STATE"
jq -e '.kept' "$SBM_SUBSTORE_DIR/data/test.json" >/dev/null
python3 - "$ROOT/bad.zip" <<'PY_ZIP'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    z.writestr('../escape', 'unsafe')
PY_ZIP
expect_failure python3 "$PROJECT/libexec/component_archive.py" "$ROOT/bad.zip" "$ROOT/extract"
[[ ! -e "$ROOT/escape" ]]
printf 'SUBSTORE SMOKE PASSED\n'
