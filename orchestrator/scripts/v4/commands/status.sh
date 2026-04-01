#!/bin/bash
# status.sh — /status command: show git log, active specs, and extension toggle states
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_status() {
  echo "=== Git Log ==="
  git -C "$PROJECT_ROOT" log --oneline -10
  echo ""
  echo "=== Active Specs ==="
  ls "$PROJECT_ROOT/specs/" 2>/dev/null || echo "No active specs"
  echo ""
  echo "=== Extension Status ==="
  echo "  worktree-parallel: ${ENABLE_WORKTREE_PARALLEL:-disabled}"
  echo "  ui-restorer:       ${ENABLE_UI_RESTORER:-disabled}"
  echo "  human-gate:        $([ -n "${FEISHU_APPROVAL_CODE:-}" ] && echo "enabled" || echo "disabled")"
  echo "  deploy-executor:   ${ENABLE_DEPLOY:-disabled}"
  echo "  jira-sync:         $([ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_TOKEN:-}" ] && echo "enabled" || echo "disabled")"
}
