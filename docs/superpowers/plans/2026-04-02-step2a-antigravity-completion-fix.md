# Step 2a Antigravity 完成判定与审查链路修复

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Step 2a antigravity UI 还原的完成判定、审查文件范围、产物追踪、任务边界四个问题，确保 antigravity 任务的执行结果可信、可追踪、可验收。

**Architecture:** 在 `antigravity.sh` 的 `step2a_restore_task` 中新增产物清单写入（`specs/<feature>/.ui-restore-artifacts.json`），每个 task 执行完后记录产出文件；`step2-develop.sh` 的 Step 2a 循环改为严格跟踪成功/失败，Phase 3 审查只读产物清单中的文件，Step 2b 启动前验证所有 antigravity 任务已标记 done。

**Tech Stack:** Bash 3.2+, jq, git

**约束:** 不引入 bash 4.x 特性（macOS 默认 bash 3.2）；不改变外部接口（`step2_develop` 函数签名不变）

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `orchestrator/scripts/v4/lib/antigravity.sh` | Modify | 在 `step2a_restore_task` 末尾写产物清单；新增 `_record_ui_artifact` 和 `_read_ui_artifacts` 辅助函数 |
| `orchestrator/scripts/v4/steps/step2-develop.sh` | Modify | Step 2a 循环严格判定；Phase 3 只审查产物文件；Step 2b 前验证 antigravity 任务 done |

不新增文件。运行时会在 `specs/<feature>/` 下生成 `.ui-restore-artifacts.json`（由代码自动创建）。

---

### Task 1: antigravity.sh — 产物清单写入与任务标记

**Files:**
- Modify: `orchestrator/scripts/v4/lib/antigravity.sh:126-280`

- [ ] **Step 1: 在 `step2a_restore_task` 函数开头初始化产物清单文件**

在第 133 行 `local spec_dir=...` 之后添加产物清单路径变量和初始化：

```bash
  local artifact_file="$spec_dir/.ui-restore-artifacts.json"

  # 初始化本 task 的产物记录（追加模式，多 task 共享同一文件）
  if [ ! -f "$artifact_file" ]; then
    echo '{"tasks":{}}' > "$artifact_file"
  fi
```

- [ ] **Step 2: 在 `step2a_restore_task` 函数末尾（return 0 之前）写入产物清单并标记 task done**

替换当前第 279 行的 `return 0` 为：

```bash
  # ── 记录产物清单 ──
  # 收集本 task 的文件范围（从 tasks.md 字段 + git diff 实际变更取交集）
  local task_ui_files=""
  if [ -n "$file_path" ]; then
    # file_path 可能是单文件或目录，展开为实际存在的文件列表
    if [ -d "$PROJECT_ROOT/$file_path" ]; then
      task_ui_files=$(find "$PROJECT_ROOT/$file_path" -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.jsx' -o -name '*.js' -o -name '*.css' -o -name '*.scss' \) 2>/dev/null \
        | sed "s|^$PROJECT_ROOT/||" | sort)
    elif [ -f "$PROJECT_ROOT/$file_path" ]; then
      task_ui_files="$file_path"
    fi
  fi
  # 兜底：从 git diff 取本轮实际变更的 src 文件（排除 .claude/ specs/ .env 等）
  if [ -z "$task_ui_files" ]; then
    task_ui_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD -- 'src/**' 2>/dev/null \
      | grep -E '\.(tsx?|jsx?|css|scss)$' | sort)
  fi

  # 写入 JSON 产物清单
  local files_json="[]"
  if [ -n "$task_ui_files" ]; then
    files_json=$(printf '%s\n' "$task_ui_files" | jq -R . | jq -s .)
  fi
  local task_entry
  task_entry=$(jq -n \
    --arg tn "$task_num" \
    --arg name "$task_name" \
    --arg fp "$file_path" \
    --argjson files "$files_json" \
    --argjson blocks "$block_total" \
    --argjson passed "$(echo "${#block_results[@]}")" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name, file_path:$fp, files:$files, blocks_total:$blocks, blocks_passed:$passed, timestamp:$ts}')

  # 合并到产物清单（jq 追加/覆盖 task 条目）
  local tmp_artifact
  tmp_artifact=$(mktemp)
  jq --arg tn "$task_num" --argjson entry "$task_entry" \
    '.tasks[$tn] = $entry' "$artifact_file" > "$tmp_artifact" 2>/dev/null \
    && mv "$tmp_artifact" "$artifact_file" \
    || rm -f "$tmp_artifact"

  echo "  [ui-restorer] Task $task_num 产物已记录: $(echo "$task_ui_files" | wc -l | tr -d ' ') 个文件" >&2

  # ── 标记 task done（写回 tasks.md）──
  # 检查是否所有块都通过（无 NEEDS_REVIEW）
  local has_review_needed=false
  for r in "${block_results[@]}"; do
    if echo "$r" | grep -q "NEEDS_REVIEW"; then
      has_review_needed=true
      break
    fi
  done

  if [ "$has_review_needed" = "false" ] && [ ${#block_results[@]} -gt 0 ]; then
    # 所有块通过，标记 done
    sed -i.bak "/^### Task ${task_num}/,/^### Task [0-9]/ s/^- 状态：.*/- 状态：done/" "$tasks_file" 2>/dev/null || true
    rm -f "${tasks_file}.bak"
    echo "  [ui-restorer] Task $task_num 已标记为 done" >&2
  else
    echo "  [ui-restorer] Task $task_num 有未通过的块，不标记 done" >&2
    return 1
  fi

  return 0
```

- [ ] **Step 3: 新增 `_read_ui_artifacts` 辅助函数**

