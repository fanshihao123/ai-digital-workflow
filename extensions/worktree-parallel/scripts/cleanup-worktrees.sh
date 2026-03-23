#!/bin/bash
# cleanup-worktrees.sh — 清理已完成 feature 的所有 worktree
# 用法: bash cleanup-worktrees.sh <feature-name> [--delete-branches] [--force]

set -euo pipefail

FEATURE_NAME="${1:?用法: cleanup-worktrees.sh <feature-name> [--delete-branches]}"
DELETE_BRANCHES=false
FORCE=false

shift
for arg in "$@"; do
  case "$arg" in
    --delete-branches) DELETE_BRANCHES=true ;;
    --force) FORCE=true ;;
  esac
done

PROJECT_ROOT=$(git rev-parse --show-toplevel)
LOG_FILE="$PROJECT_ROOT/specs/${FEATURE_NAME}/.workflow-log"
CLEANED=0
SKIPPED=0

echo "🧹 清理 ${FEATURE_NAME} 相关的 worktree"

# 列出所有匹配的 worktree
git worktree list --porcelain | grep -B2 "$FEATURE_NAME" | grep "^worktree " | sed 's/^worktree //' | while read -r WORKTREE_PATH; do
  # 获取分支名
  BRANCH=$(cd "$WORKTREE_PATH" 2>/dev/null && git branch --show-current 2>/dev/null || echo "unknown")

  # 检查未提交变更
  if [ "$FORCE" != "true" ]; then
    DIRTY=$(cd "$WORKTREE_PATH" 2>/dev/null && git status --porcelain 2>/dev/null || echo "")
    UNPUSHED=$(cd "$WORKTREE_PATH" 2>/dev/null && git log --oneline @{upstream}..HEAD 2>/dev/null | wc -l || echo "0")

    if [ -n "$DIRTY" ]; then
      echo "  ⚠️  $WORKTREE_PATH: 有未提交的变更，跳过 (用 --force 强制)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # 移除 worktree
  git worktree remove "$WORKTREE_PATH" --force 2>/dev/null && {
    echo "  ✅ 已移除: $WORKTREE_PATH"
    CLEANED=$((CLEANED + 1))
  } || {
    echo "  ❌ 移除失败: $WORKTREE_PATH"
    SKIPPED=$((SKIPPED + 1))
  }

  # 删除分支
  if [ "$DELETE_BRANCHES" = "true" ] && [ "$BRANCH" != "unknown" ]; then
    git branch -D "$BRANCH" 2>/dev/null && echo "  ✅ 已删除分支: $BRANCH" || true
  fi
done

# 清理残留引用
git worktree prune 2>/dev/null

echo ""
echo "📊 清理结果: 已清理 $CLEANED / 跳过 $SKIPPED"
echo "[$(date +%H:%M:%S)] WORKTREE_CLEANUP: cleaned=$CLEANED skipped=$SKIPPED" >> "$LOG_FILE" 2>/dev/null || true
