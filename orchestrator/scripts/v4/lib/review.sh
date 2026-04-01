#!/bin/bash
# review.sh — Code review execution
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

run_local_review() {
  local feature_name="$1"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local review_report="$spec_dir/review-report.md"
  local default_branch
  default_branch=$(get_default_branch "$PROJECT_ROOT")

  # 获取变更 diff
  local changed_files
  changed_files=$(git -C "$PROJECT_ROOT" diff --name-only "${default_branch}..HEAD" 2>/dev/null || echo "")
  local diff_content
  diff_content=$(git -C "$PROJECT_ROOT" diff "${default_branch}..HEAD" 2>/dev/null || echo "")
  local review_output=""
  local review_exit=0

  # 调用 Claude Code 执行真正的两轮代码审查
  set +e
  review_output=$(opencli claude --model sonnet --print --permission-mode bypassPermissions -p "
    Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
    Read $PROJECT_ROOT/.claude/skills/code-reviewer/references/review-checklist.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md

    Execute code-reviewer for feature '$feature_name':

    变更文件: $changed_files

    按照 SKILL.md 执行两轮审查：
    - Round 1: 完整审查，发现 CRITICAL/ERROR 问题
    - 如有问题：生成修复指令并执行修复
    - Round 2: 验证修复 + 检查新问题（强制执行，即使 Round 1 无问题）

    生成结构化报告到 $review_report，必须包含：
    - ## Round 1 和 ## Round 2 标题
    - ROUND_1_STATUS: PASS|FAIL
    - ROUND_2_STATUS: PASS|FAIL
    - FINAL_VERDICT: PASS|FAIL
  " 2>&1)
  review_exit=$?
  set -e

  if [ "$review_exit" -ne 0 ]; then
    cat > "$review_report" <<EOF
# 审查报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 审查工具：local fallback (Claude Code 执行失败)

## Round 1
- 状态：FAIL（审查执行失败）
- 输出摘要：
\`\`\`
$(printf '%s\n' "$review_output" | sed -n '1,60p')
\`\`\`

## Round 2
- 状态：SKIP（Round 1 未完成）

## 结论：FAIL

ROUND_1_STATUS: FAIL
ROUND_2_STATUS: FAIL
FINAL_VERDICT: FAIL
EOF
    return 1
  fi

  # 检查报告格式
  if [ ! -f "$review_report" ]; then
    return 1
  fi

  if ! grep -q "^## Round 1" "$review_report" 2>/dev/null || ! grep -q "^## Round 2" "$review_report" 2>/dev/null; then
    return 1
  fi

  local round1_status round2_status final_verdict
  round1_status=$(sed -n 's/^ROUND_1_STATUS:[[:space:]]*//p' "$review_report" | tail -1 | tr -d '\r')
  round2_status=$(sed -n 's/^ROUND_2_STATUS:[[:space:]]*//p' "$review_report" | tail -1 | tr -d '\r')
  final_verdict=$(sed -n 's/^FINAL_VERDICT:[[:space:]]*//p' "$review_report" | tail -1 | tr -d '\r')

  [ "$round1_status" = "PASS" ] && [ "$round2_status" = "PASS" ] && [ "$final_verdict" = "PASS" ]
}
