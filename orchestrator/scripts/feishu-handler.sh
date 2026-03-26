#!/bin/bash
# Feishu → Claude Code Webhook Handler
# 接收飞书消息并触发工作流编排器
#
# v3 路径:
#   编排器: .claude/orchestrator/SKILL.md
#   核心 skill: .claude/skills/{spec-writer,code-reviewer,test-runner,doc-syncer}/SKILL.md
#   扩展: .claude/extensions/{worktree-parallel,ui-restorer,human-gate,deploy-executor,jira-sync}/SKILL.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# 加载公共函数库
source "$SCRIPT_DIR/lib/common.sh"

load_env "$PROJECT_ROOT"

# 配置验证
validate_config || echo "⚠️ 部分配置无效，请检查 .env" >&2

# 错误处理和清理
_NOTIFIED_ERROR=false

cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ "$_NOTIFIED_ERROR" = "false" ]; then
    _NOTIFIED_ERROR=true
    local feature
    feature=$(detect_feature_name)
    if [ -n "$feature" ]; then
      pipeline_state_set "$feature" "last_run" "failed"
      feishu_notify "❌ 流水线异常退出: $feature (exit code: $exit_code)" "$feature"
      log "PIPELINE_FAILED: $feature (exit code: $exit_code)" "$PROJECT_ROOT/specs/.workflow-log"
    fi
  fi
}

trap cleanup EXIT ERR

MESSAGE="${1:-$(cat -)}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

mkdir -p "$PROJECT_ROOT/specs"
echo "[$TIMESTAMP] Received: $MESSAGE" >> "$PROJECT_ROOT/specs/.workflow-log"

MSG_TYPE=$(echo "$MESSAGE" | jq -r '.msg_type // "text"' 2>/dev/null || echo "text")
MSG_TEXT=$(echo "$MESSAGE" | jq -r '.content.text // .content // empty' 2>/dev/null || echo "$MESSAGE")

# ============================================================
# 辅助函数
# ============================================================

# 模型选择（复用外部脚本）
select_model() {
  local complexity="${1:-low}"
  source "$SCRIPT_DIR/select-model.sh" "$complexity" >&2
  echo "$CLAUDE_MODEL"
}

# 加载公司 skills
load_company_skills() {
  bash "$SCRIPT_DIR/load-company-skills.sh" 2>/dev/null || true
}

