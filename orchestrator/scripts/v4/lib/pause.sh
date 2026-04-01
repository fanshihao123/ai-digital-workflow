#!/bin/bash
# pause.sh — Pause/resume state management
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 检查是否处于 /pause 手动暂停状态
has_paused_state() {
  local feature_name="$1"
  local state_file="$PROJECT_ROOT/specs/$feature_name/paused.json"
  [ -f "$state_file" ] && jq -e '.status == "paused"' "$state_file" >/dev/null 2>&1
}

# 读取 paused.json 指定字段
get_paused_field() {
  local feature_name="$1"
  local field="$2"
  local state_file="$PROJECT_ROOT/specs/$feature_name/paused.json"
  [ -f "$state_file" ] && jq -r ".$field // empty" "$state_file" 2>/dev/null || true
}

# 若 feature 已被 /pause，当前执行链路应尽快停止继续推进
ensure_not_paused() {
  local feature_name="$1"
  local context="${2:-workflow}"
  if has_paused_state "$feature_name"; then
    echo "  [paused-check] '$feature_name' 已处于 paused，停止 $context" >&2
    log "PIPELINE_STOPPED_BY_PAUSE: $feature_name ($context)" "$PROJECT_ROOT/specs/.workflow-log"
    return 1
  fi
  return 0
}

# 终止指定 feature 的活跃 pipeline 进程（排除当前 /pause 自己）
terminate_feature_pipeline_processes() {
  local feature_name="$1"
  local current_pid="$$"
  local pids=""

  pids=$(ps -Ao pid=,command= | awk -v feature="$feature_name" -v self="$current_pid" '
    /feishu-handler\.sh/ && $0 !~ /\/pause / && index($0, feature) > 0 {
      pid=$1
      if (pid != self) print pid
    }
  ' 2>/dev/null || true)

  [ -z "$pids" ] && return 0

  echo "  [pause] 终止活跃 pipeline 进程: $(echo "$pids" | xargs)" >&2
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
}
