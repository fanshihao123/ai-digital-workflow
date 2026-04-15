#!/bin/bash
# spec-review.sh — Spec review blocking state management
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 保存 spec 审查阻断状态（CRITICAL >= 3 时调用）
save_spec_review_state() {
  local feature_name="$1"
  local critical_count="$2"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-spec-review.json"
  jq -n \
    --arg feature "$feature_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cc "$critical_count" \
    '{feature:$feature,status:"awaiting",timestamp:$ts,critical_count:$cc}' \
    > "$state_file"
}

# 检查是否有待处理的 spec 审查阻断
has_pending_spec_review() {
  local feature_name="$1"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-spec-review.json"
  [ -f "$state_file" ] && jq -e '.status == "awaiting"' "$state_file" >/dev/null 2>&1
}

# 清理 spec 审查阻断状态
clear_spec_review_state() {
  local feature_name="$1"
  rm -f "$WORKFLOW_DATA_DIR/$feature_name/awaiting-spec-review.json"
}
