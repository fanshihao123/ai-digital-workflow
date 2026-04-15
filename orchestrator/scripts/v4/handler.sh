#!/bin/bash
# v4/handler.sh — 模块化流水线入口
# 职责：初始化环境 → source 所有模块 → 解析消息 → 路由命令
#
# 目录结构：
#   v4/lib/       — 工具函数（状态机、澄清、暂停、测试、审查等）
#   v4/steps/     — 流水线 7 个阶段
#   v4/commands/  — 飞书斜杠命令处理器

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")")"

# ── 加载公共函数库 ──
source "$SCRIPT_DIR/../lib/common.sh"

load_env "$PROJECT_ROOT"
validate_config || echo "⚠️ 部分配置无效，请检查 .env" >&2

# ── 工作流数据目录（specs/状态/日志等产物，不污染项目仓库） ──
if [ -z "${WORKFLOW_DATA_DIR:-}" ]; then
  _project_name=$(basename "$PROJECT_ROOT")
  WORKFLOW_DATA_DIR="$HOME/.ai-workflow/data/$_project_name"
fi
export WORKFLOW_DATA_DIR

# ── 加载 v4 模块 ──
# lib（工具函数）
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/clarification.sh"
source "$SCRIPT_DIR/lib/spec-review.sh"
source "$SCRIPT_DIR/lib/pause.sh"
source "$SCRIPT_DIR/lib/testing.sh"
source "$SCRIPT_DIR/lib/review.sh"
source "$SCRIPT_DIR/lib/doc-sync.sh"
source "$SCRIPT_DIR/lib/dev-server.sh"
source "$SCRIPT_DIR/lib/antigravity.sh"
source "$SCRIPT_DIR/lib/integrations.sh"
source "$SCRIPT_DIR/lib/progress.sh"

# steps（流水线阶段）
source "$SCRIPT_DIR/steps/step0-prepare.sh"
source "$SCRIPT_DIR/steps/step1-spec-writer.sh"
source "$SCRIPT_DIR/steps/step2-develop.sh"
source "$SCRIPT_DIR/steps/step3-review.sh"
source "$SCRIPT_DIR/steps/step4-test.sh"
source "$SCRIPT_DIR/steps/step5-doc-sync.sh"
source "$SCRIPT_DIR/steps/step6-deploy.sh"
source "$SCRIPT_DIR/steps/step7-notify.sh"
source "$SCRIPT_DIR/steps/pipeline.sh"

# commands（斜杠命令）
source "$SCRIPT_DIR/commands/start-workflow.sh"
source "$SCRIPT_DIR/commands/hotfix.sh"
source "$SCRIPT_DIR/commands/pause.sh"
source "$SCRIPT_DIR/commands/restart.sh"
source "$SCRIPT_DIR/commands/resume.sh"
source "$SCRIPT_DIR/commands/answer.sh"
source "$SCRIPT_DIR/commands/fix-spec.sh"
source "$SCRIPT_DIR/commands/review.sh"
source "$SCRIPT_DIR/commands/test.sh"
source "$SCRIPT_DIR/commands/status.sh"
source "$SCRIPT_DIR/commands/deploy.sh"
source "$SCRIPT_DIR/commands/rollback.sh"

