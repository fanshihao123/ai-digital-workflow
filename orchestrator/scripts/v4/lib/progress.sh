#!/bin/bash
# progress.sh — 飞书实时进度推送引擎
# Sourced by v4/handler.sh; depends on common.sh (feishu_notify, log)
#
# 在流水线每个 Step 的开始/结束时推送结构化进度到飞书，
# 同时写入 specs/{feature}/progress.md 供 /status 离线查看。
#
# 用法:
#   progress_init         feature_name total_steps input
#   progress_step_start   feature_name step_num step_name
#   progress_step_done    feature_name step_num step_name [detail]
#   progress_step_skip    feature_name step_num step_name reason
#   progress_step_fail    feature_name step_num step_name reason
#   progress_substep      feature_name step_num substep_msg status
#   progress_finish       feature_name
#   progress_render       feature_name   (输出当前快照到 stdout)

# ============================================================
# 内部状态
# ============================================================

_progress_file() {
  echo "$PROJECT_ROOT/specs/$1/progress.md"
}

_progress_json() {
  echo "$PROJECT_ROOT/specs/$1/progress.json"
}

# 初始化 progress.json 内部状态
_progress_json_init() {
  local feature="$1"
  local total_steps="$2"
  local input="$3"
  local file
  file=$(_progress_json "$feature")
  mkdir -p "$(dirname "$file")"

  jq -n \
    --arg f "$feature" \
    --arg input "$input" \
    --argjson total "$total_steps" \
    --arg start "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      feature: $f,
      input: $input,
      total_steps: $total,
      started_at: $start,
      ended_at: "",
      final_status: "running",
      steps: {}
    }' > "$file"
}

# 更新 progress.json 某个 step 的状态
_progress_json_update_step() {
  local feature="$1"
  local step_num="$2"
  local step_name="$3"
  local status="$4"
  local detail="${5:-}"
  local file
  file=$(_progress_json "$feature")
  [ -f "$file" ] || return 0

  local tmp; tmp=$(mktemp)
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq \
    --arg sn "$step_num" \
    --arg name "$step_name" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg ts "$ts" \
    '.steps[$sn] = {
      name: $name,
      status: $status,
      detail: $detail,
      updated_at: $ts
    }' "$file" > "$tmp" && mv "$tmp" "$file"
}

# 追加子步骤信息到 progress.json
_progress_json_add_substep() {
  local feature="$1"
  local step_num="$2"
  local msg="$3"
  local status="$4"
  local file
  file=$(_progress_json "$feature")
  [ -f "$file" ] || return 0

  local tmp; tmp=$(mktemp)
  jq \
    --arg sn "$step_num" \
    --arg msg "$msg" \
    --arg status "$status" \
    'if .steps[$sn].substeps then
       .steps[$sn].substeps += [{"msg": $msg, "status": $status}]
     else
       .steps[$sn].substeps = [{"msg": $msg, "status": $status}]
     end' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ============================================================
# Step 名称映射
# ============================================================
_step_display_name() {
  local step_num="$1"
  local custom_name="${2:-}"
  [ -n "$custom_name" ] && echo "$custom_name" && return

  case "$step_num" in
    0) echo "环境准备" ;;
    1) echo "需求分析" ;;
    2) echo "开发执行" ;;
    3) echo "代码审查" ;;
    4) echo "测试" ;;
    5) echo "文档同步" ;;
    6) echo "部署" ;;
    7) echo "完成通知" ;;
    *) echo "Step $step_num" ;;
  esac
}

_step_icon() {
  local step_num="$1"
  case "$step_num" in
    0) echo "🔧" ;;
    1) echo "📝" ;;
    2) echo "💻" ;;
    3) echo "🔍" ;;
    4) echo "🧪" ;;
    5) echo "📚" ;;
    6) echo "🚀" ;;
    7) echo "📢" ;;
    *) echo "▶️" ;;
  esac
}

_status_icon() {
  local status="$1"
  case "$status" in
    running)   echo "⏳" ;;
    done)      echo "✅" ;;
    skip)      echo "⏭️" ;;
    fail)      echo "❌" ;;
    pending)   echo "⬜" ;;
    *)         echo "❓" ;;
  esac
}

