#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(tr -d '[:space:]' <"$SOURCE_DIR/VERSION")
OUTPUT=${1:-"$SOURCE_DIR/../sb-manager-install.sh"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ROOT="sb-manager-$VERSION"
mkdir -p "$TMP/$ROOT"
cp -a "$SOURCE_DIR"/. "$TMP/$ROOT"/
rm -rf "$TMP/$ROOT/.git" "$TMP/$ROOT/.github" "$TMP/$ROOT/dist"
rm -rf "$TMP/$ROOT/sing-box-official-docs-cn" "$TMP/$ROOT/sing-box-official-docs-cn-"*.zip
tar -C "$TMP" -czf "$TMP/payload.tar.gz" "$ROOT"
cat >"$OUTPUT" <<EOF_HEADER
#!/usr/bin/env bash
set -Eeuo pipefail
umask 027
PAYLOAD_LINE=\$(awk '/^__SB_MANAGER_PAYLOAD_BELOW__\$/ {print NR + 1; exit}' "\$0")
[[ -n "\$PAYLOAD_LINE" ]] || { echo '安装器载荷损坏。' >&2; exit 1; }
TMPDIR_INSTALL=\$(mktemp -d)
cleanup() { rm -rf "\$TMPDIR_INSTALL"; }
trap cleanup EXIT INT TERM
if ! tail -n +"\$PAYLOAD_LINE" "\$0" | base64 -d | tar -xzf - -C "\$TMPDIR_INSTALL"; then
  echo '安装器载荷解码失败。' >&2
  exit 1
fi
bash "\$TMPDIR_INSTALL/$ROOT/setup.sh" "\$@"
rc=\$?
exit "\$rc"
__SB_MANAGER_PAYLOAD_BELOW__
EOF_HEADER
base64 "$TMP/payload.tar.gz" >>"$OUTPUT"
chmod +x "$OUTPUT"
printf '%s\n' "$OUTPUT"
