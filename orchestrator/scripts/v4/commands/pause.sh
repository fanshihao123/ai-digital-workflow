#!/bin/bash
# pause.sh — /pause command: manually pause the workflow, save checkpoint and requirements.md snapshot
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_pause() {
  local feature_name="$1"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"

  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /pause {需求名称}"
    return 1
  fi
  if ! validate_feature_name "$feature_name"; then
    echo "❌ 非法的 feature name: $feature_name"
    return 1
  fi

  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  if [ ! -d "$spec_dir" ]; then
    echo "❌ 未找到 specs 目录: $spec_dir"
    return 1
  fi

  # 防止重复暂停
  if has_paused_state "$feature_name"; then
    local already_at
    already_at=$(get_paused_field "$feature_name" "paused_at")
    echo "⚠️ '$feature_name' 已处于暂停状态（暂停于 $already_at）"
    if has_pending_spec_review "$feature_name"; then
      echo "   当前因 Spec 审查严重问题阻断，请用: /fix $feature_name {修改指导}"
    else
      echo "   修改需求后执行: /continue $feature_name"
    fi
    return 0
  fi

  # 从 workflow-log 计算断点（下一个未完成的 Step）
  local last_done_step=1
  if [ -f "$pipeline_log" ]; then
    for step in 2 3 4 5 6 7; do
      if grep -q "STEP_${step}_DONE" "$pipeline_log" 2>/dev/null; then
        last_done_step=$step
      fi
    done
  fi
  local paused_step=$((last_done_step + 1))

  # 快照 requirements.md
  local req_file="$spec_dir/requirements.md"
  local snapshot_file="$spec_dir/requirements.md.snapshot"
  if [ -f "$req_file" ]; then
    cp "$req_file" "$snapshot_file"
    echo "  [pause] requirements.md 快照已保存" >&2
  else
    echo "  ⚠️ 未找到 requirements.md，快照跳过" >&2
  fi

  # 写入 paused.json
  jq -n \
    --arg feature "$feature_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ps "$paused_step" \
    --argjson ls "$last_done_step" \
    '{feature:$feature,status:"paused",paused_at:$ts,paused_step:$ps,last_done_step:$ls,requirements_snapshot:"requirements.md.snapshot"}' \
    > "$spec_dir/paused.json"

  terminate_feature_pipeline_processes "$feature_name"

  log "PIPELINE_PAUSED_BY_USER: $feature_name at step $paused_step" "$pipeline_log"
  notify "⏸️ 工作流已手动暂停 (断点 Step $paused_step): $feature_name"
  echo "⏸️ 已暂停 '$feature_name'（断点 Step $paused_step）"
  echo "   - 如需改需求: 编辑 $WORKFLOW_DATA_DIR/$feature_name/requirements.md，然后 /continue $feature_name"
  echo "   - 不改需求:  直接 /continue $feature_name"
}
