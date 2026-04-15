#!/bin/bash
# resume.sh — /resume command: resume from crash/unexpected interruption, continue from last completed step
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_resume() {
  local feature_name="$1"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"

  # 若未指定 feature，自动检测
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /resume {需求名称}"
    echo "   提示: 用 /status 查看当前活跃需求"
    return 1
  fi

  # 若处于等待澄清状态，提示用 /answer
  if has_pending_clarification "$feature_name"; then
    local questions
    questions=$(get_clarification_field "$feature_name" "questions")
    echo "⏸️ '$feature_name' 正在等待需求澄清，请用 /answer 回复："
    echo "$questions"
    echo ""
    echo "用法: /answer $feature_name 1.你的答案 2.你的答案"
    return 0
  fi

  # 若处于 spec 审查阻断状态，提示用 /fix-spec
  if has_pending_spec_review "$feature_name"; then
    echo "⏸️ '$feature_name' 处于 Spec 审查阻断状态（CRITICAL 问题未解决）"
    echo "   请用 /fix-spec $feature_name {修改指导} 告诉 AI 如何修改"
    echo "   示例: /fix-spec $feature_name 去掉短信验证，用JWT替换session"
    return 0
  fi

  # 从 workflow-log 判断断点
  local last_done_step=1
  if [ -f "$pipeline_log" ]; then
    for step in 2 3 4 5 6 7; do
      if grep -q "STEP_${step}_DONE" "$pipeline_log" 2>/dev/null; then
        last_done_step=$step
      fi
    done
  fi

  local resume_from=$((last_done_step + 1))

  notify "▶️ 从 Step $resume_from 恢复工作流: $feature_name"
  echo "  [resume] 从 Step $resume_from 继续: $feature_name" >&2
  log "PIPELINE_RESUME: $feature_name from Step $resume_from" "$pipeline_log"

  case "$resume_from" in
    2) run_pipeline_steps_2_to_7 "$feature_name" ;;
    3) step3_review "$feature_name" && step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    4) step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    5) step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    6) step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    7) step7_notify "$feature_name" ;;
    *) echo "✅ '$feature_name' 流水线已全部完成，无需恢复" ;;
  esac
}
