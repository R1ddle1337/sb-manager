#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_LIB=${SBM_LIB:-/usr/local/lib/sb-manager}
TARGET_BIN=${SBM_BIN_DIR:-/usr/local/bin}
SETUP_SYSTEMD_DIR=${SBM_SYSTEMD_DIR:-/etc/systemd/system}
SETUP_OPENRC_DIR=${SBM_OPENRC_DIR:-/etc/init.d}
SETUP_PERIODIC_DIR=${SBM_PERIODIC_DIR:-/etc/periodic}
PROGRAM_BACKUP_ROOT=${SBM_BACKUPS:-${SBM_VAR:-/var/lib/sb-manager}/backups}
NO_MENU=0
NO_START=0
CORE_VERSION=latest
INSTALL_PROFILE=${SBM_INSTALL_PROFILE:-minimal}
INSTALL_CLOUDFLARED=${SBM_INSTALL_CLOUDFLARED:-0}
TEST_MODE=${SBM_TEST_MODE:-0}
SETUP_MUTATED=0
SETUP_ROLLBACK_DIR=''

# Load only the small dependency policy before the source tree is copied.  It
# is loaded again from TARGET_LIB below so an upgrade uses the installed code.
# shellcheck source=lib/common.sh
source "$SRC_DIR/lib/common.sh"
# shellcheck source=lib/dependencies.sh
source "$SRC_DIR/lib/dependencies.sh"

setup_rollback_on_error() {
  local rc=$?
  trap - ERR
  set +e
  if [[ "$SETUP_MUTATED" == 1 && -n "$SETUP_ROLLBACK_DIR" && -d "$SETUP_ROLLBACK_DIR/program" ]]; then
    printf '[ROLLBACK] 安装失败，正在恢复上一版程序和服务定义…\n' >&2
    find "$TARGET_LIB" -mindepth 1 -maxdepth 1 ! -name cores -exec rm -rf {} +
    cp -a "$SETUP_ROLLBACK_DIR/program"/. "$TARGET_LIB"/
    rm -f "$SETUP_SYSTEMD_DIR/sb-sing-box.service" "$SETUP_SYSTEMD_DIR/sb-cloudflared.service" "$SETUP_SYSTEMD_DIR/sb-nginx-stream.service" \
      "$SETUP_SYSTEMD_DIR/sb-core-update.service" "$SETUP_SYSTEMD_DIR/sb-core-update.timer" \
      "$SETUP_SYSTEMD_DIR/sb-acme-renew.service" "$SETUP_SYSTEMD_DIR/sb-acme-renew.timer" \
      "$SETUP_SYSTEMD_DIR/sb-quick-tunnel-refresh.service" "$SETUP_SYSTEMD_DIR/sb-quick-tunnel-refresh.timer" \
      "$SETUP_SYSTEMD_DIR/sb-subscription.service" "$SETUP_SYSTEMD_DIR/sb-traffic.service" \
      "$SETUP_SYSTEMD_DIR/sb-traffic-sync.service" "$SETUP_SYSTEMD_DIR/sb-traffic-sync.timer" \
      "$SETUP_SYSTEMD_DIR/sb-health-check.service" "$SETUP_SYSTEMD_DIR/sb-health-check.timer"
    [[ ! -d "$SETUP_ROLLBACK_DIR/systemd" ]] || cp -a "$SETUP_ROLLBACK_DIR/systemd"/. "$SETUP_SYSTEMD_DIR"/
    rm -f "$SETUP_OPENRC_DIR/sb-sing-box" "$SETUP_OPENRC_DIR/sb-cloudflared" "$SETUP_OPENRC_DIR/sb-nginx-stream" "$SETUP_OPENRC_DIR/sb-subscription" "$SETUP_OPENRC_DIR/sb-traffic"
    [[ ! -d "$SETUP_ROLLBACK_DIR/openrc" ]] || cp -a "$SETUP_ROLLBACK_DIR/openrc"/. "$SETUP_OPENRC_DIR"/
    rm -f "$SETUP_PERIODIC_DIR/15min/sb-health-check"
    if [[ -f "$SETUP_ROLLBACK_DIR/periodic/sb-health-check" ]]; then
      mkdir -p "$SETUP_PERIODIC_DIR/15min"
      cp -a "$SETUP_ROLLBACK_DIR/periodic/sb-health-check" "$SETUP_PERIODIC_DIR/15min/sb-health-check"
    fi
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

setup_fail_if_requested() {
  if [[ ${SBM_TEST_FAIL_STEP:-} == "$1" ]]; then
    printf '测试注入：安装步骤 %s 失败。\n' "$1" >&2
    return 97
  fi
}

prune_runtime_payload() {
  # Documentation, tests and release-only assets are useful in the checkout
  # but never needed by the installed CLI.  Keeping them out of /usr/local is
  # noticeable on small disks and does not touch the source tree when setup is
  # run in-place.
  rm -rf \
    "$TARGET_LIB/.git" "$TARGET_LIB/.github" "$TARGET_LIB/tests" \
    "$TARGET_LIB/docs" "$TARGET_LIB/sing-box-official-docs-cn" \
    "$TARGET_LIB"/sing-box-official-docs-cn-*.zip \
    "$TARGET_LIB/libexec/__pycache__"
  rm -f "$TARGET_LIB/AGENTS.md" "$TARGET_LIB/README.md" "$TARGET_LIB/CHANGELOG.md"
}

prune_setup_backups() {
  local keep=${SBM_PROGRAM_BACKUP_RETENTION:-2} i
  local -a backups=()
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
  [[ -d "$PROGRAM_BACKUP_ROOT" ]] || return 0
  while IFS= read -r path; do [[ -n "$path" ]] && backups+=("$path"); done < <(
    find "$PROGRAM_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'program-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{sub(/^[^ ]+ /, ""); print}'
  )
  for ((i=keep; i<${#backups[@]}; i++)); do rm -rf -- "${backups[$i]}"; done
}

usage() {
  cat <<'EOF_USAGE'
用法：sudo ./setup.sh [选项]
  --no-menu             安装后不打开交互面板
  --no-start            不启动/启用 systemd 或 OpenRC 服务和定时任务
  --core-version VER    安装指定 sing-box 版本（默认 latest）
  --profile PROFILE     安装依赖档位：minimal（默认）或 full
  --full                --profile full 的快捷方式（会预装高级功能依赖）
  --with-cloudflared    同时安装可选的 Cloudflare Tunnel 客户端
  -h, --help            帮助
EOF_USAGE
}
while (($#)); do
  case "$1" in
    --no-menu) NO_MENU=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --core-version) CORE_VERSION=${2:?}; shift 2 ;;
    --profile) INSTALL_PROFILE=${2:?}; shift 2 ;;
    --full) INSTALL_PROFILE=full; shift ;;
    --with-cloudflared) INSTALL_CLOUDFLARED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 1 ;;
  esac
done

case "$INSTALL_PROFILE" in
  minimal|full) ;;
  *) echo '安装依赖档位只能是 minimal 或 full。' >&2; exit 1 ;;
