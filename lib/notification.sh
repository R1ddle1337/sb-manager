#!/usr/bin/env bash
# shellcheck shell=bash

notification_thresholds_json() {
  local value=${1:-80,90,100}
  jq -cen --arg value "$value" '
    ($value | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $parts
    | if ($parts | length) == 0 or any($parts[]; test("^[0-9]+$") | not) then error("invalid") else $parts end
    | map(tonumber)
    | if any(.[]; . < 1 or . > 100) then error("range") else unique | sort end
  ' 2>/dev/null
}

notification_write_secret() {
  local json=$1 tmp
  mkdir -p "$SBM_SECRETS"
  tmp=$(mktemp "$SBM_SECRETS/.notifications.XXXXXX")
  printf '%s\n' "$json" | jq . >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$SBM_NOTIFICATION_SECRET"
}

_notification_configure() {
  local provider=$1 secret=$2 destination=${3:-} thresholds=${4:-80,90,100} secret_json thresholds_json candidate
  thresholds_json=$(notification_thresholds_json "$thresholds") || die '通知阈值必须是 1-100 的逗号分隔整数，例如 80,90,100。'
  [[ -n "$secret" ]] || die '通知凭据不能为空。'
  case "$provider" in
    telegram)
      [[ -n "$destination" ]] || die 'Telegram chat ID 不能为空。'
      secret_json=$(jq -n --arg provider "$provider" --arg token "$secret" --arg chat_id "$destination" \
        '{provider:$provider,bot_token:$token,chat_id:$chat_id}')
      ;;
    wecom|webhook)
      [[ "$secret" == https://* || "$secret" == http://127.0.0.1:* || "$secret" == http://localhost:* ]] \
        || die 'Webhook URL 必须使用 HTTPS（仅本机测试允许 HTTP）。'
      secret_json=$(jq -n --arg provider "$provider" --arg url "$secret" '{provider:$provider,webhook_url:$url}')
      ;;
    *) die '通知类型必须是 telegram、wecom 或 webhook。' ;;
  esac
  notification_write_secret "$secret_json"
  candidate=$(state_candidate)
  jq --arg provider "$provider" --argjson thresholds "$thresholds_json" '
    .notifications.enabled=true
    | .notifications.provider=$provider
    | .notifications.traffic_thresholds=$thresholds
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" notification-configure; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "通知已启用：$provider；流量阈值 $(jq -r 'join("% / ")' <<<"$thresholds_json")%。"
}

notification_configure() { with_state_transaction notification-configure _notification_configure "$@"; }

notification_configure_cli() {
  local provider=$1; shift
  local credential='' credential_file='' destination='' thresholds='80,90,100'
  while (($#)); do
    case "$1" in
      --token-file|--url-file|--secret-file) credential_file=${2:?缺少凭据文件}; shift 2 ;;
      --chat-id) destination=${2:?缺少 chat ID}; shift 2 ;;
      --thresholds) thresholds=${2:?缺少阈值}; shift 2 ;;
      *) die '用法：sb notify configure telegram --token-file FILE --chat-id ID [--thresholds 80,90,100]；或 wecom|webhook --url-file FILE' ;;
    esac
  done
  if [[ -n "$credential_file" ]]; then
    [[ -r "$credential_file" ]] || die "通知凭据文件不可读：$credential_file"
    credential=$(tr -d '\r\n' <"$credential_file")
  elif [[ -t 0 ]]; then
    if [[ "$provider" == telegram ]]; then prompt_secret credential 'Telegram Bot Token'; else prompt_secret credential 'Webhook URL'; fi
  else
    die '非交互配置必须使用 --token-file、--url-file 或 --secret-file 提供凭据。'
  fi
  if [[ "$provider" == telegram && -z "$destination" && -t 0 ]]; then prompt_value destination 'Telegram Chat ID' ''; fi
  notification_configure "$provider" "$credential" "$destination" "$thresholds"
}

_notification_disable() {
  local candidate
  candidate=$(state_candidate)
  jq '.notifications.enabled=false' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" notification-disable; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok '通知已停用；受保护的凭据文件予以保留。'
}
notification_disable() { with_state_transaction notification-disable _notification_disable; }

notification_status_json() {
  local secret_ready=false
  [[ -s "$SBM_NOTIFICATION_SECRET" ]] && jq -e --arg provider "$(jq -r '.notifications.provider' "$SBM_STATE")" '.provider==$provider' "$SBM_NOTIFICATION_SECRET" >/dev/null 2>&1 && secret_ready=true
  jq --argjson secret_ready "$secret_ready" '.notifications + {credentials_ready:$secret_ready}' "$SBM_STATE"
}

notification_status() {
  local json=${1:-0} data
  data=$(notification_status_json)
  if [[ "$json" == 1 ]]; then printf '%s\n' "$data"; return 0; fi
  jq -r '"通知：\(if .enabled then "启用" else "停用" end)\n渠道：\(.provider)\n凭据：\(if .credentials_ready then "已就绪" else "缺失" end)\n流量阈值：\(.traffic_thresholds|map(tostring+"%")|join("、"))"' <<<"$data"
}

