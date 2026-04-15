#!/bin/bash
# state.sh — 统一状态机引擎
#
# 所有 feature 的运行状态统一到 $WORKFLOW_DATA_DIR/{feature}/state.json，替代散落的：
#   paused.json, awaiting-clarification.json, awaiting-spec-review.json, workflow-log grep
#
# 状态枚举:
#   idle            → 初始/已完成
#   running         → 流水线执行中
#   awaiting-answer → 等待用户澄清 [UNCERTAIN] 问题
#   awaiting-fix    → 等待用户 /fix-spec 修改指导
#   paused          → 用户主动 /pause
#   failed          → 流水线异常终止
#   done            → 全部完成
#
# state.json 格式:
# {
#   "feature": "user-login",
#   "status": "running",
#   "step": 2,
#   "substep": "stage-2-codex-review",
#   "updated_at": "2026-04-01T10:00:00Z",
#   "resume_command": "/fix-spec",
#   "context": { ... 各状态的附加数据 }
# }

# ============================================================
# 状态转移表
# 定义: 从哪个状态 + 什么命令 → 允许转移到哪个状态
# 格式: "from_status:command" → allowed
# ============================================================

# 状态转移查询函数（兼容 bash 3.2，不依赖 declare -A）
# 返回目标状态，无匹配则返回空字符串
_state_transition_lookup() {
  local key="$1"
  case "$key" in
    # 正常流水线推进
    idle:start)           echo "running" ;;
    running:step)         echo "running" ;;
    running:pause)        echo "paused" ;;
    running:fail)         echo "failed" ;;
    running:done)         echo "done" ;;

    # 自动暂停（开放问题 / spec 审查阻断）
    running:await-answer) echo "awaiting-answer" ;;
    running:await-fix)    echo "awaiting-fix" ;;

    # 用户恢复命令
    awaiting-answer:answer) echo "running" ;;
    awaiting-fix:fix-spec)  echo "running" ;;
    paused:restart)         echo "running" ;;
    failed:resume)          echo "running" ;;

    # 从暂停态也可以 resume（等同于 restart）
    paused:resume)          echo "running" ;;

    # done 态可以重新启动
    done:start)             echo "running" ;;

    *) echo "" ;;
  esac
}

# ============================================================
# 核心 API
# ============================================================

# 获取 state.json 路径
_state_file() {
  local feature="$1"
  echo "$WORKFLOW_DATA_DIR/$feature/state.json"
}

# 读取当前状态（返回 status 字段，无文件返回 idle）
state_get() {
  local feature="$1"
  local file
  file=$(_state_file "$feature")
  if [ -f "$file" ]; then
    jq -r '.status // "idle"' "$file" 2>/dev/null || echo "idle"
  else
    echo "idle"
  fi
}

# 读取 state.json 任意字段
state_field() {
  local feature="$1"
  local field="$2"
  local file
  file=$(_state_file "$feature")
  [ -f "$file" ] && jq -r ".$field // empty" "$file" 2>/dev/null || true
}

# 读取整个 state.json
state_read() {
  local feature="$1"
  local file
  file=$(_state_file "$feature")
  [ -f "$file" ] && cat "$file" || echo '{}'
}

# 写入 state.json（完整覆写）
state_write() {
  local feature="$1"
  local json="$2"
  local file
  file=$(_state_file "$feature")
  mkdir -p "$(dirname "$file")"
  echo "$json" > "$file"
}

# 更新 state.json 指定字段（保留其他字段）
state_update() {
  local feature="$1"
  shift
  # 接受 jq filter 参数，例如: state_update feature '.step = 2 | .substep = "dev"'
  local filter="$1"
  local file
  file=$(_state_file "$feature")

  if [ -f "$file" ]; then
    local tmp; tmp=$(mktemp)
    jq "$filter | .updated_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$file" > "$tmp" && mv "$tmp" "$file"
  fi
}

