#!/bin/bash
# step2-develop.sh — Step 2: 开发执行（Agent 路由）
# Sourced by v4/handler.sh; all lib modules already loaded
# Dependencies: lib/utils.sh, lib/pause.sh, lib/integrations.sh, lib/antigravity.sh, lib/dev-server.sh

step2_develop() {
  local feature_name="$1"
  local complexity
  complexity=$(get_complexity "$feature_name")
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

  ensure_not_paused "$feature_name" "step2_develop" || return 0

  echo "=== Step 2: 开发执行 ==="
  notify "💻 Step 2: 开始开发 $feature_name (complexity: $complexity)"

  if [ -f "$tasks_file" ] && grep -q "> 状态：done" "$tasks_file" 2>/dev/null; then
    echo "  [resume] tasks.md 已完成，跳过开发执行"
    notify "🟡 Step 2 复用已有开发结果: $feature_name"
    return 0
  fi

  # Jira 同步
  jira_sync "dev-start" "$feature_name"

  # 升级模型（如果 high complexity）
  local model
  model=$(select_model "$complexity")

  # 检查是否需要 worktree 并行
  if [ "$complexity" = "high" ] && [ "${ENABLE_WORKTREE_PARALLEL:-false}" = "true" ]; then
    echo "  [worktree-parallel] 高复杂度，启动多 Agent 并行..."
    if [ -f "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/spawn-worktree-agents.sh" ]; then
      bash "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/spawn-worktree-agents.sh" \
        "$feature_name" "$tasks_file" 2>&1 || {
        echo "  ⚠️ worktree-parallel 失败，回退顺序执行"
        # 回退到顺序执行
        step2_sequential "$feature_name" "$model"
      }
      # 合并 worktree
      if [ -f "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/merge-worktrees.sh" ]; then
        bash "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/merge-worktrees.sh" "$feature_name" || true
      fi
      if [ -f "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/cleanup-worktrees.sh" ]; then
        bash "$PROJECT_ROOT/.claude/extensions/worktree-parallel/scripts/cleanup-worktrees.sh" "$feature_name" || true
      fi
    else
      echo "  ⚠️ worktree-parallel 脚本缺失，回退顺序执行"
      step2_sequential "$feature_name" "$model"
    fi
  else
    step2_sequential "$feature_name" "$model"
  fi
}

