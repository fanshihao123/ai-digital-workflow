#!/bin/bash
# Post-execution audit log hook
# Logs command results and updates workflow status

set -euo pipefail

TOOL_INPUT="${1:-}"
TOOL_OUTPUT="${2:-}"
LOG_FILE=".claude/logs/execution-$(date +%Y-%m-%d).log"
mkdir -p .claude/logs

# Extract exit code hint from output
EXIT_STATUS="success"
if echo "$TOOL_OUTPUT" | grep -qi "error\|failed\|exception\|traceback"; then
  EXIT_STATUS="error"
fi

echo "[$(date +%H:%M:%S)] POST-EXEC [$EXIT_STATUS]: $TOOL_INPUT" >> "$LOG_FILE"

# Track file changes for doc-sync
CHANGED_FILES=$(git diff --name-only 2>/dev/null || true)
if [ -n "$CHANGED_FILES" ]; then
  echo "[$(date +%H:%M:%S)] FILES_CHANGED: $CHANGED_FILES" >> "$LOG_FILE"
fi

# Update active workflow log if exists
ACTIVE_FEATURE=$(ls -t specs/*/tasks.md 2>/dev/null | head -1 | sed 's|specs/||;s|/tasks.md||')
if [ -n "$ACTIVE_FEATURE" ]; then
  echo "[$(date +%H:%M:%S)] [$EXIT_STATUS] $TOOL_INPUT" >> "specs/$ACTIVE_FEATURE/.workflow-log"
fi

exit 0
