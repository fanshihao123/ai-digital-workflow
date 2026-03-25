#!/bin/bash
# On-complete hook — runs when Claude Code finishes a session
# Archives logs and sends final status to Feishu

set -euo pipefail

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ACTIVE_FEATURE=$(ls -t "$PROJECT_ROOT"/specs/*/tasks.md 2>/dev/null | head -1 | sed "s|$PROJECT_ROOT/specs/||;s|/tasks.md||" || echo "")

if [ -z "$ACTIVE_FEATURE" ]; then
  exit 0
fi

FEATURE_DIR="$PROJECT_ROOT/specs/$ACTIVE_FEATURE"
TASKS_FILE="$FEATURE_DIR/tasks.md"

# Count task statuses
TOTAL=$(grep -c "^### Task" "$TASKS_FILE" 2>/dev/null || echo 0)
DONE=$(grep -cE "状态[：:].*done|Status.*done" "$TASKS_FILE" 2>/dev/null || echo 0)
FAILED=$(grep -cE "状态[：:].*failed|Status.*failed" "$TASKS_FILE" 2>/dev/null || echo 0)

# Determine overall status
if [ "$DONE" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
  STATUS="✅ All $TOTAL tasks complete"
elif [ "$FAILED" -gt 0 ]; then
  STATUS="❌ $FAILED/$TOTAL tasks failed"
else
  STATUS="⏸ $DONE/$TOTAL tasks done (session ended)"
fi

# Log completion
echo "[$(date +%H:%M:%S)] SESSION_END: $STATUS" >> "$FEATURE_DIR/.workflow-log"

# Notify via Feishu
if [ -f "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" ]; then
  bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" "Session complete: $STATUS\n\nFeature: $ACTIVE_FEATURE\nTasks: $DONE/$TOTAL done"
fi

exit 0
