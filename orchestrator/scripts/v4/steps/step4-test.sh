#!/bin/bash
# step4-test.sh — Step 4: test-runner（测试 + 覆盖率）+ 自动修复回路
# Sourced by v4/handler.sh; all lib modules already loaded

step4_test() {
  local feature_name="$1"
  local test_report="$WORKFLOW_DATA_DIR/$feature_name/test-report.md"
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
    notify "❌ 测试失败: $feature_name\n查看 $WORKFLOW_DATA_DIR/$feature_name/test-report.md"
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
  local test_report="$WORKFLOW_DATA_DIR/$feature_name/test-report.md"
  local workflow_verdict

  echo "=== Step 4.5: 测试失败自动修复 ==="
  notify "🩹 Step 4.5: 开始自动修复测试失败 ($feature_name)"

  if [ ! -f "$test_report" ]; then
    echo "  ❌ 缺少 test-report.md，无法进入修复回路"
    notify "❌ Step 4.5 失败: 缺少 test-report.md ($feature_name)"
    return 1
  fi

  if ! command -v codex &>/dev/null; then
    echo "  ❌ codex 未安装，无法执行测试修复"
    notify "❌ Step 4.5 失败: codex 未安装 ($feature_name)"
    return 1
  fi

  set +e
  codex exec --full-auto "
    你是 test-fixer，负责修复 feature '$feature_name' 的测试失败。

    请读取以下文件：
    - $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md（如存在）
    - $PROJECT_ROOT/.claude/CODING_GUIDELINES.md（如存在）
    - $PROJECT_ROOT/.claude/ARCHITECTURE.md（如存在）
    - $WORKFLOW_DATA_DIR/$feature_name/test-report.md
    - $WORKFLOW_DATA_DIR/$feature_name/tasks.md

    执行单次测试修复回路：
    1. 分析 test-report.md 中的失败测试
    2. 只修复导致 FEATURE_SCOPE_STATUS 失败的阻断项
    3. 不要修复无关的历史全仓技术债
    4. 应用最小化补丁
    5. 重新运行 feature-scope 相关测试
    6. 重新运行全仓测试，判断债务是否仍为非阻断
    7. 更新 $test_report，保持原有报告格式，末尾必须包含机器可读行：
       FEATURE_SCOPE_STATUS: PASS|FAIL
       FULL_REPO_STATUS: PASS|FAIL|NOT_RUN
       REPO_DEBT_STATUS: PASS|FAIL|NOT_RUN
       WORKFLOW_VERDICT: PASS|FAIL
    8. 如测试仍失败，清楚说明阻断项在 feature 范围还是历史债
  " 2>&1
  set -e

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
