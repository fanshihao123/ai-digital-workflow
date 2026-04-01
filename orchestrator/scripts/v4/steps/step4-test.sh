#!/bin/bash
# step4-test.sh — Step 4: test-runner（测试 + 覆盖率）+ 自动修复回路
# Sourced by v4/handler.sh; all lib modules already loaded

step4_test() {
  local feature_name="$1"
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  local feature_status
  local repo_debt_status
  local workflow_verdict

  ensure_not_paused "$feature_name" "step4_test" || return 0

  echo "=== Step 4: test-runner ==="
  notify "🧪 Step 4: 开始测试 $feature_name"
  run_local_test "$feature_name"

  # Jira 同步
  jira_sync "test-done" "$feature_name"

  if [ ! -f "$test_report" ]; then
    echo "  ❌ 缺少 test-report.md"
    notify "❌ 测试失败: 缺少 test-report.md ($feature_name)"
    return 1
  fi

  feature_status=$(extract_report_field "$test_report" "FEATURE_SCOPE_STATUS")
  repo_debt_status=$(extract_report_field "$test_report" "REPO_DEBT_STATUS")
  workflow_verdict=$(extract_report_field "$test_report" "WORKFLOW_VERDICT")

  if [ -z "$workflow_verdict" ]; then
    echo "  ❌ test-report.md 缺少 WORKFLOW_VERDICT，无法判定测试门控"
    notify "❌ 测试失败: test-report.md 缺少结构化结论 ($feature_name)"
    return 1
  fi

  if [ "$workflow_verdict" = "FAIL" ]; then
    echo "  ⚠️ 测试未通过"
    notify "❌ 测试失败: $feature_name\n查看 specs/$feature_name/test-report.md"
    return 1
  fi

  echo "  ✅ 测试通过"
  if [ "$repo_debt_status" = "FAIL" ] && [ "$feature_status" = "PASS" ]; then
    echo "  ℹ️ feature 自身通过，存在非阻断的全仓技术债失败"
    notify "✅ 测试通过（feature-scope）: $feature_name\n存在非阻断历史测试债，详见 test-report.md"
    return 0
  fi
  notify "✅ Step 4 完成: 测试通过 ($feature_name)"
}

step4_fix_and_retry() {
  local feature_name="$1"
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  local workflow_verdict

  echo "=== Step 4.5: 测试失败自动修复 ==="
  notify "🩹 Step 4.5: 开始自动修复测试失败 ($feature_name)"

  if [ ! -f "$test_report" ]; then
    echo "  ❌ 缺少 test-report.md，无法进入修复回路"
    notify "❌ Step 4.5 失败: 缺少 test-report.md ($feature_name)"
    return 1
  fi

  opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
    Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/specs/$feature_name/test-report.md
    Read $PROJECT_ROOT/specs/$feature_name/tasks.md

    Execute a single test-fix loop for feature '$feature_name':
    1. Analyze the failing tests from test-report.md
    2. Only fix blockers that make FEATURE_SCOPE_STATUS fail
    3. Do not spend this loop fixing unrelated historical repo-wide debt
    4. Apply the minimal patch
    5. Re-run the most relevant feature-scope tests first
    6. Re-run broader repo tests only to re-check whether debt remains non-blocking or has become a real regression
    7. Update specs/$feature_name/test-report.md with the new result summary and machine-readable lines:
       FEATURE_SCOPE_STATUS: PASS|FAIL
       FULL_REPO_STATUS: PASS|FAIL|NOT_RUN
       REPO_DEBT_STATUS: PASS|FAIL|NOT_RUN
       WORKFLOW_VERDICT: PASS|FAIL
    8. If tests still fail, clearly explain whether the blocker is in feature scope or historical debt
  "

  workflow_verdict=$(extract_report_field "$test_report" "WORKFLOW_VERDICT")
  if [ "$workflow_verdict" = "FAIL" ]; then
    echo "  ⚠️ 自动修复后测试仍失败"
    notify "❌ Step 4.5 结束: 自动修复后仍失败 ($feature_name)"
    return 1
  fi

  echo "  ✅ 自动修复后测试通过"
  notify "✅ Step 4.5 完成: 自动修复并重测通过 ($feature_name)"
  return 0
}