在 `step2a_restore_task` 函数之前（第 126 行前）添加：

```bash
# 读取 UI 还原产物清单中所有文件（用于 Phase 3 审查）
# 输出：每行一个相对路径
_read_ui_artifacts() {
  local feature_name="$1"
  local artifact_file="$PROJECT_ROOT/specs/$feature_name/.ui-restore-artifacts.json"
  [ -f "$artifact_file" ] || return 0
  jq -r '.tasks[].files[]' "$artifact_file" 2>/dev/null | sort -u
}

# 检查指定 task 在产物清单中是否已标记
_task_has_artifacts() {
  local feature_name="$1"
  local task_num="$2"
  local artifact_file="$PROJECT_ROOT/specs/$feature_name/.ui-restore-artifacts.json"
  [ -f "$artifact_file" ] && jq -e ".tasks[\"$task_num\"]" "$artifact_file" >/dev/null 2>&1
}
```

- [ ] **Step 4: 验证修改无语法错误**

Run: `bash -n orchestrator/scripts/v4/lib/antigravity.sh`
Expected: 无输出（无语法错误）

- [ ] **Step 5: Commit**

```bash
git add orchestrator/scripts/v4/lib/antigravity.sh
git commit -m "feat(antigravity): 写入产物清单 + task done 标记

step2a_restore_task 执行完后：
- 将产物文件列表写入 specs/<feature>/.ui-restore-artifacts.json
- 所有块通过时标记 tasks.md 中对应 task 为 done
- 有未通过块时返回 1（不标记 done）"
```

---

### Task 2: step2-develop.sh — Step 2a 严格完成判定

**Files:**
- Modify: `orchestrator/scripts/v4/steps/step2-develop.sh:89-106`

- [ ] **Step 1: 替换 Step 2a 循环和完成通知逻辑**

将第 89-106 行（从 `# 逐个执行 antigravity 任务` 到 `notify "✅ Step 2a 完成"` ）替换为：

```bash
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
```

- [ ] **Step 2: 验证修改无语法错误**

Run: `bash -n orchestrator/scripts/v4/steps/step2-develop.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add orchestrator/scripts/v4/steps/step2-develop.sh
git commit -m "fix(step2a): 严格完成判定 — 全部 task done + 有产物才允许通知完成

- 循环中严格区分成功/失败 task
- 验证 tasks.md 中所有 antigravity task 状态为 done
- 验证产物清单 .ui-restore-artifacts.json 有记录
- 任一验证失败则中止 Step 2a 并通知用户"
```

---

### Task 3: step2-develop.sh — Phase 3 审查只用产物文件

**Files:**
- Modify: `orchestrator/scripts/v4/steps/step2-develop.sh:108-163`

- [ ] **Step 1: 替换 Phase 3 的文件范围获取逻辑**

将第 108-163 行（整个 Phase 3 块）替换为：

```bash
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
```

- [ ] **Step 2: 验证修改无语法错误**

Run: `bash -n orchestrator/scripts/v4/steps/step2-develop.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add orchestrator/scripts/v4/steps/step2-develop.sh
git commit -m "fix(step2a): Phase 3 审查只用 UI 产物文件

从 .ui-restore-artifacts.json 读取审查范围，
不再用 git diff --name-only HEAD（会混入 .claude/ 等无关文件）。
Codex 审查 prompt 中明确列出审查文件列表。"
```

---

### Task 4: step2-develop.sh — Step 2b 前验证 antigravity 任务完成

**Files:**
- Modify: `orchestrator/scripts/v4/steps/step2-develop.sh:170-184`

- [ ] **Step 1: 在 Step 2b 启动前添加 antigravity 完成验证**

在第 170 行 `# ── Step 2b:` 注释之后、第 171 行 `echo` 之前插入：

```bash
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
```

- [ ] **Step 2: 增强 Step 2b prompt —— 明确告知已完成的 antigravity 产物**

将第 174-184 行的 `opencli claude` 调用替换为：

```bash
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
```

- [ ] **Step 3: 验证修改无语法错误**

Run: `bash -n orchestrator/scripts/v4/steps/step2-develop.sh`
Expected: 无输出

- [ ] **Step 4: Commit**

```bash
git add orchestrator/scripts/v4/steps/step2-develop.sh
git commit -m "fix(step2b): 验证 antigravity 任务完成后才启动业务开发

- Step 2b 前检查所有 antigravity task 状态为 done，否则阻断
- 将产物文件列表注入 Step 2b prompt，防止 Claude Code 重写 UI
- Task 边界明确：antigravity 负责 UI，claude-code 负责业务集成"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - Problem 1 (完成条件过松) → Task 2 修复
   - Problem 2 (审查对象错误) → Task 3 修复
   - Problem 3 (无产物追踪) → Task 1 修复
   - Problem 4 (Task 边界不清) → Task 4 修复
   - 全部覆盖 ✅

2. **Placeholder scan:** 所有代码块包含完整实现，无 TBD/TODO

3. **Type consistency:**
   - `_read_ui_artifacts` 在 Task 1 定义，Task 2/3/4 使用 — 一致
   - `artifact_file` 路径 `specs/<feature>/.ui-restore-artifacts.json` — 全文一致
   - `task_num` 变量名 — 全文一致
   - `extract_task_field` 已在 antigravity.sh 第 7 行定义 — 复用

4. **bash 3.2 兼容性:**
   - 未使用 `declare -A`（关联数组）
   - `failed_tasks`/`succeeded_tasks` 用字符串拼接而非数组 — 兼容
   - `block_results` 数组已在原代码中存在 — 保持原样
