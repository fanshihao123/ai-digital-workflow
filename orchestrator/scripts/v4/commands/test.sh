#!/bin/bash
# test.sh — /test command: trigger tests (Step 4) for a feature or run all tests
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_test() {
  echo "Running tests..."
  FEATURE=$(detect_feature_name)
  if [ -n "$FEATURE" ]; then
    step4_test "$FEATURE"
  else
    if command -v codex &>/dev/null; then
      codex exec --full-auto "
        Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md (if exists)
        Run all tests in $PROJECT_ROOT and generate a summary report.
        Execute: typecheck, lint, build, unit tests, e2e tests (if available).
        Print results to stdout.
      "
    else
      echo "  ❌ codex 未安装，无法执行测试"
      return 1
    fi
  fi
}
