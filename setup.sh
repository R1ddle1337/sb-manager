#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_LIB=${SBM_LIB:-/usr/local/lib/sb-manager}
TARGET_BIN=${SBM_BIN_DIR:-/usr/local/bin}
NO_MENU=0
NO_START=0
CORE_VERSION=$(tr -d '[:space:]' <"$SRC_DIR/TESTED_CORE_VERSION" 2>/dev/null || true)
CORE_VERSION=${CORE_VERSION:-latest}
TEST_MODE=${SBM_TEST_MODE:-0}

usage() {
  cat <<'EOF_USAGE'
用法：sudo ./setup.sh [选项]
  --no-menu             安装后不打开交互面板
  --no-start            不启动/启用 systemd 服务与定时器
  --core-version VER    安装指定 sing-box 版本（默认 latest）
  -h, --help            帮助
EOF_USAGE
}
while (($#)); do
  case "$1" in
    --no-menu) NO_MENU=1; shift;; --no-start) NO_START=1; shift;; --core-version) CORE_VERSION=${2:?}; shift 2;; -h|--help) usage; exit 0;; *) echo "未知参数：$1" >&2; usage; exit 1;;
  esac
done

if [[ "$TEST_MODE" != 1 ]]; then
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '请使用 root/sudo 运行。' >&2; exit 1; }
  command -v systemctl >/dev/null 2>&1 || { echo '当前版本只支持 systemd Linux。' >&2; exit 1; }
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == systemd ]] || { echo 'PID 1 不是 systemd。' >&2; exit 1; }
fi

install_dependencies() {
  local packages=(curl ca-certificates jq openssl tar gzip coreutils util-linux procps)
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${packages[@]}" iproute2 passwd
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}" iproute shadow-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}" iproute shadow-utils
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${packages[@]}" iproute2 shadow
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${packages[@]}" iproute2 shadow
  else
    echo '不支持的包管理器。当前支持 apt、dnf、yum、pacman、zypper。' >&2
    exit 1
  fi
}

printf '[1/7] 安装依赖…\n'
[[ "$TEST_MODE" == 1 ]] || install_dependencies

[[ "$TEST_MODE" == 1 ]] || command -v useradd >/dev/null 2>&1 || { echo '缺少 useradd，无法创建低权限服务用户。' >&2; exit 1; }

printf '[2/7] 安装程序文件…\n'
if [[ -d "$TARGET_LIB" && -f "$TARGET_LIB/sb" ]]; then
  backup="/var/lib/sb-manager/backups/program-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup"
  cp -a "$TARGET_LIB" "$backup/" || true
fi
mkdir -p "$TARGET_LIB" "$TARGET_BIN"
find "$TARGET_LIB" -mindepth 1 -maxdepth 1 ! -name cores -exec rm -rf {} + 2>/dev/null || true
cp -a "$SRC_DIR"/. "$TARGET_LIB"/
chmod 0755 "$TARGET_LIB/sb" "$TARGET_LIB/setup.sh" "$TARGET_LIB/lib/"*.sh "$TARGET_LIB/protocols/"*.sh
ln -sfn "$TARGET_LIB/sb" "$TARGET_BIN/sb"

# shellcheck source=lib/common.sh
source "$TARGET_LIB/lib/common.sh"
source "$TARGET_LIB/lib/state.sh"
source "$TARGET_LIB/protocols/vmess_ws_cf.sh"
source "$TARGET_LIB/protocols/shadowsocks.sh"
source "$TARGET_LIB/protocols/anytls.sh"
source "$TARGET_LIB/protocols/hysteria2.sh"
source "$TARGET_LIB/lib/render.sh"
source "$TARGET_LIB/lib/core.sh"
source "$TARGET_LIB/lib/tunnel.sh"

printf '[3/7] 创建低权限服务用户和数据目录…\n'
if [[ "$TEST_MODE" != 1 ]] && ! id "$SBM_SERVICE_USER" >/dev/null 2>&1; then
  nologin=$(command -v nologin || echo /usr/sbin/nologin)
  useradd --system --home-dir "$SBM_VAR" --create-home --shell "$nologin" "$SBM_SERVICE_USER"
fi
state_init
chown root:"$SBM_SERVICE_USER" "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" 2>/dev/null || true
mkdir -p "$SBM_VAR/cloudflared-home"
chown root:root "$SBM_VAR" "$SBM_RUN" 2>/dev/null || true
chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/cloudflared-home" 2>/dev/null || true
chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR" "$SBM_VAR/cloudflared-home"
chown root:"$SBM_SERVICE_USER" "$SBM_SECRETS" 2>/dev/null || true
chmod 0710 "$SBM_SECRETS"
chmod 0700 "$SBM_SECRETS/nodes"

