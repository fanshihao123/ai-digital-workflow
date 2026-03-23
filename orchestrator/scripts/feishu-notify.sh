#!/bin/bash
# Feishu notification hook
# Sends workflow events to Feishu channel via webhook

set -euo pipefail

NOTIFICATION="${1:-}"

# Load env
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[ -f "$PROJECT_ROOT/.env" ] && source "$PROJECT_ROOT/.env"

# Skip if no webhook URL configured
if [ -z "${FEISHU_WEBHOOK_URL:-}" ]; then
  exit 0
fi

# Determine notification type and color
TEMPLATE="blue"
if echo "$NOTIFICATION" | grep -qi "error\|fail\|blocked"; then
  TEMPLATE="red"
elif echo "$NOTIFICATION" | grep -qi "complete\|pass\|success"; then
  TEMPLATE="green"
elif echo "$NOTIFICATION" | grep -qi "warning\|retry"; then
  TEMPLATE="orange"
fi

# Detect active feature
ACTIVE_FEATURE=$(ls -t specs/*/tasks.md 2>/dev/null | head -1 | sed 's|specs/||;s|/tasks.md||' || echo "unknown")

# Send to Feishu
curl -s -X POST "$FEISHU_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"msg_type\": \"interactive\",
    \"card\": {
      \"header\": {
        \"title\": {\"tag\": \"plain_text\", \"content\": \"🤖 AI Workforce: $ACTIVE_FEATURE\"},
        \"template\": \"$TEMPLATE\"
      },
      \"elements\": [
        {
          \"tag\": \"markdown\",
          \"content\": \"$NOTIFICATION\"
        },
        {
          \"tag\": \"note\",
          \"elements\": [{
            \"tag\": \"plain_text\",
            \"content\": \"$(date '+%Y-%m-%d %H:%M:%S') | Agent: Claude Code\"
          }]
        }
      ]
    }
  }" > /dev/null 2>&1 || true

exit 0
