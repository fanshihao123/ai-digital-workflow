#!/bin/bash
# feishu-approval-gate.sh — 创建飞书审批并阻塞等待结果
# 用法: bash feishu-approval-gate.sh <gate_type> <feature_name> [summary]
#   gate_type: security | deploy
#   返回值: 0=通过, 1=拒绝, 2=取消, 3=超时

set -euo pipefail

GATE_TYPE="${1:?用法: feishu-approval-gate.sh <security|deploy> <feature-name> [summary]}"
FEATURE_NAME="${2:?请提供功能名称}"
SUMMARY="${3:-无附加说明}"

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_FILE="$PROJECT_ROOT/specs/${FEATURE_NAME}/.workflow-log"
TIMEOUT="${HITL_TIMEOUT:-3600}"

# 加载环境变量
[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

# 检查必要配置
for VAR in FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_APPROVAL_CODE; do
  if [ -z "${!VAR:-}" ]; then
    echo "❌ 缺少环境变量: $VAR"
    exit 1
  fi
done

# ------------------------------------------
# Step 1: 获取 tenant_access_token
# ------------------------------------------
get_token() {
  curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{
      \"app_id\": \"$FEISHU_APP_ID\",
      \"app_secret\": \"$FEISHU_APP_SECRET\"
    }" | jq -r '.tenant_access_token'
}

TOKEN=$(get_token)

# ------------------------------------------
# Step 2: 收集审批表单数据
# ------------------------------------------
collect_form_data() {
  local gate="$1"
  local feature="$2"
  local summary="$3"

  # 公共字段
  CHANGED_FILES=$(git diff --name-only main..HEAD 2>/dev/null | head -20 | tr '\n' ', ' || echo "unknown")
  COMMIT_COUNT=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")

  case "$gate" in
    security)
      # 安全门控特有字段
      RISK="medium"
      SECURITY_FILES=$(git diff --name-only main..HEAD 2>/dev/null | \
        grep -iE "(auth|security|crypto|cors|csrf|\.env|Dockerfile|nginx)" | \
        tr '\n' ', ' || echo "none")

      REVIEW_REPORT="$PROJECT_ROOT/specs/${feature}/review-report.md"
      SEC_FINDINGS="无"
      if [ -f "$REVIEW_REPORT" ]; then
        SEC_FINDINGS=$(grep -i "SEC-" "$REVIEW_REPORT" | head -5 || echo "无")
      fi

      cat << EOF
[
  {"id":"gate_type","type":"input","value":"🔒 安全相关代码变更"},
  {"id":"feature","type":"input","value":"$feature"},
  {"id":"summary","type":"textarea","value":"$summary"},
  {"id":"risk","type":"input","value":"$RISK"},
  {"id":"files","type":"textarea","value":"安全敏感文件: $SECURITY_FILES\n全部变更: $CHANGED_FILES"},
  {"id":"review_verdict","type":"input","value":"PASS (待安全确认)"}
]
EOF
      ;;

    deploy)
      # 部署门控特有字段
      TEST_REPORT="$PROJECT_ROOT/specs/${feature}/test-report.md"
      COVERAGE="unknown"
      if [ -f "$TEST_REPORT" ]; then
        COVERAGE=$(grep -oP 'Statements.*?(\d+)%' "$TEST_REPORT" | grep -oP '\d+%' | head -1 || echo "unknown")
      fi

      COMMITS=$(git log --oneline main..HEAD 2>/dev/null | head -10 || echo "none")
      ROLLBACK="git revert --no-commit HEAD~${COMMIT_COUNT}..HEAD && git commit -m 'rollback: ${feature}'"

      cat << EOF
[
  {"id":"gate_type","type":"input","value":"🚀 生产环境部署"},
  {"id":"feature","type":"input","value":"$feature"},
  {"id":"summary","type":"textarea","value":"$summary\n\n提交记录:\n$COMMITS"},
  {"id":"risk","type":"input","value":"${COMMIT_COUNT} 个提交"},
  {"id":"files","type":"textarea","value":"$CHANGED_FILES"},
  {"id":"review_verdict","type":"input","value":"PASS"},
  {"id":"test_coverage","type":"input","value":"$COVERAGE"},
  {"id":"rollback_plan","type":"textarea","value":"$ROLLBACK"}
]
EOF
      ;;
  esac
}

FORM_DATA=$(collect_form_data "$GATE_TYPE" "$FEATURE_NAME" "$SUMMARY")

