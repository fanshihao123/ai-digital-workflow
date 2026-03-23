#!/bin/bash
# Feishu → Claude Code Webhook Handler
# 接收飞书消息并触发工作流编排器
#
# v3 路径:
#   编排器: .claude/orchestrator/SKILL.md
#   核心 skill: .claude/skills/{spec-writer,code-reviewer,test-runner,doc-syncer}/SKILL.md
#   扩展: .claude/extensions/{worktree-parallel,ui-restorer,human-gate,deploy-executor,jira-sync}/SKILL.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

MESSAGE="${1:-$(cat -)}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

mkdir -p "$PROJECT_ROOT/specs"
echo "[$TIMESTAMP] Received: $MESSAGE" >> "$PROJECT_ROOT/specs/.workflow-log"

MSG_TYPE=$(echo "$MESSAGE" | jq -r '.msg_type // "text"' 2>/dev/null || echo "text")
MSG_TEXT=$(echo "$MESSAGE" | jq -r '.content.text // .content // empty' 2>/dev/null || echo "$MESSAGE")

# 模型选择函数
select_model() {
  local complexity="${1:-low}"
  if [ "$complexity" = "high" ]; then
    claude --model opus -p "echo ok" > /dev/null 2>&1 && echo "opus" || echo "sonnet"
  else
    echo "sonnet"
  fi
}

MODEL=$(select_model "low")  # 默认 sonnet，spec-writer 生成 design.md 后可能升级

if [[ "$MSG_TEXT" == /* ]]; then
  COMMAND=$(echo "$MSG_TEXT" | awk '{print $1}')
  ARGS=$(echo "$MSG_TEXT" | cut -d' ' -f2-)
  
  case "$COMMAND" in
    /workflow|/start-workflow)
      echo "Starting full workflow pipeline..."
      claude --model "$MODEL" -p "
        Read $PROJECT_ROOT/.claude/orchestrator/SKILL.md
        Read all skills in $PROJECT_ROOT/.claude/skills/
        Read $PROJECT_ROOT/.claude/CLAUDE.md and $PROJECT_ROOT/.claude/ARCHITECTURE.md
        Execute the full pipeline with this requirement: $ARGS
      "
      ;;
    /hotfix)
      echo "Starting hotfix (skip design)..."
      claude --model "$MODEL" -p "
        Read $PROJECT_ROOT/.claude/orchestrator/SKILL.md
        Execute hotfix pipeline (skip design) with: $ARGS
      "
      ;;
    /review)
      echo "Starting code review..."
      claude --model "$MODEL" -p "
        Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
        Read $PROJECT_ROOT/.claude/SECURITY.md and $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
        Review recent changes: $ARGS
      "
      ;;
    /test)
      echo "Running tests..."
      claude --model sonnet -p "
        Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
        Run all tests and generate report.
      "
      ;;
    /status)
      echo "=== Git Log ==="
      git -C "$PROJECT_ROOT" log --oneline -10
      echo ""
      echo "=== Active Specs ==="
      ls "$PROJECT_ROOT/specs/" 2>/dev/null || echo "No active specs"
      ;;
    *)
      echo "Unknown command: $COMMAND"
      echo "Available: /workflow /hotfix /review /test /status"
      ;;
  esac
else
  echo "Processing natural language request..."
  claude --model "$MODEL" -p "
    Read $PROJECT_ROOT/.claude/orchestrator/SKILL.md
    Read all skills in $PROJECT_ROOT/.claude/skills/
    Read $PROJECT_ROOT/.claude/CLAUDE.md and $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Process this request: $MSG_TEXT
  "
fi

# 飞书通知
if [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
  curl -s -X POST "$FEISHU_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"msg_type\": \"interactive\",
      \"card\": {
        \"header\": {
          \"title\": {\"tag\": \"plain_text\", \"content\": \"Workflow Complete\"},
          \"template\": \"green\"
        },
        \"elements\": [{
          \"tag\": \"markdown\",
          \"content\": \"Request: $MSG_TEXT\"
        }]
      }
    }" > /dev/null 2>&1
fi