# 顺序执行开发任务（显式两阶段：Step 2a antigravity → Step 2b claude-code）
step2_sequential() {
  local feature_name="$1"
  local model="$2"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

  local has_antigravity
  has_antigravity=$(count_pattern_in_file "agent: antigravity" "$tasks_file")

  # 收尾格式化：尽量贴近本地 VS Code command+s（Prettier on save）
  local format_changed_files_after_dev
  format_changed_files_after_dev() {
    local changed_files=""
    changed_files=$(git -C "$PROJECT_ROOT" diff --name-only -- '*.js' '*.jsx' '*.ts' '*.tsx' '*.json' '*.md' '*.css' '*.scss' 2>/dev/null || true)
    [ -z "$changed_files" ] && return 0

    echo "  [format-on-save] 使用 Prettier 格式化变更文件（贴近 command+s）..." >&2
    printf '%s\n' "$changed_files" | while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      [ -f "$PROJECT_ROOT/$rel" ] || continue
      npx prettier --write "$PROJECT_ROOT/$rel" >/dev/null 2>&1 || true
    done
  }

  # ── Step 2a: Antigravity UI 还原（显式优先执行）──
  if [ "$has_antigravity" -gt 0 ] && [ "${ENABLE_UI_RESTORER:-false}" = "true" ]; then
    echo "  [Step 2a] 检测到 $has_antigravity 个 antigravity 任务，开始 UI 还原" >&2
    notify "🎨 Step 2a: 开始 UI 还原 ($has_antigravity 个任务)" "$feature_name"

    # Phase 0: 确保 dev server 运行
    local base_url
    base_url=$(ensure_dev_server "$feature_name") || return 1

    # 逐个执行 antigravity 任务（严格跟踪成功/失败）
    local task_nums
    task_nums=$(grep -n "agent: antigravity" "$tasks_file" 2>/dev/null \
      | while read -r line; do
          local lineno="${line%%:*}"
          awk "NR<=$lineno" "$tasks_file" \
            | grep "^### Task [0-9]" | tail -1 \
            | grep -o "[0-9]*" | head -1
        done | sort -un)

    local failed_tasks=""
    local succeeded_tasks=""
    for task_num in $task_nums; do
      if step2a_restore_task "$feature_name" "$task_num" "$base_url"; then
        succeeded_tasks="$succeeded_tasks $task_num"
      else
        failed_tasks="$failed_tasks $task_num"
        echo "  [Step 2a] Task $task_num 还原失败" >&2
      fi
    done

    # 验证：所有 antigravity 任务必须在 tasks.md 中标记为 done
    local undone_tasks=""
    for task_num in $task_nums; do
      if ! awk "/^### Task ${task_num}[：:]/,/^### Task [0-9]/" "$tasks_file" 2>/dev/null \
           | grep -q "^- 状态：done"; then
        undone_tasks="$undone_tasks $task_num"
      fi
    done

    if [ -n "$undone_tasks" ]; then
      notify "❌ Step 2a 失败: Task${undone_tasks} 未完成，UI 还原中止" "$feature_name"
      agent_notify \
        "需求 '$feature_name' 的 UI 还原未完成。\n\n未完成的 Task:${undone_tasks}\n已完成的 Task:${succeeded_tasks:-无}\n\n请检查后重新执行。" \
        "用户可以 /resume $feature_name 重试，或手动修改后继续" \
        "$feature_name"
      return 1
    fi

    # 验证：产物清单必须有记录
    local ui_artifact_files
    ui_artifact_files=$(_read_ui_artifacts "$feature_name")
    if [ -z "$ui_artifact_files" ]; then
      notify "❌ Step 2a 异常: 任务标记完成但无产物文件记录" "$feature_name"
      return 1
    fi

    notify "✅ Step 2a 完成: UI 还原结束 ($(echo "$ui_artifact_files" | wc -l | tr -d ' ') 个 UI 文件)，开始 Phase 3 Codex 审查" "$feature_name"

    # Phase 3: Codex 代码规范审查（一轮）—— 只审查 UI 产物文件
    echo "  [Step 2a] Phase 3: Codex 代码规范审查..." >&2
    if command -v codex >/dev/null 2>&1; then
      # 从产物清单读取（不用 git diff，避免混入 .claude/ 等无关文件）
      local ui_files_for_review
      ui_files_for_review=$(_read_ui_artifacts "$feature_name")

      if [ -z "$ui_files_for_review" ]; then
        echo "  ⚠️ 产物清单为空，跳过 Codex 审查" >&2
      else
        echo "  [Step 2a] 审查范围: $(echo "$ui_files_for_review" | wc -l | tr -d ' ') 个 UI 文件" >&2

        codex exec --full-auto "
审查 Antigravity 生成的 UI 代码（代码规范审查，非视觉审查）。

审查文件（仅以下文件，不要审查其他文件）：
$ui_files_for_review

审查清单：
1. 是否有硬编码颜色/字号/间距（必须使用 design token / CSS 变量）
2. 是否重复造轮子（项目已有的 design system 组件是否被正确使用）
3. Props 接口是否合理（纯 UI 组件不应依赖业务类型）
4. 是否有不必要的 div 嵌套（超过 4 层需说明）
5. 所有交互元素是否有 aria-label 或 alt 文本（a11y）
6. 表单元素是否有 label 关联
7. 图片是否使用 lazy loading
8. 组件命名是否符合项目规范

输出格式：
CODEX_VERDICT: PASS|FAIL
REVIEWED_FILES:
$(echo "$ui_files_for_review" | sed 's/^/  - /')
ISSUES:
  - SEVERITY: WARNING|ERROR
    FILE: {文件路径}
    LINE: {行号}
    ISSUE: {问题描述}
    FIX: {修复建议}
        " > "$PROJECT_ROOT/specs/$feature_name/ui-codex-review.md" 2>/dev/null || true

        local codex_verdict
        codex_verdict=$(grep "^CODEX_VERDICT:" \
          "$PROJECT_ROOT/specs/$feature_name/ui-codex-review.md" 2>/dev/null \
          | sed 's/CODEX_VERDICT:[[:space:]]*//' | tr -d ' \r')

        if [ "$codex_verdict" = "FAIL" ]; then
          local error_issues
          error_issues=$(grep -A3 "SEVERITY: ERROR" \
            "$PROJECT_ROOT/specs/$feature_name/ui-codex-review.md" 2>/dev/null || echo "")
          if [ -n "$error_issues" ]; then
            echo "  [Step 2a] Codex 发现 ERROR 级问题，触发 Antigravity 修复..." >&2
            antigravity_send_message \
              "修复以下代码规范问题：
$error_issues
严格按 FIX 建议修改，不要改其他代码。" "fast" || true
          fi
          local warning_issues
          warning_issues=$(grep -A3 "SEVERITY: WARNING" \
            "$PROJECT_ROOT/specs/$feature_name/ui-codex-review.md" 2>/dev/null || echo "")
          [ -n "$warning_issues" ] && \
            notify "⚠️ UI Codex 审查警告（不阻塞）:\n$warning_issues" "$feature_name"
        fi
      fi
    else
      echo "  ⚠️ codex 未安装，跳过 UI 代码规范审查" >&2
    fi

    notify "✅ Step 2a 全部完成: UI 还原 + Codex 审查通过" "$feature_name"
  elif [ "$has_antigravity" -gt 0 ]; then
    echo "  ⚠️ 发现 antigravity 任务但 ENABLE_UI_RESTORER 未启用，使用 Claude Code 执行" >&2
  fi

  # ── Step 2b 前置检查：antigravity 任务必须已完成 ──
  if [ "$has_antigravity" -gt 0 ] && [ "${ENABLE_UI_RESTORER:-false}" = "true" ]; then
    local pending_ag_tasks=""
    local ag_task_nums
    ag_task_nums=$(grep -n "agent: antigravity" "$tasks_file" 2>/dev/null \
      | while read -r line; do
          local lineno="${line%%:*}"
          awk "NR<=$lineno" "$tasks_file" \
            | grep "^### Task [0-9]" | tail -1 \
            | grep -o "[0-9]*" | head -1
        done | sort -un)
    for tn in $ag_task_nums; do
      if ! awk "/^### Task ${tn}[：:]/,/^### Task [0-9]/" "$tasks_file" 2>/dev/null \
           | grep -q "^- 状态：done"; then
        pending_ag_tasks="$pending_ag_tasks $tn"
      fi
    done
    if [ -n "$pending_ag_tasks" ]; then
      echo "  [Step 2b] ❌ antigravity 任务未完成 (Task${pending_ag_tasks})，不启动业务开发" >&2
      notify "❌ Step 2b 阻断: UI 还原任务 (Task${pending_ag_tasks}) 未完成" "$feature_name"
      return 1
    fi
  fi

  # ── Step 2b: claude-code 任务（业务逻辑，依赖 2a 产出）──
  echo "  [Step 2b] 执行 claude-code 任务..." >&2
  notify "💻 Step 2b: 开始业务逻辑开发" "$feature_name"

  # 读取 antigravity 产物清单，告知 Step 2b 哪些文件已由 UI 还原生成
  local ag_artifact_hint=""
  local ag_files
  ag_files=$(_read_ui_artifacts "$feature_name" 2>/dev/null)
  if [ -n "$ag_files" ]; then
    ag_artifact_hint="以下文件已由 Step 2a (Antigravity UI 还原) 生成，请勿重写或覆盖：
$ag_files
如需修改这些文件（如添加业务逻辑），仅做增量修改，不要重写 UI 结构。"
  fi

  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $tasks_file
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant company skills from $PROJECT_ROOT/.claude/company-skills/")

    ${ag_artifact_hint}

    Execute all tasks marked 'agent: claude-code' (or with no agent tag) in tasks.md.
    Skip tasks marked 'agent: antigravity' — they are already completed in Step 2a. Do NOT re-implement their UI output.
    Follow task dependencies. Mark each task as done after completion.
  " >&2

  format_changed_files_after_dev
}
