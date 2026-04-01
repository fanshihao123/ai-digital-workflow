#!/bin/bash
# integrations.sh — Jira + human-gate integrations
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# Jira 同步（如启用）
jira_sync() {
  local phase="$1"
  local feature_name="$2"
  local details="${3:-}"

  if [ -z "${JIRA_BASE_URL:-}" ] || [ -z "${JIRA_TOKEN:-}" ]; then
    return 0
  fi

  local jira_key
  jira_key=$(get_jira_key "$feature_name")
  if [ -z "$jira_key" ]; then
    return 0
  fi

  echo "  [jira-sync] $jira_key → $phase"
  bash "$PROJECT_ROOT/.claude/extensions/jira-sync/scripts/sync-jira.sh" \
    "$jira_key" "$phase" "$feature_name" "$details" 2>/dev/null || true
}

# Human-gate 安全门控检查（G1: code-review 后）
human_gate_security() {
  local feature_name="$1"
  if [ -z "${FEISHU_APPROVAL_CODE:-}" ]; then
    return 0
  fi
  local result
  result=$(bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/detect-security-changes.sh" \
    "$feature_name" 2>/dev/null || echo "NO_GATE_REQUIRED")
  if [ "$result" = "SECURITY_GATE_REQUIRED" ]; then
    echo "  [human-gate G1] 检测到安全变更，等待飞书审批..."
    notify "🔒 安全门控触发: $feature_name\n等待审批中..."
    bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/feishu-approval-gate.sh" \
      security "$feature_name" "安全变更审批" || {
      notify "❌ 安全审批被拒绝: $feature_name"
      echo "  [human-gate G1] 审批被拒绝，流水线暂停"
      return 1
    }
    echo "  [human-gate G1] 审批通过"
  fi
}

# Human-gate 部署门控（G2: doc-syncer 后）
human_gate_deploy() {
  local feature_name="$1"
  if [ -z "${FEISHU_APPROVAL_CODE:-}" ]; then
    return 0
  fi
  echo "  [human-gate G2] 部署审批，等待飞书审批..."
  notify "🚀 部署审批: $feature_name\n等待审批中..."
  bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/feishu-approval-gate.sh" \
    deploy "$feature_name" "部署审批" || {
    notify "❌ 部署审批被拒绝: $feature_name"
    echo "  [human-gate G2] 审批被拒绝，跳过部署"
    return 1
  }
  echo "  [human-gate G2] 审批通过"
}