# ============================================================
# 计算耗时（秒 → 可读格式）
# ============================================================
_format_duration() {
  local seconds="$1"
  if [ "$seconds" -lt 60 ]; then
    echo "${seconds}s"
  elif [ "$seconds" -lt 3600 ]; then
    echo "$((seconds / 60))m $((seconds % 60))s"
  else
    echo "$((seconds / 3600))h $((seconds / 60 % 60))m"
  fi
}

# ============================================================
# 公开 API
# ============================================================

# 初始化进度（流水线启动时调用）
progress_init() {
  local feature="$1"
  local total_steps="${2:-7}"
  local input="${3:-}"
  local file
  file=$(_progress_file "$feature")
  mkdir -p "$(dirname "$file")"

  _progress_json_init "$feature" "$total_steps" "$input"

  # 写 progress.md 初始内容
  cat > "$file" << EOF
# Pipeline Progress: $feature

> 启动时间: $(date '+%Y-%m-%d %H:%M:%S')
> 需求: $input
> 状态: **running**

| # | 阶段 | 状态 | 耗时 | 备注 |
|---|------|------|------|------|
| 0 | 🔧 环境准备 | ⬜ pending | - | |
| 1 | 📝 需求分析 | ⬜ pending | - | |
| 2 | 💻 开发执行 | ⬜ pending | - | |
| 3 | 🔍 代码审查 | ⬜ pending | - | |
| 4 | 🧪 测试 | ⬜ pending | - | |
| 5 | 📚 文档同步 | ⬜ pending | - | |
| 6 | 🚀 部署 | ⬜ pending | - | |
| 7 | 📢 完成通知 | ⬜ pending | - | |
EOF

  # 飞书推送启动通知
  feishu_notify "**$feature** 流水线已启动\n需求: $input\n预计 $total_steps 个阶段" "$feature"
}

# Step 开始
progress_step_start() {
  local feature="$1"
  local step_num="$2"
  local step_name="${3:-}"
  step_name=$(_step_display_name "$step_num" "$step_name")
  local icon
  icon=$(_step_icon "$step_num")

  _progress_json_update_step "$feature" "$step_num" "$step_name" "running"

  # 更新 progress.md 对应行
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local pattern="| $step_num |"
    local replacement="| $step_num | $icon $step_name | ⏳ running | ... | |"
    # 用 awk 精确替换匹配行
    awk -v pat="$pattern" -v rep="$replacement" \
      'index($0, pat) == 1 { print rep; next } { print }' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # 记录开始时间（写到临时文件供 step_done 计算耗时）
  echo "$(date +%s)" > "$PROJECT_ROOT/specs/$feature/.step${step_num}_start"

  # 飞书推送
  local total_steps
  total_steps=$(jq -r '.total_steps' "$(_progress_json "$feature")" 2>/dev/null || echo 7)
  feishu_notify "⏳ **[$((step_num + 1))/$total_steps] $step_name** 开始..." "$feature"
}

# Step 完成
progress_step_done() {
  local feature="$1"
  local step_num="$2"
  local step_name="${3:-}"
  local detail="${4:-}"
  step_name=$(_step_display_name "$step_num" "$step_name")
  local icon
  icon=$(_step_icon "$step_num")

  # 计算耗时
  local duration_str="-"
  local start_file="$PROJECT_ROOT/specs/$feature/.step${step_num}_start"
  if [ -f "$start_file" ]; then
    local start_ts end_ts elapsed
    start_ts=$(cat "$start_file")
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    duration_str=$(_format_duration "$elapsed")
    rm -f "$start_file"
  fi

  _progress_json_update_step "$feature" "$step_num" "$step_name" "done" "$detail"

  # 更新 progress.md
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local pattern="| $step_num |"
    local detail_short
    detail_short=$(echo "$detail" | head -1 | cut -c1-40)
    local replacement="| $step_num | $icon $step_name | ✅ done | $duration_str | $detail_short |"
    awk -v pat="$pattern" -v rep="$replacement" \
      'index($0, pat) == 1 { print rep; next } { print }' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # 飞书推送
  local total_steps
  total_steps=$(jq -r '.total_steps' "$(_progress_json "$feature")" 2>/dev/null || echo 7)
  local msg="✅ **[$((step_num + 1))/$total_steps] $step_name** 完成 ($duration_str)"
  [ -n "$detail" ] && msg="$msg\n$detail"
  feishu_notify "$msg" "$feature"
}

