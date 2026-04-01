#!/bin/bash
# rollback.sh — /rollback command: rollback a feature using deploy-executor script or git revert
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_rollback() {
  local feature_name="$1"
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /rollback {需求名称}"
    return 1
  fi

  echo "Starting rollback for: $feature_name"
  notify "⏪ 开始回滚: $feature_name"

  if [ -f "$PROJECT_ROOT/.claude/extensions/deploy-executor/scripts/rollback.sh" ]; then
    bash "$PROJECT_ROOT/.claude/extensions/deploy-executor/scripts/rollback.sh" "$feature_name"
  else
    # 使用 git revert 作为默认回滚方式
    opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
      Read $PROJECT_ROOT/.claude/extensions/deploy-executor/SKILL.md
      Rollback feature '$feature_name': git revert the relevant commits and push.
    "
  fi

  # Jira 同步
  jira_sync "rollback" "$feature_name"

  notify "⏪ 回滚完成: $feature_name"
  echo "  ✅ 回滚完成: $feature_name"
}
