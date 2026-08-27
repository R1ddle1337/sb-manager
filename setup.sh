#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_LIB=${SBM_LIB:-/usr/local/lib/sb-manager}
TARGET_BIN=${SBM_BIN_DIR:-/usr/local/bin}
PROGRAM_BACKUP_ROOT=${SBM_BACKUPS:-${SBM_VAR:-/var/lib/sb-manager}/backups}
NO_MENU=0
NO_START=0
CORE_VERSION=$(tr -d '[:space:]' <"$SRC_DIR/TESTED_CORE_VERSION" 2>/dev/null || true)
CORE_VERSION=${CORE_VERSION:-latest}
TEST_MODE=${SBM_TEST_MODE:-0}

usage() {
  cat <<'EOF_USAGE'
用法：sudo ./setup.sh [选项]
  --no-menu             安装后不打开交互面板
  --no-start            不启动/启用 systemd 或 OpenRC 服务和定时任务
  --core-version VER    安装指定 sing-box 版本（默认 latest）
  -h, --help            帮助
EOF_USAGE
}
while (($#)); do
  case "$1" in
    --no-menu) NO_MENU=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --core-version) CORE_VERSION=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

[[ "$TEST_MODE" == 1 || ${EUID:-$(id -u)} -eq 0 ]] || { echo '请使用 root/sudo 运行。' >&2; exit 1; }

install_dependencies() {
  local packages=(curl ca-certificates jq openssl tar gzip coreutils util-linux procps findutils)
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash "${packages[@]}" iproute2 shadow openrc dcron libcap musl-utils gcompat
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "${packages[@]}" iproute2 passwd libcap2-bin
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}" iproute shadow-utils libcap
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${packages[@]}" iproute shadow-utils libcap
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed "${packages[@]}" iproute2 shadow libcap
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${packages[@]}" iproute2 shadow libcap-progs
  else
    echo '不支持的包管理器。当前支持 apk、apt、dnf、yum、pacman、zypper。' >&2
    exit 1
  fi
}

create_service_account() {
  [[ "$TEST_MODE" == 1 ]] && return 0
  if ! group_exists "$SBM_SERVICE_USER"; then
    if command_exists groupadd; then groupadd --system "$SBM_SERVICE_USER"
    elif command_exists addgroup; then addgroup -S "$SBM_SERVICE_USER"
    else die '缺少 groupadd/addgroup，无法创建服务组。'; fi
  fi
  if ! id "$SBM_SERVICE_USER" >/dev/null 2>&1; then
    local nologin
    nologin=$(command -v nologin || true); nologin=${nologin:-/sbin/nologin}
    if command_exists useradd; then
      useradd --system --gid "$SBM_SERVICE_USER" --home-dir "$SBM_VAR" --create-home --shell "$nologin" "$SBM_SERVICE_USER"
    elif command_exists adduser; then
      adduser -S -D -h "$SBM_VAR" -s "$nologin" -G "$SBM_SERVICE_USER" "$SBM_SERVICE_USER"
    else
      die '缺少 useradd/adduser，无法创建服务用户。'
    fi
  elif [[ $(id -gn "$SBM_SERVICE_USER") != "$SBM_SERVICE_USER" ]]; then
    if command_exists usermod; then usermod --gid "$SBM_SERVICE_USER" "$SBM_SERVICE_USER"
    elif command_exists addgroup; then addgroup "$SBM_SERVICE_USER" "$SBM_SERVICE_USER"
    else die "无法把 $SBM_SERVICE_USER 加入同名服务组。"; fi
  fi
}

write_systemd_runtime() {
  mkdir -p "$SBM_SYSTEMD_DIR"
  cat >"$SBM_SYSTEMD_DIR/$SBM_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager managed sing-box service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
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
}

write_periodic_job() {
  local schedule=$1 name=$2 command=$3 path
  path="$SBM_PERIODIC_DIR/$schedule/$name"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF_JOB
#!/bin/sh
exec $command >/dev/null 2>&1
EOF_JOB
  chmod 0755 "$path"
}

write_openrc_runtime() {
  mkdir -p "$SBM_OPENRC_DIR" "$SBM_LOG_DIR"
  write_openrc_supervised_service \
    "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SERVICE")" \
    'sb-manager sing-box' 'sb-manager managed sing-box service' \
    "$SBM_SING_BOX_BIN" "run -c $SBM_CONFIG" "$SBM_SERVICE_USER" \
    "$SBM_SINGBOX_LOG" "$SBM_SINGBOX_ERROR_LOG" 'after firewall'
  write_periodic_job daily sb-core-update "$SBM_BIN_DIR/sb core auto"
  write_periodic_job daily sb-acme-renew "$SBM_BIN_DIR/sb cert renew --quiet"
}

