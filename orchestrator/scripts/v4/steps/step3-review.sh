#!/bin/bash
# step3-review.sh — Step 3: code-reviewer（两轮审查）
# Sourced by v4/handler.sh; all lib modules already loaded

step3_review() {
  local feature_name="$1"
  local review_report="$WORKFLOW_DATA_DIR/$feature_name/review-report.md"

  ensure_not_paused "$feature_name" "step3_review" || return 0

  echo "=== Step 3: code-reviewer ==="
  notify "🔍 开始代码审查: $feature_name"
  echo "  [Round 1+2] 本地两轮审查..."
  notify "🔍 Step 3: 开始两轮 code review ($feature_name)"
  run_local_review "$feature_name"

  if [ ! -f "$review_report" ]; then
    echo "  ❌ 缺少 review-report.md，无法确认两轮审查已执行"
    notify "❌ Step 3 失败: 缺少 review-report.md ($feature_name)"
    return 1
  fi

  if ! grep -q "^## Round 1" "$review_report" 2>/dev/null || ! grep -q "^## Round 2" "$review_report" 2>/dev/null; then
    echo "  ❌ review-report.md 缺少两轮审查标记"
    notify "❌ Step 3 失败: 未真实执行满两轮 code review ($feature_name)"
    return 1
  fi

  # human-gate G1：安全门控（条件触发）
  human_gate_security "$feature_name" || return 1

  # Jira 同步
  jira_sync "review-done" "$feature_name"
  notify "✅ Step 3 完成: code review 结束 ($feature_name)"
}
