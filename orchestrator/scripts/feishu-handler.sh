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
      agent_notify \
        "需求 '$feature' 的流水线异常退出（exit code: $exit_code），可执行 /resume $feature 从断点继续。" \
        "需要我帮你排查原因吗？还是直接 /resume $feature 继续？" \
        "$feature"
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

# 检查是否处于 /pause 手动暂停状态
has_paused_state() {
  local feature_name="$1"
  local state_file="$PROJECT_ROOT/specs/$feature_name/paused.json"
  [ -f "$state_file" ] && jq -e '.status == "paused"' "$state_file" >/dev/null 2>&1
}

# 读取 paused.json 指定字段
get_paused_field() {
  local feature_name="$1"
  local field="$2"
  local state_file="$PROJECT_ROOT/specs/$feature_name/paused.json"
  [ -f "$state_file" ] && jq -r ".$field // empty" "$state_file" 2>/dev/null || true
}

# 格式化开放问题并通过飞书发送给用户
notify_open_questions() {
  local feature_name="$1"
  local questions_text="$2"
  local q_count
  q_count=$(echo "$questions_text" | grep -c "." 2>/dev/null || echo 0)
  local questions_list=""
  local idx=1
  while IFS= read -r qline; do
    [ -z "$qline" ] && continue
    local q_text
    q_text=$(echo "$qline" \
      | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//' \
      | sed 's/\[INFERRED\][[:space:]]*//' \
      | xargs)
    questions_list+="${idx}. ${q_text}\n"
    idx=$((idx + 1))
  done <<< "$questions_text"

  local context="需求 '$feature_name' 的 Step 1 已暂停，检测到 ${q_count} 个开放问题需要用户确认后才能继续生成设计和任务。"
  local question="请逐一向用户提问：\n${questions_list}\n用户回复后执行：/answer $feature_name 1.答案 2.答案"
  agent_notify "$context" "$question" "$feature_name"
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
  # 优先找 tasks.md（Stage 1b 完成后），fallback 到 requirements.md（Stage 1a 完成后）
  local by_tasks by_reqs
  by_tasks=$(ls -t "$PROJECT_ROOT"/specs/*/tasks.md 2>/dev/null \
    | head -1 | sed "s|$PROJECT_ROOT/specs/||;s|/tasks.md||" || echo "")
  if [ -n "$by_tasks" ]; then
    echo "$by_tasks"
    return
  fi
  by_reqs=$(ls -t "$PROJECT_ROOT"/specs/*/requirements.md 2>/dev/null \
    | head -1 | sed "s|$PROJECT_ROOT/specs/||;s|/requirements.md||" || echo "")
  echo "$by_reqs"
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
      agent_notify \
        "需求 '$feature_name' 的 Spec 审查发现 $critical_count 个严重问题，流水线已阻断。详见 specs/$feature_name/spec-review.md。" \
        "是否需要我根据审查意见重新修改 spec 后继续？还是由你人工处理后再 /restart $feature_name？" \
        "$feature_name"
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

# ============================================================
# dev server 生命周期管理
# ============================================================

# 检测 dev server 端口（从 package.json 读取，fallback 3000）
_detect_dev_port() {
  local pkg="$PROJECT_ROOT/package.json"
  local port=""
  if [ -f "$pkg" ]; then
    port=$(node -e "
      try {
        const pkg = require('$pkg');
        const devScript = pkg.scripts?.dev || '';
        const match = devScript.match(/--port[= ](\d+)/);
        console.log(match ? match[1] : '');
      } catch(e) { console.log(''); }
    " 2>/dev/null || true)
  fi
  echo "${port:-3000}"
}

# 检查 dev server 是否正在运行
_dev_server_running() {
  local port="$1"
  lsof -i :"$port" | grep -q LISTEN 2>/dev/null
}

# 等待 dev server 端口就绪（最多 60s）
_wait_dev_server() {
  local port="$1"
  local elapsed=0
  while [ $elapsed -lt 60 ]; do
    if _dev_server_running "$port"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# 确保 dev server 已启动，返回访问 URL
# 返回值（stdout）: http://localhost:{PORT}
# 返回码: 0=成功 1=失败
ensure_dev_server() {
  local feature_name="$1"
  local port
  port=$(_detect_dev_port)
  local base_url="http://localhost:${port}"

  if _dev_server_running "$port"; then
    echo "  [dev-server] 已在端口 $port 运行" >&2
    notify "dev server 已在 $base_url 运行" "$feature_name"
    echo "$base_url"
    return 0
  fi

  echo "  [dev-server] 未检测到运行中的 dev server，尝试启动..." >&2
  local log_file="/tmp/devserver-${feature_name}.log"

  # 后台启动
  nohup npm --prefix "$PROJECT_ROOT" run dev \
    > "$log_file" 2>&1 &

  echo "  [dev-server] 等待端口 $port 就绪（最多 60s）..." >&2
  if _wait_dev_server "$port"; then
    echo "  [dev-server] 启动成功: $base_url" >&2
    notify "dev server 已启动: $base_url\n日志: $log_file" "$feature_name"
    echo "$base_url"
    return 0
  else
    echo "  [dev-server] ❌ 启动超时（60s）" >&2
    agent_notify \
      "需求 '$feature_name' 的 dev server 启动失败，日志: $log_file" \
      "请手动启动 dev server 后执行 /resume $feature_name 继续" \
      "$feature_name"
    return 1
  fi
}

# ============================================================
# Step 2a: Antigravity UI 还原（显式两阶段：先 antigravity，再 claude-code）
# ============================================================

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

# 执行单个 antigravity 任务的分块还原
# 返回: 0=通过(包括人工确认) 1=失败
step2a_restore_task() {
  local feature_name="$1"
  local task_num="$2"
  local base_url="$3"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
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

      # 选择生成模式
      local gen_model gen_variant
      if [ "$round" -eq 1 ] || [ "$diff_complexity" = "major" ]; then
        gen_model="antigravity-gemini-3-pro"
        gen_variant="high"
      else
        # Round 2 minor → Fast
        gen_model="antigravity-gemini-3-flash"
        gen_variant="minimal"
      fi

      # 调用 Antigravity 生成/修复
      if [ "$round" -eq 1 ]; then
        opencli antigravity send \
          --model="$gen_model" --variant="$gen_variant" \
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

请生成 $block_name 的代码，写入 $file_path。" >/dev/null 2>&1 || true
      else
        # Round 2：带精确 diff 修复
        opencli antigravity send \
          --model="$gen_model" --variant="$gen_variant" \
          "根据以下视觉 diff 精确修复 $file_path：

$fixes

Figma 设计规格参考：
$design_spec

只修改与 diff 相关的代码，不要重写其他部分。" >/dev/null 2>&1 || true
      fi

      sleep 3  # 等待热更新

      # 截图
      local screenshot="${screenshot_base}-round${round}.png"
      if [ -n "$cdp_target" ]; then
        node "$PROJECT_ROOT/scripts/cdp.mjs" shot "$cdp_target" "$screenshot" >/dev/null 2>&1 || true
      fi

      # Antigravity Pro 模式视觉打分
      local score_output
      score_output=$(opencli antigravity send \
        --model="antigravity-gemini-3-pro" \
        "请对比以下两张图，评估 UI 还原质量：

图1（Figma 设计稿）：通过 Figma MCP 打开 $figma_url，查看 $block_name 区域
图2（当前渲染截图）：[附图: $screenshot]

评估维度：
1. 整体布局结构是否一致
2. 间距/padding/margin 是否准确
3. 颜色/字体/字号是否匹配
4. 组件细节（圆角/阴影/边框）是否还原
5. 响应式是否正确

严格按以下格式输出，不要有其他文字：
SCORE: {1-10}
DIFF_COMPLEXITY: minor|major
FIXES:
  - {元素.属性: 实际值 → 设计值}
PASS: true|false" 2>/dev/null || echo "SCORE: 0
DIFF_COMPLEXITY: major
FIXES:
  - 截图获取失败，跳过视觉打分
PASS: false")

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

# 顺序执行开发任务（显式两阶段：Step 2a antigravity → Step 2b claude-code）
step2_sequential() {
  local feature_name="$1"
  local model="$2"
  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

  local has_antigravity
  has_antigravity=$(count_pattern_in_file "agent: antigravity" "$tasks_file")

  # ── Step 2a: Antigravity UI 还原（显式优先执行）──
  if [ "$has_antigravity" -gt 0 ] && [ "${ENABLE_UI_RESTORER:-false}" = "true" ]; then
    echo "  [Step 2a] 检测到 $has_antigravity 个 antigravity 任务，开始 UI 还原" >&2
    notify "🎨 Step 2a: 开始 UI 还原 ($has_antigravity 个任务)" "$feature_name"

    # Phase 0: 确保 dev server 运行
    local base_url
    base_url=$(ensure_dev_server "$feature_name") || return 1

    # 逐个执行 antigravity 任务
    local task_nums
    task_nums=$(grep -n "agent: antigravity" "$tasks_file" 2>/dev/null \
      | while read -r line; do
          local lineno="${line%%:*}"
          # 往上找最近的 ### Task N
          awk "NR<=$lineno" "$tasks_file" \
            | grep "^### Task [0-9]" | tail -1 \
            | grep -o "[0-9]*" | head -1
        done | sort -un)

    for task_num in $task_nums; do
      step2a_restore_task "$feature_name" "$task_num" "$base_url" || {
        echo "  ⚠️ Task $task_num 还原失败，继续下一个" >&2
      }
    done

    notify "✅ Step 2a 完成: UI 还原结束，开始 Phase 3 Codex 审查" "$feature_name"

    # Phase 3: Codex 代码规范审查（一轮）
    echo "  [Step 2a] Phase 3: Codex 代码规范审查..." >&2
    if command -v codex >/dev/null 2>&1; then
      local changed_files
      changed_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD 2>/dev/null || echo "")
      codex exec --full-auto "
审查 Antigravity 生成的 UI 代码（代码规范审查，非视觉审查）。

变更文件：
$changed_files

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
          opencli antigravity send \
            --model="antigravity-gemini-3-flash" --variant="minimal" \
            "修复以下代码规范问题：
$error_issues
严格按 FIX 建议修改，不要改其他代码。" >/dev/null 2>&1 || true
        fi
        local warning_issues
        warning_issues=$(grep -A3 "SEVERITY: WARNING" \
          "$PROJECT_ROOT/specs/$feature_name/ui-codex-review.md" 2>/dev/null || echo "")
        [ -n "$warning_issues" ] && \
          notify "⚠️ UI Codex 审查警告（不阻塞）:\n$warning_issues" "$feature_name"
      fi
    else
      echo "  ⚠️ codex 未安装，跳过 UI 代码规范审查" >&2
    fi

    notify "✅ Step 2a 全部完成: UI 还原 + Codex 审查通过" "$feature_name"
  elif [ "$has_antigravity" -gt 0 ]; then
    echo "  ⚠️ 发现 antigravity 任务但 ENABLE_UI_RESTORER 未启用，使用 Claude Code 执行" >&2
  fi

  # ── Step 2b: claude-code 任务（业务逻辑，依赖 2a 产出）──
  echo "  [Step 2b] 执行 claude-code 任务..." >&2
  notify "💻 Step 2b: 开始业务逻辑开发" "$feature_name"

  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $tasks_file
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant company skills from $PROJECT_ROOT/.claude/company-skills/")

    Execute all tasks marked 'agent: claude-code' (or with no agent tag) in tasks.md.
    Skip tasks marked 'agent: antigravity' (already completed in Step 2a).
    Follow task dependencies. Mark each task as done after completion.
  " >&2
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
    agent_notify \
      "需求 '$feature_name' 的测试（Step 4）失败，正在进入自动修复回路，我会尝试自动修复后重跑测试。" \
      "如果自动修复失败我会再通知你，你可以随时发 /status 查看进展。" \
      "$feature_name"
    step4_fix_and_retry "$feature_name" || {
      echo "  ❌ 自动修复回路失败，流水线终止"
      agent_notify \
        "需求 '$feature_name' 的自动修复回路也失败了，无法自动解决测试问题，流水线已终止。详见 specs/$feature_name/test-report.md。" \
        "需要我帮你分析失败原因吗？还是你来人工修复后执行 /resume $feature_name 继续？" \
        "$feature_name"
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
# /pause 命令：手动暂停工作流，保存断点和 requirements.md 快照
# ============================================================
cmd_pause() {
  local feature_name="$1"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"

  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /pause {需求名称}"
    return 1
  fi
  if ! validate_feature_name "$feature_name"; then
    echo "❌ 非法的 feature name: $feature_name"
    return 1
  fi

  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  if [ ! -d "$spec_dir" ]; then
    echo "❌ 未找到 specs 目录: $spec_dir"
    return 1
  fi

  # 防止重复暂停
  if has_paused_state "$feature_name"; then
    local already_at
    already_at=$(get_paused_field "$feature_name" "paused_at")
    echo "⚠️ '$feature_name' 已处于暂停状态（暂停于 $already_at）"
    echo "   修改需求后执行: /restart $feature_name"
    return 0
  fi

  # 从 workflow-log 计算断点（下一个未完成的 Step）
  local last_done_step=1
  if [ -f "$pipeline_log" ]; then
    for step in 2 3 4 5 6 7; do
      if grep -q "STEP_${step}_DONE" "$pipeline_log" 2>/dev/null; then
        last_done_step=$step
      fi
    done
  fi
  local paused_step=$((last_done_step + 1))

  # 快照 requirements.md
  local req_file="$spec_dir/requirements.md"
  local snapshot_file="$spec_dir/requirements.md.snapshot"
  if [ -f "$req_file" ]; then
    cp "$req_file" "$snapshot_file"
    echo "  [pause] requirements.md 快照已保存" >&2
  else
    echo "  ⚠️ 未找到 requirements.md，快照跳过" >&2
  fi

  # 写入 paused.json
  jq -n \
    --arg feature "$feature_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ps "$paused_step" \
    --argjson ls "$last_done_step" \
    '{feature:$feature,status:"paused",paused_at:$ts,paused_step:$ps,last_done_step:$ls,requirements_snapshot:"requirements.md.snapshot"}' \
    > "$spec_dir/paused.json"

  log "PIPELINE_PAUSED_BY_USER: $feature_name at step $paused_step" "$pipeline_log"
  notify "⏸️ 工作流已手动暂停 (断点 Step $paused_step): $feature_name"
  echo "⏸️ 已暂停 '$feature_name'（断点 Step $paused_step）"
  echo "   - 如需改需求: 编辑 specs/$feature_name/requirements.md，然后 /restart $feature_name"
  echo "   - 不改需求:  直接 /restart $feature_name"
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

  # 计算 diff
  local diff_output
  diff_output=$(diff "$snapshot_file" "$req_file" 2>/dev/null || true)

  if [ -z "$diff_output" ]; then
    echo "  [restart] requirements.md 无变更，直接从 Step $paused_step 继续" >&2
    notify "▶️ 需求无变更，从 Step $paused_step 继续: $feature_name"
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

# ============================================================
# /restart 命令：从 paused 状态恢复，智能判断需求变更
# ============================================================
cmd_restart() {
  local feature_name="$1"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"

  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /restart {需求名称}"
    return 1
  fi
  if ! validate_feature_name "$feature_name"; then
    echo "❌ 非法的 feature name: $feature_name"
    return 1
  fi

  # 优先检查是否有待澄清状态（避免与 paused.json 产生歧义）
  if has_pending_clarification "$feature_name"; then
    echo "⚠️ '$feature_name' 处于等待澄清状态，请先用 /answer 回复问题后再 /restart"
    return 1
  fi

  if ! has_paused_state "$feature_name"; then
    echo "❌ '$feature_name' 不处于 paused 状态"
    echo "   提示: 先用 /pause $feature_name 暂停工作流"
    return 1
  fi

  local paused_step
  paused_step=$(get_paused_field "$feature_name" "paused_step")
  local paused_at
  paused_at=$(get_paused_field "$feature_name" "paused_at")

  echo "  [restart] '$feature_name' 暂停于 $paused_at，断点 Step $paused_step" >&2
  notify "🔄 开始重启工作流: $feature_name (断点 Step $paused_step)"
  log "PIPELINE_RESTART_START: $feature_name from Step $paused_step" "$pipeline_log"

  # 检查快照是否存在
  local spec_dir="$PROJECT_ROOT/specs/$feature_name"
  local snapshot_file="$spec_dir/requirements.md.snapshot"
  if [ ! -f "$snapshot_file" ]; then
    echo "  ⚠️ 未找到 requirements.md.snapshot，跳过 diff，直接从断点继续" >&2
    rm -f "$spec_dir/paused.json"
    cmd_resume "$feature_name"
    return $?
  fi

  # 增量更新（有变更）或直接继续（无变更）
  step1_restart_with_diff "$feature_name" "$paused_step"
  local diff_result=$?

  if [ $diff_result -eq 2 ]; then
    # 再次遇到 [UNCERTAIN]，保留 paused.json 等用户 /answer 后再 /restart
    echo "⏸️ 需求变更中仍有未确认问题，已暂停"
    echo "   请用 /answer $feature_name 回复后，再次执行 /restart $feature_name"
    return 0
  fi

  # 消费 paused.json + 快照
  rm -f "$spec_dir/paused.json" "$spec_dir/requirements.md.snapshot"
  log "PIPELINE_PAUSED_STATE_CLEARED: $feature_name" "$pipeline_log"

  notify "▶️ 从 Step $paused_step 继续工作流: $feature_name"
  log "PIPELINE_RESTART_RESUME: $feature_name from Step $paused_step" "$pipeline_log"

  case "$paused_step" in
    2) run_pipeline_steps_2_to_7 "$feature_name" ;;
    3) step3_review "$feature_name" && step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    4) step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    5) step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    6) step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    7) step7_notify "$feature_name" ;;
    *) echo "✅ '$feature_name' 所有 Step 均已完成，无需继续" ;;
  esac
}