scheduler_reconcile() {
  [[ "$NO_START" == 0 && "$TEST_MODE" != 1 ]] || return 0
  case "$(init_system)" in
    systemd)
      systemctl enable --now sb-core-update.timer sb-acme-renew.timer
      ;;
    openrc)
      if service_exists crond; then
        service_enable crond || true
        service_active crond || service_start crond || log_warn '无法启动 crond；自动更新和证书续期定时任务不会运行。'
      else
        log_warn '未发现 crond OpenRC 服务；自动更新和证书续期定时任务不会运行。'
      fi
      ;;
  esac
}

printf '[1/7] 安装依赖…\n'
[[ "$TEST_MODE" == 1 ]] || install_dependencies

printf '[2/7] 安装程序文件…\n'
mkdir -p "$TARGET_LIB" "$TARGET_BIN"
chmod 0755 "$(dirname "$TARGET_LIB")" "$TARGET_LIB" "$TARGET_BIN"
src_real=$(readlink -f "$SRC_DIR")
target_real=$(readlink -m "$TARGET_LIB")
if [[ "$src_real" != "$target_real" ]]; then
  if [[ -f "$TARGET_LIB/sb" ]]; then
    backup="$PROGRAM_BACKUP_ROOT/program-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup"
    cp -a "$TARGET_LIB" "$backup/" || true
  fi
  find "$TARGET_LIB" -mindepth 1 -maxdepth 1 ! -name cores -exec rm -rf {} + 2>/dev/null || true
  cp -a "$SRC_DIR"/. "$TARGET_LIB"/
  rm -rf "$TARGET_LIB/.git"
else
  printf '      检测到从已安装目录执行，跳过自覆盖复制。\n'
fi
find "$TARGET_LIB/lib" "$TARGET_LIB/protocols" -type d -exec chmod 0755 {} +
chmod 0755 "$TARGET_LIB" "$TARGET_LIB/sb" "$TARGET_LIB/setup.sh" "$TARGET_LIB/install.sh" "$TARGET_LIB/build-standalone.sh" "$TARGET_LIB/lib/"*.sh "$TARGET_LIB/protocols/"*.sh
ln -sfn "$TARGET_LIB/sb" "$TARGET_BIN/sb"

# shellcheck source=lib/common.sh
source "$TARGET_LIB/lib/common.sh"
source "$TARGET_LIB/lib/service.sh"
source "$TARGET_LIB/lib/state.sh"
source "$TARGET_LIB/protocols/vmess_ws_cf.sh"
source "$TARGET_LIB/protocols/shadowsocks.sh"
source "$TARGET_LIB/protocols/anytls.sh"
source "$TARGET_LIB/protocols/hysteria2.sh"
source "$TARGET_LIB/lib/render.sh"
source "$TARGET_LIB/lib/core.sh"
source "$TARGET_LIB/lib/tunnel.sh"

if [[ "$TEST_MODE" != 1 ]]; then require_init_system; fi
BACKEND=$(init_system 2>/dev/null || true)
[[ "$BACKEND" != none && -n "$BACKEND" ]] || BACKEND=${SBM_TEST_INIT_BACKEND:-systemd}

printf '[3/7] 创建低权限服务用户和数据目录…\n'
create_service_account
state_init
mkdir -p "$SBM_VAR/cloudflared-home" "$SBM_LOG_DIR"
chown root:"$SBM_SERVICE_USER" "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" 2>/dev/null || true
chown root:"$SBM_SERVICE_USER" "$SBM_VAR" 2>/dev/null || true
chown root:root "$SBM_RUN" 2>/dev/null || true
chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/cloudflared-home" "$SBM_LOG_DIR" 2>/dev/null || true
chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR" "$SBM_VAR/cloudflared-home" "$SBM_LOG_DIR"
chown root:"$SBM_SERVICE_USER" "$SBM_SECRETS" 2>/dev/null || true
chmod 0710 "$SBM_SECRETS"
chmod 0700 "$SBM_SECRETS/nodes"