# ── 错误处理和清理 ──
_NOTIFIED_ERROR=false

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ "$_NOTIFIED_ERROR" = "false" ]; then
    _NOTIFIED_ERROR=true

    # 安全获取 feature（模块可能尚未加载）
    local feature=""
    if type detect_feature_name >/dev/null 2>&1; then
      feature=$(detect_feature_name 2>/dev/null || true)
    fi

    local error_msg="流水线异常退出（exit code: $exit_code）"
    [ -n "$feature" ] && error_msg="需求 '$feature' 的${error_msg}，可执行 /resume $feature 从断点继续。"

    # 附带最近日志摘要帮助排查
    local recent_log=""
    if [ -d "$WORKFLOW_DATA_DIR" ] && [ -f "$WORKFLOW_DATA_DIR/.workflow-log" ]; then
      recent_log=$(tail -10 "$WORKFLOW_DATA_DIR/.workflow-log" 2>/dev/null || true)
    fi
    [ -n "$recent_log" ] && error_msg="${error_msg}\n\n最近日志:\n\`\`\`\n${recent_log}\n\`\`\`"

    # 写日志（即使模块未加载也尝试）
    if [ -d "$WORKFLOW_DATA_DIR" ]; then
      echo "[$(date '+%H:%M:%S')] PIPELINE_FAILED: ${feature:-unknown} (exit code: $exit_code)" \
        >> "$WORKFLOW_DATA_DIR/.workflow-log" 2>/dev/null || true
    fi

    # 记录 pipeline 状态
    if [ -n "$feature" ] && type pipeline_state_set >/dev/null 2>&1; then
      pipeline_state_set "$feature" "last_run" "failed" 2>/dev/null || true
    fi

    # 发送通知（优先 agent_notify，降级到 feishu_notify，再降级到 openclaw 直接调用）
    if [ -n "$feature" ] && type agent_notify >/dev/null 2>&1; then
      agent_notify \
        "$error_msg" \
        "需要我帮你排查原因吗？还是直接 /resume $feature 继续？" \
        "$feature" 2>/dev/null || true
    elif type feishu_notify >/dev/null 2>&1; then
      feishu_notify "❌ $error_msg" "${feature:-unknown}" 2>/dev/null || true
    else
      # 最后兜底：模块全未加载，直接用 openclaw/webhook 通知
      local _oc_bin="${OPENCLAW_BIN:-}"
      [ -z "$_oc_bin" ] && _oc_bin=$(command -v openclaw 2>/dev/null || true)
      if [ -n "$_oc_bin" ] && [ -x "$_oc_bin" ] && [ -n "${FEISHU_NOTIFY_TARGET:-}" ]; then
        "$_oc_bin" message send \
          --channel feishu \
          --target "$FEISHU_NOTIFY_TARGET" \
          --message "[🤖 AI Workforce] ❌ $error_msg" \
          > /dev/null 2>&1 || true
      elif [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
        curl -s -X POST "$FEISHU_WEBHOOK_URL" \
          -H "Content-Type: application/json" \
          --max-time 5 \
          -d "$(printf '{"msg_type":"text","content":{"text":"[AI Workforce] ❌ %s"}}' "$error_msg")" \
          > /dev/null 2>&1 || true
      fi
    fi
  fi
}

trap cleanup EXIT ERR

# ── 解析消息 ──
MESSAGE="${1:-$(cat -)}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

mkdir -p "$WORKFLOW_DATA_DIR"
echo "[$TIMESTAMP] Received: $MESSAGE" >> "$WORKFLOW_DATA_DIR/.workflow-log"

MSG_TYPE=$(echo "$MESSAGE" | jq -r '.msg_type // "text"' 2>/dev/null || echo "text")
MSG_TEXT=$(echo "$MESSAGE" | jq -r '.content.text // .content // empty' 2>/dev/null || echo "$MESSAGE")

# ── 命令路由 ──
if [[ "$MSG_TEXT" == /* ]]; then
  COMMAND=$(echo "$MSG_TEXT" | awk '{print $1}')
  ARGS=$(echo "$MSG_TEXT" | cut -d' ' -f2-)
  [ "$ARGS" = "$COMMAND" ] && ARGS=""

  case "$COMMAND" in
    /workflow|/start-workflow)
      echo "Starting full workflow pipeline..."
      cmd_start_workflow "$ARGS"
      ;;
    /hotfix)
      echo "Starting hotfix (skip design)..."
      cmd_hotfix "$ARGS"
      ;;
    /review)
      echo "Starting code review..."
      cmd_review "$ARGS"
      ;;
    /test)
      echo "Running tests..."
      cmd_test "$ARGS"
      ;;
    /deploy)
      cmd_deploy "$ARGS"
      ;;
    /rollback)
      cmd_rollback "$ARGS"
      ;;
    /answer)
      cmd_answer_clarification "$ARGS"
      ;;
    /fix-spec)
      cmd_fix_spec "$ARGS"
      ;;
    /pause)
      cmd_pause "$ARGS"
      ;;
    /restart)
      cmd_restart "$ARGS"
      ;;
    /resume)
      cmd_resume "$ARGS"
      ;;
    /status)
      cmd_status
      ;;
    *)
      echo "Unknown command: $COMMAND"
      echo "Available: /workflow /hotfix /review /test /answer /fix-spec /pause /restart /resume /deploy /rollback /status"
      ;;
  esac
else
  echo "Processing natural language request..."
  run_full_pipeline "$MSG_TEXT"
fi
