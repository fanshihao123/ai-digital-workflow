#!/bin/bash
# merge-worktrees.sh — 按顺序合并多个 worktree 分支到主干
# 用法: bash merge-worktrees.sh <feature-name> <agent-ids-comma-separated> <assignment-json>

set -euo pipefail

FEATURE_NAME="${1:?}"
AGENT_IDS="${2:?}"
ASSIGNMENT_FILE="${3:?}"
PROJECT_ROOT=$(git rev-parse --show-toplevel)
LOG_FILE="$PROJECT_ROOT/specs/${FEATURE_NAME}/.workflow-log"

# 验证输入
if [ -z "$AGENT_IDS" ]; then
  echo "⚠️ 未提供 agent 列表"
  exit 1
fi
if ! jq empty "$ASSIGNMENT_FILE" 2>/dev/null; then
  echo "❌ 无效的 JSON 文件: $ASSIGNMENT_FILE"
  exit 1
fi

cd "$PROJECT_ROOT"

echo "🔀 开始合并 worktree 分支"

IFS=',' read -ra AGENTS <<< "$AGENT_IDS"
MERGED=0
FAILED=0

for AGENT_ID in "${AGENTS[@]}"; do
  [ -z "$AGENT_ID" ] && continue

  BRANCH=$(jq -r --arg id "$AGENT_ID" '.agents[] | select(.id==$id) | .branch' "$ASSIGNMENT_FILE")

  if [ -z "$BRANCH" ] || [ "$BRANCH" = "null" ]; then
    echo "  ⚠️  $AGENT_ID: 未找到分支信息，跳过"
    continue
  fi

  # 检查分支是否有新提交
  COMMIT_COUNT=$(git rev-list --count "$(git merge-base HEAD "$BRANCH")".."$BRANCH" 2>/dev/null || echo 0)
  if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "  ⏭  $AGENT_ID ($BRANCH): 无新提交，跳过"
    continue
  fi

  echo "  🔀 合并 $AGENT_ID ($BRANCH, $COMMIT_COUNT 个提交)..."

  # 预检：dry-run 合并测试
  if ! git merge --no-commit --no-ff "$BRANCH" 2>/dev/null; then
    echo "  ❌ 预检发现冲突: $BRANCH"
    echo "  冲突文件:"
    git diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    /'
    git merge --abort 2>/dev/null

    echo "[$(date +%H:%M:%S)] MERGE_CONFLICT: $AGENT_ID ($BRANCH)" >> "$LOG_FILE"

    # 尝试自动冲突解决
    echo "  🤖 尝试自动冲突解决..."
    RESOLVER_WORKTREE=".claude/worktrees/${FEATURE_NAME}-resolver"
    git worktree add -B "worktree/${FEATURE_NAME}/resolver" "$RESOLVER_WORKTREE" HEAD 2>/dev/null || true

    cd "$RESOLVER_WORKTREE"
    git merge "$BRANCH" --no-commit 2>/dev/null || true

    # 调度冲突解决 Agent
    CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    opencli claude --model sonnet --print "
      你在冲突解决 worktree 中工作。
      以下文件存在合并冲突: $CONFLICT_FILES
      请解决所有冲突标记（<<<<<<< ======= >>>>>>>），
      保留两个分支的正确逻辑。
      解决后 git add 并 git commit。
    " 2>/dev/null

    if [ $? -eq 0 ] && [ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      echo "  ✅ 冲突自动解决成功"
      cd "$PROJECT_ROOT"
      git merge "worktree/${FEATURE_NAME}/resolver" --no-ff -m "merge: 自动解决 ${AGENT_ID} 冲突"
      git worktree remove "$RESOLVER_WORKTREE" --force 2>/dev/null
      git branch -D "worktree/${FEATURE_NAME}/resolver" 2>/dev/null
      MERGED=$((MERGED + 1))
    else
      echo "  ❌ 自动冲突解决失败，需要人工介入"
      cd "$PROJECT_ROOT"
      git worktree remove "$RESOLVER_WORKTREE" --force 2>/dev/null
      git branch -D "worktree/${FEATURE_NAME}/resolver" 2>/dev/null
      FAILED=$((FAILED + 1))

      bash .claude/orchestrator/scripts/feishu-notify.sh "❌ 合并冲突无法自动解决: ${AGENT_ID} ($BRANCH)\\n冲突文件: $CONFLICT_FILES"
      exit 1
    fi
  else
    # 预检通过，正式合并
    git merge --abort 2>/dev/null  # 清理预检状态
    git merge "$BRANCH" --no-ff -m "merge(${FEATURE_NAME}): 合并 ${AGENT_ID}

Tasks: $(jq -r ".agents[] | select(.id==\"$AGENT_ID\") | .tasks | join(\", \")" "$ASSIGNMENT_FILE")
Agent: $AGENT_ID
Branch: $BRANCH"

    MERGED=$((MERGED + 1))
    echo "  ✅ $AGENT_ID 合并成功"
    echo "[$(date +%H:%M:%S)] MERGE_OK: $AGENT_ID ($BRANCH)" >> "$LOG_FILE"
  fi

  # 更新 assignment 状态
  jq "(.agents[] | select(.id==\"$AGENT_ID\") | .status) = \"merged\"" \
    "$ASSIGNMENT_FILE" > /tmp/assign.tmp && mv /tmp/assign.tmp "$ASSIGNMENT_FILE"
done

echo ""
echo "📊 合并结果: 成功 $MERGED / 失败 $FAILED / 总计 ${#AGENTS[@]}"
echo "[$(date +%H:%M:%S)] MERGE_SUMMARY: ok=$MERGED fail=$FAILED" >> "$LOG_FILE"
