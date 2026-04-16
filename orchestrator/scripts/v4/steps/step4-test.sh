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

  # 清除上一轮的陈旧报告，避免 /resume 或重试时读到旧的 FAIL 结论
  rm -f "$test_report"

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

  # 将仓库外文件内联到 prompt，避免 Codex workspace-write 沙箱读写限制
  local test_report_content tasks_content
  test_report_content=$(cat "$test_report")
  tasks_content=$(cat "$WORKFLOW_DATA_DIR/$feature_name/tasks.md" 2>/dev/null || echo "(无)")

  set +e
  codex exec --full-auto "
    你是 test-fixer，负责修复 feature '$feature_name' 的测试失败。

    请读取以下文件（如存在）：
    - $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
    - $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    - $PROJECT_ROOT/.claude/ARCHITECTURE.md

    以下是当前测试报告内容：
    <test-report>
$test_report_content
    </test-report>

    以下是任务列表：
    <tasks>
$tasks_content
    </tasks>

    执行单次测试修复回路：
    1. 分析上面测试报告中的失败测试
    2. 只修复导致 FEATURE_SCOPE_STATUS 失败的阻断项
    3. 不要修复无关的历史全仓技术债
    4. 应用最小化补丁
    5. 重新运行 feature-scope 相关测试验证修复
    6. 不需要生成或更新任何报告文件，只需完成代码修复
  " 2>&1
  set -e

  # Codex 只负责修复代码，报告由外层 shell 重新生成（避免沙箱写仓库外路径失败）
  echo "  [Step 4.5] 修复完成，重新运行测试生成报告..." >&2
  run_local_test "$feature_name"

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
