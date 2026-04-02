#!/bin/bash
# antigravity.sh — Antigravity UI restoration
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 提取 tasks.md 中所有 antigravity 任务的字段值
# 用法: extract_task_field <tasks_file> <task_number> <field>
extract_task_field() {
  local tasks_file="$1"
  local task_num="$2"
  local field="$3"
  # 提取从 ### Task {N} 开始到下一个 ### Task 之间的内容，再取字段值
  awk "/^### Task ${task_num}[：:]/,/^### Task [0-9]/" "$tasks_file" 2>/dev/null \
    | grep "^- ${field}:" \
    | head -1 \
    | sed "s/^- ${field}:[[:space:]]*//"
}

# Antigravity CLI 兼容层（适配 opencli 1.3.x）
ANTIGRAVITY_BIN="${ANTIGRAVITY_BIN:-/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity}"

# 说明：当前 opencli antigravity send 不支持 --model/--variant，且 send 只保证发出消息，
# AI 回复需再通过 read 读取。因此这里统一做状态检查 + send + best-effort read。
antigravity_is_page_scriptable() {
  local status_output url
  status_output=$(opencli antigravity status 2>/dev/null || true)
  echo "$status_output" | grep -q "Connected" || return 1
  url=$(echo "$status_output" | awk -F'│' '/Connected/ {gsub(/^ +| +$/, "", $3); print $3; exit}')
  [ -n "$url" ] || return 1
  case "$url" in
    about:blank*|chrome://*|chrome-extension://*|https://chromewebstore.google.com/*|https://clients2.google.com/*)
      return 1
      ;;
  esac
  return 0
}

antigravity_switch_model() {
  local mode="$1"
  local candidates=()
  case "$mode" in
    thinking)
      candidates=("Claude Opus 4.6 (Thinking)" "Gemini 3.1 Pro (High)" "Gemini 3 Flash" "claude" "gemini")
      ;;
    pro)
      candidates=("Gemini 3.1 Pro (High)" "Gemini 3 Flash" "gemini")
      ;;
    fast)
      candidates=("Gemini 3.1 Pro (High)" "Gemini 3 Flash" "gemini")
      ;;
    *)
      candidates=("Gemini 3.1 Pro (High)" "Gemini 3 Flash" "gemini")
      ;;
  esac

  local target
  for target in "${candidates[@]}"; do
    if opencli antigravity model "$target" >/dev/null 2>&1; then
      echo "[antigravity] mode=$mode switched model=$target" >&2
      return 0
    fi
  done

  echo "[antigravity] mode=$mode failed to switch any candidate model" >&2
  return 1
}

antigravity_send_message() {
  local prompt="$1"
  local mode="${2:-thinking}"
  if ! antigravity_is_page_scriptable; then
    echo "[antigravity] page not scriptable or bridge not ready" >&2
    return 1
  fi
  antigravity_switch_model "$mode" || true
  opencli antigravity send "$prompt" >/dev/null 2>&1
}

codex_score_ui() {
  local figma_url="$1"
  local block_name="$2"
  local screenshot="$3"
  local design_spec="$4"

  if ! command -v codex >/dev/null 2>&1; then
    cat <<'EOF'
SCORE: 0
DIFF_COMPLEXITY: major
FIXES:
  - Codex 未安装，无法执行视觉评分
PASS: false
EOF
    return 0
  fi

  codex exec --full-auto "你现在是 UI 视觉评分器。请基于以下信息给出结构化评分：

Figma 设计稿：$figma_url
目标区域：$block_name
当前渲染截图文件：$screenshot
设计规格：
$design_spec

任务：评估当前截图相对设计稿/设计规格的还原质量。

评估维度：
1. 整体布局结构是否一致
2. 间距/padding/margin 是否准确
3. 颜色/字体/字号是否匹配
4. 组件细节（圆角/阴影/边框）是否还原
5. 响应式是否正确（如截图中可判断）

严格按以下格式输出，不要有其他文字：
SCORE: {1-10}
DIFF_COMPLEXITY: minor|major
FIXES:
  - {元素.属性: 实际值 → 设计值}
PASS: true|false" 2>/dev/null || cat <<'EOF'
SCORE: 0
DIFF_COMPLEXITY: major
FIXES:
  - Codex 视觉评分执行失败
PASS: false
EOF
}

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

