#!/bin/bash
# antigravity.sh — Antigravity UI restoration
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# ── Block-level structured logging ──

# Reason codes for step2a_restore_task failures:
#   UI_RESTORE_NO_BLOCK_RESULTS       — block loop produced zero results
#   UI_RESTORE_BLOCK_SCORE_FAILED     — one or more blocks did not pass after 2 rounds
#   UI_RESTORE_ARTIFACT_RECORD_FAILED — blocks passed but no artifact files recorded
#   UI_RESTORE_TASK_STATUS_UPDATE_FAILED — artifacts ok but tasks.md status not updated

# Append a block-round entry to the restore log JSON
# Usage: _ui_log_block <log_file> <task_num> <block_idx> <block_name> <round>
#        <screenshot> <score> <diff_complexity> <pass> <fixes> <duration_sec> <status>
_ui_log_block() {
  local log_file="$1" task_num="$2" block_idx="$3" block_name="$4" round="$5"
  local screenshot="$6" score="$7" diff_complexity="$8" pass_val="$9"
  shift 9
  local fixes="$1" duration_sec="$2" status="$3"

  local bi_json rn_json sc_json dur_json
  bi_json=$(_safe_json_int "$block_idx")
  rn_json=$(_safe_json_int "$round")
  sc_json=$(_safe_json_int "$score")
  dur_json=$(_safe_json_int "$duration_sec")

  local entry
  entry=$(jq -n \
    --arg tn "$task_num" \
    --argjson bi "$bi_json" \
    --arg bn "$block_name" \
    --argjson rn "$rn_json" \
    --arg ss "$screenshot" \
    --argjson sc "$sc_json" \
    --arg dc "$diff_complexity" \
    --arg pv "$pass_val" \
    --arg fx "$fixes" \
    --argjson dur "$dur_json" \
    --arg st "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task: $tn, block_idx: $bi, block_name: $bn, round: $rn,
      screenshot: $ss, score: $sc, diff_complexity: $dc, pass: $pv,
      fixes: $fx, duration_sec: $dur, status: $st, timestamp: $ts}')

  local tmp
  tmp=$(mktemp)
  if [ -f "$log_file" ]; then
    jq --argjson e "$entry" '.entries += [$e]' "$log_file" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$log_file" \
      || { rm -f "$tmp"; echo "$entry" >> "${log_file}.fallback"; }
  else
    jq -n --argjson e "$entry" '{entries: [$e]}' > "$log_file" 2>/dev/null \
      || echo "$entry" >> "${log_file}.fallback"
  fi
}

# Write task-level summary to the restore log
# Usage: _ui_log_task_summary <log_file> <task_num> <task_name> <reason_code>
#        <block_total> <blocks_passed> <failed_blocks_json> <extra_msg>
_ui_log_task_summary() {
  local log_file="$1" task_num="$2" task_name="$3" reason_code="$4"
  local block_total="$5" blocks_passed="$6" failed_blocks_json="$7" extra_msg="$8"

  local bt_json bp_json fb_json
  bt_json=$(_safe_json_int "$block_total")
  bp_json=$(_safe_json_int "$blocks_passed")
  fb_json=$(_safe_json_array "$failed_blocks_json")

  local summary
  summary=$(jq -n \
    --arg tn "$task_num" \
    --arg name "$task_name" \
    --arg reason "$reason_code" \
    --argjson bt "$bt_json" \
    --argjson bp "$bp_json" \
    --argjson fb "$fb_json" \
    --arg msg "$extra_msg" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{task: $tn, task_name: $name, reason_code: $reason,
      blocks_total: $bt, blocks_passed: $bp, failed_blocks: $fb,
      message: $msg, timestamp: $ts}')

  local tmp
  tmp=$(mktemp)
  if [ -f "$log_file" ]; then
    jq --argjson s "$summary" '.task_summary += [$s]' "$log_file" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$log_file" \
      || { rm -f "$tmp"; echo "$summary" >> "${log_file}.fallback"; }
  else
    jq -n --argjson s "$summary" '{entries: [], task_summary: [$s]}' > "$log_file" 2>/dev/null \
      || echo "$summary" >> "${log_file}.fallback"
  fi
}

# 提取 Task N 的完整正文（从标题行的下一行开始，到下一个 ### Task 标题之前）
# 修复：旧版 awk range 模式 /^### Task N/,/^### Task [0-9]/ 会在标题行同时
# 命中起始和结束条件，导致区间立即关闭，正文全部丢失。
# 用法: _extract_task_body <tasks_file> <task_number>
_extract_task_body() {
  local tasks_file="$1"
  local task_num="$2"
  awk -v tn="$task_num" '
    BEGIN { found=0 }
    /^### Task / {
      if (found) exit
      # 匹配 "### Task N：" 或 "### Task N:"
      if ($0 ~ "^### Task " tn "[：:]") { found=1; next }
    }
    found { print }
  ' "$tasks_file" 2>/dev/null
}

# 提取 tasks.md 中所有 antigravity 任务的字段值
# 用法: extract_task_field <tasks_file> <task_number> <field>
extract_task_field() {
  local tasks_file="$1"
  local task_num="$2"
  local field="$3"
  _extract_task_body "$tasks_file" "$task_num" \
    | grep -E "^- ${field}[：:]" \
    | head -1 \
    | sed -E "s/^- ${field}[：:][[:space:]]*//"
}

# 安全数值 / JSON 兜底，避免 jq --argjson 因空值直接崩溃
_safe_json_int() {
  local value="$1"
  if printf '%s' "$value" | grep -Eq '^-?[0-9]+$'; then
    printf '%s' "$value"
  else
    printf '0'
  fi
}

_safe_json_array() {
  local value="$1"
  if printf '%s' "$value" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$value"
  else
    printf '[]'
  fi
}

_safe_json_object() {
  local value="$1"
  if printf '%s' "$value" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$value"
  else
    printf '{}'
  fi
}