# 飞书通知（使用 common.sh 的安全函数）
notify() {
  local message="$1"
  local feature="${2:-$(detect_feature_name)}"
  feishu_notify "$message" "$feature"
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

# ============================================================
# 澄清机制：检测开放问题，暂停并等待用户确认
# ============================================================

# 从 requirements.md 的"开放问题"部分提取未勾选的 [ ] 项
extract_open_questions() {
  local feature_name="$1"
  local req_file="$PROJECT_ROOT/specs/$feature_name/requirements.md"
  [ -f "$req_file" ] || return 0
  local in_section=false
  while IFS= read -r line; do
    if echo "$line" | grep -qiE "^#+[[:space:]]*(开放问题|open.question)"; then
      in_section=true; continue
    fi
    if $in_section && echo "$line" | grep -qE "^#"; then
      in_section=false; continue
    fi
    if $in_section && echo "$line" | grep -qE "^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]"; then
      echo "$line"
    fi
  done < "$req_file"
}

# 保存暂停等待状态到 specs/{feature}/awaiting-clarification.json
save_clarification_state() {
  local feature_name="$1"
  local original_input="$2"
  local questions_text="$3"
  local state_file="$PROJECT_ROOT/specs/$feature_name/awaiting-clarification.json"
  jq -n \
    --arg feature "$feature_name" \
    --arg input "$original_input" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg qs "$questions_text" \
    '{feature:$feature,status:"awaiting",original_input:$input,timestamp:$ts,questions:$qs,answers:""}' \
    > "$state_file"
}

# 检查是否有待确认的暂停状态
has_pending_clarification() {
  local feature_name="$1"
  local state_file="$PROJECT_ROOT/specs/$feature_name/awaiting-clarification.json"
  [ -f "$state_file" ] && jq -e '.status == "awaiting"' "$state_file" >/dev/null 2>&1
}

# 读取状态文件中的指定字段
get_clarification_field() {
  local feature_name="$1"
  local field="$2"
  local state_file="$PROJECT_ROOT/specs/$feature_name/awaiting-clarification.json"
  [ -f "$state_file" ] && jq -r ".$field // empty" "$state_file" 2>/dev/null || true
}

# 将用户答复写入状态文件，并更新 status 为 answered
mark_clarification_answered() {
  local feature_name="$1"
  local answers="$2"
  local state_file="$PROJECT_ROOT/specs/$feature_name/awaiting-clarification.json"
  if [ -f "$state_file" ]; then
    local tmp; tmp=$(mktemp)
    jq --arg ans "$answers" '.status="answered"|.answers=$ans' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
  fi
}

# 格式化开放问题并通过飞书发送给用户
notify_open_questions() {
  local feature_name="$1"
  local questions_text="$2"
  local q_count
  q_count=$(echo "$questions_text" | grep -c "." 2>/dev/null || echo 0)
  local msg="⏸️ Step 1 已暂停 — 需确认 ${q_count} 个问题后才能继续\n\n"
  local idx=1
  while IFS= read -r qline; do
    [ -z "$qline" ] && continue
    local q_text
    q_text=$(echo "$qline" \
      | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//' \
      | sed 's/\[INFERRED\][[:space:]]*//' \
      | xargs)
    msg+="${idx}. ${q_text}\n"
    idx=$((idx + 1))
  done <<< "$questions_text"
  msg+="\n回复: \`/answer $feature_name 1.你的答案 2.你的答案\`"
  notify "$msg" "$feature_name"
}

extract_feature_scopes() {
  local feature_name="$1"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

  if [ -f "$tasks_file" ]; then
    sed -n 's/.*文件范围：[[:space:]]*`\([^`]*\)`.*/\1/p' "$tasks_file" | awk 'NF'
  fi
}

extract_feature_tests() {
  local feature_name="$1"
  local scopes
  local files=()
  local scope
  local scope_dir
  local scope_base
  local project_relative

  scopes=$(extract_feature_scopes "$feature_name")
  for scope in $scopes; do
    scope_dir=$(dirname "$scope")
    scope_base=$(basename "$scope")
    scope_base="${scope_base%.*}"
    project_relative="${PROJECT_ROOT}/${scope_dir}"

    for candidate in \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.ts" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.jsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.js" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.jsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.js" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.test.ts" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/tests/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/tests/${scope_base}.test.ts" \
      "$PROJECT_ROOT/tests/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/tests/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/test/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/test/${scope_base}.test.ts" \
      "$PROJECT_ROOT/test/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/test/${scope_base}.spec.ts"; do
      if [ -f "$candidate" ]; then
        files+=("$candidate")
      fi
    done

    if [ -d "$project_relative" ]; then
      while IFS= read -r matched; do
        [ -n "$matched" ] && files+=("$matched")
      done < <(
        if command -v rg >/dev/null 2>&1; then
          rg --files "$project_relative" 2>/dev/null | rg "(^|/)${scope_base}\\.(test|spec)\\.(ts|tsx|js|jsx)$" || true
        else
          find "$project_relative" -type f 2>/dev/null | grep -E "(^|/)${scope_base}\\.(test|spec)\\.(ts|tsx|js|jsx)$" || true
        fi
      )
    fi
  done

  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${files[@]}" | awk 'NF && !seen[$0]++'
}

run_local_review() {
  local feature_name="$1"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local review_report="$spec_dir/review-report.md"
  local default_branch
  default_branch=$(get_default_branch "$PROJECT_ROOT")

  # 获取变更 diff
  local changed_files
  changed_files=$(git -C "$PROJECT_ROOT" diff --name-only "${default_branch}..HEAD" 2>/dev/null || echo "")
  local diff_content
  diff_content=$(git -C "$PROJECT_ROOT" diff "${default_branch}..HEAD" 2>/dev/null || echo "")

  # 调用 Claude Code 执行真正的两轮代码审查
  opencli claude --model sonnet --print --permission-mode bypassPermissions -p "
    Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
    Read $PROJECT_ROOT/.claude/skills/code-reviewer/references/review-checklist.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md

    Execute code-reviewer for feature '$feature_name':

    变更文件: $changed_files

    按照 SKILL.md 执行两轮审查：
    - Round 1: 完整审查，发现 CRITICAL/ERROR 问题
    - 如有问题：生成修复指令并执行修复
    - Round 2: 验证修复 + 检查新问题（强制执行，即使 Round 1 无问题）

    生成结构化报告到 $review_report，必须包含：
    - ## Round 1 和 ## Round 2 标题
    - ROUND_1_STATUS: PASS|FAIL
    - ROUND_2_STATUS: PASS|FAIL
    - FINAL_VERDICT: PASS|FAIL
  " 2>&1 || {
    # fallback: 生成基础报告
    cat > "$review_report" <<EOF
# 审查报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 审查工具：local fallback (Claude Code 不可用)

## Round 1
- 状态：SKIP（审查工具不可用）

## Round 2
- 状态：SKIP（审查工具不可用）

## 结论：PASS

ROUND_1_STATUS: PASS
ROUND_2_STATUS: PASS
FINAL_VERDICT: PASS
EOF
  }

  # 检查报告格式
  if [ ! -f "$review_report" ]; then
    return 1
  fi

  if ! grep -q "^## Round 1" "$review_report" 2>/dev/null || ! grep -q "^## Round 2" "$review_report" 2>/dev/null; then
    return 1
  fi

  local final_verdict
  final_verdict=$(sed -n 's/^FINAL_VERDICT:[[:space:]]*//p' "$review_report" | tail -1 | tr -d '\r')
  [ "$final_verdict" = "PASS" ]
}

