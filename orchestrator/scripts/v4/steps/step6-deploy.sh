#!/bin/bash
# step6-deploy.sh — Step 6: 部署（扩展 — 按需）
# Sourced by v4/handler.sh; all lib modules already loaded

step6_deploy() {
  local feature_name="$1"

  ensure_not_paused "$feature_name" "step6_deploy" || return 0

  echo "=== Step 6: 部署 ==="

  # human-gate G2：部署门控（如启用）
  if [ -n "${FEISHU_APPROVAL_CODE:-}" ]; then
    human_gate_deploy "$feature_name" || {
      echo "  部署审批被拒绝，跳过部署"
      return 0
    }
  fi

  # deploy-executor（如启用）
  if [ "${ENABLE_DEPLOY:-false}" = "true" ]; then
    echo "  [deploy-executor] 执行部署..."
    notify "🚀 开始部署: $feature_name"

    opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
      Read $PROJECT_ROOT/.claude/extensions/deploy-executor/SKILL.md

      Execute deploy-executor for feature '$feature_name':
      1. Generate deploy-manifest.json
      2. Deploy using strategy: ${DEPLOY_STRATEGY:-push}
      3. Health check: ${DEPLOY_HEALTH_URL:-http://localhost:3000/health} (timeout: ${DEPLOY_TIMEOUT:-150}s)
      4. If health check fails, run rollback via scripts/rollback.sh
      5. Report result
    "

    # Jira 同步
    jira_sync "deployed" "$feature_name"
  else
    echo "  deploy-executor 未启用，跳过部署"
  fi
}
