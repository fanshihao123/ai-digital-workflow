#!/bin/bash
# test.sh — /test command: trigger tests (Step 4) for a feature or run all tests
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_test() {
  echo "Running tests..."
  FEATURE=$(detect_feature_name)
  if [ -n "$FEATURE" ]; then
    step4_test "$FEATURE"
  else
    opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
      Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
      Run all tests and generate report.
    "
  fi
}
