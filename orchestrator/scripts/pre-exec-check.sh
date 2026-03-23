#!/bin/bash
# Pre-execution safety check hook
# Runs before every Bash tool use in Claude Code
# Blocks dangerous operations and logs all commands

set -euo pipefail

TOOL_INPUT="$1"
LOG_FILE=".claude/logs/execution-$(date +%Y-%m-%d).log"
mkdir -p .claude/logs

# Log the command
echo "[$(date +%H:%M:%S)] PRE-EXEC: $TOOL_INPUT" >> "$LOG_FILE"

# Block dangerous patterns
BLOCKED_PATTERNS=(
  "rm -rf /"
  "rm -rf ~"
  "DROP DATABASE"
  "DROP TABLE"
  "TRUNCATE TABLE"
  "format "
  "mkfs"
  "> /dev/sd"
  "chmod 777"
  "curl.*| bash"
  "wget.*| sh"
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$TOOL_INPUT" | grep -qi "$pattern"; then
    echo "BLOCKED: Dangerous command pattern detected: $pattern" >&2
    echo "[$(date +%H:%M:%S)] BLOCKED: $TOOL_INPUT (pattern: $pattern)" >> "$LOG_FILE"
    exit 1
  fi
done

# Warn on production-touching commands
WARN_PATTERNS=(
  "production"
  "prod "
  "deploy"
  "migrate"
  "seed"
)

for pattern in "${WARN_PATTERNS[@]}"; do
  if echo "$TOOL_INPUT" | grep -qi "$pattern"; then
    echo "WARNING: Command may affect production environment" >&2
    echo "[$(date +%H:%M:%S)] WARNING: $TOOL_INPUT (pattern: $pattern)" >> "$LOG_FILE"
  fi
done

exit 0
