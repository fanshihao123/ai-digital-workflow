#!/bin/bash
# Feishu → Claude Code Webhook Handler — 版本路由入口
# 根据 HANDLER_VERSION 环境变量分发到 v3（单体）或 v4（模块化）
#
# 切换方式：在 .env.ai-digital-workflow 中设置 HANDLER_VERSION=v3 或 v4
# 默认使用 v4（模块化版本）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# 加载环境变量（获取 HANDLER_VERSION）
if [ -f "$PROJECT_ROOT/.env.ai-digital-workflow" ]; then
  set -a
  source "$PROJECT_ROOT/.env.ai-digital-workflow"
  set +a
fi

VERSION="${HANDLER_VERSION:-v4}"

case "$VERSION" in
  v3)
    exec bash "$SCRIPT_DIR/v3/handler.sh" "$@"
    ;;
  v4)
    exec bash "$SCRIPT_DIR/v4/handler.sh" "$@"
    ;;
  *)
    echo "❌ 未知的 HANDLER_VERSION: $VERSION（支持 v3 或 v4）" >&2
    exit 1
    ;;
esac
