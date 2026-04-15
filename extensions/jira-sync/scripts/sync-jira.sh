#!/bin/bash
# sync-jira.sh — Jira 双向同步
# 用法: bash sync-jira.sh <issue-key> <phase> <feature-name> [details]

set -euo pipefail

ISSUE_KEY="${1:?用法: sync-jira.sh <issue-key> <phase> <feature-name> [details]}"
PHASE="${2:?}"
FEATURE_NAME="${3:?}"
DETAILS="${4:-}"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

# 获取默认分支（不硬编码 main）
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

for VAR in JIRA_BASE_URL JIRA_TOKEN JIRA_USER_EMAIL; do
  if [ -z "${!VAR:-}" ]; then
    echo "⚠️ 跳过 Jira 同步：缺少 $VAR"
    exit 0
  fi
done

# 验证 URL 格式
if ! [[ "$JIRA_BASE_URL" =~ ^https?://.+ ]]; then
  echo "❌ 非法的 Jira URL: $JIRA_BASE_URL"
  exit 1
fi

AUTH="$JIRA_USER_EMAIL:$JIRA_TOKEN"
API="$JIRA_BASE_URL/rest/api/3"

jira_transition() {
  local key="$1" name="$2"
  local tid
  tid=$(curl -s --max-time 10 --connect-timeout 5 -u "$AUTH" "$API/issue/$key/transitions" | \
    jq -r --arg name "$name" '.transitions[] | select(.name==$name) | .id')
  if [ -n "$tid" ] && [ "$tid" != "null" ]; then
    curl -s --max-time 10 --connect-timeout 5 -u "$AUTH" -H "Content-Type: application/json" \
      -X POST "$API/issue/$key/transitions" \
      -d "$(jq -n --arg id "$tid" '{transition: {id: $id}}')" > /dev/null && \
    echo "  ✅ $key → $name"
  else
    echo "  ⚠️ Transition '$name' 不可用"
  fi
}

jira_comment() {
  local key="$1" text="$2"
  local payload
  payload=$(jq -n --arg text "$text" '{
    body: {
      type: "doc",
      version: 1,
      content: [{
        type: "paragraph",
        content: [{type: "text", text: $text}]
      }]
    }
  }')
  curl -s --max-time 10 --connect-timeout 5 -u "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/issue/$key/comment" \
    -d "$payload" > /dev/null
  echo "  ✅ 评论已添加"
}

echo "🔄 Jira 同步: $ISSUE_KEY ($PHASE)"

case "$PHASE" in
  requirements-done)
    jira_transition "$ISSUE_KEY" "In Analysis"
    jira_comment "$ISSUE_KEY" "[AI Workflow] Phase 1 完成：需求已解析 → $WORKFLOW_DATA_DIR/${FEATURE_NAME}/requirements.md"
    ;;
  design-done)
    jira_transition "$ISSUE_KEY" "In Design"
    jira_comment "$ISSUE_KEY" "[AI Workflow] Phase 2 完成：设计已生成，复杂度: ${DETAILS:-unknown}"
    ;;
  dev-start)
    jira_transition "$ISSUE_KEY" "In Progress"
    jira_comment "$ISSUE_KEY" "[AI Workflow] Phase 3 开始：开发执行中"
    ;;
  review-done)
    jira_comment "$ISSUE_KEY" "[AI Workflow] Phase 4 完成：代码审查 ${DETAILS:-PASS}"
    ;;
  test-done)
    jira_comment "$ISSUE_KEY" "[AI Workflow] Phase 5 完成：${DETAILS:-测试通过}"
    ;;
  deployed)
    jira_transition "$ISSUE_KEY" "Done"
    COMMITS=$(git log --oneline "${DEFAULT_BRANCH}..HEAD" 2>/dev/null | head -5 || echo "N/A")
    jira_comment "$ISSUE_KEY" "[AI Workflow] 已部署 ✅\n提交: $(git rev-parse --short HEAD 2>/dev/null || echo 'N/A')\n$COMMITS"
    ;;
  rollback)
    jira_transition "$ISSUE_KEY" "Reopened"
    jira_comment "$ISSUE_KEY" "[AI Workflow] ⚠️ 已回滚: ${DETAILS:-健康检查失败}"
    ;;
  *)
    echo "⚠️ 未知 phase: $PHASE"
    ;;
esac
