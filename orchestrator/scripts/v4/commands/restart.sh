#!/bin/bash
# restart.sh — /restart command: resume from paused state with intelligent requirements diff
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_restart() {
  local feature_name="$1"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"

  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /restart {需求名称}"
    return 1
  fi
  if ! validate_feature_name "$feature_name"; then
    echo "❌ 非法的 feature name: $feature_name"
    return 1
  fi

  # 优先检查是否有待澄清状态（避免与 paused.json 产生歧义）
  if has_pending_clarification "$feature_name"; then
    echo "⚠️ '$feature_name' 处于等待澄清状态，请先用 /answer 回复问题后再 /restart"
    return 1
  fi

  # 检查是否处于 spec 审查阻断状态（必须用 /fix-spec 恢复）
  if has_pending_spec_review "$feature_name"; then
    echo "⚠️ '$feature_name' 处于 Spec 审查阻断状态（CRITICAL 问题未解决）"
    echo "   请用 /fix-spec $feature_name {修改指导} 告诉 AI 如何修改"
    return 1
  fi

  if ! has_paused_state "$feature_name"; then
    echo "❌ '$feature_name' 不处于 paused 状态"
    echo "   提示: 先用 /pause $feature_name 暂停工作流"
    return 1
  fi

  local paused_step
  paused_step=$(get_paused_field "$feature_name" "paused_step")
  local paused_at
  paused_at=$(get_paused_field "$feature_name" "paused_at")

  echo "  [restart] '$feature_name' 暂停于 $paused_at，断点 Step $paused_step" >&2
  notify "🔄 开始重启工作流: $feature_name (断点 Step $paused_step)"
  log "PIPELINE_RESTART_START: $feature_name from Step $paused_step" "$pipeline_log"

  # 当断点已经在 Step 3 及之后，默认视为执行态恢复，不再回到 spec diff/update
  if is_numeric "$paused_step" && [ "$paused_step" -ge 3 ]; then
    echo "  [restart] 断点 >= Step 3，跳过 requirements diff，直接从断点继续" >&2
    rm -f "$WORKFLOW_DATA_DIR/$feature_name/paused.json"
    log "PIPELINE_PAUSED_STATE_CLEARED: $feature_name" "$pipeline_log"
    notify "▶️ 从 Step $paused_step 继续工作流: $feature_name"
    log "PIPELINE_RESTART_RESUME: $feature_name from Step $paused_step" "$pipeline_log"

    case "$paused_step" in
      3) step3_review "$feature_name" && step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
      4) step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
      5) step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
      6) step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
      7) step7_notify "$feature_name" ;;
      *) echo "✅ '$feature_name' 所有 Step 均已完成，无需继续" ;;
    esac
    return 0
  fi

  # 检查快照是否存在
  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  local snapshot_file="$spec_dir/requirements.md.snapshot"
  if [ ! -f "$snapshot_file" ]; then
    echo "  ⚠️ 未找到 requirements.md.snapshot，跳过 diff，直接从断点继续" >&2
    rm -f "$spec_dir/paused.json"
    cmd_resume "$feature_name"
    return $?
  fi

  # 增量更新（有变更）或直接继续（无变更）
  step1_restart_with_diff "$feature_name" "$paused_step"
  local diff_result=$?

  if [ $diff_result -eq 2 ]; then
    # 再次遇到 [UNCERTAIN]，保留 paused.json 等用户 /answer 后再 /restart
    echo "⏸️ 需求变更中仍有未确认问题，已暂停"
    echo "   请用 /answer $feature_name 回复后，再次执行 /restart $feature_name"
    return 0
  fi

  # 消费 paused.json + 快照
  rm -f "$spec_dir/paused.json" "$spec_dir/requirements.md.snapshot"
  log "PIPELINE_PAUSED_STATE_CLEARED: $feature_name" "$pipeline_log"

  notify "▶️ 从 Step $paused_step 继续工作流: $feature_name"
  log "PIPELINE_RESTART_RESUME: $feature_name from Step $paused_step" "$pipeline_log"

  case "$paused_step" in
    2) run_pipeline_steps_2_to_7 "$feature_name" ;;
    3) step3_review "$feature_name" && step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    4) step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    5) step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    6) step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    7) step7_notify "$feature_name" ;;
    *) echo "✅ '$feature_name' 所有 Step 均已完成，无需继续" ;;
  esac
}
