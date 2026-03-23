#!/bin/bash
# spawn-worktree-agents.sh — 创建 worktree 并调度并行 Agent
# 用法: bash spawn-worktree-agents.sh <feature-name> <assignment-json>

set -euo pipefail

FEATURE_NAME="${1:?用法: spawn-worktree-agents.sh <feature-name> <assignment-json>}"
ASSIGNMENT_FILE="${2:?请提供 .agent-assignment.json 路径}"
PROJECT_ROOT=$(git rev-parse --show-toplevel)
BASE_BRANCH=$(git branch --show-current)
LOG_FILE="$PROJECT_ROOT/specs/${FEATURE_NAME}/.workflow-log"

mkdir -p "$PROJECT_ROOT/specs/${FEATURE_NAME}"
echo "[$(date +%H:%M:%S)] MULTI_AGENT_START: $FEATURE_NAME (base: $BASE_BRANCH)" >> "$LOG_FILE"

# ------------------------------------------
# Step 1: 为每个 Agent 创建 worktree
# ------------------------------------------
echo "🌳 创建 worktree 环境..."

AGENT_COUNT=$(jq '.agents | length' "$ASSIGNMENT_FILE")
PIDS=()

for i in $(seq 0 $((AGENT_COUNT - 1))); do
  AGENT_ID=$(jq -r ".agents[$i].id" "$ASSIGNMENT_FILE")
  ROLE=$(jq -r ".agents[$i].role" "$ASSIGNMENT_FILE")
  BRANCH=$(jq -r ".agents[$i].branch" "$ASSIGNMENT_FILE")
  WORKTREE_DIR=$(jq -r ".agents[$i].worktree" "$ASSIGNMENT_FILE")
  TASKS=$(jq -r ".agents[$i].tasks | join(\", \")" "$ASSIGNMENT_FILE")
  FILE_SCOPE=$(jq -r ".agents[$i].file_scope | join(\", \")" "$ASSIGNMENT_FILE")

  # 创建 worktree（如果不存在）
  if [ ! -d "$PROJECT_ROOT/$WORKTREE_DIR" ]; then
    git worktree add -B "$BRANCH" "$PROJECT_ROOT/$WORKTREE_DIR" "$BASE_BRANCH"
    echo "  ✅ Worktree: $WORKTREE_DIR (分支: $BRANCH)"
  else
    echo "  ⏭  Worktree 已存在: $WORKTREE_DIR"
  fi

  echo "[$(date +%H:%M:%S)] WORKTREE_CREATED: $AGENT_ID → $WORKTREE_DIR" >> "$LOG_FILE"
done

# ------------------------------------------
# Step 2: 获取并行分组
# ------------------------------------------
GROUPS=$(jq -r '.parallel_groups | keys[]' "$ASSIGNMENT_FILE")