# ============================================================
# 状态转移（带验证）
# 用法: state_transition feature command [jq_context_updates]
# 返回: 0=成功 1=非法转移
# ============================================================
state_transition() {
  local feature="$1"
  local command="$2"
  local context_update="${3:-}"

  local current
  current=$(state_get "$feature")
  local key="${current}:${command}"
  local target
  target=$(_state_transition_lookup "$key")

  if [ -z "$target" ]; then
    echo "❌ 非法状态转移: '$feature' 当前状态 '$current'，不允许执行 '$command'" >&2
    _suggest_command "$current" "$feature"
    return 1
  fi

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local file
  file=$(_state_file "$feature")

  if [ -f "$file" ]; then
    # 更新已有 state.json
    local filter=".status = \"$target\" | .updated_at = \"$ts\""
    [ -n "$context_update" ] && filter="$filter | $context_update"
    local tmp; tmp=$(mktemp)
    jq "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
  else
    # 首次创建
    mkdir -p "$(dirname "$file")"
    local init_json
    init_json=$(jq -n \
      --arg f "$feature" \
      --arg s "$target" \
      --arg t "$ts" \
      '{feature:$f, status:$s, step:0, substep:"", updated_at:$t, resume_command:"", context:{}}')
    [ -n "$context_update" ] && init_json=$(echo "$init_json" | jq "$context_update")
    echo "$init_json" > "$file"
  fi

  return 0
}

# ============================================================
# 便捷方法
# ============================================================

# 检查是否允许执行某命令
state_can() {
  local feature="$1"
  local command="$2"
  local current
  current=$(state_get "$feature")
  [ -n "$(_state_transition_lookup "${current}:${command}")" ]
}

# 设置当前 step（流水线推进时调用）
state_set_step() {
  local feature="$1"
  local step="$2"
  local substep="${3:-}"
  state_update "$feature" ".step = $step | .substep = \"$substep\""
}

# 暂停：等待用户澄清
state_await_answer() {
  local feature="$1"
  local questions="$2"
  state_transition "$feature" "await-answer" \
    ".resume_command = \"/answer\" | .context.questions = $(echo "$questions" | jq -Rs .)"
}

# 暂停：等待用户 /fix-spec
state_await_fix() {
  local feature="$1"
  local critical_count="$2"
  local review_summary="$3"
  state_transition "$feature" "await-fix" \
    ".resume_command = \"/fix-spec\" | .context.critical_count = $critical_count | .context.review_summary = $(echo "$review_summary" | jq -Rs .)"
}

# 用户主动暂停
state_pause() {
  local feature="$1"
  local step
  step=$(state_field "$feature" "step")
  state_transition "$feature" "pause" \
    ".resume_command = \"/restart\" | .context.paused_step = ${step:-1}"
}

# 标记失败
state_fail() {
  local feature="$1"
  local reason="$2"
  state_transition "$feature" "fail" \
    ".resume_command = \"/resume\" | .context.fail_reason = $(echo "$reason" | jq -Rs .)" 2>/dev/null || true
}

# 标记完成
state_complete() {
  local feature="$1"
  state_transition "$feature" "done" '.step = 7 | .substep = "complete" | .resume_command = ""'
}

# 验证命令是否可执行，不可执行时输出友好提示
state_validate_command() {
  local feature="$1"
  local command="$2"
  if ! state_can "$feature" "$command"; then
    local current
    current=$(state_get "$feature")
    echo "❌ '$feature' 当前状态为 '$current'，无法执行 '$command'" >&2
    _suggest_command "$current" "$feature"
    return 1
  fi
  return 0
}

# 内部：根据状态给出建议命令
_suggest_command() {
  local status="$1"
  local feature="$2"
  case "$status" in
    awaiting-answer)
      echo "   请先用 /answer $feature {答复} 回复开放问题" >&2 ;;
    awaiting-fix)
      echo "   请先用 /fix-spec $feature {修改指导} 解决审查问题" >&2 ;;
    paused)
      echo "   请用 /restart $feature 恢复，或 /resume $feature 从断点继续" >&2 ;;
    failed)
      echo "   请用 /resume $feature 从断点恢复" >&2 ;;
    running)
      echo "   流水线正在运行中，如需暂停请用 /pause $feature" >&2 ;;
    done)
      echo "   该需求已完成。如需重新启动，请用 /start-workflow" >&2 ;;
    *)
      echo "   用 /status 查看当前状态" >&2 ;;
  esac
}