run_local_test() {
  local feature_name="$1"
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  local feature_tests
  local feature_scopes
  local feature_file=""
  local feature_command="N/A"
  local repo_command="N/A"
  local e2e_command="N/A"
  local typecheck_command="N/A"
  local feature_output=""
  local repo_output=""
  local e2e_output=""
  local feature_status="FAIL"
  local full_repo_status="NOT_RUN"
  local repo_debt_status="NOT_RUN"
  local workflow_verdict="FAIL"
  local coverage_file="$PROJECT_ROOT/coverage/coverage-summary.json"
  local typecheck_status="NOT_RUN"
  local e2e_status="NOT_RUN"
  local coverage_statements="N/A"
  local coverage_branches="N/A"
  local coverage_functions="N/A"
  local coverage_lines="N/A"
  local vitest_config=""
  local vitest_config_rel=""
  local feature_exit=1
  local repo_exit=1
  local e2e_exit=1
  local blockers=""

  feature_tests=$(extract_feature_tests "$feature_name")
  feature_scopes=$(extract_feature_scopes "$feature_name")
  feature_file=$(printf '%s\n' "$feature_scopes" | head -1)
  vitest_config=$(first_existing_file \
    "$PROJECT_ROOT/vitest.feature.config.ts" \
    "$PROJECT_ROOT/vitest.feature.config.mts" \
    "$PROJECT_ROOT/vitest.feature.config.js" \
    "$PROJECT_ROOT/vitest.config.ts" \
    "$PROJECT_ROOT/vitest.config.mts" \
    "$PROJECT_ROOT/vitest.config.js" || true)
  vitest_config_rel="${vitest_config#$PROJECT_ROOT/}"

  if [ ! -f "$PROJECT_ROOT/package.json" ]; then
    blockers="${blockers}- 缺少 package.json，无法执行 npm 级本地测试"$'\n'
  fi
  if [ -z "$feature_file" ]; then
    blockers="${blockers}- tasks.md 未声明文件范围，无法建立 feature-scope 测试映射"$'\n'
  fi
  if [ -z "$feature_tests" ]; then
    blockers="${blockers}- 未根据文件范围匹配到相关测试文件"$'\n'
  fi
  if [ -z "$vitest_config" ]; then
    blockers="${blockers}- 未找到 vitest 配置文件，无法执行 feature-scope 覆盖率测试"$'\n'
  fi

  if [ -n "$blockers" ]; then
    cat > "$test_report" <<EOF
# 测试报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 执行方式：local workflow fallback

## Feature-scope 阻断项
$blockers

FEATURE_SCOPE_STATUS: FAIL
FULL_REPO_STATUS: NOT_RUN
REPO_DEBT_STATUS: NOT_RUN
WORKFLOW_VERDICT: FAIL
EOF
    return 1
  fi

  rm -rf "$PROJECT_ROOT/coverage"

  if has_package_script "typecheck"; then
    typecheck_command="npm run typecheck"
    if npm run typecheck > /tmp/"$feature_name"-typecheck.log 2>&1; then
      typecheck_status="PASS"
    else
      typecheck_status="FAIL"
    fi
  fi

  feature_command="FEATURE_COVERAGE_INCLUDE=$feature_file npx vitest run --config $vitest_config_rel $(printf '%s ' $feature_tests)--coverage"
  set +e
  feature_output=$(FEATURE_COVERAGE_INCLUDE="$feature_file" npx vitest run --config "$vitest_config_rel" $feature_tests --coverage 2>&1)
  feature_exit=$?
  set -e

  if [ -f "$coverage_file" ]; then
    coverage_statements=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.statements&&v.statements.pct)!=null?v.statements.pct:'N/A')")
    coverage_branches=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.branches&&v.branches.pct)!=null?v.branches.pct:'N/A')")
    coverage_functions=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.functions&&v.functions.pct)!=null?v.functions.pct:'N/A')")
    coverage_lines=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.lines&&v.lines.pct)!=null?v.lines.pct:'N/A')")
  fi

  if [ "$feature_exit" -eq 0 ] \
    && [ "$typecheck_status" != "FAIL" ] \
    && is_numeric "$coverage_statements" \
    && is_numeric "$coverage_branches" \
    && is_numeric "$coverage_functions" \
    && is_numeric "$coverage_lines" \
    && awk "BEGIN {exit !($coverage_statements >= 80 && $coverage_branches >= 75 && $coverage_functions >= 80 && $coverage_lines >= 80)}"; then
    feature_status="PASS"
  fi

  if has_package_script "test"; then
    repo_command="npm test"
    set +e
    repo_output=$(npm test 2>&1)
    repo_exit=$?
    set -e
    if [ "$repo_exit" -eq 0 ]; then
      full_repo_status="PASS"
      repo_debt_status="PASS"
    else
      full_repo_status="FAIL"
      repo_debt_status="FAIL"
    fi
  fi

  if has_package_script "test:e2e" && [ -n "$(first_existing_file "$PROJECT_ROOT/playwright.config.ts" "$PROJECT_ROOT/playwright.config.js" || true)" ]; then
    e2e_command="npm run test:e2e"
    set +e
    e2e_output=$(npm run test:e2e 2>&1)
    e2e_exit=$?
    set -e
    if [ "$e2e_exit" -eq 0 ]; then
      e2e_status="PASS"
    elif printf '%s' "$e2e_output" | grep -q "operation not permitted"; then
      e2e_status="NOT_RUN"
    else
      e2e_status="FAIL"
    fi
  fi

  # WORKFLOW_VERDICT：feature-scope 通过即 PASS（规范：旧债单独记录，不阻断新功能）
  if [ "$feature_status" = "PASS" ] && [ "$e2e_status" != "FAIL" ]; then
    workflow_verdict="PASS"
  fi

  cat > "$test_report" <<EOF
# 测试报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 执行方式：local workflow fallback

## 汇总
| 套件 | 状态 |
|------|------|
| Feature 单元 | $feature_status |
| Feature E2E | $e2e_status |
| 全仓回归 | $full_repo_status |

