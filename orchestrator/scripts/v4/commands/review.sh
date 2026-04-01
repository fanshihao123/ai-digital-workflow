#!/bin/bash
# review.sh — /review command: trigger code review (Step 3) for a feature or recent changes
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_review() {
  local ARGS="$1"
  echo "Starting code review..."
  FEATURE=$(detect_feature_name)
  if [ -n "$FEATURE" ]; then
    step3_review "$FEATURE"
  else
    MODEL=$(select_model "low")
    opencli claude --print --permission-mode bypassPermissions --model "$MODEL" -p "
      Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
      Read $PROJECT_ROOT/.claude/SECURITY.md
      Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
      Review recent changes: $ARGS
    "
  fi
}
