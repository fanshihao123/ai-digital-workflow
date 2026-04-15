#!/bin/bash
# clarification.sh — Open question / clarification state management
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 从 requirements.md 的"开放问题"部分提取未勾选的 [ ] 项
extract_open_questions() {
  local feature_name="$1"
  local req_file="$WORKFLOW_DATA_DIR/$feature_name/requirements.md"
  [ -f "$req_file" ] || return 0
  local in_section=false
  while IFS= read -r line; do
    if echo "$line" | grep -qiE "^#+[[:space:]]*(开放问题|open.question)"; then
      in_section=true; continue
    fi
    if $in_section && echo "$line" | grep -qE "^#"; then
      in_section=false; continue
    fi
    if $in_section && echo "$line" | grep -qE "^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]"; then
      echo "$line"
    fi
  done < "$req_file"
}

# 保存暂停等待状态到 $WORKFLOW_DATA_DIR/{feature}/awaiting-clarification.json
save_clarification_state() {
  local feature_name="$1"
  local original_input="$2"
  local questions_text="$3"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-clarification.json"
  jq -n \
    --arg feature "$feature_name" \
    --arg input "$original_input" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg qs "$questions_text" \
    '{feature:$feature,status:"awaiting",original_input:$input,timestamp:$ts,questions:$qs,answers:""}' \
    > "$state_file"
}

# 检查是否有待确认的暂停状态
has_pending_clarification() {
  local feature_name="$1"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-clarification.json"
  [ -f "$state_file" ] && jq -e '.status == "awaiting"' "$state_file" >/dev/null 2>&1
}

# 读取状态文件中的指定字段
get_clarification_field() {
  local feature_name="$1"
  local field="$2"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-clarification.json"
  [ -f "$state_file" ] && jq -r ".$field // empty" "$state_file" 2>/dev/null || true
}

# 将用户答复写入状态文件，并更新 status 为 answered
mark_clarification_answered() {
  local feature_name="$1"
  local answers="$2"
  local state_file="$WORKFLOW_DATA_DIR/$feature_name/awaiting-clarification.json"
  if [ -f "$state_file" ]; then
    local tmp; tmp=$(mktemp)
    jq --arg ans "$answers" '.status="answered"|.answers=$ans' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi
}

# 格式化开放问题并通过飞书发送给用户
notify_open_questions() {
  local feature_name="$1"
  local questions_text="$2"
  local q_count
  q_count=$(echo "$questions_text" | grep -c "." 2>/dev/null || echo 0)
  local questions_list=""
  local idx=1
  while IFS= read -r qline; do
    [ -z "$qline" ] && continue
    local q_text
    q_text=$(echo "$qline" \
      | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//' \
      | sed 's/\[INFERRED\][[:space:]]*//' \
      | xargs)
    questions_list+="${idx}. ${q_text}\n"
    idx=$((idx + 1))
  done <<< "$questions_text"

  local context="需求 '$feature_name' 的 Step 1 已暂停，检测到 ${q_count} 个开放问题需要用户确认后才能继续生成设计和任务。"
  local question="请逐一向用户提问：\n${questions_list}\n用户回复后执行：/answer $feature_name 1.答案 2.答案"
  agent_notify "$context" "$question" "$feature_name"
}
