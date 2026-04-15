#!/bin/bash
# step7-notify.sh — Step 7: 完成通知
# Sourced by v4/handler.sh; all lib modules already loaded

step7_notify() {
  local feature_name="$1"

  ensure_not_paused "$feature_name" "step7_notify" || return 0

  echo "=== Step 7: 完成通知 ==="

  # 收集信息用于富通知
  local coverage="N/A"
  local feature_test_status="N/A"
  local repo_debt_status="N/A"
  local review_status="N/A"
  local commit_hash
  commit_hash=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%h" 2>/dev/null || echo "N/A")
  local commit_msg
  commit_msg=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%s" 2>/dev/null || echo "N/A")

  # 从测试报告提取覆盖率
  local test_report="$WORKFLOW_DATA_DIR/$feature_name/test-report.md"
  if [ -f "$test_report" ]; then
    coverage=$(sed -n 's/.*Statements[[:space:]]*|[[:space:]]*\([0-9][0-9]*%\).*/\1/p' "$test_report" 2>/dev/null | head -1)
    [ -z "$coverage" ] && coverage="N/A"
    feature_test_status=$(extract_report_field "$test_report" "FEATURE_SCOPE_STATUS")
    repo_debt_status=$(extract_report_field "$test_report" "REPO_DEBT_STATUS")
  fi

  # 从审查报告提取结论
  local review_report="$WORKFLOW_DATA_DIR/$feature_name/review-report.md"
  if [ -f "$review_report" ]; then
    review_status=$(sed -n 's/.*结论：[[:space:]]*\([^[:space:]]*\).*/\1/p' "$review_report" 2>/dev/null | head -1)
    if [ -z "$review_status" ]; then
      review_status=$(grep -o 'PASS\|FAIL' "$review_report" 2>/dev/null | tail -1)
    fi
    [ -z "$review_status" ] && review_status="N/A"
  fi

  # 发送富飞书通知（使用 common.sh 的安全函数）
  local message
  message="**功能**: $feature_name
**Feature 测试**: ${feature_test_status:-N/A}
**全仓技术债**: ${repo_debt_status:-N/A}
**覆盖率**: $coverage
**审查状态**: $review_status
**最新提交**: $commit_hash $commit_msg"

  feishu_notify "$message" "$feature_name"

  echo "  ✅ 流水线完成: $feature_name"
  echo "    Feature 测试: ${feature_test_status:-N/A} | 全仓技术债: ${repo_debt_status:-N/A} | 覆盖率: $coverage | 审查: $review_status | 提交: $commit_hash"
}