esac
case "$INSTALL_CLOUDFLARED" in
  0|1) ;;
  *) echo 'SBM_INSTALL_CLOUDFLARED 只能是 0 或 1。' >&2; exit 1 ;;
esac

[[ "$TEST_MODE" == 1 || ${EUID:-$(id -u)} -eq 0 ]] || { echo '请使用 root/sudo 运行。' >&2; exit 1; }

install_dependencies() { dependency_install_base "$INSTALL_PROFILE"; }

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
TasksMax=1024
MemoryAccounting=true
TasksAccounting=true
UMask=0027
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
ReadWritePaths=$SBM_VAR/dashboard

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

  cat >"$SBM_SYSTEMD_DIR/$SBM_TRAFFIC_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager traffic control lifecycle
After=network-pre.target nftables.service ufw.service firewalld.service
Before=$SBM_SERVICE

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SBM_BIN_DIR/sb traffic reconcile
ExecStop=$SBM_BIN_DIR/sb traffic sync

[Install]
WantedBy=multi-user.target
EOF_UNIT
  cat >"$SBM_SYSTEMD_DIR/sb-traffic-sync.service" <<EOF_UNIT
[Unit]
Description=Checkpoint and maintain sb-manager traffic counters
After=$SBM_TRAFFIC_SERVICE

[Service]
Type=oneshot
ExecStart=$SBM_BIN_DIR/sb traffic tick
EOF_UNIT
  cat >"$SBM_SYSTEMD_DIR/sb-traffic-sync.timer" <<'EOF_UNIT'
[Unit]
Description=Periodic sb-manager traffic counter checkpoint

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_UNIT
  cat >"$SBM_SYSTEMD_DIR/$SBM_HEALTH_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager periodic health check and notification
After=network-online.target $SBM_SERVICE $SBM_TRAFFIC_SERVICE
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SBM_BIN_DIR/sb health tick
EOF_UNIT
  cat >"$SBM_SYSTEMD_DIR/sb-health-check.timer" <<'EOF_UNIT'
