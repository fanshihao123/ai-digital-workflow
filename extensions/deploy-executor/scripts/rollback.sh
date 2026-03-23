#!/bin/bash
# rollback.sh — 执行回滚操作
# 用法: bash rollback.sh <需求名称> [target-commit]

set -euo pipefail

FEATURE_NAME="${1:?用法: rollback.sh <需求名称> [target-commit]}"
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SPECS_DIR="$PROJECT_ROOT/specs/${FEATURE_NAME}"
DEPLOY_MANIFEST="$SPECS_DIR/deploy-manifest.json"
LOG_FILE="$SPECS_DIR/.workflow-log"

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

if [ -n "${2:-}" ]; then
  ROLLBACK_COMMIT="$2"
elif [ -f "$DEPLOY_MANIFEST" ]; then
  ROLLBACK_COMMIT=$(jq -r '.rollback_commit' "$DEPLOY_MANIFEST")
  COMMIT_COUNT=$(jq -r '.commit_count' "$DEPLOY_MANIFEST")
else
  echo "❌ 找不到 deploy-manifest.json 且未指定回滚目标"
  exit 1
fi

echo "🔄 开始回滚: ${FEATURE_NAME}"
echo "   目标: ${ROLLBACK_COMMIT:0:10}"
echo "[$(date +%H:%M:%S)] ROLLBACK_START: $FEATURE_NAME → $ROLLBACK_COMMIT" >> "$LOG_FILE"

if [ -n "${COMMIT_COUNT:-}" ]; then
  git revert --no-commit HEAD~${COMMIT_COUNT}..HEAD
else
  git revert --no-commit HEAD..${ROLLBACK_COMMIT}
fi

git commit -m "rollback(${FEATURE_NAME}): 回滚部署

原因: 健康检查失败或手动触发
回滚到: ${ROLLBACK_COMMIT:0:10}"

git push origin "$(git branch --show-current)"

echo "✅ 回滚完成"
echo "[$(date +%H:%M:%S)] ROLLBACK_DONE: $FEATURE_NAME" >> "$LOG_FILE"

bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" \
  "🔄 已回滚: ${FEATURE_NAME}\n目标: ${ROLLBACK_COMMIT:0:7}" 2>/dev/null || true
