#!/bin/bash
# AI数字员工24小时可编排工作流 v3 — 项目初始化
# 4 核心 skill + 4 可插拔扩展
# 用法: bash init-project.sh /path/to/your/project

set -euo pipefail
PROJECT_ROOT="${1:-.}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🤖 AI数字员工24小时可编排工作流 v3 — 初始化: $PROJECT_ROOT"
echo "=================================================="

mkdir -p "$PROJECT_ROOT/.claude"/{skills,extensions,orchestrator,logs}
mkdir -p "$PROJECT_ROOT/specs/archive"

echo "🧠 安装 4 个核心 skill..."
for s in spec-writer code-reviewer test-runner doc-syncer; do
  cp -r "$SRC/skills/$s" "$PROJECT_ROOT/.claude/skills/"
  echo "  ✅ $s"
done

echo "🔌 安装 5 个可插拔扩展..."
for e in worktree-parallel deploy-executor jira-sync human-gate ui-restorer; do
  cp -r "$SRC/extensions/$e" "$PROJECT_ROOT/.claude/extensions/"
  echo "  ✅ $e"
done

echo "⚙️  安装编排器..."
cp -r "$SRC/orchestrator/"* "$PROJECT_ROOT/.claude/orchestrator/"
cp "$SRC/orchestrator/assets/hooks.json" "$PROJECT_ROOT/.claude/hooks.json" 2>/dev/null || true
chmod +x "$PROJECT_ROOT/.claude/orchestrator/scripts/"*.sh 2>/dev/null || true
chmod +x "$PROJECT_ROOT/.claude/extensions/"*/scripts/*.sh 2>/dev/null || true

echo "📚 检查知识库文件..."
for f in CLAUDE.md ARCHITECTURE.md SECURITY.md CODING_GUIDELINES.md; do
  [ ! -f "$PROJECT_ROOT/.claude/$f" ] && echo "# $f" > "$PROJECT_ROOT/.claude/$f" && echo "  ✅ 创建 $f"
done

if [ ! -f "$PROJECT_ROOT/.env.ai-digital-workflow" ]; then
  cat > "$PROJECT_ROOT/.env.ai-digital-workflow" << 'EOF'
# ==========================================
# AI数字员工24小时可编排工作流 v3 配置
# ==========================================

# --- 飞书 ---
FEISHU_APP_ID=
FEISHU_APP_SECRET=
FEISHU_WEBHOOK_URL=

# --- 可插拔扩展开关 ---
ENABLE_WORKTREE_PARALLEL=false
ENABLE_DEPLOY=false
ENABLE_UI_RESTORER=false

# --- Figma MCP（ENABLE_UI_RESTORER=true 时使用）---
# FIGMA_API_KEY=figd_xxx

# --- 飞书审批（配置后自动启用 human-gate）---
# FEISHU_APPROVAL_CODE=
# FEISHU_APPROVER_ID=
# HITL_TIMEOUT=3600

# --- Jira（配置后自动启用 jira-sync）---
# JIRA_BASE_URL=
# JIRA_TOKEN=
# JIRA_USER_EMAIL=

# --- 公司 skills（配置后自动加载）---
# COMPANY_SKILLS_GIT=https://github.com/your-org/skills.git
# COMPANY_SKILLS_BRANCH=main

# --- 部署（ENABLE_DEPLOY=true 时使用）---
# DEPLOY_STRATEGY=push
# DEPLOY_HEALTH_URL=http://localhost:3000/health

# --- OpenCLI + Codex ---
# OPENAI_API_KEY=
EOF
  echo "  ✅ 创建 .env.ai-digital-workflow"
fi

echo ""
echo "=================================================="
echo "🎉 AI数字员工24小时可编排工作流 初始化完成！"
echo ""
echo "  核心 skill (始终运行)："
echo "    spec-writer     需求+设计+任务一站式生成"
echo "    code-reviewer   OpenCLI→Codex 两轮审查"
echo "    test-runner     Jest + Playwright + Chrome MCP"
echo "    doc-syncer      文档同步 + 迭代归档"
echo ""
echo "  可插拔扩展 (按需启用)："
echo "    worktree-parallel  ENABLE_WORKTREE_PARALLEL=true"
echo "    deploy-executor    ENABLE_DEPLOY=true"
echo "    ui-restorer        ENABLE_UI_RESTORER=true  ← Antigravity+Figma"
echo "    human-gate         配置 FEISHU_APPROVAL_CODE"
echo "    jira-sync          配置 JIRA_BASE_URL + JIRA_TOKEN"
echo ""
echo "  下一步："
echo "    1. 编辑 .claude/*.md 填入项目信息"
echo "    2. cp .env.ai-digital-workflow .env && vim .env"
echo "    3. 测试: claude '/start-workflow 添加用户登录'"
echo "=================================================="
