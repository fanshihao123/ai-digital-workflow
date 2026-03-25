#!/bin/bash
# Feishu notification hook
# Sends workflow events to Feishu channel via webhook

set -euo pipefail

NOTIFICATION="${1:-}"

# 加载公共函数库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Load env
PROJECT_ROOT=$(get_project_root)
load_env "$PROJECT_ROOT"

# Skip if no webhook URL configured
if [ -z "${FEISHU_WEBHOOK_URL:-}" ]; then
  exit 0
fi

# Detect active feature
ACTIVE_FEATURE=$(ls -t "$PROJECT_ROOT"/specs/*/tasks.md 2>/dev/null | head -1 | sed "s|$PROJECT_ROOT/specs/||;s|/tasks.md||" || echo "unknown")

# 使用 common.sh 中的安全通知函数
feishu_notify "$NOTIFICATION" "$ACTIVE_FEATURE"

exit 0