# 提取多行“文件范围”字段中的真实文件路径（去掉中文备注）
# 输出：每行一个相对路径
extract_task_file_paths() {
  local tasks_file="$1"
  local task_num="$2"
  _extract_task_body "$tasks_file" "$task_num" | awk '
    BEGIN { in_field=0 }
    /^- 文件范围[：:]/ { in_field=1; next }
    in_field {
      if ($0 ~ /^- /) exit
      if ($0 ~ /^  - /) {
        line=$0
        sub(/^  - /, "", line)
        sub(/[[:space:]]*[（(].*$/, "", line)
        gsub(/`/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line != "") print line
      }
    }
  '
}

# Antigravity CLI 兼容层（适配 opencli 1.3.x）
ANTIGRAVITY_BIN="${ANTIGRAVITY_BIN:-/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity}"

# 说明：当前 opencli antigravity send 不支持 --model/--variant，且 send 只保证发出消息，
# AI 回复需再通过 read 读取。因此这里统一做状态检查 + send + best-effort read。
antigravity_is_page_scriptable() {
  local status_output url
  status_output=$(opencli antigravity status 2>/dev/null || true)
  echo "$status_output" | grep -q "Connected" || return 1
  url=$(printf '%s\n' "$status_output" | grep -Eo 'https?://[^[:space:]│]+' | head -1)
  [ -n "$url" ] || return 1
  case "$url" in
    about:blank*|chrome://*|chrome-extension://*|https://chromewebstore.google.com/*|https://clients2.google.com/*)
      return 1
      ;;
  esac
  return 0
}

# 当前 Antigravity tab 是否命中预期 URL（允许 query/hash 差异）
antigravity_current_url_matches() {
  local expected_url="$1"
  local status_output current_url expected_base
  status_output=$(opencli antigravity status 2>/dev/null || true)
  echo "$status_output" | grep -q "Connected" || return 1
  current_url=$(printf '%s\n' "$status_output" | grep -Eo 'https?://[^[:space:]│]+' | head -1)
  [ -n "$current_url" ] || return 1
  expected_base=${expected_url%%[#?]*}
  case "$current_url" in
    "$expected_base"|"$expected_base"\?*|"$expected_base"\#*|"$expected_base"\?*\#*)
      return 0
      ;;
  esac
  return 1
}

antigravity_status_json() {
  local status_output current_url title
  status_output=$(opencli antigravity status 2>/dev/null || true)
  current_url=$(printf '%s\n' "$status_output" | grep -Eo 'https?://[^[:space:]│]+' | head -1)
  title=$(printf '%s\n' "$status_output" | awk -F'│' '/Connected/ {gsub(/^ +| +$/, "", $4); print $4; exit}')
  jq -n --arg url "$current_url" --arg title "$title" '{url:$url,title:$title}' 2>/dev/null || echo '{}'
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
  local attempt=1
  local max_attempts=3

  while [ "$attempt" -le "$max_attempts" ]; do
    if antigravity_is_page_scriptable; then
      antigravity_switch_model "$mode" || true
      opencli antigravity send "$prompt" >/dev/null 2>&1
      return 0
    fi
    echo "[antigravity] page not scriptable or bridge not ready (attempt ${attempt}/${max_attempts})" >&2
    sleep 2
    attempt=$((attempt + 1))
  done

  return 1
}

# 统一解析 antigravity read/watch 的 JSON 输出
# stdout: 文本回复；return 0=有有效文本 1=空/无效
_parse_antigravity_reply_json() {
  local raw_json="$1"
  [ -z "$raw_json" ] && return 1
  [ "$raw_json" = "[]" ] && return 1
  if printf '%s' "$raw_json" | jq -e 'length == 1 and .[0].role == "history" and ((.[0].content // "") == "null")' >/dev/null 2>&1; then
    return 1
  fi

  local reply
  reply=$(printf '%s' "$raw_json" | jq -r '[ .[] | select((.role // "") != "history") | .content // empty ] | join("\n")' 2>/dev/null || true)
  [ -z "$reply" ] && reply=$(printf '%s' "$raw_json" | jq -r '.[0].content // empty' 2>/dev/null || true)
  [ -n "$reply" ] || return 1
  printf '%s' "$reply"
  return 0
}

# ── 发送消息并等待 AI 回复（watch + extract-code + read fallback）──
# 用法: antigravity_send_and_wait <prompt> <mode> <max_wait> <reply_out_file>
# return: 0=收到有效回复 1=超时或无回复
# side effect: 设置全局 AG_LAST_REASON
antigravity_send_and_wait() {
  local prompt="$1"
  local mode="${2:-thinking}"
  local max_wait="${3:-120}"
  local reply_out_file="${4:-}"
  AG_LAST_REASON=""

  local before_read after_read
  before_read=$(opencli antigravity read --format json 2>/dev/null || true)

  if ! antigravity_send_message "$prompt" "$mode"; then
    AG_LAST_REASON="ANTIGRAVITY_SEND_FAILED"
    return 1
  fi

  local elapsed=0
  local poll_interval=5
  local watch_window=12
  local raw_reply_json=""
  local reply=""
  local code_json=""
  local code_count="0"
  echo "  [antigravity] 等待 AI 回复（最多 ${max_wait}s）..." >&2

  while [ "$elapsed" -lt "$max_wait" ]; do
    raw_reply_json=$(perl -e 'alarm shift @ARGV; exec @ARGV' "$watch_window" opencli antigravity watch --format json 2>/dev/null || true)
    elapsed=$((elapsed + watch_window))

    reply=$(_parse_antigravity_reply_json "$raw_reply_json" || true)

    # watch 没抓到时，再用 read 做兜底
    if [ -z "$reply" ]; then
      sleep "$poll_interval"
      elapsed=$((elapsed + poll_interval))
      raw_reply_json=$(opencli antigravity read --format json 2>/dev/null || true)
      reply=$(_parse_antigravity_reply_json "$raw_reply_json" || true)
    fi

    after_read=$(opencli antigravity read --format json 2>/dev/null || true)
    code_json=$(opencli antigravity extract-code --format json 2>/dev/null || true)
    code_count=$(printf '%s' "$code_json" | jq -r 'length' 2>/dev/null)
    code_count=$(_safe_json_int "$code_count")

    # 有真实文本回复，或者至少检测到代码块，才算有效
    if [ -n "$reply" ] || [ "$code_count" -gt 0 ]; then
      echo "  [antigravity] 收到 AI 回复（${elapsed}s），reply_len=$(echo "$reply" | wc -c | tr -d ' ') code_blocks=${code_count}" >&2
      if [ -n "$reply_out_file" ]; then
        if [ "$code_count" -gt 0 ]; then
          printf '%s\n\n[code_blocks=%s]' "$reply" "$code_count" > "$reply_out_file"
        else
          printf '%s' "$reply" > "$reply_out_file"
        fi
      fi
      return 0
    fi
  done

  if [ -n "$before_read" ] && [ "$before_read" = "$after_read" ]; then
    AG_LAST_REASON="ANTIGRAVITY_SEND_NO_CONVERSATION_UPDATE"
    echo "  [antigravity] ⚠️ send 后会话无变化（read 输出未更新）" >&2
  else
    AG_LAST_REASON="ANTIGRAVITY_REPLY_TIMEOUT"
  fi
  echo "  [antigravity] ⚠️ 等待 AI 回复超时（${max_wait}s）" >&2
  return 1
}

# 获取 antigravity DOM dump 文件路径，帮助 prompt 绑定当前页面上下文
# stdout: htmlFile|snapFile
antigravity_dump_context() {
  local dump_json
  dump_json=$(opencli antigravity dump --format json 2>/dev/null || true)
  local html_file snap_file
  html_file=$(printf '%s' "$dump_json" | jq -r '.[0].htmlFile // empty' 2>/dev/null || true)
  snap_file=$(printf '%s' "$dump_json" | jq -r '.[0].snapFile // empty' 2>/dev/null || true)
  printf '%s|%s' "$html_file" "$snap_file"
}

# ── 验证目标文件是否被创建或修改 ──
# Usage: antigravity_verify_files_changed <project_root> <file_path> <git_baseline_ref>
# return: 0=有文件变化 1=无变化
antigravity_verify_files_changed() {
  local project_root="$1"
  local file_path="$2"
  local baseline_ref="${3:-HEAD}"

  # 检查文件是否存在
  if [ -n "$file_path" ]; then
    if [ -d "$project_root/$file_path" ]; then
      local new_or_modified
      new_or_modified=$(git -C "$project_root" diff --name-only "$baseline_ref" -- "$file_path" 2>/dev/null || true)
      local untracked
      untracked=$(git -C "$project_root" ls-files --others --exclude-standard -- "$file_path" 2>/dev/null || true)
      if [ -n "$new_or_modified" ] || [ -n "$untracked" ]; then
        echo "  [antigravity] ✅ 文件变化检测通过: $(echo "$new_or_modified $untracked" | wc -w | tr -d ' ') 个文件" >&2
        return 0
      fi
    elif [ -f "$project_root/$file_path" ]; then
      # 单文件：检查是否新建或有 diff
      if git -C "$project_root" diff --name-only "$baseline_ref" -- "$file_path" 2>/dev/null | grep -q . \
         || git -C "$project_root" ls-files --others --exclude-standard -- "$file_path" 2>/dev/null | grep -q .; then
        echo "  [antigravity] ✅ 文件变化检测通过: $file_path" >&2
        return 0
      fi
    fi
  fi

  echo "  [antigravity] ❌ 文件无变化: $file_path" >&2
  return 1
}

# 带超时的 CDP 调用，避免 cdp.mjs 卡死把整个 workflow 挂住
_run_cdp_timeout() {
  local project_root="$1"
  local timeout_sec="$2"
  shift 2
  perl -e 'alarm shift @ARGV; exec @ARGV' "$timeout_sec" node "$project_root/scripts/cdp.mjs" "$@"
}

# ── 检测页面是否为 404 / fallback 页面 ──
# Usage: antigravity_check_page_not_404 <cdp_target> <project_root> <screenshot_path>
# return: 0=页面正常 1=页面是 404/fallback
antigravity_check_page_not_404() {
  local cdp_target="$1"
  local project_root="$2"
  local screenshot_path="${3:-}"

  # 方法 1: 通过 CDP eval 检测页面文本内容
  local page_text
  page_text=$(_run_cdp_timeout "$project_root" 5 eval "$cdp_target" \
    "document.body?.innerText?.substring(0, 500) || ''" 2>/dev/null || echo "")

  # 常见 404 / fallback 页面特征检测
  if echo "$page_text" | grep -qi "404\|not found\|page not found\|页面不存在\|页面未找到\|does not exist"; then
    echo "  [antigravity] ❌ 检测到 404/fallback 页面" >&2
    echo "  [antigravity] 页面文本片段: $(echo "$page_text" | head -3)" >&2
    return 1
  fi

  # 方法 2: 检测页面标题
  local page_title
  page_title=$(_run_cdp_timeout "$project_root" 5 eval "$cdp_target" \
    "document.title || ''" 2>/dev/null || echo "")
  if echo "$page_title" | grep -qi "404\|not found"; then
    echo "  [antigravity] ❌ 页面标题包含 404: $page_title" >&2
    return 1
  fi

  # 方法 3: 检测是否几乎没有内容（空白页面）
  local body_child_count
  body_child_count=$(_run_cdp_timeout "$project_root" 5 eval "$cdp_target" \
    "document.body?.children?.length || 0" 2>/dev/null || echo "0")
  if [ "$body_child_count" -le 1 ]; then
    echo "  [antigravity] ⚠️ 页面内容极少（children=$body_child_count），可能是空白/fallback" >&2
    # 不直接 fail，仅警告（SPA 可能只有一个 root div）
  fi

  echo "  [antigravity] ✅ 页面非 404（title=$page_title）" >&2
  return 0
}

# ── 预览路由前置：确保目标路由可访问 ──
# 方案 A: 在 App.tsx 中注入最小占位路由（如果路由不存在）
# Usage: antigravity_ensure_preview_route <project_root> <feature_name> <preview_route> <file_path> <base_url>
# return: 0=路由可访问 1=无法确保
antigravity_ensure_preview_route() {
  local project_root="$1"
  local feature_name="$2"
  local preview_route="$3"
  local file_path="$4"
  local base_url="$5"

  local page_url="${base_url}${preview_route}"
  echo "  [antigravity] 检查预览路由: $page_url" >&2
  echo "  [antigravity][debug] before preview curl" >&2

  # 先检查路由是否已经可用（通过 HTTP 请求 + 内容检查，带总超时避免挂死）
  local http_body
  http_body=$(perl -e 'alarm shift @ARGV; exec @ARGV' 5 curl -s --connect-timeout 3 --max-time 4 "$page_url" 2>/dev/null || echo "")

  echo "  [antigravity][debug] after preview curl" >&2

  # SPA 通常总返回 200（index.html），所以需要检查页面实际渲染结果
  # 通过 cdp 检查比较可靠，但这里做一个快速预检：检查目标组件文件是否存在
  local primary_file=""
  if [ -n "$file_path" ]; then
    # file_path 可能是目录或单文件
    if echo "$file_path" | grep -q ","; then
      # 多文件：取第一个
      primary_file=$(echo "$file_path" | cut -d',' -f1 | tr -d ' ')
    else
      primary_file="$file_path"
    fi
  fi

  # 检查目标页面组件文件是否已存在
  if [ -n "$primary_file" ] && [ -f "$project_root/$primary_file" ]; then
    echo "  [antigravity] 目标文件已存在: $primary_file，跳过占位生成" >&2
    return 0
  fi

  echo "  [antigravity] 目标文件不存在，生成最小占位页面 + 注册路由..." >&2

  # 查找 App.tsx / App.jsx 的路由注册点
  local app_file=""
  for candidate in "src/App.tsx" "src/App.jsx" "src/app.tsx" "src/app.jsx"; do
    if [ -f "$project_root/$candidate" ]; then
      app_file="$candidate"
      break
    fi
  done

  if [ -z "$app_file" ]; then
    echo "  [antigravity] ⚠️ 未找到 App.tsx，无法自动注册路由" >&2
    return 1
  fi

  # 解析目标页面组件名（从 file_path 推导）
  local page_component_name=""
  if [ -n "$primary_file" ]; then
    # src/pages/CouponPage.tsx → CouponPage
    page_component_name=$(basename "$primary_file")
    page_component_name="${page_component_name%.tsx}"
    page_component_name="${page_component_name%.jsx}"
    page_component_name="${page_component_name%.ts}"
    page_component_name="${page_component_name%.js}"
  fi
  [ -z "$page_component_name" ] && page_component_name="PlaceholderPage"

  # 确保目标目录存在
  local primary_dir
  primary_dir=$(dirname "$project_root/$primary_file")
  mkdir -p "$primary_dir" 2>/dev/null || true

  # 生成最小占位页面（仅骨架，antigravity 会覆盖）
  cat > "$project_root/$primary_file" << PLACEHOLDER_EOF
// Placeholder generated by antigravity UI restorer — will be overwritten
export default function ${page_component_name}() {
  return (
    <div data-testid="antigravity-placeholder" style={{ padding: '20px' }}>
      <h1>${page_component_name}</h1>
      <p>UI restore in progress...</p>
    </div>
  );
}
PLACEHOLDER_EOF

  echo "  [antigravity] 生成占位页面: $primary_file" >&2

  # 在 App.tsx 中注册路由（如果尚未注册）
  if ! grep -q "path=\"$preview_route\"" "$project_root/$app_file" 2>/dev/null; then
    # 计算相对导入路径
    local import_path
    import_path=$(echo "$primary_file" | sed 's|^src/||; s|\.tsx$||; s|\.jsx$||; s|\.ts$||; s|\.js$||')

    # 在文件顶部 import 区域追加 lazy import
    # 在最后一个 import 行后插入
    local last_import_line
    last_import_line=$(grep -n "^import " "$project_root/$app_file" | tail -1 | cut -d: -f1)
    if [ -n "$last_import_line" ]; then
      sed -i '' "${last_import_line}a\\
import ${page_component_name} from '@/${import_path}';
" "$project_root/$app_file" 2>/dev/null || true
    fi

    # 在 Route 区域插入路由（在最后一个 </Route> 或 </Routes> 前插入）
    # 策略：找包含 <Route 的区域，在最后一个 <Route .../> 后插入
    local route_insert_line
    route_insert_line=$(grep -n "<Route " "$project_root/$app_file" | tail -1 | cut -d: -f1)
    if [ -n "$route_insert_line" ]; then
      sed -i '' "${route_insert_line}a\\
              <Route path=\"${preview_route}\" element={<${page_component_name} />} />
" "$project_root/$app_file" 2>/dev/null || true
      echo "  [antigravity] 路由已注册: $preview_route → $page_component_name (in $app_file)" >&2
    else
      echo "  [antigravity] ⚠️ 未找到 Route 插入点，请手动注册路由" >&2
      return 1
    fi
  else
    echo "  [antigravity] 路由已存在: $preview_route" >&2
  fi

  # 等待 HMR 生效
  sleep 3
  return 0
}

# ── Figma MCP 任务级日志 ──
# Usage: figma_mcp_log <spec_dir> <action> <data_json>
figma_mcp_log() {
  local spec_dir="$1"
  local action="$2"
  local data_json="${3:-{}}"
  local log_file="$spec_dir/figma-mcp-log.json"

  local data_safe_json
  data_safe_json=$(_safe_json_object "$data_json")

  local entry
  entry=$(jq -n \
    --arg action "$action" \
    --argjson data "$data_safe_json" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{action: $action, data: $data, timestamp: $ts}')

  local tmp
  tmp=$(mktemp)
  if [ -f "$log_file" ]; then
    jq --argjson e "$entry" '.entries += [$e]' "$log_file" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$log_file" \
      || { rm -f "$tmp"; echo "$entry" >> "${log_file}.fallback"; }
  else
    jq -n --argjson e "$entry" '{entries: [$e]}' > "$log_file" 2>/dev/null \
      || echo "$entry" >> "${log_file}.fallback"
  fi
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
# 失败时设置全局变量 UI_RESTORE_LAST_REASON / UI_RESTORE_LAST_FAILED_BLOCKS / UI_RESTORE_LAST_LOG
step2a_restore_task() {
  local feature_name="$1"
  local task_num="$2"
  local base_url="$3"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local artifact_file="$spec_dir/.ui-restore-artifacts.json"
  local log_file="$spec_dir/ui-restore-log.json"

  # Reset per-task diagnostics (consumed by caller)
  UI_RESTORE_LAST_REASON=""
  UI_RESTORE_LAST_FAILED_BLOCKS=""
  UI_RESTORE_LAST_LOG="$log_file"

  # 初始化本 task 的产物记录（追加模式，多 task 共享同一文件）
  if [ ! -f "$artifact_file" ]; then
    echo '{"tasks":{}}' > "$artifact_file"
  fi

  # 初始化 restore log（如果不存在）
  if [ ! -f "$log_file" ]; then
    echo '{"entries":[],"task_summary":[]}' > "$log_file"
  fi

  local score_threshold="${UI_RESTORE_SCORE_THRESHOLD:-8}"
  local report_batch="${UI_RESTORE_REPORT_BATCH_SIZE:-3}"

  local figma_url preview_route file_path task_name page_url
  local task_file_paths primary_file
  figma_url=$(extract_task_field "$tasks_file" "$task_num" "figma")
  preview_route=$(extract_task_field "$tasks_file" "$task_num" "预览路由")
  task_file_paths=$(extract_task_file_paths "$tasks_file" "$task_num")
  primary_file=$(printf '%s\n' "$task_file_paths" | head -1)
  file_path=$(printf '%s\n' "$task_file_paths" | paste -sd ',' -)
  task_name=$(awk "/^### Task ${task_num}[：:]/{print; exit}" "$tasks_file" \
    | sed 's/^### Task [0-9]*[：:][[:space:]]*//')

  page_url="${base_url}${preview_route}"

  echo "  [ui-restorer] Task $task_num: $task_name" >&2
  echo "  [ui-restorer] figma=$figma_url route=$preview_route file=$file_path" >&2
  echo "  [ui-restorer] log=$log_file" >&2

  # ── Figma MCP 日志：记录任务开始 ──
  figma_mcp_log "$spec_dir" "task_start" "$(jq -n \
    --arg tn "$task_num" --arg name "$task_name" \
    --arg figma "$figma_url" --arg route "$preview_route" \
    --argjson status "$(antigravity_status_json)" \
    '{task: $tn, name: $name, figma_url: $figma, preview_route: $route, antigravity_status: $status}')"

  # ── P0-0: 先做一次当前 tab 硬校验。若当前 attach 明显漂到别的站点，直接失败，避免浪费 send ──
  if ! antigravity_current_url_matches "$page_url"; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_ANTIGRAVITY_WRONG_TAB"
    local ag_status_json
    ag_status_json=$(antigravity_status_json)
    echo "  [ui-restorer] ❌ Task $task_num FAILED EARLY: $UI_RESTORE_LAST_REASON — 当前 attach 未命中 $page_url" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "0" "0" "[]" "Antigravity current tab does not match preview route before route/setup phase"
    figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" --arg url "$page_url" --argjson status "$ag_status_json" \
      '{reason: $reason, expected_url: $url, antigravity_status: $status, phase: "preflight"}')"
    return 1
  fi

  # ── P0-1: 确保预览路由可访问（生成占位页面 + 注册路由）──
  if [ -z "$primary_file" ]; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_FILE_PATH_PARSE_FAILED"
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — 无法从“文件范围”解析主文件" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "0" "0" "[]" "Cannot parse primary file from 文件范围"
    figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" '{reason: $reason}')"
    return 1
  fi

  if [ -n "$preview_route" ] && [ -n "$primary_file" ]; then
    if ! antigravity_ensure_preview_route "$PROJECT_ROOT" "$feature_name" "$preview_route" "$primary_file" "$base_url"; then
      UI_RESTORE_LAST_REASON="UI_RESTORE_PREVIEW_ROUTE_SETUP_FAILED"
      echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — 无法确保预览路由 $preview_route 可访问" >&2
      _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
        "0" "0" "[]" "Cannot ensure preview route $preview_route is accessible"
      figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" '{reason: $reason}')"
      return 1
    fi
  fi

  # 记录 git baseline（用于后续文件变化检测）
  local git_baseline
  git_baseline=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "HEAD")

  # 导航到预览页面
  local page_url="${base_url}${preview_route}"
  local cdp_target
  cdp_target=$(_run_cdp_timeout "$PROJECT_ROOT" 8 list 2>/dev/null \
    | grep -i "localhost:${base_url##*:}" | head -1 | awk '{print $1}' || echo "")

  if [ -n "$cdp_target" ]; then
    _run_cdp_timeout "$PROJECT_ROOT" 8 nav "$cdp_target" "$page_url" >/dev/null 2>&1 || true
    sleep 3  # 等待页面渲染（HMR + SPA routing）
  else
    echo "  [ui-restorer] ⚠️ 未获取到 CDP target，后续仅做弱校验" >&2
  fi

  # ── P0-3: 导航后立即检测是否为目标 tab + 非 404 页面 ──
  if ! antigravity_current_url_matches "$page_url"; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_ANTIGRAVITY_WRONG_TAB"
    local ag_status_json
    ag_status_json=$(antigravity_status_json)
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — Antigravity 当前 tab 未命中 $page_url" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      0 0 "[]" "Antigravity current tab does not match preview route $page_url"
    figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" --arg url "$page_url" --argjson status "$ag_status_json" \
      '{reason: $reason, expected_url: $url, antigravity_status: $status}')"
    return 1
  fi

  if [ -n "$cdp_target" ]; then
    if ! antigravity_check_page_not_404 "$cdp_target" "$PROJECT_ROOT"; then
      UI_RESTORE_LAST_REASON="UI_RESTORE_PREVIEW_ROUTE_INVALID"
      echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — $page_url 渲染为 404/fallback 页面" >&2
      _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
        0 0 "[]" "Preview route $preview_route rendered as 404/fallback page after scaffold setup"
      figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" --arg url "$page_url" \
        '{reason: $reason, url: $url}')"
      return 1
    fi
  fi

  # 读取分块策略
  local blocks_raw
  blocks_raw=$(_extract_task_body "$tasks_file" "$task_num" \
    | grep "^  - 块" | sed 's/^  - //')
  local block_total
  block_total=$(echo "$blocks_raw" | grep -c "块" || echo 1)

  echo "  [ui-restorer] 检测到 $block_total 个还原分块" >&2

  # 读取设计规格（整块提取）
  local design_spec
  design_spec=$(_extract_task_body "$tasks_file" "$task_num" \
    | awk '/^- 设计规格[：:]/,/^- [^ ]/' \
    | grep -v "^- 还原策略" | grep -v "^- 指令")

  local block_results=()   # 记录每块结果 "block_name:score:screenshot"
  local needs_review=()    # 记录需人工确认的块
  local block_idx=0
  local blocks_passed=0

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
    local block_final_status="failed"
    local dump_ctx dump_html dump_snap
    dump_ctx=$(antigravity_dump_context)
    dump_html=${dump_ctx%%|*}
    dump_snap=${dump_ctx#*|}

    for round in 1 2; do
      local round_start_ts
      round_start_ts=$(date +%s)
      echo "  [ui-restorer] Round $round..." >&2

      # 调用 Antigravity 生成/修复 + 等待回复（强确认闭环）
      local ag_reply=""
      local ag_ok=true
      local ag_reply_file="/tmp/antigravity-reply-${feature_name}-task${task_num}-block${block_idx}-round${round}.txt"
      rm -f "$ag_reply_file" 2>/dev/null || true
      if [ "$round" -eq 1 ]; then
        antigravity_send_and_wait \
          "你只负责 UI 还原，不碰业务逻辑。

页面：$task_name
当前分块：$block_name（第 $block_idx/$block_total 块）
生成文件：$file_path
预览路由：$preview_route
当前页面 DOM dump：$dump_html
当前页面 snapshot：$dump_snap

设计规格（Figma MCP 已提取）：
$design_spec

项目约束：
- 使用 src/components/ui/ 中已有的 design system 组件
- 使用项目 CSS 变量 / Tailwind 配置
- 响应式断点：mobile(375) / tablet(768) / desktop(1440)
- Props 接口定义在组件顶部
- 禁止：API 调用 / 状态管理 / 路由跳转 / 硬编码颜色 / 内联样式

你必须直接修改本地目标文件，并在回复中给出明确代码块；如果未写文件，本轮视为失败。

请生成 $block_name 的代码，写入 $file_path。" "thinking" 120 "$ag_reply_file" || ag_ok=false
      else
        # Round 2：带精确 diff 修复
        antigravity_send_and_wait \
          "根据以下视觉 diff 精确修复 $file_path：

$fixes

当前页面 DOM dump：$dump_html
当前页面 snapshot：$dump_snap

Figma 设计规格参考：
$design_spec

你必须直接修改本地目标文件，并在回复中给出明确代码块；如果未写文件，本轮视为失败。

只修改与 diff 相关的代码，不要重写其他部分。" "$([ "$diff_complexity" = "major" ] && echo thinking || echo fast)" 90 "$ag_reply_file" || ag_ok=false
      fi

      local ag_reply=""
      [ -f "$ag_reply_file" ] && ag_reply=$(cat "$ag_reply_file" 2>/dev/null || true)

      if [ "$ag_ok" = "false" ]; then
        echo "  [ui-restorer] ⚠️ Antigravity send/read failed for block $block_idx round $round (reason=${AG_LAST_REASON:-UNKNOWN})" >&2
        figma_mcp_log "$spec_dir" "antigravity_no_reply" "$(jq -n \
          --arg tn "$task_num" --argjson bi "$block_idx" --argjson rn "$round" \
          --arg reason "${AG_LAST_REASON:-UNKNOWN}" \
          '{task: $tn, block_idx: $bi, round: $rn, reason: $reason}')"

        if [ "${AG_LAST_REASON:-}" = "ANTIGRAVITY_SEND_NO_CONVERSATION_UPDATE" ] && [ "$round" -eq 2 ] && [ "$block_idx" -eq 1 ]; then
          UI_RESTORE_LAST_REASON="UI_RESTORE_ANTIGRAVITY_SEND_NO_CONVERSATION_UPDATE"
          UI_RESTORE_LAST_FAILED_BLOCKS="$block_name"
          echo "  [ui-restorer] ❌ Task $task_num FAILED FAST: $UI_RESTORE_LAST_REASON — send 成功但会话无更新" >&2
          _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
            "$block_total" "0" "[]" "Antigravity send returned success but conversation did not update for first block after 2 rounds"
          figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" --arg block "$block_name" '{reason: $reason, block: $block}')"
          return 1
        fi
      fi

      # P0-2: 验证 AI 回复是否有效（非空且包含代码相关内容）
      local has_code_blocks=false
      if printf '%s' "$ag_reply" | grep -q '\[code_blocks='; then
        has_code_blocks=true
      fi

      if [ -z "$ag_reply" ]; then
        echo "  [ui-restorer] ⚠️ 块 $block_idx Round $round: AI 未返回有效回复 (reason=${AG_LAST_REASON:-UNKNOWN})" >&2
      else
        figma_mcp_log "$spec_dir" "antigravity_reply" "$(jq -n \
          --arg tn "$task_num" --argjson bi "$block_idx" --argjson rn "$round" \
          --arg excerpt "$(printf '%s' "$ag_reply" | head -c 240)" \
          --arg has_code "$has_code_blocks" \
          --arg dump_html "$dump_html" \
          --arg dump_snap "$dump_snap" \
          '{task: $tn, block_idx: $bi, round: $rn, excerpt: $excerpt, has_code_blocks: $has_code, dump_html: $dump_html, dump_snap: $dump_snap}')"
      fi

      # P0-2: 验证目标文件是否被创建/修改
      sleep 3  # 等待热更新
      local files_changed=true
      if ! antigravity_verify_files_changed "$PROJECT_ROOT" "$file_path" "$git_baseline"; then
        files_changed=false
        echo "  [ui-restorer] ⚠️ 块 $block_idx Round $round: 目标文件未变化，Antigravity 可能未实际写入" >&2
        figma_mcp_log "$spec_dir" "files_not_changed" "$(jq -n \
          --arg tn "$task_num" --argjson bi "$block_idx" --argjson rn "$round" --arg fp "$file_path" \
          --arg excerpt "$(printf '%s' "$ag_reply" | head -c 240)" \
          '{task: $tn, block_idx: $bi, round: $rn, file_path: $fp, reply_excerpt: $excerpt}')"
      fi

      # 如果有回复但文件没变，当前 round 直接视为失败，不再进入视觉评分
      if [ "$files_changed" = "false" ]; then
        score=0
        diff_complexity="major"
        fixes="Antigravity 有回复但未修改目标文件，无法继续视觉评分"
        local pass_val="false"
        local round_end_ts
        round_end_ts=$(date +%s)
        local round_duration=$(( round_end_ts - round_start_ts ))
        local round_status="retry"
        if [ "$round" -eq 2 ]; then
          round_status="needs_review"
          needs_review+=("${block_name}:${score}::NEEDS_REVIEW:${fixes}")
          block_results+=("${block_name}:${score}::NEEDS_REVIEW")
          block_final_status="needs_review"
        fi
        _ui_log_block "$log_file" "$task_num" "$block_idx" "$block_name" "$round" \
          "" "$score" "$diff_complexity" "$pass_val" "$fixes" "$round_duration" "$round_status"

        # 如果第一块连续两轮都没有真正写文件，基本可判定整条 Antigravity 写回链路失效，直接 fail fast
        if [ "$round" -eq 2 ] && [ "$block_idx" -eq 1 ]; then
          if [ "${AG_LAST_REASON:-}" = "ANTIGRAVITY_SEND_NO_CONVERSATION_UPDATE" ]; then
            UI_RESTORE_LAST_REASON="UI_RESTORE_ANTIGRAVITY_SEND_NO_CONVERSATION_UPDATE"
            echo "  [ui-restorer] ❌ Task $task_num FAILED FAST: $UI_RESTORE_LAST_REASON — send 成功但会话无更新" >&2
          else
            UI_RESTORE_LAST_REASON="UI_RESTORE_ANTIGRAVITY_NO_WRITE"
            echo "  [ui-restorer] ❌ Task $task_num FAILED FAST: $UI_RESTORE_LAST_REASON — Antigravity 连续两轮未写入目标文件" >&2
          fi
          UI_RESTORE_LAST_FAILED_BLOCKS="$block_name"
          _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
            "$block_total" "0" "[]" "Antigravity returned no effective file changes for first block after 2 rounds; has_code_blocks=${has_code_blocks}; ag_last_reason=${AG_LAST_REASON:-UNKNOWN}"
          figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" --arg block "$block_name" --arg has_code "$has_code_blocks" --arg ag_reason "${AG_LAST_REASON:-UNKNOWN}" '{reason: $reason, block: $block, has_code_blocks: $has_code, antigravity_reason: $ag_reason}')"
          return 1
        fi
        continue
      fi

      # P0-3: 重新检测页面是否仍为 404（文件变了但路由可能没生效）
      if [ -n "$cdp_target" ]; then
        # 刷新页面以获取最新渲染
        _run_cdp_timeout "$PROJECT_ROOT" 8 nav "$cdp_target" "$page_url" >/dev/null 2>&1 || true
        sleep 2
        if ! antigravity_check_page_not_404 "$cdp_target" "$PROJECT_ROOT"; then
          echo "  [ui-restorer] ⚠️ 块 $block_idx Round $round: 页面仍为 404/fallback，评分无意义" >&2
          # 直接标记为失败分数，跳过 codex 评分（省 token）
          score=0
          diff_complexity="major"
          fixes="页面渲染为 404/fallback，无法评分"
          local pass_val="false"
          local round_end_ts
          round_end_ts=$(date +%s)
          local round_duration=$(( round_end_ts - round_start_ts ))
          local round_status="retry"
          [ "$round" -eq 2 ] && round_status="needs_review"
          _ui_log_block "$log_file" "$task_num" "$block_idx" "$block_name" "$round" \
            "" "$score" "$diff_complexity" "$pass_val" "$fixes" "$round_duration" "$round_status"
          if [ "$round" -eq 2 ]; then
            needs_review+=("${block_name}:${score}::NEEDS_REVIEW:${fixes}")
            block_results+=("${block_name}:${score}::NEEDS_REVIEW")
            block_final_status="needs_review"
          fi
          continue
        fi
      fi

      # 截图
      local screenshot="${screenshot_base}-round${round}.png"
      local screenshot_ok=true
      if [ -n "$cdp_target" ]; then
        _run_cdp_timeout "$PROJECT_ROOT" 10 shot "$cdp_target" "$screenshot" >/dev/null 2>&1 || screenshot_ok=false
      else
        screenshot_ok=false
      fi
      [ "$screenshot_ok" = "false" ] && echo "  [ui-restorer] ⚠️ Screenshot failed for block $block_idx round $round" >&2

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

      local round_end_ts
      round_end_ts=$(date +%s)
      local round_duration=$(( round_end_ts - round_start_ts ))

      if [ "$pass_val" = "true" ] || [ "$score" -ge "$score_threshold" ]; then
        block_results+=("${block_name}:${score}:${screenshot}")
        block_final_status="pass"
        blocks_passed=$((blocks_passed + 1))
        echo "  [ui-restorer] 块 $block_idx PASS (${score}/10)" >&2

        # Log successful round
        _ui_log_block "$log_file" "$task_num" "$block_idx" "$block_name" "$round" \
          "$screenshot" "$score" "$diff_complexity" "$pass_val" "$fixes" "$round_duration" "pass"
        break
      fi

      # Log non-passing round
      local round_status="retry"
      if [ "$round" -eq 2 ]; then
        round_status="needs_review"
        # 2 轮后仍不达标，加入人工确认队列
        needs_review+=("${block_name}:${score}:${screenshot}:${fixes}")
        block_results+=("${block_name}:${score}:${screenshot}:NEEDS_REVIEW")
        block_final_status="needs_review"
        echo "  [ui-restorer] 块 $block_idx 2轮后仍不达标(${score}/10)，等待人工确认" >&2
      fi

      _ui_log_block "$log_file" "$task_num" "$block_idx" "$block_name" "$round" \
        "$screenshot" "$score" "$diff_complexity" "$pass_val" "$fixes" "$round_duration" "$round_status"
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

  # ── 构建失败 block 列表（用于诊断）──
  local failed_blocks_json="[]"
  local failed_block_names=""
  for r in "${block_results[@]}"; do
    if echo "$r" | grep -q "NEEDS_REVIEW"; then
      local fb_name fb_score fb_shot
      fb_name=$(echo "$r" | cut -d: -f1)
      fb_score=$(echo "$r" | cut -d: -f2)
      fb_shot=$(echo "$r" | cut -d: -f3)
      failed_blocks_json=$(echo "$failed_blocks_json" | jq --arg n "$fb_name" --arg s "$fb_score" --arg ss "$fb_shot" \
        '. + [{name: $n, score: ($s | tonumber), screenshot: $ss}]')
      failed_block_names="${failed_block_names:+$failed_block_names, }$fb_name"
    fi
  done

  # ── Failure path: no block results at all ──
  if [ ${#block_results[@]} -eq 0 ]; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_NO_BLOCK_RESULTS"
    UI_RESTORE_LAST_FAILED_BLOCKS=""
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — block loop produced zero results" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "$block_total" "0" "[]" "Block loop produced zero results. Check blocks_raw parsing and tasks.md format."
    figma_mcp_log "$spec_dir" "task_fail" "$(jq -n --arg reason "$UI_RESTORE_LAST_REASON" '{reason: $reason}')"
    return 1
  fi

  # ── Failure path: some blocks did not pass ──
  if [ "$blocks_passed" -lt "$block_total" ]; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_BLOCK_SCORE_FAILED"
    UI_RESTORE_LAST_FAILED_BLOCKS="$failed_block_names"
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — blocks not passed: $failed_block_names" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "$block_total" "$blocks_passed" "$failed_blocks_json" \
      "Blocks failed after 2 rounds: $failed_block_names"
    figma_mcp_log "$spec_dir" "task_fail" "$(jq -n \
      --arg reason "$UI_RESTORE_LAST_REASON" --arg blocks "$failed_block_names" \
      '{reason: $reason, failed_blocks: $blocks}')"
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
    --argjson passed "$blocks_passed" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name, file_path:$fp, files:$files, blocks_total:$blocks, blocks_passed:$passed, timestamp:$ts}')

  local tmp_artifact
  tmp_artifact=$(mktemp)
  if jq --arg tn "$task_num" --argjson entry "$task_entry" \
    '.tasks[$tn] = $entry' "$artifact_file" > "$tmp_artifact" 2>/dev/null; then
    mv "$tmp_artifact" "$artifact_file"
  else
    rm -f "$tmp_artifact"
    # Artifact write failed
    UI_RESTORE_LAST_REASON="UI_RESTORE_ARTIFACT_RECORD_FAILED"
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — jq write to $artifact_file failed" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "$block_total" "$blocks_passed" "[]" "All blocks passed but artifact JSON write failed: $artifact_file"
    return 1
  fi

  local ui_file_count=0
  [ -n "$task_ui_files" ] && ui_file_count=$(printf '%s\n' "$task_ui_files" | wc -l | tr -d ' ')

  if [ "$ui_file_count" -eq 0 ]; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_ARTIFACT_RECORD_FAILED"
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — blocks passed but 0 artifact files found" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "$block_total" "$blocks_passed" "[]" "All blocks passed but no UI files detected in $file_path or git diff"
    return 1
  fi

  echo "  [ui-restorer] Task $task_num 产物已记录: $ui_file_count 个文件" >&2

  # ── 标记 task done（所有块已通过）──
  # 用 awk 状态机替代 sed range（避免起始行即终止行的 bug）
  awk -v tn="$task_num" '
    BEGIN { found=0 }
    /^### Task / {
      if ($0 ~ "^### Task " tn "[：:]") { found=1 }
      else { found=0 }
    }
    found && /^- 状态[：:]/ { sub(/^- 状态[：:].*/, "- 状态：done"); print; next }
    { print }
  ' "$tasks_file" > "${tasks_file}.tmp" 2>/dev/null && mv "${tasks_file}.tmp" "$tasks_file" || true

  # 验证 done 标记是否生效
  if ! _extract_task_body "$tasks_file" "$task_num" \
       | grep -q "^- 状态：done"; then
    UI_RESTORE_LAST_REASON="UI_RESTORE_TASK_STATUS_UPDATE_FAILED"
    echo "  [ui-restorer] ❌ Task $task_num FAILED: $UI_RESTORE_LAST_REASON — sed did not update tasks.md" >&2
    _ui_log_task_summary "$log_file" "$task_num" "$task_name" "$UI_RESTORE_LAST_REASON" \
      "$block_total" "$blocks_passed" "[]" \
      "All blocks passed, $ui_file_count artifacts recorded, but tasks.md status update failed"
    return 1
  fi

  echo "  [ui-restorer] Task $task_num 已标记为 done" >&2

  # Log success
  _ui_log_task_summary "$log_file" "$task_num" "$task_name" "SUCCESS" \
    "$block_total" "$blocks_passed" "[]" "$ui_file_count artifact files recorded"

  figma_mcp_log "$spec_dir" "task_success" "$(jq -n \
    --arg tn "$task_num" --arg name "$task_name" \
    --argjson files "$files_json" --argjson bp "$blocks_passed" \
    '{task: $tn, name: $name, files: $files, blocks_passed: $bp}')"

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