# Step 跳过
progress_step_skip() {
  local feature="$1"
  local step_num="$2"
  local step_name="${3:-}"
  local reason="${4:-}"
  step_name=$(_step_display_name "$step_num" "$step_name")
  local icon
  icon=$(_step_icon "$step_num")

  _progress_json_update_step "$feature" "$step_num" "$step_name" "skip" "$reason"

  # 更新 progress.md
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local pattern="| $step_num |"
    local replacement="| $step_num | $icon $step_name | ⏭️ skip | - | $reason |"
    awk -v pat="$pattern" -v rep="$replacement" \
      'index($0, pat) == 1 { print rep; next } { print }' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # 飞书推送（跳过的不推送，减少噪音）
}

# Step 失败
progress_step_fail() {
  local feature="$1"
  local step_num="$2"
  local step_name="${3:-}"
  local reason="${4:-}"
  step_name=$(_step_display_name "$step_num" "$step_name")
  local icon
  icon=$(_step_icon "$step_num")

  # 计算耗时
  local duration_str="-"
  local start_file="$PROJECT_ROOT/specs/$feature/.step${step_num}_start"
  if [ -f "$start_file" ]; then
    local start_ts end_ts elapsed
    start_ts=$(cat "$start_file")
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))
    duration_str=$(_format_duration "$elapsed")
    rm -f "$start_file"
  fi

  _progress_json_update_step "$feature" "$step_num" "$step_name" "fail" "$reason"

  # 更新 progress.md
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local pattern="| $step_num |"
    local reason_short
    reason_short=$(echo "$reason" | head -1 | cut -c1-40)
    local replacement="| $step_num | $icon $step_name | ❌ fail | $duration_str | $reason_short |"
    awk -v pat="$pattern" -v rep="$replacement" \
      'index($0, pat) == 1 { print rep; next } { print }' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # 飞书推送
  local total_steps
  total_steps=$(jq -r '.total_steps' "$(_progress_json "$feature")" 2>/dev/null || echo 7)
  feishu_notify "❌ **[$((step_num + 1))/$total_steps] $step_name** 失败 ($duration_str)\n$reason" "$feature"
}