[Unit]
Description=Periodic sb-manager health check

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
RandomizedDelaySec=2min
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
  write_periodic_job 15min sb-traffic-sync "$SBM_BIN_DIR/sb traffic tick"
  write_periodic_job 15min sb-health-check "$SBM_BIN_DIR/sb health tick"
  cat >"$SBM_OPENRC_DIR/$(service_native_name "$SBM_TRAFFIC_SERVICE")" <<EOF_OPENRC
#!/sbin/openrc-run
name="sb-manager traffic control"
description="Restore and checkpoint sb-manager nftables traffic rules"

depend() {
  need localmount
  after firewall
  before sb-sing-box
}

start() {
  ebegin "Applying sb-manager traffic controls"
  "$SBM_BIN_DIR/sb" traffic reconcile
  eend \$?
}

stop() {
  ebegin "Checkpointing sb-manager traffic counters"
  "$SBM_BIN_DIR/sb" traffic sync
  eend \$?
}
EOF_OPENRC
  chmod 0755 "$SBM_OPENRC_DIR/$(service_native_name "$SBM_TRAFFIC_SERVICE")"
  mkdir -p "$(dirname "$SBM_LOGROTATE_FILE")"
  cat >"$SBM_LOGROTATE_FILE" <<EOF_LOGROTATE
