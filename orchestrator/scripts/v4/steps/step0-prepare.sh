#!/bin/bash
# step0-prepare.sh — Step 0: 环境准备 + 知识加载
# Sourced by v4/handler.sh; all lib modules already loaded

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

  # D. 检查全局 LESSONS.md（跨 feature 经验沉淀）
  if [ -f "$WORKFLOW_DATA_DIR/LESSONS.md" ]; then
    local lessons_entries
    lessons_entries=$(grep -c "^## " "$WORKFLOW_DATA_DIR/LESSONS.md" 2>/dev/null || echo 0)
    echo "  已加载全局 LESSONS.md ($lessons_entries 条经验记录)"
  fi
}
