#!/bin/bash
# status.sh — /status command: show git log, active specs, and extension toggle states
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_status() {
  echo "=== Git Log ==="
  git -C "$PROJECT_ROOT" log --oneline -10
  echo ""

  echo "=== Pipeline Progress ==="
  progress_render_all
  echo ""

  echo "=== Active Specs ==="
  for spec_dir in "$PROJECT_ROOT"/specs/*/; do
    [ -d "$spec_dir" ] || continue
    local fname
    fname=$(basename "$spec_dir")
    [ "$fname" = "archive" ] && continue
    local status="unknown"
    if [ -f "$spec_dir/state.json" ]; then
      status=$(jq -r '.status // "unknown"' "$spec_dir/state.json" 2>/dev/null)
      local step
      step=$(jq -r '.step // "?"' "$spec_dir/state.json" 2>/dev/null)
      local resume_cmd
      resume_cmd=$(jq -r '.resume_command // ""' "$spec_dir/state.json" 2>/dev/null)
      echo "  $fname — status: $status, step: $step$([ -n "$resume_cmd" ] && echo ", next: $resume_cmd")"
    elif [ -f "$spec_dir/progress.json" ]; then
      status=$(jq -r '.final_status // "unknown"' "$spec_dir/progress.json" 2>/dev/null)
      echo "  $fname — $status"
    else
      echo "  $fname"
    fi
  done
  echo ""

  echo "=== Extension Status ==="
  echo "  worktree-parallel: ${ENABLE_WORKTREE_PARALLEL:-disabled}"
  echo "  ui-restorer:       ${ENABLE_UI_RESTORER:-disabled}"
  echo "  human-gate:        $([ -n "${FEISHU_APPROVAL_CODE:-}" ] && echo "enabled" || echo "disabled")"
  echo "  deploy-executor:   ${ENABLE_DEPLOY:-disabled}"
  echo "  jira-sync:         $([ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_TOKEN:-}" ] && echo "enabled" || echo "disabled")"
}
