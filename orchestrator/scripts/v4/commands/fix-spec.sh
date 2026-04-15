#!/bin/bash
# fix-spec.sh — /fix-spec command: user provides guidance, Claude auto-fixes spec and re-reviews
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_fix_spec() {
  local args="$1"
  local feature_name
  feature_name=$(echo "$args" | awk '{print $1}')
  local guidance
  guidance=$(echo "$args" | cut -d' ' -f2-)
  [ "$guidance" = "$feature_name" ] && guidance=""

  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /fix-spec {需求名称} {修改指导}"
    echo "   示例: /fix-spec user-login 1.去掉短信验证 2.用JWT替换session"
    return 1
  fi
  if ! has_pending_spec_review "$feature_name"; then
    echo "❌ '$feature_name' 没有待处理的 spec 审查问题"
    echo "   提示: 该命令仅在 Codex 审查发现严重问题并自动暂停后可用"
    return 1
  fi
  if [ -z "$guidance" ]; then
    echo "❌ 请提供修改指导"
    echo "   示例: /fix-spec $feature_name 1.去掉短信验证 2.用JWT替换session"
    return 1
  fi

  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"

  # 立即标记为处理中，防止并发 /fix-spec 重入
  local state_file="$spec_dir/awaiting-spec-review.json"
  if [ -f "$state_file" ]; then
    local tmp; tmp=$(mktemp)
    jq '.status="fixing"' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi

  notify "🔧 开始根据用户指导修复 spec: $feature_name"
  log "FIX_SPEC_START: $feature_name" "$pipeline_log"

  # Claude 根据 spec-review.md + 用户指导，自动修改三文档
  local model
  local complexity
  complexity=$(get_complexity "$feature_name")
  model=$(select_model "$complexity")

  echo "  [fix-spec] Claude 根据审查意见 + 用户指导修改 spec..." >&2
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $spec_dir/spec-review.md
    Read $spec_dir/requirements.md
    Read $spec_dir/design.md
    Read $spec_dir/tasks.md

    Codex spec 审查报告中有严重问题（CRITICAL_ISSUES >= 3），用户提供了以下修改指导：
    $guidance

    请执行以下操作：
    1. 逐条对照 spec-review.md 中的 CRITICAL/ISSUE 项
    2. 结合用户指导，修改 requirements.md、design.md、tasks.md
    3. 用户指导优先于 Codex 建议（当两者冲突时以用户为准）
    4. 更新三个文件头部状态为 revised
    5. 保持文件格式和结构不变，只修改需要改的部分
  " >&2

  # 重新走 Codex 审查
  echo "  [fix-spec] 重新执行 Codex 审查..." >&2
  notify "🟣 fix-spec: 重新执行 Codex spec 审查 ($feature_name)"

  if command -v codex &> /dev/null; then
    codex exec --full-auto "
      你是一个资深技术架构师，负责审查以下 spec 文档的质量。

      requirements.md:
      $(cat "$spec_dir/requirements.md")

      design.md:
      $(cat "$spec_dir/design.md")

      tasks.md:
      $(cat "$spec_dir/tasks.md")

      项目架构参考:
      $(cat "$PROJECT_ROOT/.claude/ARCHITECTURE.md" 2>/dev/null || echo '(无)')

      请从 13 维度审查（R1-R4, D1-D4, T1-T5），对每项给出 PASS / ISSUE 判定。
      输出格式: DIMENSION: Rx  VERDICT: PASS|ISSUE  DETAIL: ...  SUGGESTION: ...
      最后输出: OVERALL: PASS|NEEDS_REVISION  CRITICAL_ISSUES: {数量}
    " > "$spec_dir/spec-review.md" 2>/dev/null || {
      echo "  ⚠️ Codex 重新审查失败" >&2
    }
  else
    # codex 不可用时，由 Claude 执行审查替代，避免读取旧 spec-review.md 陷入死循环
    echo "  ⚠️ codex 未安装，改用 Claude 执行审查" >&2
    opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
      Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
      Read $spec_dir/requirements.md
      Read $spec_dir/design.md
      Read $spec_dir/tasks.md
      $([ -f "$PROJECT_ROOT/.claude/ARCHITECTURE.md" ] && echo "Read $PROJECT_ROOT/.claude/ARCHITECTURE.md")

      你是一个资深技术架构师，请从 13 维度审查（R1-R4, D1-D4, T1-T5）。
      对每项给出 PASS / ISSUE 判定。
      输出格式: DIMENSION: Rx  VERDICT: PASS|ISSUE  DETAIL: ...  SUGGESTION: ...
      最后输出: OVERALL: PASS|NEEDS_REVISION  CRITICAL_ISSUES: {数量}
      将结果写入 $spec_dir/spec-review.md
    " >&2
  fi

  # Claude 复审定稿
  if [ -f "$spec_dir/spec-review.md" ]; then
    echo "  [fix-spec] Claude 复审定稿..." >&2
    opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
      Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
      Read $spec_dir/spec-review.md
      Read $spec_dir/requirements.md
      Read $spec_dir/design.md
      Read $spec_dir/tasks.md

      Execute spec-writer Stage 3: 根据 Codex 审查报告复审并定稿。
      - PASS 的维度不做修改
      - ISSUE 的维度按建议修改（如不同意则在 spec-review.md 中标注理由）
      - 更新三个文件头部状态为 reviewed

      如果 CRITICAL_ISSUES >= 3 且无法全部解决，输出 NEEDS_HUMAN_REVIEW。
    " >&2
  fi

  # 再次检查 CRITICAL_ISSUES
  local new_critical_count
  new_critical_count=$(sed -n 's/.*CRITICAL_ISSUES:[[:space:]]*\([0-9]*\).*/\1/p' \
    "$spec_dir/spec-review.md" 2>/dev/null | tail -1)
  new_critical_count="${new_critical_count:-0}"

  if is_numeric "$new_critical_count" && [ "$new_critical_count" -ge 3 ]; then
    # 仍然不通过，更新状态，再次通知
    save_spec_review_state "$feature_name" "$new_critical_count"
    local critical_summary
    critical_summary=$(grep -i "CRITICAL\|ISSUE" "$spec_dir/spec-review.md" 2>/dev/null | head -20)
    agent_notify \
      "需求 '$feature_name' 修改后重新审查仍有 $new_critical_count 个严重问题。\n\n问题摘要：\n${critical_summary}" \
      "请告知用户仍有问题，询问进一步修改方向。用户回复后执行：/fix-spec $feature_name {修改指导}" \
      "$feature_name"
    echo "  ❌ 修改后仍有 $new_critical_count 个 CRITICAL_ISSUES，继续等待指导" >&2
    log "FIX_SPEC_STILL_CRITICAL: $feature_name ($new_critical_count)" "$pipeline_log"
    return 0
  fi

  # 审查通过，清理状态，继续流水线
  clear_spec_review_state "$feature_name"
  rm -f "$spec_dir/paused.json" "$spec_dir/requirements.md.snapshot"
  log "FIX_SPEC_DONE: $feature_name (CRITICAL resolved)" "$pipeline_log"
  log "STEP_1_DONE: $feature_name (fix-spec)" "$pipeline_log"
  notify "✅ Spec 审查通过: $feature_name，继续流水线"
  echo "  ✅ spec 审查通过，继续 Steps 2-7" >&2

  run_pipeline_steps_2_to_7 "$feature_name"
}
