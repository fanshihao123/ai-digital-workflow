#!/bin/bash
# step1-spec-writer.sh — Step 1: spec-writer（三阶段交叉审查）+ restart 增量更新
# Sourced by v4/handler.sh; all lib modules already loaded

step1_spec_writer() {
  local input="$1"
  local is_hotfix="${2:-false}"
  local model

  echo "=== Step 1: spec-writer ===" >&2
  notify "📝 开始需求分析: $input"

  if [ "$is_hotfix" = "false" ] && [ -n "$input" ] && has_reviewed_spec "$input"; then
    echo "  [resume] 使用已有 reviewed spec: $input" >&2
    notify "🟡 Step 1 复用已有 reviewed spec: $input"
    echo "$input"
    return 0
  fi

  # Stage 1a: Claude 仅生成 requirements.md（澄清前不生成 design/tasks，避免重复浪费）
  echo "  [Stage 1a] Claude 生成 requirements.md..." >&2
  model=$(select_model "low")
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Execute spec-writer Stage 1a: generate requirements.md ONLY (do NOT generate design.md or tasks.md yet) for: $input
    Mark all [UNCERTAIN] items as unchecked [ ] in the '开放问题' section of requirements.md.
    $([ "$is_hotfix" = "true" ] && echo "This is a /hotfix — generate minimal requirements.md only, no open questions needed")
  " >&2

  local feature_name
  feature_name=$(detect_feature_name)
  if [ -z "$feature_name" ]; then
    echo "  ❌ spec-writer 未生成 specs 目录" >&2
    notify "❌ spec-writer 失败: 未生成 specs 目录"
    return 1
  fi

  # 验证 feature name 安全性（防路径遍历）
  if ! validate_feature_name "$feature_name"; then
    notify "❌ spec-writer 生成了非法的 feature name: $feature_name"
    return 1
  fi

  # Jira 同步
  jira_sync "requirements-done" "$feature_name" >&2

  # ── 开放问题检测：若有不确定项则暂停，等待用户澄清（此时 design/tasks 尚未生成）──
  if [ "$is_hotfix" = "false" ]; then
    local open_questions_text
    open_questions_text=$(extract_open_questions "$feature_name")
    if [ -n "$open_questions_text" ]; then
      local oq_count
      oq_count=$(echo "$open_questions_text" | grep -c "." || echo 0)
      echo "  [clarification] 检测到 $oq_count 个开放问题，暂停工作流" >&2
      save_clarification_state "$feature_name" "$input" "$open_questions_text"
      notify_open_questions "$feature_name" "$open_questions_text"
      log "STEP_1_PAUSED: $feature_name ($oq_count 开放问题)" "$PROJECT_ROOT/specs/.workflow-log"
      echo "  ⏸️ 等待用户答复: $feature_name" >&2
      echo "__PAUSED__"
      return 0
    fi
  fi
  # ─────────────────────────────────────────────────────────────────────────

  # Stage 1b: requirements.md 无开放问题，继续生成 design.md + tasks.md
  feishu_notify "✅ **[Stage 1a]** requirements.md 生成完毕，无开放问题\n⏳ **[Stage 1b]** 开始生成 design.md + tasks.md..." "$feature_name"
  echo "  [Stage 1b] Claude 生成 design.md + tasks.md..." >&2
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $PROJECT_ROOT/specs/$feature_name/requirements.md
    Execute spec-writer Stage 1b: generate design.md + tasks.md based on the confirmed requirements.md above.
    $([ "$is_hotfix" = "true" ] && echo "This is a /hotfix — generate tasks.md directly with minimal design")
  " >&2

  # 只有 hotfix 或简单任务允许跳过完整 spec 审查
  local complexity
  complexity=$(get_complexity "$feature_name")

  # 跳过审查条件：hotfix 或 (任务数 <= 2 且 complexity: low)
  local task_count
  task_count=$(grep -c "^### Task" "$PROJECT_ROOT/specs/$feature_name/tasks.md" 2>/dev/null || echo 0)

  if [ "$is_hotfix" = "true" ] || { [ "$task_count" -le 2 ] && [ "$complexity" = "low" ]; }; then
    local skip_reason
    [ "$is_hotfix" = "true" ] && skip_reason="hotfix 模式" || skip_reason="简单任务 (${task_count} tasks, complexity: low)"
    echo "  [Stage 2+3] 跳过（$skip_reason）" >&2
    notify "🟡 Step 1 完成（$skip_reason）: 跳过 Codex 审查"
    echo "$feature_name"
    return 0
  fi

  # Stage 2: OpenAI Codex 审查
  echo "  [Stage 2] OpenAI Codex 审查..." >&2
  feishu_notify "✅ **[Stage 1b]** design.md + tasks.md 生成完毕 (${task_count} 个任务, complexity: $complexity)\n⏳ **[Stage 2]** 开始 Codex spec 审查..." "$feature_name"
  if command -v codex &> /dev/null; then
    codex exec --full-auto "
      你是一个资深技术架构师，负责审查以下 spec 文档的质量。

      requirements.md:
      $(cat "$PROJECT_ROOT/specs/$feature_name/requirements.md")

      design.md:
      $(cat "$PROJECT_ROOT/specs/$feature_name/design.md")

      tasks.md:
      $(cat "$PROJECT_ROOT/specs/$feature_name/tasks.md")

      项目架构参考:
      $(cat "$PROJECT_ROOT/.claude/ARCHITECTURE.md" 2>/dev/null || echo '(无)')

      请从 13 维度审查（R1-R4, D1-D4, T1-T5），对每项给出 PASS / ISSUE 判定。
      输出格式: DIMENSION: Rx  VERDICT: PASS|ISSUE  DETAIL: ...  SUGGESTION: ...
      最后输出: OVERALL: PASS|NEEDS_REVISION  CRITICAL_ISSUES: {数量}
    " > "$PROJECT_ROOT/specs/$feature_name/spec-review.md" 2>/dev/null || {
      echo "  ⚠️ Codex 审查失败，跳过 Stage 2" >&2
    }
  else
    echo "  ❌ codex 未安装，无法执行强制 spec 审查" >&2
    notify "❌ Step 1 失败: codex 未安装，无法执行强制 spec 审查 ($feature_name)"
    return 1
  fi

  # Stage 3: Claude 复审 + 定稿
  feishu_notify "✅ **[Stage 2]** Codex 审查完毕\n⏳ **[Stage 3]** Claude 复审 + 定稿..." "$feature_name"
  echo "  [Stage 3] Claude 复审 + 定稿..." >&2
  if [ -f "$PROJECT_ROOT/specs/$feature_name/spec-review.md" ]; then
    model=$(select_model "$complexity")
    opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
      Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
      Read $PROJECT_ROOT/specs/$feature_name/spec-review.md
      Read $PROJECT_ROOT/specs/$feature_name/requirements.md
      Read $PROJECT_ROOT/specs/$feature_name/design.md
      Read $PROJECT_ROOT/specs/$feature_name/tasks.md

      Execute spec-writer Stage 3: 根据 Codex 审查报告复审并定稿。
      - PASS 的维度不做修改
      - ISSUE 的维度按建议修改（如不同意则在 spec-review.md 中标注理由）
      - 更新三个文件头部状态为 reviewed

      如果 CRITICAL_ISSUES >= 3 且无法全部解决，输出 NEEDS_HUMAN_REVIEW。
    " >&2

    # 审查失败兜底
    local critical_count
    critical_count=$(sed -n 's/.*CRITICAL_ISSUES:[[:space:]]*\([0-9]*\).*/\1/p' \
      "$PROJECT_ROOT/specs/$feature_name/spec-review.md" 2>/dev/null | tail -1)
    critical_count="${critical_count:-0}"
    if is_numeric "$critical_count" && [ "$critical_count" -ge 3 ]; then
      # 自动保存阻断状态（paused.json + awaiting-spec-review.json）
      save_spec_review_state "$feature_name" "$critical_count"
      local spec_dir="$PROJECT_ROOT/specs/$feature_name"
      jq -n \
        --arg feature "$feature_name" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson ps 1 \
        --argjson ls 0 \
        '{feature:$feature,status:"paused",paused_at:$ts,paused_step:$ps,last_done_step:$ls,reason:"spec-review-critical",requirements_snapshot:"requirements.md.snapshot"}' \
        > "$spec_dir/paused.json"
      # 保存 requirements.md 快照（供 /restart 做 diff 用）
      [ -f "$spec_dir/requirements.md" ] && cp "$spec_dir/requirements.md" "$spec_dir/requirements.md.snapshot"
      log "PIPELINE_PAUSED_BY_SPEC_REVIEW: $feature_name ($critical_count CRITICAL_ISSUES)" "$PROJECT_ROOT/specs/.workflow-log"

      # 提取 CRITICAL 问题摘要发送给用户
      local critical_summary
      critical_summary=$(grep -i "CRITICAL\|ISSUE" "$spec_dir/spec-review.md" 2>/dev/null | head -20)
      agent_notify \
        "需求 '$feature_name' 的 Spec 审查发现 $critical_count 个严重问题，流水线已自动暂停。\n\n问题摘要：\n${critical_summary}\n\n详见 specs/$feature_name/spec-review.md" \
        "请向用户展示以上问题，询问修改方向。用户回复后执行：/fix-spec $feature_name {用户的修改指导}" \
        "$feature_name"
      echo "  ❌ $critical_count 个 CRITICAL_ISSUES，已自动暂停（/fix-spec 恢复）" >&2
      echo "__PAUSED__"
      return 0
    fi

    # 验证三个文件是否已标记为 reviewed
    local reviewed_count=0
    for doc in requirements.md design.md tasks.md; do
      if grep -qi "reviewed\|status:.*reviewed" "$PROJECT_ROOT/specs/$feature_name/$doc" 2>/dev/null; then
        reviewed_count=$((reviewed_count + 1))
      fi
    done
    if [ "$reviewed_count" -lt 3 ]; then
      echo "  ⚠️ 仅 $reviewed_count/3 个文件标记为 reviewed" >&2
    fi
  fi

  progress_substep "$feature_name" 1 "Stage 3: Claude 复审定稿" "done"
  notify "✅ Step 1 完成: 已生成并复审 spec ($feature_name)"
  echo "$feature_name"
}

