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

# 递归收集指定 PID 的所有后代进程（子、孙...）
_collect_descendants() {
  local parent="$1"
  local all_ps="$2"  # 预取的 "pid ppid" 列表
  local children
  children=$(echo "$all_ps" | awk -v p="$parent" '$2 == p { print $1 }')
  for child in $children; do
    echo "$child"
    _collect_descendants "$child" "$all_ps"
  done
}

# 终止指定 feature 的活跃 pipeline 进程（排除当前 /pause 自己）
# /resume 拉起的执行链：feishu-handler.sh → opencli claude → claude CLI → 子进程
# 需要匹配入口进程，再递归 kill 整个进程树（claude 子进程命令行不含 feature name）
terminate_feature_pipeline_processes() {
  local feature_name="$1"
  local current_pid="$$"
  local current_ppid
  current_ppid=$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ')

  # 预取全部进程的 pid ppid（用于递归查子树）
  local all_ps
  all_ps=$(ps -Ao pid=,ppid= 2>/dev/null)

  # 匹配入口进程：feishu-handler.sh / opencli.*claude / claude.*bypassPermissions
  # 排除：当前 /pause 进程自身及其父进程
  local root_pids
  root_pids=$(ps -Ao pid=,ppid=,command= | awk -v feature="$feature_name" -v self="$current_pid" -v selfparent="$current_ppid" '
    {
      pid=$1; ppid=$2; $1=""; $2=""; cmd=$0
    }
    (pid == self || pid == selfparent) { next }
    /\/pause / { next }
    (
      (cmd ~ /feishu-handler\.sh/ || cmd ~ /opencli.*claude/ || cmd ~ /claude.*bypassPermissions/)
      && index(cmd, feature) > 0
    ) {
      print pid
    }
  ' 2>/dev/null || true)

  [ -z "$root_pids" ] && return 0

  # 从入口进程递归收集整个进程树（含 claude CLI、node 等子进程）
  local all_pids="$root_pids"
  while IFS= read -r rpid; do
    [ -z "$rpid" ] && continue
    local descendants
    descendants=$(_collect_descendants "$rpid" "$all_ps")
    [ -n "$descendants" ] && all_pids=$(printf '%s\n%s' "$all_pids" "$descendants")
  done <<< "$root_pids"

  # 去重 + 排除自身
  all_pids=$(echo "$all_pids" | sort -un | grep -v "^${current_pid}$" | grep -v "^${current_ppid}$")
  [ -z "$all_pids" ] && return 0

  echo "  [pause] 终止活跃 pipeline 进程树: $(echo "$all_pids" | xargs)" >&2

  # 先 SIGTERM
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$all_pids"

  # 等 2 秒，对仍存活的进程 SIGKILL
  sleep 2
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "  [pause] 进程 $pid 仍存活，强制 SIGKILL" >&2
      kill -9 "$pid" 2>/dev/null || true
    fi
  done <<< "$all_pids"
}