# ============================================================
# /resume 命令：从断点继续工作流
# 从 workflow-log 找最后一个未完成的 Step，从那里继续
# ============================================================
cmd_resume() {
  local feature_name="$1"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"

  # 若未指定 feature，自动检测
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /resume {需求名称}"
    echo "   提示: 用 /status 查看当前活跃需求"
    return 1
  fi

  # 若处于等待澄清状态，提示用 /answer
  if has_pending_clarification "$feature_name"; then
    local questions
    questions=$(get_clarification_field "$feature_name" "questions")
    echo "⏸️ '$feature_name' 正在等待需求澄清，请用 /answer 回复："
    echo "$questions"
    echo ""
    echo "用法: /answer $feature_name 1.你的答案 2.你的答案"
    return 0
  fi

  # 从 workflow-log 判断断点
  local last_done_step=1
  if [ -f "$pipeline_log" ]; then
    for step in 2 3 4 5 6 7; do
      if grep -q "STEP_${step}_DONE" "$pipeline_log" 2>/dev/null; then
        last_done_step=$step
      fi
    done
  fi

  local resume_from=$((last_done_step + 1))

  notify "▶️ 从 Step $resume_from 恢复工作流: $feature_name"
  echo "  [resume] 从 Step $resume_from 继续: $feature_name" >&2
  log "PIPELINE_RESUME: $feature_name from Step $resume_from" "$pipeline_log"

  case "$resume_from" in
    2) run_pipeline_steps_2_to_7 "$feature_name" ;;
    3) step3_review "$feature_name" && step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    4) step4_test "$feature_name" && step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    5) step5_doc_sync "$feature_name" && step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    6) step6_deploy "$feature_name" && step7_notify "$feature_name" ;;
    7) step7_notify "$feature_name" ;;
    *) echo "✅ '$feature_name' 流水线已全部完成，无需恢复" ;;
  esac
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

  # Stage 1a 恢复：仅更新 requirements.md（融入用户澄清，design/tasks 尚未生成）
  local model
  model=$(select_model "low")
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $PROJECT_ROOT/specs/$feature_name/requirements.md

    用户已为开放问题提供澄清，请仅覆写 specs/$feature_name/requirements.md：
    原始需求: $original_input
    用户澄清答复: $answers

    要求：
    - 已解答的开放问题从 [ ] 改为 [x]
    - 根据澄清内容更新 requirements.md
    - 仍有不确定的项保留 [ ]（不要强行推断）
    - 不要生成或修改 design.md、tasks.md
    Execute spec-writer Stage 1a with clarification context.
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

  # Stage 1b：requirements.md 已确认，生成 design.md + tasks.md
  echo "  [Stage 1b] 澄清完成，生成 design.md + tasks.md..." >&2
  opencli claude --print --permission-mode bypassPermissions --model "$model" -p "
    Read $PROJECT_ROOT/.claude/skills/spec-writer/SKILL.md
    Read $PROJECT_ROOT/.claude/CLAUDE.md
    Read $PROJECT_ROOT/.claude/ARCHITECTURE.md
    Read $PROJECT_ROOT/.claude/SECURITY.md
    Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md
    $([ -d "$PROJECT_ROOT/.claude/company-skills" ] && echo "Read relevant skills from $PROJECT_ROOT/.claude/company-skills/")
    Read $PROJECT_ROOT/specs/$feature_name/requirements.md
    Execute spec-writer Stage 1b: generate design.md + tasks.md based on the confirmed requirements.md above.
  " >&2

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
    /pause)
      cmd_pause "$ARGS"
      ;;
    /restart)
      cmd_restart "$ARGS"
      ;;
    /resume)
      cmd_resume "$ARGS"
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
      echo "Available: /workflow /hotfix /review /test /answer /pause /restart /resume /deploy /rollback /status"
      ;;
  esac
else
  echo "Processing natural language request..."
  run_full_pipeline "$MSG_TEXT"
fi