# ============================================================
# restart 专用：增量更新 requirements.md → design.md + tasks.md
# 返回值: 0=无变更或更新完成  2=再次遇到[UNCERTAIN]暂停
# ============================================================
step1_restart_with_diff() {
  local feature_name="$1"
  local paused_step="$2"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local req_file="$spec_dir/requirements.md"
  local snapshot_file="$spec_dir/requirements.md.snapshot"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"
  local model
  model=$(select_model "low")

  # 计算 diff（先拿完整 diff，再过滤掉元信息噪音）
  local raw_diff_output diff_output
  raw_diff_output=$(diff "$snapshot_file" "$req_file" 2>/dev/null || true)
  diff_output=$(printf '%s\n' "$raw_diff_output" | awk '
    /^--- / || /^\+\+\+ / || /^@@ / { print; next }
    /^[+-]> 状态：/ { next }
    /^[+-]> 更新时间：/ { next }
    /^[+-]> 审查状态：/ { next }
    /^[+-]> 审查模型：/ { next }
    /^[+-]> 审查轮次：/ { next }
    /^[+-]> 审查结论：/ { next }
    /^[+-]> 修改项：/ { next }
    { print }
  ' | sed '/^$/d')

  if [ -z "$diff_output" ] || [ "$diff_output" = "--- $snapshot_file" ] || [ "$diff_output" = "+++ $req_file" ]; then
    echo "  [restart] requirements.md 无实质需求变更，直接从 Step $paused_step 继续" >&2
    notify "▶️ 需求无实质变更，从 Step $paused_step 继续: $feature_name"
    log "PIPELINE_RESTART_NO_CHANGE: $feature_name from Step $paused_step" "$pipeline_log"
    return 0
  fi

  echo "  [restart] 检测到 requirements.md 变更，进入增量更新流程" >&2
  notify "🔄 需求有变更，开始增量更新 spec: $feature_name"
  log "PIPELINE_RESTART_WITH_DIFF: $feature_name" "$pipeline_log"

  # Stage 1a'：模型润色规范化用户手改的 requirements.md
  echo "  [Stage 1a'] 规范化 requirements.md..." >&2
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    Read $spec_dir/requirements.md

    以下是用户对 requirements.md 的变更 diff（快照 → 当前版本）：
    ---DIFF START---
    $diff_output
    ---DIFF END---

    任务（Stage 1a'）：
    - 仅覆写 specs/$feature_name/requirements.md
    - 保留用户的所有意图和新增内容，不做删减
    - 补全格式：标准 Markdown 结构、验收标准、边界说明
    - 对仍不确定的需求项打上 [UNCERTAIN] 标记并写入开放问题 section
    - 不要生成或修改 design.md、tasks.md
  " >&2

  # 检测 [UNCERTAIN]
  local open_questions
  open_questions=$(extract_open_questions "$feature_name")
  if [ -n "$open_questions" ]; then
    local oq_count
    oq_count=$(echo "$open_questions" | grep -c "." || echo 0)
    echo "  [restart] 检测到 $oq_count 个 [UNCERTAIN]，暂停询问用户" >&2
    save_clarification_state "$feature_name" "restart-diff" "$open_questions"
    notify_open_questions "$feature_name" "$open_questions"
    log "STEP_1_PAUSED: $feature_name ($oq_count 开放问题，restart)" "$pipeline_log"
    return 2
  fi

  # Stage 1b'：最小粒度更新 design.md + tasks.md
  echo "  [Stage 1b'] 增量更新 design.md + tasks.md..." >&2
  local complexity
  complexity=$(get_complexity "$feature_name")
  local stage1b_model
  stage1b_model=$(select_model "$complexity")

  opencli claude --print --permission-mode bypassPermissions --model "$stage1b_model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    Read $spec_dir/requirements.md
    Read $spec_dir/design.md
    Read $spec_dir/tasks.md

    以下是 requirements.md 相对快照的变更 diff：
    ---DIFF START---
    $diff_output
    ---DIFF END---

    任务（Stage 1b'）：
    - 以最小粒度更新 design.md 和 tasks.md，仅修改与 diff 相关的部分
    - 未受 diff 影响的设计决策和任务条目保持原样，不要重写
    - 新增需求 → 追加对应 design 章节和 task 条目
    - 删除需求 → 移除对应内容
    - 修改需求 → 就地更新受影响部分
    - 更新两个文件 status 标记为 reviewed
  " >&2

  log "STEP_1_DONE: $feature_name (restart with diff)" "$pipeline_log"
  notify "✅ 增量 spec 更新完成: $feature_name"
  return 0
}