printf '[4/7] 安装 sing-box 核心…\n'
if [[ "$TEST_MODE" == 1 ]]; then
  test_version=$(${SBM_TEST_SING_BOX:?} version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  mkdir -p "$SBM_CORE_DIR/sing-box/$test_version"
  install -m 0755 "$SBM_TEST_SING_BOX" "$SBM_CORE_DIR/sing-box/$test_version/sing-box"
  sb_binary="$SBM_CORE_DIR/sing-box/$test_version/sing-box"
else
  sb_binary=$(core_download_version "$CORE_VERSION")
fi
ln -sfn "$sb_binary" "$SBM_SING_BOX_BIN.new"; mv -Tf "$SBM_SING_BOX_BIN.new" "$SBM_SING_BOX_BIN"

printf '[5/7] 安装 cloudflared…\n'
if [[ "$TEST_MODE" == 1 ]]; then
  mkdir -p "$SBM_CORE_DIR/cloudflared/test"
  cat >"$SBM_CORE_DIR/cloudflared/test/cloudflared" <<'EOF_CF'
#!/usr/bin/env bash
echo 'cloudflared version 2026.1.0'
EOF_CF
  chmod +x "$SBM_CORE_DIR/cloudflared/test/cloudflared"
  cf_binary="$SBM_CORE_DIR/cloudflared/test/cloudflared"
else
  cf_binary=$(cloudflared_download_latest)
fi
ln -sfn "$cf_binary" "$SBM_CLOUDFLARED_BIN.new"; mv -Tf "$SBM_CLOUDFLARED_BIN.new" "$SBM_CLOUDFLARED_BIN"

printf '[6/7] 生成配置与 systemd 服务…\n'
render_current_config
cat >"$SBM_SYSTEMD_DIR/$SBM_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager managed sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStart=$SBM_SING_BOX_BIN run -c $SBM_CONFIG
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=$SBM_ETC $SBM_LIB

[Install]
WantedBy=multi-user.target
EOF_UNIT

cat >"$SBM_SYSTEMD_DIR/sb-core-update.service" <<EOF_UNIT
[Unit]
Description=sb-manager sing-box update policy check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SBM_BIN_DIR/sb core auto
EOF_UNIT
cat >"$SBM_SYSTEMD_DIR/sb-core-update.timer" <<'EOF_UNIT'
[Unit]
Description=Periodic sb-manager sing-box update check

[Timer]
OnBootSec=15min
OnUnitActiveSec=12h
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF_UNIT
cat >"$SBM_SYSTEMD_DIR/sb-acme-renew.service" <<EOF_UNIT
[Unit]
Description=sb-manager ACME renewal check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SBM_BIN_DIR/sb cert renew --quiet
EOF_UNIT
cat >"$SBM_SYSTEMD_DIR/sb-acme-renew.timer" <<'EOF_UNIT'
[Unit]
Description=Daily sb-manager ACME renewal check

[Timer]
OnBootSec=30min
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF_UNIT
chmod 0644 "$SBM_SYSTEMD_DIR/$SBM_SERVICE" "$SBM_SYSTEMD_DIR"/sb-*.service "$SBM_SYSTEMD_DIR"/sb-*.timer

printf '[7/7] 启动服务…\n'
if [[ "$TEST_MODE" != 1 ]]; then systemctl daemon-reload; fi
if [[ "$NO_START" == 0 && "$TEST_MODE" != 1 ]]; then
  systemctl enable --now "$SBM_SERVICE" sb-core-update.timer sb-acme-renew.timer
  systemctl is-active --quiet "$SBM_SERVICE" || { journalctl -u "$SBM_SERVICE" -n 60 --no-pager >&2 || true; exit 1; }
  tunnel_reconcile 1 || true
else
  tunnel_reconcile 0 || true
fi

printf '\n安装完成。\n'
printf '  面板命令：sb\n'
printf '  状态检查：sb status\n'
printf '  诊断命令：sb doctor\n'
printf '  数据目录：%s\n' "$SBM_ETC"
printf '\n注意：脚本不会关闭防火墙，也不会自动开放直连协议端口。\n'

if [[ "$NO_MENU" == 0 && -t 0 ]]; then "$SBM_BIN_DIR/sb"; fi