notification_send() {
  local event=$1 message=$2 provider secret response
  [[ $(jq -r '.notifications.enabled // false' "$SBM_STATE") == true ]] || return 2
  provider=$(jq -r '.notifications.provider' "$SBM_STATE")
  [[ -s "$SBM_NOTIFICATION_SECRET" ]] || { log_warn '通知凭据文件缺失，消息未发送。'; return 1; }
  secret=$(jq -c . "$SBM_NOTIFICATION_SECRET" 2>/dev/null) || { log_warn '通知凭据文件无效，消息未发送。'; return 1; }
  [[ $(jq -r '.provider' <<<"$secret") == "$provider" ]] || { log_warn '通知配置与凭据渠道不一致，消息未发送。'; return 1; }
  if [[ -n ${SBM_NOTIFICATION_SENDER:-} ]]; then
    "$SBM_NOTIFICATION_SENDER" "$provider" "$event" "$message"
    return
  fi
  require_command curl
  case "$provider" in
    telegram)
      response=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        --request POST "https://api.telegram.org/bot$(jq -r '.bot_token' <<<"$secret")/sendMessage" \
        --data-urlencode "chat_id=$(jq -r '.chat_id' <<<"$secret")" --data-urlencode "text=$message") || return 1
      jq -e '.ok==true' <<<"$response" >/dev/null 2>&1 || return 1
      ;;
    wecom)
      curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        -H 'Content-Type: application/json' --data "$(jq -n --arg message "$message" '{msgtype:"text",text:{content:$message}}')" \
        "$(jq -r '.webhook_url' <<<"$secret")" >/dev/null
      ;;
    webhook)
      curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
        -H 'Content-Type: application/json' --data "$(jq -n --arg event "$event" --arg message "$message" --arg now "$(now_iso)" '{source:"sb-manager",event:$event,message:$message,timestamp:$now}')" \
        "$(jq -r '.webhook_url' <<<"$secret")" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

notification_test() {
  notification_send test "sb-manager 测试通知：$(hostname 2>/dev/null || printf unknown) $(now_iso)" \
    || die '测试通知发送失败，请检查凭据、目标和网络。'
  log_ok '测试通知发送成功。'
}

notification_events_init_unlocked() {
  local tmp
  if [[ -s "$SBM_NOTIFICATION_EVENTS" ]] && jq -e '.schema_version==1 and (.sent|type=="object")' "$SBM_NOTIFICATION_EVENTS" >/dev/null 2>&1; then return 0; fi
  tmp=$(mktemp "$SBM_VAR/.notification-events.XXXXXX")
  jq -n --arg now "$(now_iso)" '{schema_version:1,updated_at:$now,sent:{}}' >"$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_NOTIFICATION_EVENTS"
}

notification_event_record_unlocked() {
  local key=$1 tmp
  tmp=$(mktemp "$SBM_VAR/.notification-events.XXXXXX")
  jq --arg key "$key" --arg now "$(now_iso)" '
    .updated_at=$now | .sent[$key]=$now
    | .sent=(.sent | to_entries | sort_by(.value) | reverse | .[:2000] | from_entries)
  ' "$SBM_NOTIFICATION_EVENTS" >"$tmp"
  chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_NOTIFICATION_EVENTS"
}

notification_traffic_check_unlocked() {
  local row id name cycle quota billable percent threshold key message failed=0
  [[ $(jq -r '.notifications.enabled // false' "$SBM_STATE") == true ]] || return 0
  traffic_usage_init_unlocked
  notification_events_init_unlocked
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    quota=$(jq -r '.quota_bytes' <<<"$row")
    [[ "$quota" != null && $(jq -r '.traffic_enabled' <<<"$row") == true ]] || continue
    id=$(jq -r '.id' <<<"$row"); name=$(jq -r '.name' <<<"$row"); cycle=$(jq -r '.cycle_id // 0' <<<"$row")
    billable=$(jq -r '.billable_bytes' <<<"$row"); percent=$((billable * 100 / quota))
    while IFS= read -r threshold; do
      (( percent >= threshold )) || continue
      key="traffic:${id}:${cycle}:${threshold}"
      jq -e --arg key "$key" '.sent[$key] != null' "$SBM_NOTIFICATION_EVENTS" >/dev/null && continue
      message="sb-manager 流量提醒：节点 ${name} (${id}) 本周期已使用 ${percent}%，达到 ${threshold}% 阈值。"
      if notification_send traffic_threshold "$message"; then
        notification_event_record_unlocked "$key"
      else
        log_warn "节点 $id 的 ${threshold}% 流量提醒发送失败，下一轮将重试。"
        failed=1
      fi
    done < <(jq -r '.notifications.traffic_thresholds[]' "$SBM_STATE")
  done < <(traffic_status_json_unlocked all | jq -c '.[]')
  return "$failed"
}