$SBM_LOG_DIR/*.log {
  weekly
  rotate 8
  size 10M
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  su $SBM_SERVICE_USER $SBM_SERVICE_USER
}
EOF_LOGROTATE
  chmod 0644 "$SBM_LOGROTATE_FILE"
}

scheduler_reconcile() {
  [[ "$NO_START" == 0 && "$TEST_MODE" != 1 ]] || return 0
  case "$(init_system)" in
    systemd)
      systemctl enable --now sb-core-update.timer sb-acme-renew.timer sb-traffic-sync.timer sb-health-check.timer "$SBM_TRAFFIC_SERVICE"
      ;;
    openrc)
      service_enable "$SBM_TRAFFIC_SERVICE"
      service_active "$SBM_TRAFFIC_SERVICE" || service_start "$SBM_TRAFFIC_SERVICE"
      if service_exists crond; then
        service_enable crond || true
        service_active crond || service_start crond || log_warn '无法启动 crond；自动更新和证书续期定时任务不会运行。'
      else
        log_info '未安装 dcron；已保留 periodic 任务，需自动更新/续期时运行 sb deps install scheduler。'
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
    mkdir -p "$PROGRAM_BACKUP_ROOT"
    backup=$(mktemp -d "$PROGRAM_BACKUP_ROOT/program-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    SETUP_ROLLBACK_DIR="$backup"
    mkdir -p "$backup/program" "$backup/systemd" "$backup/openrc" "$backup/periodic"
    cp -a "$TARGET_LIB"/. "$backup/program/"
    rm -rf "$backup/program/cores"
    for path in "$SETUP_SYSTEMD_DIR"/sb-*.service "$SETUP_SYSTEMD_DIR"/sb-*.timer; do [[ ! -f "$path" ]] || cp -a "$path" "$backup/systemd/"; done
    for path in "$SETUP_OPENRC_DIR"/sb-*; do [[ ! -f "$path" ]] || cp -a "$path" "$backup/openrc/"; done
    [[ ! -f "$SETUP_PERIODIC_DIR/15min/sb-health-check" ]] || cp -a "$SETUP_PERIODIC_DIR/15min/sb-health-check" "$backup/periodic/"
    SETUP_MUTATED=1
    trap setup_rollback_on_error ERR
  fi
  find "$TARGET_LIB" -mindepth 1 -maxdepth 1 ! -name cores -exec rm -rf {} + 2>/dev/null || true
  cp -a "$SRC_DIR"/. "$TARGET_LIB"/
  prune_runtime_payload
else
  printf '      检测到从已安装目录执行，跳过自覆盖复制。\n'
fi
setup_fail_if_requested 2
find "$TARGET_LIB/lib" "$TARGET_LIB/protocols" -type d -exec chmod 0755 {} +
[[ ! -d "$TARGET_LIB/libexec" ]] || find "$TARGET_LIB/libexec" -type d -exec chmod 0755 {} +
chmod 0755 "$TARGET_LIB" "$TARGET_LIB/sb" "$TARGET_LIB/setup.sh" "$TARGET_LIB/install.sh" "$TARGET_LIB/build-standalone.sh" "$TARGET_LIB/build-release.sh" "$TARGET_LIB/lib/"*.sh "$TARGET_LIB/protocols/"*.sh
[[ ! -f "$TARGET_LIB/libexec/subscription_server.py" ]] || chmod 0755 "$TARGET_LIB/libexec/subscription_server.py"
ln -sfn "$TARGET_LIB/sb" "$TARGET_BIN/sb"

# shellcheck source=lib/common.sh
source "$TARGET_LIB/lib/common.sh"
source "$TARGET_LIB/lib/dependencies.sh"
source "$TARGET_LIB/lib/service.sh"
source "$TARGET_LIB/lib/state.sh"
source "$TARGET_LIB/lib/nginx_stream.sh"
source "$TARGET_LIB/protocols/vmess_ws_cf.sh"
source "$TARGET_LIB/protocols/shadowsocks.sh"
source "$TARGET_LIB/protocols/anytls.sh"
source "$TARGET_LIB/protocols/hysteria2.sh"
source "$TARGET_LIB/protocols/trojan.sh"
source "$TARGET_LIB/protocols/tuic.sh"
source "$TARGET_LIB/protocols/vless.sh"
source "$TARGET_LIB/protocols/naive.sh"
source "$TARGET_LIB/protocols/shadowtls.sh"
source "$TARGET_LIB/protocols/snell.sh"
source "$TARGET_LIB/lib/render.sh"
source "$TARGET_LIB/lib/traffic.sh"
source "$TARGET_LIB/lib/notification.sh"
source "$TARGET_LIB/lib/health.sh"
source "$TARGET_LIB/lib/status.sh"
source "$TARGET_LIB/lib/config.sh"
source "$TARGET_LIB/lib/template.sh"
source "$TARGET_LIB/lib/core.sh"
source "$TARGET_LIB/lib/tunnel.sh"
source "$TARGET_LIB/lib/subscription.sh"
source "$TARGET_LIB/lib/api.sh"
source "$TARGET_LIB/lib/realm.sh"
source "$TARGET_LIB/lib/bbr.sh"
source "$TARGET_LIB/lib/hysteria2_tuning.sh"

if [[ "$TEST_MODE" != 1 ]]; then require_init_system; fi
BACKEND=$(init_system 2>/dev/null || true)
[[ "$BACKEND" != none && -n "$BACKEND" ]] || BACKEND=${SBM_TEST_INIT_BACKEND:-systemd}

printf '[3/7] 创建低权限服务用户和数据目录…\n'
create_service_account
state_init
mkdir -p "$SBM_VAR/dashboard" "$SBM_LOG_DIR"
if [[ "$INSTALL_CLOUDFLARED" == 1 || -x "$SBM_CLOUDFLARED_BIN" || $(jq -r '.tunnel.mode // "none"' "$SBM_STATE") != none ]]; then
  mkdir -p "$SBM_VAR/cloudflared-home"
fi
chown root:"$SBM_SERVICE_USER" "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" 2>/dev/null || true
chown root:"$SBM_SERVICE_USER" "$SBM_VAR" 2>/dev/null || true
chown root:root "$SBM_RUN" 2>/dev/null || true
chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/dashboard" "$SBM_LOG_DIR" 2>/dev/null || true
[[ ! -d "$SBM_VAR/cloudflared-home" ]] || chown "$SBM_SERVICE_USER":"$SBM_SERVICE_USER" "$SBM_VAR/cloudflared-home" 2>/dev/null || true
chmod 0750 "$SBM_ETC" "$SBM_GENERATED_DIR" "$SBM_CERTS" "$SBM_VAR" "$SBM_VAR/dashboard" "$SBM_LOG_DIR"
[[ ! -d "$SBM_VAR/cloudflared-home" ]] || chmod 0750 "$SBM_VAR/cloudflared-home"
chown root:"$SBM_SERVICE_USER" "$SBM_SECRETS" 2>/dev/null || true
chmod 0710 "$SBM_SECRETS"
chmod 0700 "$SBM_SECRETS/nodes"

printf '[4/7] 安装 sing-box 核心…\n'
current_core_version=$(core_current_version || true)
if [[ "$TEST_MODE" == 1 ]]; then
  test_version_output=$(${SBM_TEST_SING_BOX:?} version)
  test_version=$(extract_semver "$test_version_output") || die '无法识别测试 sing-box 核心版本。'
  mkdir -p "$SBM_CORE_DIR/sing-box/$test_version"
  install -m 0755 "$SBM_TEST_SING_BOX" "$SBM_CORE_DIR/sing-box/$test_version/sing-box"
  if [[ -f "$(dirname "$SBM_TEST_SING_BOX")/libcronet.so" ]]; then
    install -m 0755 "$(dirname "$SBM_TEST_SING_BOX")/libcronet.so" "$SBM_CORE_DIR/sing-box/$test_version/libcronet.so"
  fi
  sb_binary="$SBM_CORE_DIR/sing-box/$test_version/sing-box"
else
  if [[ "$CORE_VERSION" == latest ]]; then
    CORE_VERSION=$(core_latest_version) || die '无法查询 sing-box 最新官方版本。'
    if [[ -n "$current_core_version" && "$current_core_version" != "$CORE_VERSION" ]] && version_ge "$current_core_version" "$CORE_VERSION"; then
      log_warn "解析到的目标核心 $CORE_VERSION 不高于当前 $current_core_version，保留现有核心以避免意外降级。"
      CORE_VERSION=$current_core_version
    fi
  fi
  sb_binary=$(core_download_version "$CORE_VERSION")
fi
validate_runtime_binary_path sing-box "$sb_binary"
ensure_program_permissions
prepare_singbox_binary_for_backend "$sb_binary" "$BACKEND"
ln -sfn "$sb_binary" "$SBM_SING_BOX_BIN.new"; mv -Tf "$SBM_SING_BOX_BIN.new" "$SBM_SING_BOX_BIN"
prepare_singbox_binary_for_backend "$SBM_SING_BOX_BIN" "$BACKEND"
core_prune_cached_versions

if [[ "$INSTALL_CLOUDFLARED" == 1 ]]; then
  printf '[5/7] 安装可选 cloudflared…\n'
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
elif [[ -x "$SBM_CLOUDFLARED_BIN" ]]; then
  printf '[5/7] 保留现有 cloudflared（可用 --with-cloudflared 更新）…\n'
  validate_runtime_binary_path cloudflared "$SBM_CLOUDFLARED_BIN"
else
  printf '[5/7] 跳过 cloudflared（按需执行：sb cloudflared install）…\n'
fi

printf '[6/7] 生成配置与 %s 服务…\n' "$BACKEND"
render_current_config
if [[ "$TEST_MODE" != 1 ]]; then
  # Stop a stale restart loop before replacing the service definition. The
  # final reconcile below restores the correct state based on enabled nodes.
  if service_exists "$SBM_NGINX_STREAM_SERVICE"; then service_stop "$SBM_NGINX_STREAM_SERVICE"; fi
  if service_exists "$SBM_TUNNEL_SERVICE"; then service_stop "$SBM_TUNNEL_SERVICE"; fi
  if service_exists "$SBM_SERVICE"; then
    service_stop "$SBM_SERVICE"
    service_reset_failed "$SBM_SERVICE"
  fi
fi
case "$BACKEND" in
  systemd) write_systemd_runtime ;;
  openrc) write_openrc_runtime ;;
  *) die "无法生成未知服务后端：$BACKEND" ;;
esac
setup_fail_if_requested 6

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
  if ! nginx_stream_reconcile; then
    runtime_exec_diagnostics "$SBM_SING_BOX_BIN"
    exit 1
  fi
  if ! traffic_reconcile; then
    log_error '流量控制规则协调失败。'
    exit 1
  fi
  tunnel_reconcile 1 || true
  subscription_reconcile 1 || log_warn '订阅服务协调失败；不会影响代理数据面。'
else
  tunnel_reconcile 0 || true
  subscription_reconcile 0 || true
fi
if [[ -x "$SBM_CLOUDFLARED_BIN" ]] && declare -F cloudflared_prune_cached_versions >/dev/null 2>&1; then
  cloudflared_prune_cached_versions
fi
prune_setup_backups

printf '\n安装完成。\n'
printf '  服务管理：%s\n' "$BACKEND"
printf '  安装档位：%s\n' "$INSTALL_PROFILE"
printf '  面板命令：sb\n'
printf '  状态检查：sb status\n'
printf '  诊断命令：sb doctor（自动修复：sb doctor --repair）\n'
printf '  数据目录：%s\n' "$SBM_ETC"
if ! state_runtime_required; then
  printf '  sing-box：暂无启用节点，服务保持待命；添加首个节点后会自动启动。\n'
fi
if [[ ! -x "$SBM_CLOUDFLARED_BIN" ]]; then
  printf '  cloudflared：未安装（Tunnel 功能启用前执行 sb cloudflared install）。\n'
fi
printf '\n注意：脚本不会关闭防火墙，也不会自动开放直连协议端口。\n'

trap - ERR
if [[ "$NO_MENU" == 0 && -t 0 ]]; then "$SBM_BIN_DIR/sb"; fi
