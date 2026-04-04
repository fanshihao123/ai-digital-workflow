#!/bin/bash
# utils.sh — General utility functions
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 模型选择（复用外部脚本）
select_model() {
  local complexity="${1:-low}"
  source "$SCRIPT_DIR/../select-model.sh" "$complexity" >&2
  echo "$CLAUDE_MODEL"
}

# 加载公司 skills
load_company_skills() {
  bash "$SCRIPT_DIR/../load-company-skills.sh" 2>/dev/null || true
}

# 飞书通知（后台 fire-and-forget + 超时保护，避免通知链卡死主流程）
notify() {
  local message="$1"
  local feature="${2:-$(detect_feature_name)}"
  if type feishu_notify >/dev/null 2>&1; then
    (
      perl -e 'alarm shift @ARGV; exec @ARGV' 5 bash -lc 'feishu_notify "$1" "$2"' _ "$message" "$feature" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
  fi
  return 0
}

count_pattern_in_file() {
  local pattern="$1"
  local file="$2"
  local count
  count=$(grep -c "$pattern" "$file" 2>/dev/null || true)
  count="${count//$'\n'/}"
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  echo "$count"
}

extract_report_field() {
  local file="$1"
  local field="$2"
  local value=""

  if [ -f "$file" ]; then
    value=$(sed -n "s/^$field:[[:space:]]*//p" "$file" 2>/dev/null | tail -1 | tr -d '\r')
  fi

  echo "$value"
}

has_package_script() {
  local script_name="$1"
  [ -f "$PROJECT_ROOT/package.json" ] || return 1
  grep -q "\"$script_name\"[[:space:]]*:" "$PROJECT_ROOT/package.json" 2>/dev/null
}

first_existing_file() {
  local candidate
  for candidate in "$@"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

has_reviewed_spec() {
  local feature_name="$1"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"

  [ -f "$spec_dir/requirements.md" ] || return 1
  [ -f "$spec_dir/design.md" ] || return 1
  [ -f "$spec_dir/tasks.md" ] || return 1

  grep -q "状态：reviewed" "$spec_dir/requirements.md" 2>/dev/null || return 1
  grep -q "状态：reviewed" "$spec_dir/design.md" 2>/dev/null || return 1
  grep -q "状态：done\|状态：reviewed" "$spec_dir/tasks.md" 2>/dev/null || return 1
}

# 检测活跃的 feature 名称
# 规则：不要只看 tasks.md（旧 feature 容易误判），而是综合当前 specs 子目录中最近变更的
# requirements/design/tasks/awaiting-clarification 文件来判断当前活跃 feature。
detect_feature_name() {
  local latest_file latest_feature
  latest_file=$(find "$PROJECT_ROOT/specs" -mindepth 2 -maxdepth 2 -type f \
    \( -name 'requirements.md' -o -name 'design.md' -o -name 'tasks.md' -o -name 'awaiting-clarification.json' -o -name 'awaiting-spec-review.json' \) \
    ! -path '*/archive/*' \
    -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)

  if [ -n "$latest_file" ]; then
    latest_feature=$(echo "$latest_file" | sed "s|$PROJECT_ROOT/specs/||" | cut -d/ -f1)
    echo "$latest_feature"
    return
  fi

  # fallback：仅当目录下确实存在 requirements.md 时才返回
  # 避免空目录或只有 state.json 的旧目录导致误判
  local fallback_dir
  for fallback_dir in $(find "$PROJECT_ROOT/specs" -mindepth 1 -maxdepth 1 -type d \
    ! -name 'archive' -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null); do
    if [ -s "$fallback_dir/requirements.md" ]; then
      basename "$fallback_dir"
      return
    fi
  done
}

# 从 design.md 提取复杂度（macOS 兼容）
get_complexity() {
  local feature_name="$1"
  local design_file="$PROJECT_ROOT/specs/$feature_name/design.md"
  if [ -f "$design_file" ]; then
    local val
    val=$(sed -n 's/.*复杂度：[[:space:]]*\([a-zA-Z]*\).*/\1/p' "$design_file" 2>/dev/null | head -1)
    [ -z "$val" ] && val=$(sed -n 's/.*complexity:[[:space:]]*\([a-zA-Z]*\).*/\1/p' "$design_file" 2>/dev/null | head -1)
    echo "${val:-low}"
  else
    echo "low"
  fi
}

# 从 requirements.md 提取 Jira issue key（macOS 兼容）
get_jira_key() {
  local feature_name="$1"
  local req_file="$PROJECT_ROOT/specs/$feature_name/requirements.md"
  if [ -f "$req_file" ]; then
    local val
    val=$(sed -n 's/.*Jira[：:][[:space:]]*\([A-Z][A-Z]*-[0-9][0-9]*\).*/\1/p' "$req_file" 2>/dev/null | head -1)
    echo "$val"
  else
    echo ""
  fi
}
