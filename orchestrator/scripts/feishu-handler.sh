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

  # Stage 1: Claude 生成初稿
  echo "  [Stage 1] Claude 生成初稿..." >&2
  model=$(select_model "low")
  claude --model "$model" -p "
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

  # 跳过审查的条件：hotfix 或 (complexity:low 且 任务数 ≤ 2)
  local complexity
  complexity=$(get_complexity "$feature_name")
  local task_count
  task_count=$(grep -c "^### Task" "$PROJECT_ROOT/specs/$feature_name/tasks.md" 2>/dev/null || echo 0)

  if [ "$is_hotfix" = "true" ]; then
    echo "  [Stage 2+3] 跳过（hotfix 模式）" >&2
    echo "$feature_name"
    return 0
  fi

  if [ "$complexity" = "low" ] && [ "$task_count" -le 2 ]; then
    echo "  [Stage 2+3] 跳过（complexity:low 且任务数 ≤ 2）" >&2
    echo "$feature_name"
    return 0
  fi

  # Stage 2: OpenAI Codex 审查
  echo "  [Stage 2] OpenAI Codex 审查..." >&2
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
    echo "  ⚠️ codex 未安装，跳过 Stage 2" >&2
  fi

  # Stage 3: Claude 复审 + 定稿
  echo "  [Stage 3] Claude 复审 + 定稿..." >&2
  if [ -f "$PROJECT_ROOT/specs/$feature_name/spec-review.md" ]; then
    model=$(select_model "$complexity")
    claude --model "$model" -p "
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

  echo "$feature_name"
}

# ============================================================
# Step 2：开发执行（Agent 路由）
# ============================================================
step2_develop() {
  local feature_name="$1"
  local complexity
  complexity=$(get_complexity "$feature_name")

  echo "=== Step 2: 开发执行 ==="
  notify "💻 开始开发: $feature_name (complexity: $complexity)"

  # Jira 同步
  jira_sync "dev-start" "$feature_name"

  # 升级模型（如果 high complexity）
  local model
  model=$(select_model "$complexity")

  local tasks_file="$PROJECT_ROOT/specs/$feature_name/tasks.md"

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
  has_antigravity=$(grep -c "agent: antigravity" "$tasks_file" 2>/dev/null || echo 0)

  if [ "$has_antigravity" -gt 0 ] && [ "${ENABLE_UI_RESTORER:-false}" = "true" ]; then
    echo "  [ui-restorer] 检测到 $has_antigravity 个 antigravity 任务"
    # 先执行 antigravity 任务（UI 还原）
    claude --model "$model" -p "
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
    claude --model "$model" -p "
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
  local model

  echo "=== Step 3: code-reviewer ==="
  notify "🔍 开始代码审查: $feature_name"

  model=$(select_model "low")

  # Round 1: OpenCLI Codex 审查
  echo "  [Round 1] Codex 审查..."
  local review_result="PASS"
  if command -v codex &> /dev/null; then
    claude --model "$model" -p "
      Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
      Read $PROJECT_ROOT/.claude/SECURITY.md
      Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md

      Execute code-reviewer Round 1:
      - Get the diff of recent changes for feature '$feature_name'
      - Use codex exec to review the changes
      - Save review report to specs/$feature_name/review-report.md
      - If CRITICAL or ERROR found, generate fix instructions and apply fixes
      - Then run Round 2 to verify fixes
      - Save final verdict (PASS/FAIL) at end of review-report.md
    "
  else
    echo "  ⚠️ codex 未安装，使用 Claude 单轮审查..."
    claude --model "$model" -p "
      Read $PROJECT_ROOT/.claude/skills/code-reviewer/SKILL.md
      Read $PROJECT_ROOT/.claude/SECURITY.md
      Read $PROJECT_ROOT/.claude/CODING_GUIDELINES.md

      Review recent code changes for feature '$feature_name'.
      Check for CRITICAL/ERROR issues.
      If found, fix them and verify the fixes.
      Save review report to specs/$feature_name/review-report.md
    "
  fi

  # human-gate G1：安全门控（条件触发）
  human_gate_security "$feature_name" || return 1

  # Jira 同步
  jira_sync "review-done" "$feature_name"
}

# ============================================================
# Step 4：test-runner
# ============================================================
step4_test() {
  local feature_name="$1"

  echo "=== Step 4: test-runner ==="
  notify "🧪 开始测试: $feature_name"

  claude --model sonnet -p "
    Read $PROJECT_ROOT/.claude/skills/test-runner/SKILL.md

    Execute test-runner for feature '$feature_name':
    1. Run unit tests (Jest/Vitest) with coverage
    2. Run E2E tests (Playwright, prefer Chrome MCP if available)
    3. Generate test report to specs/$feature_name/test-report.md
    4. Check coverage thresholds (Statements ≥ 80%, Branches ≥ 75%, Functions ≥ 80%)
    5. Report PASS or FAIL with details
  "

  # Jira 同步
  jira_sync "test-done" "$feature_name"

  # 检查测试结果
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  if [ -f "$test_report" ] && grep -q "FAIL" "$test_report" 2>/dev/null; then
    echo "  ⚠️ 测试未通过"
    notify "❌ 测试失败: $feature_name\n查看 specs/$feature_name/test-report.md"
    return 1
  fi

  echo "  ✅ 测试通过"
}

# ============================================================
# Step 5：doc-syncer
# ============================================================
step5_doc_sync() {
  local feature_name="$1"

  echo "=== Step 5: doc-syncer ==="
  notify "📚 同步文档: $feature_name"

  claude --model sonnet -p "
    Read $PROJECT_ROOT/.claude/skills/doc-syncer/SKILL.md
    Read $PROJECT_ROOT/specs/$feature_name/requirements.md
    Read $PROJECT_ROOT/specs/$feature_name/design.md
    Read $PROJECT_ROOT/specs/$feature_name/tasks.md

    Execute doc-syncer for feature '$feature_name':
    1. Analyze changes and update project docs (.claude/ARCHITECTURE.md, README.md, etc.) if needed
    2. Archive specs to specs/archive/$(date +%Y-%m-%d)-$feature_name/
    3. Update specs/ITERATIONS.md
    4. Commit documentation changes
  "
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

    claude --model sonnet -p "
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
  local review_status="N/A"
  local commit_hash
  commit_hash=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%h" 2>/dev/null || echo "N/A")
  local commit_msg
  commit_msg=$(git -C "$PROJECT_ROOT" log --oneline -1 --format="%s" 2>/dev/null || echo "N/A")

  # 从测试报告提取覆盖率
  local test_report="$PROJECT_ROOT/specs/$feature_name/test-report.md"
  if [ -f "$test_report" ]; then
    coverage=$(grep -oP 'Statements\s*\|\s*\K\d+%' "$test_report" 2>/dev/null || echo "N/A")
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
              \"content\": \"**功能**: $feature_name\n**覆盖率**: $coverage\n**审查状态**: $review_status\n**最新提交**: $commit_hash $commit_msg\"
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
  echo "    覆盖率: $coverage | 审查: $review_status | 提交: $commit_hash"
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
    echo "  ⚠️ 测试失败，编排器决定是否回退 Step 2"
    notify "⚠️ 测试失败: $feature_name — 需人工决策是否回退"
    return 1
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
    claude --model sonnet -p "
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
        claude --model "$MODEL" -p "
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
        claude --model sonnet -p "
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
