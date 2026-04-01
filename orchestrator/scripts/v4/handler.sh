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
    local feature
    feature=$(detect_feature_name)
    if [ -n "$feature" ]; then
      pipeline_state_set "$feature" "last_run" "failed"
      agent_notify \
        "需求 '$feature' 的流水线异常退出（exit code: $exit_code），可执行 /resume $feature 从断点继续。" \
        "需要我帮你排查原因吗？还是直接 /resume $feature 继续？" \
        "$feature"
      log "PIPELINE_FAILED: $feature (exit code: $exit_code)" "$PROJECT_ROOT/specs/.workflow-log"
    fi
  fi
}

trap cleanup EXIT ERR

# ── 解析消息 ──
MESSAGE="${1:-$(cat -)}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

mkdir -p "$PROJECT_ROOT/specs"
echo "[$TIMESTAMP] Received: $MESSAGE" >> "$PROJECT_ROOT/specs/.workflow-log"

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