# ------------------------------------------
# Step 3: 创建审批实例
# ------------------------------------------
echo "📋 创建飞书审批实例..."

RESPONSE=$(curl -s -X POST "https://open.feishu.cn/open-apis/approval/v4/instances" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"approval_code\": \"$FEISHU_APPROVAL_CODE\",
    \"open_id\": \"${FEISHU_APPROVER_ID:-}\",
    \"form\": $(echo "$FORM_DATA" | jq -Rs .)
  }")

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.data.instance_code // empty')

if [ -z "$INSTANCE_ID" ]; then
  echo "❌ 创建审批实例失败:"
  echo "$RESPONSE" | jq .
  echo "[$(date +%H:%M:%S)] HITL_CREATE_FAILED: $GATE_TYPE" >> "$LOG_FILE" 2>/dev/null
  exit 1
fi

echo "✅ 审批实例: $INSTANCE_ID"
echo "[$(date +%H:%M:%S)] HITL_CREATED: $GATE_TYPE (instance: $INSTANCE_ID)" >> "$LOG_FILE" 2>/dev/null

# 发送飞书消息通知
GATE_EMOJI=$( [ "$GATE_TYPE" = "security" ] && echo "🔒" || echo "🚀" )
GATE_LABEL=$( [ "$GATE_TYPE" = "security" ] && echo "安全变更审批" || echo "生产部署审批" )

bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" \
  "${GATE_EMOJI} 需要审批：${GATE_LABEL}\n功能：${FEATURE_NAME}\n摘要：${SUMMARY}\n\n请前往飞书审批流处理 ⏳" \
  2>/dev/null || true

# ------------------------------------------
# Step 4: 阻塞轮询等待审批结果
# ------------------------------------------
echo "⏳ 等待审批结果... (超时: ${TIMEOUT}s, 每30s检查一次)"

ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  # token 可能过期，每 10 分钟刷新
  if [ $((ELAPSED % 600)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
    TOKEN=$(get_token)
  fi

  STATUS=$(curl -s -X GET \
    "https://open.feishu.cn/open-apis/approval/v4/instances/${INSTANCE_ID}" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.data.status // "UNKNOWN"')

  case "$STATUS" in
    APPROVED)
      echo "✅ 审批通过！"
      echo "[$(date +%H:%M:%S)] HITL_APPROVED: $GATE_TYPE (${ELAPSED}s)" >> "$LOG_FILE" 2>/dev/null
      bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" \
        "✅ ${GATE_LABEL} 已通过：${FEATURE_NAME}" 2>/dev/null || true
      exit 0
      ;;
    REJECTED)
      echo "❌ 审批被拒绝"
      REJECT_REASON=$(curl -s -X GET \
        "https://open.feishu.cn/open-apis/approval/v4/instances/${INSTANCE_ID}" \
        -H "Authorization: Bearer $TOKEN" | jq -r '.data.comment // "无"')
      echo "   拒绝原因: $REJECT_REASON"
      echo "[$(date +%H:%M:%S)] HITL_REJECTED: $GATE_TYPE (reason: $REJECT_REASON)" >> "$LOG_FILE" 2>/dev/null
      bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" \
        "❌ ${GATE_LABEL} 被拒绝：${FEATURE_NAME}\n原因：${REJECT_REASON}\n流水线已暂停" 2>/dev/null || true
      exit 1
      ;;
    CANCELED)
      echo "⚠️ 审批已取消"
      echo "[$(date +%H:%M:%S)] HITL_CANCELED: $GATE_TYPE" >> "$LOG_FILE" 2>/dev/null
      exit 2
      ;;
    PENDING|UNKNOWN)
      # 每 5 分钟输出一次等待状态
      if [ $((ELAPSED % 300)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        echo "  ⏳ 仍在等待... (已过 $((ELAPSED/60)) 分钟)"
      fi
      sleep 30
      ELAPSED=$((ELAPSED + 30))
      ;;
  esac
done

echo "⏰ 审批超时 (${TIMEOUT}s)"
echo "[$(date +%H:%M:%S)] HITL_TIMEOUT: $GATE_TYPE (${TIMEOUT}s)" >> "$LOG_FILE" 2>/dev/null
bash "$PROJECT_ROOT/.claude/orchestrator/scripts/feishu-notify.sh" \
  "⏰ ${GATE_LABEL} 超时：${FEATURE_NAME}，流水线已暂停" 2>/dev/null || true
exit 3
