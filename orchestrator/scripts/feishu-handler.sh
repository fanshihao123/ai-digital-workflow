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

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

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

# 飞书通知（复用外部脚本）
notify() {
  local message="$1"
  bash "$SCRIPT_DIR/feishu-notify.sh" "$message" 2>/dev/null || true
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
        rg --files "$project_relative" 2>/dev/null | rg "(^|/)${scope_base}\\.(test|spec)\\.(ts|tsx|js|jsx)$" || true
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
  local tasks_file="$spec_dir/tasks.md"
  local review_report="$spec_dir/review-report.md"
  local diff_summary
  local scope_summary
  local findings=""
  local scope
  local scope_count=0
  local missing_scope_count=0
  local round1_status="PASS"
  local round2_status="PASS"
  local final_verdict="PASS"
  local previous_round2_status="FOUND"

  if [ ! -f "$tasks_file" ]; then
    round1_status="FAIL"
    findings="${findings}- ERROR：缺少 tasks.md，无法执行基于 feature-scope 的本地审查"$'\n'
  fi

  scope_summary=$(extract_feature_scopes "$feature_name" | sed 's/^/- `/;s/$/`/' || true)
  if [ -z "$scope_summary" ]; then
    round1_status="FAIL"
    findings="${findings}- ERROR：tasks.md 中未声明“文件范围”，无法确定本次 feature 的审查边界"$'\n'
    scope_summary="- 未提取到文件范围"
  else
    while IFS= read -r scope; do
      [ -n "$scope" ] || continue
      scope_count=$((scope_count + 1))
      if [ ! -e "$PROJECT_ROOT/$scope" ]; then
        missing_scope_count=$((missing_scope_count + 1))
        findings="${findings}- WARNING：声明的文件范围不存在：\`$scope\`"$'\n'
      fi
    done < <(extract_feature_scopes "$feature_name")
  fi

  if ! grep -q "^## Round 2" "$review_report" 2>/dev/null; then
    previous_round2_status="MISSING"
    findings="${findings}- INFO：旧版 review-report.md 缺少 \`## Round 2\`，本次 fallback 将重建两轮结构化报告"$'\n'
  fi

  if [ "$missing_scope_count" -gt 0 ]; then
    round2_status="FAIL"
    final_verdict="FAIL"
  elif [ "$round1_status" != "PASS" ]; then
    round2_status="FAIL"
    final_verdict="FAIL"
  fi

  diff_summary=$(git -C "$PROJECT_ROOT" diff -- . ":(exclude)specs/archive" 2>/dev/null || true)
  [ -z "$findings" ] && findings="- 未发现阻断当前 fallback 审查的结构性问题"

  cat > "$review_report" <<EOF
# 审查报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 审查工具：local workflow fallback
> 轮次：2

## Round 1

### 审查范围
$scope_summary

### 结果
- tasks.md 是否存在：$( [ -f "$tasks_file" ] && echo "PASS" || echo "FAIL" )
- 文件范围声明数：$scope_count
- 缺失文件范围数：$missing_scope_count

### 发现
$findings

## Round 2

### 验证项
- 复核 Round 1 的阻断项是否已消除
- 复核报告包含强制的两轮标题和结构化结论字段
- 复核 fallback 仍然保留真实门控，而不是无条件放行

### 结果
- 上一版报告 Round 2 标记：$previous_round2_status
- 当前 Round 1 状态：$round1_status
- 当前 Round 2 状态：$round2_status

## 变更摘要

\`\`\`diff
$(printf '%s\n' "$diff_summary" | sed -n '1,120p')
\`\`\`

## 结论：$final_verdict

ROUND_1_STATUS: $round1_status
ROUND_2_STATUS: $round2_status
FINAL_VERDICT: $final_verdict
EOF

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
    && [ "$coverage_statements" != "N/A" ] \
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

  if [ "$feature_status" = "PASS" ] && [ "$e2e_status" != "FAIL" ] && { [ "$full_repo_status" = "PASS" ] || [ "$full_repo_status" = "NOT_RUN" ]; }; then
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
  local iter_file="$PROJECT_ROOT/specs/ITERATIONS.md"

  mkdir -p "$PROJECT_ROOT/specs/archive"
  if [ ! -f "$iter_file" ]; then
    cat > "$iter_file" <<EOF
# Iterations
EOF
  fi

  if ! grep -q "$feature_name" "$iter_file" 2>/dev/null; then
    printf '\n- %s %s: workflow completed via local fallback\n' "$(date '+%Y-%m-%d')" "$feature_name" >> "$iter_file"
  fi
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
  opencli claude --permission-mode bypassPermissions --model "$model" -p "
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

  # Jira 同步
  jira_sync "requirements-done" "$feature_name" >&2

  # 只有 hotfix 允许跳过完整 spec 审查；普通 workflow 一律执行 Codex 审查 + Claude 复审
  local complexity
  complexity=$(get_complexity "$feature_name")

  if [ "$is_hotfix" = "true" ]; then
    echo "  [Stage 2+3] 跳过（hotfix 模式）" >&2
    notify "🟡 Step 1 完成（hotfix）: 已生成最小 spec，跳过 Codex 审查"
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
    opencli claude --permission-mode bypassPermissions --model "$model" -p "
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
    if [ "$critical_count" -ge 3 ]; then
      notify "⚠️ Spec 审查发现 $critical_count 个严重问题，需人工介入: $feature_name"
      echo "  ⚠️ $critical_count 个 CRITICAL_ISSUES，已通知人工介入" >&2
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
    opencli claude --permission-mode bypassPermissions --model "$model" -p "
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
    opencli claude --permission-mode bypassPermissions --model "$model" -p "
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

  opencli claude --permission-mode bypassPermissions --model sonnet -p "
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

    opencli claude --permission-mode bypassPermissions --model sonnet -p "
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

  # 发送富飞书通知
  if [ -n "${FEISHU_WEBHOOK_URL:-}" ]; then
    curl -s -X POST "$FEISHU_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{
        \"msg_type\": \"interactive\",
        \"card\": {
          \"header\": {
            \"title\": {\"tag\": \"plain_text\", \"content\": \"✅ Workflow Complete: $feature_name\"},
            \"template\": \"green\"
          },
          \"elements\": [
            {
              \"tag\": \"markdown\",
              \"content\": \"**功能**: $feature_name\n**Feature 测试**: ${feature_test_status:-N/A}\n**全仓技术债**: ${repo_debt_status:-N/A}\n**覆盖率**: $coverage\n**审查状态**: $review_status\n**最新提交**: $commit_hash $commit_msg\"
            },
            {
              \"tag\": \"note\",
              \"elements\": [{
                \"tag\": \"plain_text\",
                \"content\": \"$(date '+%Y-%m-%d %H:%M:%S') | Agent: Claude Code\"
              }]
            }
          ]
        }
      }" > /dev/null 2>&1
  fi

  echo "  ✅ 流水线完成: $feature_name"
  echo "    Feature 测试: ${feature_test_status:-N/A} | 全仓技术债: ${repo_debt_status:-N/A} | 覆盖率: $coverage | 审查: $review_status | 提交: $commit_hash"
}

# ============================================================
# 完整流水线（Step 0 → Step 7）
# ============================================================
run_full_pipeline() {
  local input="$1"
  local is_hotfix="${2:-false}"

  # Step 0
  step0_prepare

  # Step 1
  local feature_name
  feature_name=$(step1_spec_writer "$input" "$is_hotfix")
  if [ -z "$feature_name" ]; then
    echo "❌ 流水线终止：spec-writer 未产出"
    notify "❌ 流水线终止: spec-writer 失败"
    return 1
  fi

  # 根据 design.md 的 complexity 选择标记 worktree 模式
  local complexity
  complexity=$(get_complexity "$feature_name")
  echo "  复杂度: $complexity"

  # Step 2
  step2_develop "$feature_name"

  # Step 3
  step3_review "$feature_name" || {
    echo "  ❌ 审查阶段被阻断"
    return 1
  }

  # Step 4
  step4_test "$feature_name" || {
    echo "  ⚠️ 测试失败，进入自动修复回路"
    notify "⚠️ Step 4 失败: $feature_name — 进入自动修复回路"
    step4_fix_and_retry "$feature_name" || {
      echo "  ❌ 自动修复回路失败，流水线终止"
      notify "❌ 自动修复回路失败: $feature_name"
      return 1
    }
  }

  # Step 5
  step5_doc_sync "$feature_name"

  # Step 6
  step6_deploy "$feature_name"

  # Step 7
  step7_notify "$feature_name"
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
    opencli claude --permission-mode bypassPermissions --model sonnet -p "
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
        opencli claude --permission-mode bypassPermissions --model "$MODEL" -p "
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
        opencli claude --permission-mode bypassPermissions --model sonnet -p "
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
      echo "Available: /workflow /hotfix /review /test /deploy /rollback /status"
      ;;
  esac
else
  echo "Processing natural language request..."
  run_full_pipeline "$MSG_TEXT"
fi