for GROUP in $GROUPS; do
  echo ""
  echo "🚀 启动并行组: $GROUP"

  AGENTS_IN_GROUP=$(jq -r ".parallel_groups[\"$GROUP\"][]" "$ASSIGNMENT_FILE")
  GROUP_PIDS=()

  for AGENT_ID in $AGENTS_IN_GROUP; do
    ROLE=$(jq -r ".agents[] | select(.id==\"$AGENT_ID\") | .role" "$ASSIGNMENT_FILE")
    WORKTREE_DIR=$(jq -r ".agents[] | select(.id==\"$AGENT_ID\") | .worktree" "$ASSIGNMENT_FILE")
    TASKS=$(jq -r ".agents[] | select(.id==\"$AGENT_ID\") | .tasks | join(\", \")" "$ASSIGNMENT_FILE")
    FILE_SCOPE=$(jq -r ".agents[] | select(.id==\"$AGENT_ID\") | .file_scope | join(\", \")" "$ASSIGNMENT_FILE")

    ABS_WORKTREE="$PROJECT_ROOT/$WORKTREE_DIR"
    SPECS_PATH="$PROJECT_ROOT/specs/${FEATURE_NAME}"

    case "$ROLE" in
      developer)
        echo "  🤖 调度开发代理: $AGENT_ID → $WORKTREE_DIR"
        (
          cd "$ABS_WORKTREE"
          claude --model sonnet --print "
            你是 ${AGENT_ID} 开发代理，在隔离的 Git worktree 中工作。

            工作目录: $ABS_WORKTREE
            当前分支: $(cd "$ABS_WORKTREE" && git branch --show-current)
            
            执行任务: $TASKS
            文件范围: $FILE_SCOPE（只允许修改这些路径）
            
            规则:
            1. 读取 ${SPECS_PATH}/tasks.md 了解任务详情
            2. 读取项目 .claude/ 下的规范文件
            3. 只修改文件范围内的文件
            4. 每完成一个子步骤就 git commit
            5. 不要操作其他 worktree 或合并分支
            6. 完成后在最后的 commit message 中标记 [AGENT_DONE]
          " 2>&1 | tee "${SPECS_PATH}/.agent-${AGENT_ID}.log"
        ) &
        PID=$!
        ;;

      reviewer)
        echo "  🔍 调度审查代理: $AGENT_ID → $WORKTREE_DIR"
        (
          cd "$ABS_WORKTREE"
          codex exec --full-auto "
            你是代码审查代理。监控以下分支的变更：
            $(jq -r '.agents[] | select(.role=="developer") | .branch' "$ASSIGNMENT_FILE" | tr '\n' ', ')
            
            按照 $PROJECT_ROOT/.claude/skills/code-reviewer/references/review-checklist.md 审查。
            发现 CRITICAL 或 ERROR 级别问题立即输出。
          " 2>&1 | tee "${SPECS_PATH}/.agent-${AGENT_ID}.log"
        ) &
        PID=$!
        ;;

      tester)
        echo "  🧪 调度测试代理: $AGENT_ID → $WORKTREE_DIR"
        (
          cd "$ABS_WORKTREE"
          claude --model sonnet --print "
            你是测试代理，在隔离的 worktree 中工作。
            运行 npm test 和 npx playwright test。
            只修改 __tests__/ 和 e2e/ 目录下的文件。
            生成测试报告到 ${SPECS_PATH}/test-report.md
          " 2>&1 | tee "${SPECS_PATH}/.agent-${AGENT_ID}.log"
        ) &
        PID=$!
        ;;
    esac

    # 记录 PID
    GROUP_PIDS+=($PID)
    jq "(.agents[] | select(.id==\"$AGENT_ID\") | .pid) = $PID | (.agents[] | select(.id==\"$AGENT_ID\") | .status) = \"running\"" \
      "$ASSIGNMENT_FILE" > /tmp/assign_update.tmp && mv /tmp/assign_update.tmp "$ASSIGNMENT_FILE"

    echo "  ✅ $AGENT_ID 已启动 (PID: $PID)"
    echo "[$(date +%H:%M:%S)] AGENT_STARTED: $AGENT_ID (PID: $PID)" >> "$LOG_FILE"
  done

  # 等待当前组所有 Agent 完成
  echo "  ⏳ 等待并行组 $GROUP 完成..."
  for PID in "${GROUP_PIDS[@]}"; do
    wait $PID 2>/dev/null || true
  done
  echo "  ✅ 并行组 $GROUP 完成"
  echo "[$(date +%H:%M:%S)] GROUP_COMPLETE: $GROUP" >> "$LOG_FILE"

  # 合并当前组的结果
  MERGE_AGENTS=$(jq -r ".parallel_groups[\"$GROUP\"][]" "$ASSIGNMENT_FILE" | \
    while read id; do
      jq -r ".agents[] | select(.id==\"$id\" and .role==\"developer\") | .id" "$ASSIGNMENT_FILE"
    done | tr '\n' ',' | sed 's/,$//')

  if [ -n "$MERGE_AGENTS" ]; then
    echo "  🔀 合并组 $GROUP 的开发分支..."
    bash "$(dirname "$0")/merge-worktrees.sh" "$FEATURE_NAME" "$MERGE_AGENTS" "$ASSIGNMENT_FILE"
  fi
done

echo ""
echo "✅ 所有并行组执行完成"
echo "[$(date +%H:%M:%S)] MULTI_AGENT_COMPLETE: $FEATURE_NAME" >> "$LOG_FILE"
