#!/bin/bash
# common.sh — 公共函数库
# 用法: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ============================================================
# 输入验证
# ============================================================

# feature name 验证（防止路径遍历）
validate_feature_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "❌ feature name 不能为空" >&2
    return 1
  fi
  # 禁止 ..、/、空白符、控制字符
  if [[ "$name" == *".."* ]] || [[ "$name" == *"/"* ]] || [[ "$name" =~ [[:cntrl:]] ]] || [[ "$name" =~ [[:space:]] ]]; then
    echo "❌ 非法 feature name: $name（禁止包含 ..、/、空白和控制字符）" >&2
    return 1
  fi
  # 只允许字母、数字、连字符、下划线、点
  if ! [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "❌ 非法 feature name: $name（仅允许字母、数字、连字符、下划线、点）" >&2
    return 1
  fi
  return 0
}

# git 分支名验证
validate_branch_name() {
  local branch="$1"
  if [ -z "$branch" ]; then
    echo "❌ branch name 不能为空" >&2
    return 1
  fi
  # git 分支名规则：允许字母、数字、/、-、_、.，禁止 ..、空格、~、^、:、\
  if [[ "$branch" == *".."* ]] || [[ "$branch" =~ [[:space:]] ]] || [[ "$branch" =~ [\~\^\:\\] ]]; then
    echo "❌ 非法分支名: $branch" >&2
    return 1
  fi
  if ! [[ "$branch" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
    echo "❌ 非法分支名: $branch" >&2
    return 1
  fi
  return 0
}

# URL 格式验证
validate_url() {
  local url="$1"
  if ! [[ "$url" =~ ^https?://.+ ]]; then
    echo "❌ 非法 URL: $url" >&2
    return 1
  fi
  return 0
}

# 安全的数值检查（防止 awk/bash 对非数字输入出错）
is_numeric() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# ============================================================
# 项目根目录
# ============================================================
get_project_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# ============================================================
# 加载环境变量
# ============================================================
load_env() {
  local root="${1:-$(get_project_root)}"
  if [ -f "$root/.env" ]; then
    set -a
    source "$root/.env"
    set +a
  fi
}

# ============================================================
# 检查必要环境变量（缺失则退出或返回失败）
# 用法: require_vars VAR1 VAR2 ...
# ============================================================
require_vars() {
  local missing=()
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing+=("$var")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "❌ 缺少环境变量: ${missing[*]}" >&2
    return 1
  fi
}

# ============================================================
# 获取默认分支名（不硬编码 main）
# ============================================================
get_default_branch() {
  local root="${1:-$(get_project_root)}"
  local branch
  # 优先从 remote HEAD 获取
  branch=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  if [ -z "$branch" ]; then
    # fallback: 常见分支名检测
    for candidate in main master develop; do
      if git -C "$root" show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
        branch="$candidate"
        break
      fi
    done
  fi
  echo "${branch:-main}"
}

# ============================================================
# JSON 安全转义（用于构建 curl JSON body）
# 用法: json_escape "string with \"quotes\" and newlines"
# ============================================================
json_escape() {
  local input="$1"
  # 使用 jq 进行安全转义（去掉外层引号）
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -Rs . | sed 's/^"//;s/"$//'
  else
    # fallback: 手动转义关键字符
    printf '%s' "$input" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' '
  fi
}

# ============================================================
# 统一日志
# 用法: log "MESSAGE" [log_file]
# ============================================================
log() {
  local message="$1"
  local log_file="${2:-}"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  echo "[$timestamp] $message"
  if [ -n "$log_file" ]; then
    echo "[$timestamp] $message" >> "$log_file"
  fi
}

# ============================================================
# 统一飞书通知（安全 JSON）
# 用法: feishu_notify "消息内容" [feature_name]
# ============================================================
feishu_notify() {
  local message="$1"
  local feature="${2:-unknown}"

  if [ -z "${FEISHU_WEBHOOK_URL:-}" ]; then
    return 0
  fi

  # 根据内容选择颜色
  local template="blue"
  if echo "$message" | grep -qi "error\|fail\|blocked\|❌"; then
    template="red"
  elif echo "$message" | grep -qi "complete\|pass\|success\|✅"; then
    template="green"
  elif echo "$message" | grep -qi "warning\|retry\|⚠️"; then
    template="orange"
  fi

  # 用 jq 安全构建 JSON
  local payload
  payload=$(jq -n \
    --arg title "🤖 AI Workforce: $feature" \
    --arg template "$template" \
    --arg content "$message" \
    --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S') | Agent: Claude Code" \
    '{
      msg_type: "interactive",
      card: {
        header: {
          title: {tag: "plain_text", content: $title},
          template: $template
        },
        elements: [
          {tag: "markdown", content: $content},
          {tag: "note", elements: [{tag: "plain_text", content: $timestamp}]}
        ]
      }
    }')

  curl -s -X POST "$FEISHU_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    --max-time 10 --connect-timeout 5 \
    -d "$payload" > /dev/null 2>&1 || true
}

# ============================================================
# Pipeline 状态持久化
# 用法:
#   pipeline_state_set <feature> <step> <status>   # 记录
#   pipeline_state_get <feature> <step>             # 查询
#   pipeline_state_check <feature> <step>           # 检查是否已完成（返回 0=已完成）
# ============================================================
PIPELINE_STATE_DIR=""

_pipeline_state_file() {
  local feature="$1"
  local root
  root=$(get_project_root)
  echo "$root/specs/$feature/.pipeline-state"
}

pipeline_state_set() {
  local feature="$1" step="$2" status="$3"
  local state_file
  state_file=$(_pipeline_state_file "$feature")
  mkdir -p "$(dirname "$state_file")"

  # 更新或追加（使用 awk 替代 sed，避免分隔符注入）
  if grep -q "^${step}=" "$state_file" 2>/dev/null; then
    awk -v key="$step" -v val="$status" 'BEGIN{FS=OFS="="} $1==key{$2=val} 1' \
      "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
  else
    echo "${step}=${status}" >> "$state_file"
  fi
}

pipeline_state_get() {
  local feature="$1" step="$2"
  local state_file
  state_file=$(_pipeline_state_file "$feature")
  if [ -f "$state_file" ]; then
    # 使用 grep + cut 替代 sed，避免 step 中特殊字符被解释为正则
    grep "^${step}=" "$state_file" 2>/dev/null | tail -1 | cut -d'=' -f2-
  fi
}

pipeline_state_check() {
  local feature="$1" step="$2"
  local status
  status=$(pipeline_state_get "$feature" "$step")
  [ "$status" = "done" ]
}

# ============================================================
# HTTP 请求重试（指数退避）
# 用法: retry_curl 3 curl -s -X POST ...
# ============================================================
retry_curl() {
  local max_retries="$1"
  shift
  local attempt=0 wait_time=1
  while [ $attempt -lt "$max_retries" ]; do
    if "$@"; then
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt "$max_retries" ]; then
      echo "  ⚠️ 请求失败，${wait_time}s 后重试 ($attempt/$max_retries)..." >&2
      sleep $wait_time
      wait_time=$((wait_time * 2))
    fi
  done
  echo "  ❌ 请求在 $max_retries 次重试后仍失败" >&2
  return 1
}

# ============================================================
# 配置验证
# 用法: validate_config
# ============================================================
validate_config() {
  local errors=0
  # 验证 URL 格式
  if [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
    validate_url "$FEISHU_WEBHOOK_URL" || errors=$((errors + 1))
  fi
  if [ -n "${JIRA_BASE_URL:-}" ]; then
    validate_url "$JIRA_BASE_URL" || errors=$((errors + 1))
  fi
  if [ -n "${DEPLOY_HEALTH_URL:-}" ]; then
    validate_url "$DEPLOY_HEALTH_URL" || errors=$((errors + 1))
  fi
  return $errors
}