printf '[4/7] 安装 sing-box 核心…\n'
if [[ "$TEST_MODE" == 1 ]]; then
  test_version_output=$(${SBM_TEST_SING_BOX:?} version)
  test_version=$(extract_semver "$test_version_output") || die '无法识别测试 sing-box 核心版本。'
  mkdir -p "$SBM_CORE_DIR/sing-box/$test_version"
  install -m 0755 "$SBM_TEST_SING_BOX" "$SBM_CORE_DIR/sing-box/$test_version/sing-box"
  sb_binary="$SBM_CORE_DIR/sing-box/$test_version/sing-box"
else
  sb_binary=$(core_download_version "$CORE_VERSION")
fi
validate_runtime_binary_path sing-box "$sb_binary"
ensure_program_permissions
prepare_singbox_binary_for_backend "$sb_binary" "$BACKEND"
ln -sfn "$sb_binary" "$SBM_SING_BOX_BIN.new"; mv -Tf "$SBM_SING_BOX_BIN.new" "$SBM_SING_BOX_BIN"
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" "$BACKEND"

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
validate_runtime_binary_path cloudflared "$cf_binary"
ensure_program_permissions
ln -sfn "$cf_binary" "$SBM_CLOUDFLARED_BIN.new"; mv -Tf "$SBM_CLOUDFLARED_BIN.new" "$SBM_CLOUDFLARED_BIN"
ensure_program_permissions

printf '[6/7] 生成配置与 %s 服务…\n' "$BACKEND"
render_current_config
if [[ "$TEST_MODE" != 1 ]] && service_exists "$SBM_SERVICE"; then
  # Stop a stale restart loop before replacing the service definition. The
  # final reconcile below restores the correct state based on enabled nodes.
  service_stop "$SBM_SERVICE"
  service_reset_failed "$SBM_SERVICE"
fi
case "$BACKEND" in
  systemd) write_systemd_runtime ;;
  openrc) write_openrc_runtime ;;
  *) die "无法生成未知服务后端：$BACKEND" ;;
esac

if [[ "$TEST_MODE" != 1 ]]; then
  service_reload_manager
  service_reset_failed "$SBM_SERVICE"
  if ! service_user_can_execute_core; then
    log_error "$SBM_SERVICE_USER 无法执行 sing-box 核心。"
    runtime_exec_diagnostics "$SBM_SING_BOX_BIN"
    exit 1
  fi
  if ! service_user_can_read_config; then
    log_error "$SBM_SERVICE_USER 无法读取生成配置。"
    command -v namei >/dev/null 2>&1 && namei -l "$SBM_CONFIG" >&2 || true
    exit 1
  fi
  if [[ "$BACKEND" == systemd && "$NO_START" == 0 ]]; then
    preflight_rc=0
    systemd_exec_preflight "$SBM_SING_BOX_BIN" || preflight_rc=$?
    case "$preflight_rc" in
      0) ;;
      2) log_warn 'systemd-run 不可用，跳过沙箱执行预检。' ;;
      *) runtime_exec_diagnostics "$SBM_SING_BOX_BIN"; exit 1 ;;
    esac
    runtime_preflight_rc=0
    systemd_runtime_preflight "$SBM_SING_BOX_BIN" "$SBM_CONFIG" || runtime_preflight_rc=$?
    case "$runtime_preflight_rc" in
      0) ;;
      2) log_warn 'systemd-run 不可用，跳过实际启动预检。' ;;
      *) runtime_exec_diagnostics "$SBM_SING_BOX_BIN"; exit 1 ;;
    esac
  fi
fi

printf '[7/7] 启动服务…\n'
if [[ "$NO_START" == 0 && "$TEST_MODE" != 1 ]]; then
  scheduler_reconcile
  if ! singbox_service_reconcile; then
    runtime_exec_diagnostics "$SBM_SING_BOX_BIN"
    exit 1
  fi
  tunnel_reconcile 1 || true
else
  tunnel_reconcile 0 || true
fi

printf '\n安装完成。\n'
printf '  服务管理：%s\n' "$BACKEND"
printf '  面板命令：sb\n'
printf '  状态检查：sb status\n'
printf '  诊断命令：sb doctor（自动修复：sb doctor --repair）\n'
printf '  数据目录：%s\n' "$SBM_ETC"
if (( $(state_enabled_count) == 0 )); then
  printf '  sing-box：暂无启用节点，服务保持待命；添加首个节点后会自动启动。\n'
fi
printf '\n注意：脚本不会关闭防火墙，也不会自动开放直连协议端口。\n'

if [[ "$NO_MENU" == 0 && -t 0 ]]; then "$SBM_BIN_DIR/sb"; fi
