#!/bin/bash
# Feishu → Claude Code Webhook Handler — 入口
# 路由到 v4 模块化编排器

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# 加载环境变量
if [ -f "$PROJECT_ROOT/.env.ai-digital-workflow" ]; then
  set -a
  source "$PROJECT_ROOT/.env.ai-digital-workflow"
  set +a
fi

exec bash "$SCRIPT_DIR/v4/handler.sh" "$@"
