#!/bin/bash
# doc-sync.sh — Documentation sync
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

run_local_doc_sync() {
  local feature_name="$1"
  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  local iter_file="$WORKFLOW_DATA_DIR/ITERATIONS.md"

  mkdir -p "$WORKFLOW_DATA_DIR/archive"

  # 初始化 ITERATIONS.md
  if [ ! -f "$iter_file" ]; then
    cat > "$iter_file" <<EOF
# Iterations
EOF
  fi

  # 调用 Claude Code 执行真正的文档同步
  opencli claude --model sonnet --print --permission-mode bypassPermissions -p "
    Read $PROJECT_ROOT/.claude/skills/doc-syncer/SKILL.md
    Read $spec_dir/requirements.md
    Read $spec_dir/design.md
    Read $spec_dir/tasks.md
    $([ -f "$spec_dir/LESSONS.md" ] && echo "Read $spec_dir/LESSONS.md")

    Execute doc-syncer for feature '$feature_name':
    1. 分析本次变更（读取 specs 产物 + git log）
    2. 按需更新 .claude/ 下的项目文档（CLAUDE.md, ARCHITECTURE.md, SECURITY.md, CODING_GUIDELINES.md）
    3. 归档本次迭代到 $WORKFLOW_DATA_DIR/archive/\$(date +%Y-%m-%d)-${feature_name}/（含 LESSONS.md）
    4. 更新 $WORKFLOW_DATA_DIR/ITERATIONS.md 追加本次迭代记录
    5. 如果 $spec_dir/LESSONS.md 存在，将其中有跨 feature 价值的条目汇总到 $WORKFLOW_DATA_DIR/LESSONS.md（去重）
  " 2>&1 || {
    # fallback: 至少追加 ITERATIONS.md
    if ! grep -q "$feature_name" "$iter_file" 2>/dev/null; then
      printf '\n- %s %s: workflow completed\n' "$(date '+%Y-%m-%d')" "$feature_name" >> "$iter_file"
    fi
  }
}