# 子步骤状态推送（不单独发飞书，只记录到 progress.md）
progress_substep() {
  local feature="$1"
  local step_num="$2"
  local msg="$3"
  local status="${4:-done}"  # done | fail | info
  local status_icon
  status_icon=$(_status_icon "$status")

  _progress_json_add_substep "$feature" "$step_num" "$msg" "$status"

  # 追加到 progress.md（在对应 step 行后面追加子步骤）
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local step_name
    step_name=$(_step_display_name "$step_num")
    local icon
    icon=$(_step_icon "$step_num")
    local pattern="| $step_num | $icon $step_name"
    # 找到 step 行的下一行，在其前面插入子步骤
    awk -v pat="$pattern" -v sub="| | \u2514\u2500 $msg | $status_icon $status | | |" \
      'printed && /^\| [0-9]/ { print sub; printed=0 }
       { print }
       index($0, pat) { printed=1 }
       END { if (printed) print sub }' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

# 流水线完成（汇总推送）
progress_finish() {
  local feature="$1"
  local final_status="${2:-done}"  # done | fail | paused

  # 更新 progress.json
  local pjson
  pjson=$(_progress_json "$feature")
  if [ -f "$pjson" ]; then
    local tmp; tmp=$(mktemp)
    jq \
      --arg status "$final_status" \
      --arg ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.final_status = $status | .ended_at = $ended' \
      "$pjson" > "$tmp" && mv "$tmp" "$pjson"
  fi

  # 更新 progress.md 状态行
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    local status_display
    case "$final_status" in
      done)   status_display="**done** ✅" ;;
      fail)   status_display="**failed** ❌" ;;
      paused) status_display="**paused** ⏸️" ;;
      *)      status_display="**$final_status**" ;;
    esac
    # 替换状态行
    if grep -q '> 状态:' "$file" 2>/dev/null; then
      awk -v rep="> 状态: $status_display" \
        '/^> 状态:/ { print rep; next } { print }' \
        "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
    # 追加结束时间
    echo "" >> "$file"
    echo "> 结束时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$file"

    # 计算总耗时
    if [ -f "$pjson" ]; then
      local started ended
      started=$(jq -r '.started_at' "$pjson" 2>/dev/null)
      ended=$(jq -r '.ended_at' "$pjson" 2>/dev/null)
      if [ -n "$started" ] && [ -n "$ended" ]; then
        local start_epoch end_epoch total_seconds
        start_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || date -d "$started" +%s 2>/dev/null || echo 0)
        end_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ended" +%s 2>/dev/null || date -d "$ended" +%s 2>/dev/null || echo 0)
        if [ "$start_epoch" -gt 0 ] && [ "$end_epoch" -gt 0 ]; then
          total_seconds=$((end_epoch - start_epoch))
          echo "> 总耗时: $(_format_duration $total_seconds)" >> "$file"
        fi
      fi
    fi
  fi

  # 汇总飞书推送（仅 done 和 fail 时发送）
  if [ "$final_status" = "done" ]; then
    # 收集各 step 结果
    local summary=""
    local step_num step_data
    for step_num in 0 1 2 3 4 5 6 7; do
      step_data=$(jq -r ".steps[\"$step_num\"] // empty" "$pjson" 2>/dev/null)
      [ -z "$step_data" ] && continue
      local sname sstatus sdetail
      sname=$(echo "$step_data" | jq -r '.name')
      sstatus=$(echo "$step_data" | jq -r '.status')
      sdetail=$(echo "$step_data" | jq -r '.detail // ""' | head -1 | cut -c1-30)
      local sicon
      sicon=$(_status_icon "$sstatus")
      summary="$summary\n$sicon $sname"
      [ -n "$sdetail" ] && summary="$summary — $sdetail"
    done

    # 收集测试和审查摘要
    local coverage="N/A" review_status="N/A"
    local test_report="$PROJECT_ROOT/specs/$feature/test-report.md"
    if [ -f "$test_report" ]; then
      coverage=$(sed -n 's/.*Statements[[:space:]]*|[[:space:]]*\([0-9][0-9]*%\).*/\1/p' "$test_report" 2>/dev/null | head -1)
      [ -z "$coverage" ] && coverage="N/A"
    fi
    local review_report="$PROJECT_ROOT/specs/$feature/review-report.md"
    if [ -f "$review_report" ]; then
      review_status=$(grep -o 'PASS\|FAIL' "$review_report" 2>/dev/null | tail -1)
      [ -z "$review_status" ] && review_status="N/A"
    fi

    feishu_notify "🎉 **$feature** 流水线完成！\n$summary\n\n审查: $review_status | 覆盖率: $coverage" "$feature"
  fi
}

# 渲染当前进度快照（供 /status 使用）
progress_render() {
  local feature="$1"
  local file
  file=$(_progress_file "$feature")
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo "暂无进度信息: $feature"
  fi
}

# 渲染所有活跃 feature 的进度（供 /status 使用）
progress_render_all() {
  local has_progress=false
  for pjson in "$PROJECT_ROOT"/specs/*/progress.json; do
    [ -f "$pjson" ] || continue
    has_progress=true
    local feature
    feature=$(jq -r '.feature' "$pjson" 2>/dev/null)
    local status
    status=$(jq -r '.final_status' "$pjson" 2>/dev/null)
    local started
    started=$(jq -r '.started_at' "$pjson" 2>/dev/null)

    echo "--- $feature ($status) started: $started ---"
    progress_render "$feature"
    echo ""
  done
  if [ "$has_progress" = "false" ]; then
    echo "暂无活跃流水线"
  fi
}