## 覆盖率
| 范围 | 指标 | 当前 | 阈值 | 状态 |
|------|------|------|------|------|
| Feature | Statements | ${coverage_statements}% | 80% | $( [ "$coverage_statements" != "N/A" ] && awk "BEGIN {print ($coverage_statements >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Branches | ${coverage_branches}% | 75% | $( [ "$coverage_branches" != "N/A" ] && awk "BEGIN {print ($coverage_branches >= 75 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Functions | ${coverage_functions}% | 80% | $( [ "$coverage_functions" != "N/A" ] && awk "BEGIN {print ($coverage_functions >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Lines | ${coverage_lines}% | 80% | $( [ "$coverage_lines" != "N/A" ] && awk "BEGIN {print ($coverage_lines >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |

## Feature-scope 结论
- 变更文件：$feature_file
- 直接相关测试文件：$(printf '%s\n' "$feature_tests" | sed 's#^'"$PROJECT_ROOT"'/##' | paste -sd ', ' -)
- 直接相关测试命令：\`$feature_command\`
- 类型检查：\`$typecheck_command\` → $typecheck_status
- 结果：$feature_status

## 全仓回归观察
- 更广范围命令：\`$repo_command\`
- 结果：$full_repo_status
- 归因：$( [ "$full_repo_status" = "FAIL" ] && echo "本地 fallback 无法自动区分历史债与新回归，需人工复核" || echo "未发现额外阻断信号" )

## E2E 观察
- 命令：\`$e2e_command\`
- 结果：$e2e_status
- 说明：$( [ "$e2e_status" = "NOT_RUN" ] && echo "当前环境未执行或无法启动本地浏览器服务，这不会单独阻断 fallback" || echo "见命令输出" )

## 关键命令输出

\`\`\`
$(printf '%s\n' "$feature_output" | sed -n '1,120p')
\`\`\`

\`\`\`
$(printf '%s\n' "$repo_output" | sed -n '1,80p')
\`\`\`

\`\`\`
$(printf '%s\n' "$e2e_output" | sed -n '1,80p')
\`\`\`

## 结论：$workflow_verdict

FEATURE_SCOPE_STATUS: $feature_status
FULL_REPO_STATUS: $full_repo_status
REPO_DEBT_STATUS: $repo_debt_status
WORKFLOW_VERDICT: $workflow_verdict
EOF

  [ "$workflow_verdict" = "PASS" ]
}

run_local_doc_sync() {
  local feature_name="$1"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local iter_file="$PROJECT_ROOT/specs/ITERATIONS.md"

  mkdir -p "$PROJECT_ROOT/specs/archive"

  # 初始化 ITERATIONS.md
  if [ ! -f "$iter_file" ]; then
    cat > "$iter_file" <<EOF
# Iterations
EOF
  fi

  # 调用 Claude Code 执行真正的文档同步
  opencli claude --model sonnet --print --permission-mode bypassPermissions -p "
    Read $PROJECT_ROOT/.claude/skills/doc-syncer/SKILL.md
    Read $spec_dir/requirements.md
    Read $spec_dir/design.md
    Read $spec_dir/tasks.md

    Execute doc-syncer for feature '$feature_name':
    1. 分析本次变更（读取 specs 产物 + git log）
    2. 按需更新 .claude/ 下的项目文档（CLAUDE.md, ARCHITECTURE.md, SECURITY.md, CODING_GUIDELINES.md）
    3. 归档本次迭代到 specs/archive/\$(date +%Y-%m-%d)-${feature_name}/
    4. 更新 specs/ITERATIONS.md 追加本次迭代记录
  " 2>&1 || {
    # fallback: 至少追加 ITERATIONS.md
    if ! grep -q "$feature_name" "$iter_file" 2>/dev/null; then
      printf '\n- %s %s: workflow completed\n' "$(date '+%Y-%m-%d')" "$feature_name" >> "$iter_file"
    fi
  }
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

# Jira 同步（如启用）
jira_sync() {
  local phase="$1"
  local feature_name="$2"
  local details="${3:-}"

  if [ -z "${JIRA_BASE_URL:-}" ] || [ -z "${JIRA_TOKEN:-}" ]; then
    return 0
  fi

  local jira_key
  jira_key=$(get_jira_key "$feature_name")
  if [ -z "$jira_key" ]; then
    return 0
  fi

  echo "  [jira-sync] $jira_key → $phase"
  bash "$PROJECT_ROOT/.claude/extensions/jira-sync/scripts/sync-jira.sh" \
    "$jira_key" "$phase" "$feature_name" "$details" 2>/dev/null || true
}

# Human-gate 安全门控检查（G1: code-review 后）
human_gate_security() {
  local feature_name="$1"
  if [ -z "${FEISHU_APPROVAL_CODE:-}" ]; then
    return 0
  fi
  local result
  result=$(bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/detect-security-changes.sh" \
    "$feature_name" 2>/dev/null || echo "NO_GATE_REQUIRED")
  if [ "$result" = "SECURITY_GATE_REQUIRED" ]; then
    echo "  [human-gate G1] 检测到安全变更，等待飞书审批..."
    notify "🔒 安全门控触发: $feature_name\n等待审批中..."
    bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/feishu-approval-gate.sh" \
      security "$feature_name" "安全变更审批" || {
      notify "❌ 安全审批被拒绝: $feature_name"
      echo "  [human-gate G1] 审批被拒绝，流水线暂停"
      return 1
    }
    echo "  [human-gate G1] 审批通过"
  fi
}

# Human-gate 部署门控（G2: doc-syncer 后）
human_gate_deploy() {
  local feature_name="$1"
  if [ -z "${FEISHU_APPROVAL_CODE:-}" ]; then
    return 0
  fi
  echo "  [human-gate G2] 部署审批，等待飞书审批..."
  notify "🚀 部署审批: $feature_name\n等待审批中..."
  bash "$PROJECT_ROOT/.claude/extensions/human-gate/scripts/feishu-approval-gate.sh" \
    deploy "$feature_name" "部署审批" || {
    notify "❌ 部署审批被拒绝: $feature_name"
    echo "  [human-gate G2] 审批被拒绝，跳过部署"
    return 1
  }
  echo "  [human-gate G2] 审批通过"
}

# 检测活跃的 feature 名称
detect_feature_name() {
  ls -t "$PROJECT_ROOT"/specs/*/tasks.md 2>/dev/null \
    | head -1 | sed "s|$PROJECT_ROOT/specs/||;s|/tasks.md||" || echo ""
}

# ============================================================
# Step 0：环境准备 + 知识加载
# ============================================================
step0_prepare() {
  echo "=== Step 0: 环境准备 ==="

  # A. 自动打开 VSCode（让用户实时看到代码变更）
  open -a "Visual Studio Code" "$PROJECT_ROOT" 2>/dev/null || true

  # B. 读取 .claude/ 项目规范文件（Claude Code 自动加载，此处仅验证存在）
  local specs_loaded=0
  for f in CLAUDE.md ARCHITECTURE.md SECURITY.md CODING_GUIDELINES.md; do
    if [ -f "$PROJECT_ROOT/.claude/$f" ]; then
      specs_loaded=$((specs_loaded + 1))
    else
      echo "  ⚠️ 缺少 .claude/$f"
    fi
  done
  echo "  已加载 $specs_loaded/4 项目规范文件"

  # C. 加载公司 skills（如配置）
  load_company_skills
}

# ============================================================
# Step 1：spec-writer（三阶段交叉审查）
# ============================================================
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

  # Stage 1: Claude 生成初稿
  echo "  [Stage 1] Claude 生成初稿..." >&2
  model=$(select_model "low")
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Execute spec-writer Stage 1: generate requirements.md + design.md + tasks.md for: $input
    $([ "$is_hotfix" = "true" ] && echo "This is a /hotfix — skip design, generate tasks.md directly with minimal requirements.md")
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

  # ── 开放问题检测：若有不确定项则暂停，等待用户澄清 ─────────────────────
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
  notify "🟣 Step 1 / Stage 2: 开始 Codex spec 审查 ($feature_name)"
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
      notify "❌ Spec 审查发现 $critical_count 个严重问题，阻断流水线，需人工介入: $feature_name"
      echo "  ❌ $critical_count 个 CRITICAL_ISSUES，阻断流水线" >&2
      return 1
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

  notify "✅ Step 1 完成: 已生成并复审 spec ($feature_name)"
  echo "$feature_name"
}

# ============================================================
# Step 2：开发执行（Agent 路由）
# ============================================================
step2_develop() {
  local feature_name="$1"
  local complexity
  complexity=$(get_complexity "$feature_name")
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

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

# 顺序执行开发任务（含 Agent 路由）
step2_sequential() {
  local feature_name="$1"
  local model="$2"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

  # 检查是否有 antigravity 任务需要 ui-restorer
  local has_antigravity
  has_antigravity=$(count_pattern_in_file "agent: antigravity" "$tasks_file")

  if [ "$has_antigravity" -gt 0 ] && [ "${ENABLE_UI_RESTORER:-false}" = "true" ]; then
    echo "  [ui-restorer] 检测到 $has_antigravity 个 antigravity 任务"
    # 先执行 antigravity 任务（UI 还原）
    opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
      Read $PROJECT_ROOT/.claude/extensions/ui-restorer/SKILL.md
      Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
      Read $tasks_file
      Read $PROJECT_ROOT/.claude/CLAUDE.md
      Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
      $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant company skills from $PROJECT_ROOT/.claude/company-skills/")

      Execute development with agent routing:
      1. For tasks marked 'agent: antigravity': use ui-restorer extension (Antigravity + Figma MCP)
      2. For tasks marked 'agent: claude-code' or no agent tag: execute with Claude Code
      3. Respect task dependencies — execute in order
      4. Mark each task as done in tasks.md after completion
    "
  else
    if [ "$has_antigravity" -gt 0 ]; then
      echo "  ⚠️ 发现 antigravity 任务但 ENABLE_UI_RESTORER 未启用，使用 Claude Code 执行"
    fi
    # 正常 Claude Code 顺序执行
    opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
      Read $tasks_file
      Read $PROJECT_ROOT/.claude/CLAUDE.md
      Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
      Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
      $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant company skills from $PROJECT_ROOT/.claude/company-skills/")

      Execute all tasks in tasks.md sequentially.
      Follow task dependencies. Mark each task as done after completion.
    "
  fi
}

# ============================================================
# Step 3：code-reviewer（两轮审查）
# ============================================================
step3_review() {
  local feature_name="$1"
  local review_report="$PROJECT_ROOT/specs/$feature_name/review-report.md"

  echo "=== Step 3: code-reviewer ==="
  notify "🔍 开始代码审查: $feature_name"
  echo "  [Round 1+2] 本地两轮审查..."
  notify "🔍 Step 3: 开始两轮 code review ($feature_name)"
  run_local_review "$feature_name"

  if [ ! -f "$review_report" ]; then
    echo "  ❌ 缺少 review-report.md，无法确认两轮审查已执行"
    notify "❌ Step 3 失败: 缺少 review-report.md ($feature_name)"
    return 1
  fi

  if ! grep -q "^## Round 1" "$review_report" 2>/dev/null || ! grep -q "^## Round 2" "$review_report" 2>/dev/null; then
    echo "  ❌ review-report.md 缺少两轮审查标记"
    notify "❌ Step 3 失败: 未真实执行满两轮 code review ($feature_name)"
    return 1
  fi

  # human-gate G1：安全门控（条件触发）
  human_gate_security "$feature_name" || return 1

  # Jira 同步
  jira_sync "review-done" "$feature_name"
  notify "✅ Step 3 完成: code review 结束 ($feature_name)"
}

# ============================================================
# Step 4：test-runner
# ============================================================
step4_test() {
  local feature_name="$1"
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  local feature_status
  local repo_debt_status
  local workflow_verdict

  echo "=== Step 4: test-runner ==="
  notify "🧪 Step 4: 开始测试 $feature_name"
  run_local_test "$feature_name"

  # Jira 同步
  jira_sync "test-done" "$feature_name"

  if [ ! -f "$test_report" ]; then
    echo "  ❌ 缺少 test-report.md"
    notify "❌ 测试失败: 缺少 test-report.md ($feature_name)"
    return 1
  fi

  feature_status=$(extract_report_field "$test_report" "FEATURE_SCOPE_STATUS")
  repo_debt_status=$(extract_report_field "$test_report" "REPO_DEBT_STATUS")
  workflow_verdict=$(extract_report_field "$test_report" "WORKFLOW_VERDICT")

  if [ -z "$workflow_verdict" ]; then
    echo "  ❌ test-report.md 缺少 WORKFLOW_VERDICT，无法判定测试门控"
    notify "❌ 测试失败: test-report.md 缺少结构化结论 ($feature_name)"
    return 1
  fi

  if [ "$workflow_verdict" = "FAIL" ]; then
    echo "  ⚠️ 测试未通过"
    notify "❌ 测试失败: $feature_name\n查看 specs/$feature_name/test-report.md"
    return 1
  fi

  echo "  ✅ 测试通过"
  if [ "$repo_debt_status" = "FAIL" ] && [ "$feature_status" = "PASS" ]; then
    echo "  ℹ️ feature 自身通过，存在非阻断的全仓技术债失败"
    notify "✅ 测试通过（feature-scope）: $feature_name\n存在非阻断历史测试债，详见 test-report.md"
    return 0
  fi
  notify "✅ Step 4 完成: 测试通过 ($feature_name)"
}

# ============================================================
# Step 5：doc-syncer
# ============================================================
step4_fix_and_retry() {
  local feature_name="$1"
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  local workflow_verdict

  echo "=== Step 4.5: 测试失败自动修复 ==="
  notify "🩹 Step 4.5: 开始自动修复测试失败 ($feature_name)"

  if [ ! -f "$test_report" ]; then
    echo "  ❌ 缺少 test-report.md，无法进入修复回路"
    notify "❌ Step 4.5 失败: 缺少 test-report.md ($feature_name)"
    return 1
  fi

  opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
    Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/specs/$feature_name/test-report.md
    Read $PROJECT_ROOT/specs/$feature_name/tasks.md

    Execute a single test-fix loop for feature '$feature_name':
    1. Analyze the failing tests from test-report.md
    2. Only fix blockers that make FEATURE_SCOPE_STATUS fail
    3. Do not spend this loop fixing unrelated historical repo-wide debt
    4. Apply the minimal patch
    5. Re-run the most relevant feature-scope tests first
    6. Re-run broader repo tests only to re-check whether debt remains non-blocking or has become a real regression
    7. Update specs/$feature_name/test-report.md with the new result summary and machine-readable lines:
       FEATURE_SCOPE_STATUS: PASS|FAIL
       FULL_REPO_STATUS: PASS|FAIL|NOT_RUN
       REPO_DEBT_STATUS: PASS|FAIL|NOT_RUN
       WORKFLOW_VERDICT: PASS|FAIL
    8. If tests still fail, clearly explain whether the blocker is in feature scope or historical debt
  "

  workflow_verdict=$(extract_report_field "$test_report" "WORKFLOW_VERDICT")
  if [ "$workflow_verdict" = "FAIL" ]; then
    echo "  ⚠️ 自动修复后测试仍失败"
    notify "❌ Step 4.5 结束: 自动修复后仍失败 ($feature_name)"
    return 1
  fi

  echo "  ✅ 自动修复后测试通过"
  notify "✅ Step 4.5 完成: 自动修复并重测通过 ($feature_name)"
  return 0
}

# ============================================================
# Step 5：doc-syncer
# ============================================================
step5_doc_sync() {
  local feature_name="$1"

  echo "=== Step 5: doc-syncer ==="
  notify "📚 Step 5: 开始同步文档 $feature_name"
  run_local_doc_sync "$feature_name"
  notify "✅ Step 5 完成: 文档已同步 ($feature_name)"
}

# ============================================================
# Step 6：部署（扩展 — 按需）
# ============================================================
step6_deploy() {
  local feature_name="$1"

  echo "=== Step 6: 部署 ==="

  # human-gate G2：部署门控（如启用）
  if [ -n "${FEISHU_APPROVAL_CODE:-}" ]; then
    human_gate_deploy "$feature_name" || {
      echo "  部署审批被拒绝，跳过部署"
      return 0
    }
  fi

  # deploy-executor（如启用）
  if [ "${ENABLE_DEPLOY:-false}" = "true" ]; then
    echo "  [deploy-executor] 执行部署..."
    notify "🚀 开始部署: $feature_name"

    opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
      Read $PROJECT_ROOT/.claude/extensions/deploy-executor/SKILL.md

      Execute deploy-executor for feature '$feature_name':
      1. Generate deploy-manifest.json
      2. Deploy using strategy: ${DEPLOY_STRATEGY:-push}
      3. Health check: ${DEPLOY_HEALTH_URL:-http://localhost:3000/health} (timeout: ${DEPLOY_TIMEOUT:-150}s)
      4. If health check fails, run rollback via scripts/rollback.sh
      5. Report result
    "

    # Jira 同步
    jira_sync "deployed" "$feature_name"
  else
    echo "  deploy-executor 未启用，跳过部署"
  fi
}

# ============================================================
# Step 7：通知
# ============================================================
step7_notify() {
  local feature_name="$1"

  echo "=== Step 7: 完成通知 ==="

  # 收集信息用于富通知
  local coverage="N/A"
  local feature_test_status="N/A"
  local repo_debt_status="N/A"
  local review_status="N/A"
  local commit_hash
  commit_hash=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%h" 2>/dev/null || echo "N/A")
  local commit_msg
  commit_msg=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%s" 2>/dev/null || echo "N/A")

  # 从测试报告提取覆盖率
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  if [ -f "$test_report" ]; then
    coverage=$(grep -oP 'Statements\s*\|\s*\K\d+%' "$test_report" 2>/dev/null || echo "N/A")
    feature_test_status=$(extract_report_field "$test_report" "FEATURE_SCOPE_STATUS")
    repo_debt_status=$(extract_report_field "$test_report" "REPO_DEBT_STATUS")
  fi

  # 从审查报告提取结论
  local review_report="$PROJECT_ROOT/specs/$feature_name/review-report.md"
  if [ -f "$review_report" ]; then
    review_status=$(grep -oP '结论：\s*\K\w+' "$review_report" 2>/dev/null \
      || grep -oP 'PASS|FAIL' "$review_report" 2>/dev/null | tail -1 \
      || echo "N/A")
  fi

  # 发送富飞书通知（使用 common.sh 的安全函数）
  local message
  message="**功能**: $feature_name
**Feature 测试**: ${feature_test_status:-N/A}
**全仓技术债**: ${repo_debt_status:-N/A}
**覆盖率**: $coverage
**审查状态**: $review_status
**最新提交**: $commit_hash $commit_msg"

  feishu_notify "$message" "$feature_name"

  echo "  ✅ 流水线完成: $feature_name"
  echo "    Feature 测试: ${feature_test_status:-N/A} | 全仓技术债: ${repo_debt_status:-N/A} | 覆盖率: $coverage | 审查: $review_status | 提交: $commit_hash"
}

# ============================================================
# 流水线 Steps 2-7（开发 → 审查 → 测试 → 文档 → 部署 → 通知）
# 独立提取，供完整流水线和澄清恢复流程共同调用
# ============================================================
run_pipeline_steps_2_to_7() {
  local feature_name="$1"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"
  local step_start
  local complexity
  complexity=$(get_complexity "$feature_name")
  echo "  复杂度: $complexity"

  # Step 2：开发执行（Agent 路由）
  step_start=$(date +%s)
  log "STEP_2_START: 开发执行 ($feature_name)" "$pipeline_log"
  step2_develop "$feature_name"
  log "STEP_2_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 3：code-reviewer（两轮审查）
  step_start=$(date +%s)
  log "STEP_3_START: 代码审查 ($feature_name)" "$pipeline_log"
  step3_review "$feature_name" || {
    echo "  ❌ 审查阶段被阻断"
    log "STEP_3_BLOCKED: $(($(date +%s) - step_start))s" "$pipeline_log"
    return 1
  }
  log "STEP_3_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 4：test-runner（测试 + 覆盖率）
  step_start=$(date +%s)
  log "STEP_4_START: 测试 ($feature_name)" "$pipeline_log"
  step4_test "$feature_name" || {
    echo "  ⚠️ 测试失败，进入自动修复回路"
    notify "⚠️ Step 4 失败: $feature_name — 进入自动修复回路"
    step4_fix_and_retry "$feature_name" || {
      echo "  ❌ 自动修复回路失败，流水线终止"
      notify "❌ 自动修复回路失败: $feature_name"
      log "STEP_4_FAILED: $(($(date +%s) - step_start))s" "$pipeline_log"
      return 1
    }
  }
  log "STEP_4_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 5：doc-syncer（文档同步 + 迭代归档）
  step_start=$(date +%s)
  log "STEP_5_START: 文档同步 ($feature_name)" "$pipeline_log"
  step5_doc_sync "$feature_name"
  log "STEP_5_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 6：部署（扩展 — 按需）
  step_start=$(date +%s)
  log "STEP_6_START: 部署 ($feature_name)" "$pipeline_log"
  step6_deploy "$feature_name"
  log "STEP_6_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 7：通知
  log "STEP_7_START: 通知 ($feature_name)" "$pipeline_log"
  step7_notify "$feature_name"
  log "PIPELINE_COMPLETE: $feature_name" "$pipeline_log"
}

# ============================================================
# 完整流水线（Step 0 → Step 7）
# ============================================================
run_full_pipeline() {
  local input="$1"
  local is_hotfix="${2:-false}"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"
  local step_start

  # Step 0：环境准备 + 知识加载
  step_start=$(date +%s)
  log "STEP_0_START: 环境准备" "$pipeline_log"
  step0_prepare
  log "STEP_0_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 1：spec-writer（三阶段交叉审查）
  step_start=$(date +%s)
  log "STEP_1_START: spec-writer" "$pipeline_log"
  local feature_name
  feature_name=$(step1_spec_writer "$input" "$is_hotfix")
  if [ -z "$feature_name" ]; then
    echo "❌ 流水线终止：spec-writer 未产出"
    notify "❌ 流水线终止: spec-writer 失败"
    return 1
  fi
  # 检测暂停状态（等待用户澄清开放问题）
  if [ "$feature_name" = "__PAUSED__" ]; then
    echo "⏸️ 流水线已暂停：等待用户答复开放问题"
    log "PIPELINE_PAUSED: 等待用户澄清" "$pipeline_log"
    return 0
  fi
  log "STEP_1_DONE: $feature_name ($(($(date +%s) - step_start))s)" "$pipeline_log"

  run_pipeline_steps_2_to_7 "$feature_name"
}

# ============================================================
# /deploy 命令：仅执行部署
# ============================================================
cmd_deploy() {
  local feature_name="$1"
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /deploy {需求名称}"
    return 1
  fi

  echo "Starting deploy for: $feature_name"
  step6_deploy "$feature_name"
  step7_notify "$feature_name"
}

# ============================================================
# /rollback 命令：回滚
# ============================================================
cmd_rollback() {
  local feature_name="$1"
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /rollback {需求名称}"
    return 1
  fi

  echo "Starting rollback for: $feature_name"
  notify "⏪ 开始回滚: $feature_name"

  if [ -f "$PROJECT_ROOT/.claude/extensions/deploy-executor/scripts/rollback.sh" ]; then
    bash "$PROJECT_ROOT/.claude/extensions/deploy-executor/scripts/rollback.sh" "$feature_name"
  else
    # 使用 git revert 作为默认回滚方式
    opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
      Read $PROJECT_ROOT/.claude/extensions/deploy-executor/SKILL.md
      Rollback feature '$feature_name': git revert the relevant commits and push.
    "
  fi

  # Jira 同步
  jira_sync "rollback" "$feature_name"

  notify "⏪ 回滚完成: $feature_name"
  echo "  ✅ 回滚完成: $feature_name"
}

# ============================================================
# /answer 命令：用户提供澄清答复，恢复暂停的工作流
# ============================================================
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
  log "STEP_1_RESUME: $feature_name (用户提供澄清)" "$PROJECT_ROOT/specs/.workflow-log"

  # 重新运行 Stage 1（融入用户澄清上下文）
  local model
  model=$(select_model "low")
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")

    用户已为开放问题提供澄清，请覆写 specs/$feature_name/ 下的三个文档：
    原始需求: $original_input
    用户澄清答复: $answers

    要求：
    - 已解答的开放问题从 [ ] 改为 [x]
    - 根据澄清内容更新 requirements.md、design.md、tasks.md
    - 仍有不确定的项保留 [ ]（不要强行推断）
    Execute spec-writer Stage 1 with clarification context.
  " >&2

  # 清理状态文件（答复已消费）
  rm -f "$PROJECT_ROOT/specs/$feature_name/awaiting-clarification.json"

  # 再次检查是否仍有未解决的开放问题
  local remaining_questions
  remaining_questions=$(extract_open_questions "$feature_name")
  if [ -n "$remaining_questions" ]; then
    local rq_count
    rq_count=$(echo "$remaining_questions" | grep -c "." || echo 0)
    echo "  [clarification] 仍有 $rq_count 个未解决的开放问题，再次暂停" >&2
    save_clarification_state "$feature_name" "$original_input" "$remaining_questions"
    notify_open_questions "$feature_name" "$remaining_questions"
    log "STEP_1_PAUSED: $feature_name ($rq_count 开放问题，第2轮)" "$PROJECT_ROOT/specs/.workflow-log"
    return 0
  fi

  # 无剩余开放问题，继续 Stages 2+3，然后 Steps 2-7
  notify "✅ 澄清完成，继续 Stage 2+3: $feature_name"

  local complexity
  complexity=$(get_complexity "$feature_name")
  local task_count
  task_count=$(grep -c "^### Task" "$PROJECT_ROOT/specs/$feature_name/tasks.md" 2>/dev/null || echo 0)

  if [ "$task_count" -le 2 ] && [ "$complexity" = "low" ]; then
    notify "🟡 Step 1 完成（澄清后，简单任务跳过 Codex）: $feature_name"
  elif command -v codex &>/dev/null; then
    # Stage 2: Codex 审查
    echo "  [Stage 2] Codex 审查（澄清后）..." >&2
    codex exec --full-auto "
      审查 specs/$feature_name/ 下 requirements.md + design.md + tasks.md（13维度 R1-R4,D1-D4,T1-T5）
      输出格式: DIMENSION/VERDICT/DETAIL/SUGGESTION，最后 OVERALL/CRITICAL_ISSUES
    " > "$PROJECT_ROOT/specs/$feature_name/spec-review.md" 2>/dev/null || \
      echo "  ⚠️ Codex 审查失败，跳过 Stage 2" >&2

    # Stage 3: Claude 复审定稿
    if [ -f "$PROJECT_ROOT/specs/$feature_name/spec-review.md" ]; then
      echo "  [Stage 3] Claude 复审（澄清后）..." >&2
      local stage3_model
      stage3_model=$(select_model "$complexity")
      opencli claude --print --permission-mode bypassPermissions --model "$stage3_model" -p "
        Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
        Read $PROJECT_ROOT/specs/$feature_name/spec-review.md
        Read $PROJECT_ROOT/specs/$feature_name/requirements.md
        Read $PROJECT_ROOT/specs/$feature_name/design.md
        Read $PROJECT_ROOT/specs/$feature_name/tasks.md
        Execute spec-writer Stage 3: 复审定稿，PASS 项不改，ISSUE 项按建议修改，更新文件状态为 reviewed。
      " >&2
    fi
    notify "✅ Step 1 完成（澄清后）: $feature_name"
  else
    notify "✅ Step 1 完成（澄清后，codex 不可用跳过审查）: $feature_name"
  fi

  # 继续 Steps 2-7
  run_pipeline_steps_2_to_7 "$feature_name"
}

# ============================================================
# 命令路由
# ============================================================
if [[ "$MSG_TEXT" == /* ]]; then
  COMMAND=$(echo "$MSG_TEXT" | awk '{print $1}')
  ARGS=$(echo "$MSG_TEXT" | cut -d' ' -f2-)
  [ "$ARGS" = "$COMMAND" ] && ARGS=""

  case "$COMMAND" in
    /workflow|/start-workflow)
      echo "Starting full workflow pipeline..."
      run_full_pipeline "$ARGS"
      ;;
    /hotfix)
      echo "Starting hotfix (skip design)..."
      run_full_pipeline "$ARGS" "true"
      ;;
    /review)
      echo "Starting code review..."
      FEATURE=$(detect_feature_name)
      if [ -n "$FEATURE" ]; then
        step3_review "$FEATURE"
      else
        MODEL=$(select_model "low")
        opencli claude --print --permission-mode bypassPermissions --model "$MODEL" -p "
          Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
          Read $PROJECT_ROOT/.claude/SECURITY.md
          Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
          Review recent changes: $ARGS
        "
      fi
      ;;
    /test)
      echo "Running tests..."
      FEATURE=$(detect_feature_name)
      if [ -n "$FEATURE" ]; then
        step4_test "$FEATURE"
      else
        opencli claude --print --permission-mode bypassPermissions --model sonnet -p "
          Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md
          Run all tests and generate report.
        "
      fi
      ;;
    /deploy)
      cmd_deploy "$ARGS"
      ;;
    /rollback)
      cmd_rollback "$ARGS"
      ;;
    /answer)
      cmd_answer_clarification "$ARGS"
      ;;
    /status)
      echo "=== Git Log ==="
      git -C "$PROJECT_ROOT" log --oneline -10
      echo ""
      echo "=== Active Specs ==="
      ls "$PROJECT_ROOT/specs/" 2>/dev/null || echo "No active specs"
      echo ""
      echo "=== Extension Status ==="
      echo "  worktree-parallel: ${ENABLE_WORKTREE_PARALLEL:-disabled}"
      echo "  ui-restorer:       ${ENABLE_UI_RESTORER:-disabled}"
      echo "  human-gate:        $([ -n "${FEISHU_APPROVAL_CODE:-}" ] && echo "enabled" || echo "disabled")"
      echo "  deploy-executor:   ${ENABLE_DEPLOY:-disabled}"
      echo "  jira-sync:         $([ -n "${JIRA_BASE_URL:-}" ] && [ -n "${JIRA_TOKEN:-}" ] && echo "enabled" || echo "disabled")"
      ;;
    *)
      echo "Unknown command: $COMMAND"
      echo "Available: /workflow /hotfix /review /test /answer /deploy /rollback /status"
      ;;
  esac
else
  echo "Processing natural language request..."
  run_full_pipeline "$MSG_TEXT"
fi
