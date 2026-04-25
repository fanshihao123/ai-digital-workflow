#!/bin/bash
# answer.sh — /answer command: provide clarification answers to resume a paused workflow
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_answer_clarification() {
  local args="$1"
  local feature_name
  feature_name=$(echo "$args" | awk '{print $1}')
  local answers
  answers=$(echo "$args" | cut -d' ' -f2-)
  [ "$answers" = "$feature_name" ] && answers=""

  if [ -z "$feature_name" ]; then
    echo "❌ 用法: /answer {需求名称} {你的答复}"
    echo "   示例: /answer user-login-oauth 1.需要邮件验证 2.不需要手机号"
    return 1
  fi
  if ! has_pending_clarification "$feature_name"; then
    echo "❌ 未找到 '$feature_name' 的待确认问题（或已过期）"
    echo "   提示: 用 /status 查看当前活跃需求"
    return 1
  fi
  if [ -z "$answers" ]; then
    echo "❌ 请提供答复内容"
    echo "   示例: /answer $feature_name 1.需要邮件验证 2.不需要手机号"
    return 1
  fi

  local original_input
  original_input=$(get_clarification_field "$feature_name" "original_input")
  mark_clarification_answered "$feature_name" "$answers"

  notify "▶️ 收到澄清，重新生成 spec: $feature_name"
  log "STEP_1_RESUME: $feature_name (用户提供澄清)" "$WORKFLOW_DATA_DIR/.workflow-log"

  # Stage 1a 恢复：仅更新 requirements.md（融入用户澄清，design/tasks 尚未生成）
  local model
  model=$(select_model "low")
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $WORKFLOW_DATA_DIR/$feature_name/requirements.md

    【重要】输出目录为 $WORKFLOW_DATA_DIR/$feature_name/（即 SKILL.md 中 \$WORKFLOW_DATA_DIR 的实际路径）。
    用户已为开放问题提供澄清，请仅覆写 $WORKFLOW_DATA_DIR/$feature_name/requirements.md：
    原始需求: $original_input
    用户澄清答复: $answers

    要求：
    - 已解答的开放问题从 [ ] 改为 [x]
    - 根据澄清内容更新 requirements.md
    - 仍有不确定的项保留 [ ]（不要强行推断）
    - 不要生成或修改 design.md、tasks.md
    Execute spec-writer Stage 1a with clarification context.
  " >&2

  # 清理状态文件（答复已消费）
  rm -f "$WORKFLOW_DATA_DIR/$feature_name/awaiting-clarification.json"

  # 再次检查是否仍有未解决的开放问题
  local remaining_questions
  remaining_questions=$(extract_open_questions "$feature_name")
  if [ -n "$remaining_questions" ]; then
    local rq_count
    rq_count=$(echo "$remaining_questions" | grep -c "." || echo 0)
    echo "  [clarification] 仍有 $rq_count 个未解决的开放问题，再次暂停" >&2
    save_clarification_state "$feature_name" "$original_input" "$remaining_questions"
    notify_open_questions "$feature_name" "$remaining_questions"
    log "STEP_1_PAUSED: $feature_name ($rq_count 开放问题，第2轮)" "$WORKFLOW_DATA_DIR/.workflow-log"
    return 0
  fi

  # Stage 1b：requirements.md 已确认，生成 design.md + tasks.md
  echo "  [Stage 1b] 澄清完成，生成 design.md + tasks.md..." >&2
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $WORKFLOW_DATA_DIR/$feature_name/requirements.md
    【重要】输出目录为 $WORKFLOW_DATA_DIR/$feature_name/（即 SKILL.md 中 \$WORKFLOW_DATA_DIR 的实际路径）。请将 design.md 和 tasks.md 写到该目录下。
    Execute spec-writer Stage 1b: generate design.md + tasks.md based on the confirmed requirements.md above.
  " >&2

  # 无剩余开放问题，继续 Stages 2+3，然后 Steps 2-7
  notify "✅ 澄清完成，继续 Stage 2+3: $feature_name"

  local complexity
  complexity=$(get_complexity "$feature_name")
  local task_count
  task_count=$(grep -c "^### Task" "$WORKFLOW_DATA_DIR/$feature_name/tasks.md" 2>/dev/null || echo 0)

  if [ "$task_count" -le 2 ] && [ "$complexity" = "low" ]; then
    notify "🟡 Step 1 完成（澄清后，简单任务跳过 Codex）: $feature_name"
  elif command -v codex &>/dev/null; then
    # Stage 2: Codex 审查
    echo "  [Stage 2] Codex 审查（澄清后）..." >&2
    codex exec --full-auto "
      审查 $WORKFLOW_DATA_DIR/$feature_name/ 下 requirements.md + design.md + tasks.md（13维度 R1-R4,D1-D4,T1-T5）
      输出格式: DIMENSION/VERDICT/DETAIL/SUGGESTION，最后 OVERALL/CRITICAL_ISSUES
    " > "$WORKFLOW_DATA_DIR/$feature_name/spec-review.md" 2>/dev/null || \
      echo "  ⚠️ Codex 审查失败，跳过 Stage 2" >&2

    # Stage 3: Claude 复审定稿
    if [ -f "$WORKFLOW_DATA_DIR/$feature_name/spec-review.md" ]; then
      echo "  [Stage 3] Claude 复审（澄清后）..." >&2
      local stage3_model
      stage3_model=$(select_model "$complexity")
      opencli claude --print --permission-mode bypassPermissions --model "$stage3_model" -p "
        Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
        Read $WORKFLOW_DATA_DIR/$feature_name/spec-review.md
        Read $WORKFLOW_DATA_DIR/$feature_name/requirements.md
        Read $WORKFLOW_DATA_DIR/$feature_name/design.md
        Read $WORKFLOW_DATA_DIR/$feature_name/tasks.md
        【重要】输出目录为 $WORKFLOW_DATA_DIR/$feature_name/（即 SKILL.md 中 \$WORKFLOW_DATA_DIR 的实际路径）。请将修改后的文件写回该目录。
        Execute spec-writer Stage 3: 复审定稿，PASS 项不改，ISSUE 项按建议修改，更新文件状态为 reviewed。
      " >&2

      # CRITICAL >= 3 阻断检查（与主路径一致）
      local critical_count
      critical_count=$(sed -n 's/.*CRITICAL_ISSUES:[[:space:]]*\([0-9]*\).*/\1/p' \
        "$WORKFLOW_DATA_DIR/$feature_name/spec-review.md" 2>/dev/null | tail -1)
      critical_count="${critical_count:-0}"
      if is_numeric "$critical_count" && [ "$critical_count" -ge 3 ]; then
        local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
        save_spec_review_state "$feature_name" "$critical_count"
        jq -n \
          --arg feature "$feature_name" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --argjson ps 1 --argjson ls 0 \
          '{feature:$feature,status:"paused",paused_at:$ts,paused_step:$ps,last_done_step:$ls,reason:"spec-review-critical",requirements_snapshot:"requirements.md.snapshot"}' \
          > "$spec_dir/paused.json"
        [ -f "$spec_dir/requirements.md" ] && cp "$spec_dir/requirements.md" "$spec_dir/requirements.md.snapshot"
        log "PIPELINE_PAUSED_BY_SPEC_REVIEW: $feature_name ($critical_count CRITICAL_ISSUES, post-clarification)" "$WORKFLOW_DATA_DIR/.workflow-log"
        local critical_summary
        critical_summary=$(grep -i "CRITICAL\|ISSUE" "$spec_dir/spec-review.md" 2>/dev/null | head -20)
        agent_notify \
          "需求 '$feature_name' 澄清后审查仍有 $critical_count 个严重问题，流水线已自动暂停。\n\n问题摘要：\n${critical_summary}" \
          "请向用户展示以上问题，询问修改方向。用户回复后执行：/fix $feature_name {修改指导}" \
          "$feature_name"
        echo "  ❌ 澄清后仍有 $critical_count 个 CRITICAL_ISSUES，已自动暂停（/fix 恢复）" >&2
        return 0
      fi
    fi
    notify "✅ Step 1 完成（澄清后）: $feature_name"
  else
    notify "✅ Step 1 完成（澄清后，codex 不可用跳过审查）: $feature_name"
  fi

  # 继续 Steps 2-7
  run_pipeline_steps_2_to_7 "$feature_name"
}