# 执行单个 antigravity 任务的分块还原
# 返回: 0=通过(包括人工确认) 1=失败
step2a_restore_task() {
  local feature_name="$1"
  local task_num="$2"
  local base_url="$3"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local artifact_file="$spec_dir/.ui-restore-artifacts.json"

  # 初始化本 task 的产物记录（追加模式，多 task 共享同一文件）
  if [ ! -f "$artifact_file" ]; then
    echo '{"tasks":{}}' > "$artifact_file"
  fi

  local score_threshold="${UI_RESTORE_SCORE_THRESHOLD:-8}"
  local report_batch="${UI_RESTORE_REPORT_BATCH_SIZE:-3}"

  local figma_url preview_route file_path task_name
  figma_url=$(extract_task_field "$tasks_file" "$task_num" "figma")
  preview_route=$(extract_task_field "$tasks_file" "$task_num" "预览路由")
  file_path=$(extract_task_field "$tasks_file" "$task_num" "文件范围" | tr -d '`')
  task_name=$(awk "/^### Task ${task_num}[：:]/{print; exit}" "$tasks_file" \
    | sed 's/^### Task [0-9]*[：:][[:space:]]*//')

  echo "  [ui-restorer] Task $task_num: $task_name" >&2
  echo "  [ui-restorer] figma=$figma_url route=$preview_route file=$file_path" >&2

  # 导航到预览页面
  local page_url="${base_url}${preview_route}"
  local cdp_target
  cdp_target=$(node "$PROJECT_ROOT/scripts/cdp.mjs" list 2>/dev/null \
    | grep -i "localhost:${base_url##*:}" | head -1 | awk '{print $1}' || echo "")

  if [ -n "$cdp_target" ]; then
    node "$PROJECT_ROOT/scripts/cdp.mjs" nav "$cdp_target" "$page_url" >/dev/null 2>&1 || true
    sleep 2  # 等待页面渲染
  fi

  # 读取分块策略
  local blocks_raw
  blocks_raw=$(awk "/^### Task ${task_num}[：:]/,/^### Task [0-9]/" "$tasks_file" 2>/dev/null \
    | grep "^  - 块" | sed 's/^  - //')
  local block_total
  block_total=$(echo "$blocks_raw" | grep -c "块" || echo 1)

  echo "  [ui-restorer] 检测到 $block_total 个还原分块" >&2

  # 读取设计规格（整块提取）
  local design_spec
  design_spec=$(awk "/^### Task ${task_num}[：:]/,/^### Task [0-9]/" "$tasks_file" 2>/dev/null \
    | awk '/^- 设计规格：/,/^- [^ ]/' \
    | grep -v "^- 还原策略" | grep -v "^- 指令")

  local block_results=()   # 记录每块结果 "block_name:score:screenshot"
  local needs_review=()    # 记录需人工确认的块
  local block_idx=0

  while IFS= read -r block_line; do
    [ -z "$block_line" ] && continue
    block_idx=$((block_idx + 1))
    local block_name="${block_line#*: }"

    echo "  [ui-restorer] 分块 $block_idx/$block_total: $block_name" >&2
    notify "🎨 UI 还原 Task $task_num 块 $block_idx/$block_total: $block_name" "$feature_name"

    local screenshot_base="/tmp/ui-restore-${feature_name}-task${task_num}-block${block_idx}"
    local score=0
    local diff_complexity="major"
    local fixes=""
    local round

    for round in 1 2; do
      echo "  [ui-restorer] Round $round..." >&2

      # 调用 Antigravity 生成/修复（opencli 1.3.x 不支持 --model/--variant）
      if [ "$round" -eq 1 ]; then
        antigravity_send_message \
          "你只负责 UI 还原，不碰业务逻辑。

页面：$task_name
当前分块：$block_name（第 $block_idx/$block_total 块）
生成文件：$file_path
预览路由：$preview_route

设计规格（Figma MCP 已提取）：
$design_spec

项目约束：
- 使用 src/components/ui/ 中已有的 design system 组件
- 使用项目 CSS 变量 / Tailwind 配置
- 响应式断点：mobile(375) / tablet(768) / desktop(1440)
- Props 接口定义在组件顶部
- 禁止：API 调用 / 状态管理 / 路由跳转 / 硬编码颜色 / 内联样式

请生成 $block_name 的代码，写入 $file_path。" "thinking" || true
      else
        # Round 2：带精确 diff 修复
        antigravity_send_message \
          "根据以下视觉 diff 精确修复 $file_path：

$fixes

Figma 设计规格参考：
$design_spec

只修改与 diff 相关的代码，不要重写其他部分。" "$([ "$diff_complexity" = "major" ] && echo thinking || echo fast)" || true
      fi

      sleep 3  # 等待热更新

      # 截图
      local screenshot="${screenshot_base}-round${round}.png"
      if [ -n "$cdp_target" ]; then
        node "$PROJECT_ROOT/scripts/cdp.mjs" shot "$cdp_target" "$screenshot" >/dev/null 2>&1 || true
      fi

      # Codex 视觉打分（Antigravity 只负责生成/修复，不负责结构化回评）
      local score_output
      score_output=$(codex_score_ui "$figma_url" "$block_name" "$screenshot" "$design_spec")

      # 解析打分结果
      score=$(echo "$score_output" | grep "^SCORE:" | sed 's/SCORE:[[:space:]]*//' | tr -d ' \r')
      diff_complexity=$(echo "$score_output" | grep "^DIFF_COMPLEXITY:" | sed 's/DIFF_COMPLEXITY:[[:space:]]*//' | tr -d ' \r')
      fixes=$(echo "$score_output" | awk '/^FIXES:/,/^PASS:/' | grep -v "^FIXES:\|^PASS:")
      local pass_val
      pass_val=$(echo "$score_output" | grep "^PASS:" | sed 's/PASS:[[:space:]]*//' | tr -d ' \r')

      is_numeric "$score" || score=0
      echo "  [ui-restorer] 块 $block_idx Round $round 得分: $score/10 (PASS=$pass_val)" >&2

      if [ "$pass_val" = "true" ] || [ "$score" -ge "$score_threshold" ]; then
        block_results+=("${block_name}:${score}:${screenshot}")
        echo "  [ui-restorer] 块 $block_idx PASS (${score}/10)" >&2
        break
      fi

      if [ "$round" -eq 2 ]; then
        # 2 轮后仍不达标，加入人工确认队列
        needs_review+=("${block_name}:${score}:${screenshot}:${fixes}")
        block_results+=("${block_name}:${score}:${screenshot}:NEEDS_REVIEW")
        echo "  [ui-restorer] 块 $block_idx 2轮后仍不达标(${score}/10)，等待人工确认" >&2
      fi
    done

    # 按批次汇报（每 report_batch 块汇报一次）
    if [ $((block_idx % report_batch)) -eq 0 ] && [ ${#block_results[@]} -gt 0 ]; then
      _report_ui_progress "$feature_name" "$task_num" "$task_name" \
        "$block_idx" "$block_total" "${block_results[@]}" "${needs_review[@]+"${needs_review[@]}"}"
      needs_review=()
    fi

  done <<< "$blocks_raw"

  # 最后一批汇报（余量 or 总块数 <= report_batch）
  if [ ${#block_results[@]} -gt 0 ]; then
    _report_ui_progress "$feature_name" "$task_num" "$task_name" \
      "$block_total" "$block_total" "${block_results[@]}" "${needs_review[@]+"${needs_review[@]}"}"
  fi

  # ── 先检查是否所有块都通过（未通过则不写产物、不标记 done）──
  local has_review_needed=false
  for r in "${block_results[@]}"; do
    if echo "$r" | grep -q "NEEDS_REVIEW"; then
      has_review_needed=true
      break
    fi
  done

  if [ "$has_review_needed" = "true" ] || [ ${#block_results[@]} -eq 0 ]; then
    echo "  [ui-restorer] Task $task_num 有未通过的块，不标记 done" >&2
    return 1
  fi

  # ── 记录产物清单（仅在所有块通过后才写入）──
  local task_ui_files=""
  if [ -n "$file_path" ]; then
    if [ -d "$PROJECT_ROOT/$file_path" ]; then
      task_ui_files=$(find "$PROJECT_ROOT/$file_path" -type f \( -name '*.tsx' -o -name '*.ts' -o -name '*.jsx' -o -name '*.js' -o -name '*.css' -o -name '*.scss' \) 2>/dev/null \
        | sed "s|^$PROJECT_ROOT/||" | sort)
    elif [ -f "$PROJECT_ROOT/$file_path" ]; then
      task_ui_files="$file_path"
    fi
  fi
  # 兜底：从 git diff 取本轮实际变更的 src 文件
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
    --argjson passed "${#block_results[@]}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name, file_path:$fp, files:$files, blocks_total:$blocks, blocks_passed:$passed, timestamp:$ts}')

  local tmp_artifact
  tmp_artifact=$(mktemp)
  jq --arg tn "$task_num" --argjson entry "$task_entry" \
    '.tasks[$tn] = $entry' "$artifact_file" > "$tmp_artifact" 2>/dev/null \
    && mv "$tmp_artifact" "$artifact_file" \
    || rm -f "$tmp_artifact"

  local ui_file_count=0
  [ -n "$task_ui_files" ] && ui_file_count=$(printf '%s\n' "$task_ui_files" | wc -l | tr -d ' ')
  echo "  [ui-restorer] Task $task_num 产物已记录: $ui_file_count 个文件" >&2

  # ── 标记 task done（所有块已通过）──
  sed -i.bak "/^### Task ${task_num}[：:]/,/^### Task [0-9]/ s/^- 状态：.*/- 状态：done/" "$tasks_file" 2>/dev/null || true
  rm -f "${tasks_file}.bak"
  echo "  [ui-restorer] Task $task_num 已标记为 done" >&2

  return 0
}

# 汇报 UI 还原进度（通过 agent_notify 发飞书）
_report_ui_progress() {
  local feature_name="$1"
  local task_num="$2"
  local task_name="$3"
  local done_count="$4"
  local total_count="$5"
  shift 5
  local results=("$@")

  local pass_count=0
  local review_lines=""
  local screenshot_list=""

  for r in "${results[@]}"; do
    local bname bscore bshot
    bname=$(echo "$r" | cut -d: -f1)
    bscore=$(echo "$r" | cut -d: -f2)
    bshot=$(echo "$r" | cut -d: -f3)
    local status
    status=$(echo "$r" | cut -d: -f4)

    if [ "$status" != "NEEDS_REVIEW" ]; then
      pass_count=$((pass_count + 1))
    else
      local bfixes
      bfixes=$(echo "$r" | cut -d: -f5-)
      review_lines+="─ ${bname}：当前得分 ${bscore}/10\n  主要问题：${bfixes}\n  截图：${bshot}\n"
    fi
    [ -n "$bshot" ] && screenshot_list+="  ${bshot}\n"
  done

  local context
  context="UI 还原进度 — Task ${task_num}: ${task_name}

已完成：${done_count}/${total_count} 块
自动通过（≥${UI_RESTORE_SCORE_THRESHOLD:-8}分）：${pass_count}/${#results[@]} 块

$([ -n "$review_lines" ] && echo "需确认的分块：
$review_lines" || echo "所有分块已自动通过 ✅")

截图路径：
$screenshot_list"

  local question="请查看截图后回复：
1. 满意 → 回复「继续」
2. 不满意 → 描述具体问题（如：按钮颜色偏蓝/间距太大），我会让 Antigravity 重新修复"

  agent_notify "$context" "$question" "$feature_name"
}
