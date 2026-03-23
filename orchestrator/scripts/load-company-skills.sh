#!/bin/bash
# load-company-skills.sh — 加载公司 skills 知识库
# 支持两种来源：Git 仓库 或 本地目录
# 用法: bash load-company-skills.sh [--git <url>] [--local <path>] [--branch <branch>]

set -euo pipefail

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SKILLS_CACHE="$PROJECT_ROOT/.claude/company-skills"
LOG_FILE="$PROJECT_ROOT/.claude/logs/skills-sync-$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "$LOG_FILE")"

[ -f "$PROJECT_ROOT/.env" ] && set -a && source "$PROJECT_ROOT/.env" && set +a

# 默认值（可在 .env 中覆盖）
GIT_URL="${COMPANY_SKILLS_GIT:-}"
LOCAL_PATH="${COMPANY_SKILLS_LOCAL:-}"
GIT_BRANCH="${COMPANY_SKILLS_BRANCH:-main}"

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --git) GIT_URL="$2"; shift 2 ;;
    --local) LOCAL_PATH="$2"; shift 2 ;;
    --branch) GIT_BRANCH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "📚 加载公司 skills 知识库..."

# ------------------------------------------
# 来源 1：Git 仓库
# ------------------------------------------
if [ -n "$GIT_URL" ]; then
  echo "  来源: Git ($GIT_URL, branch: $GIT_BRANCH)"

  if [ -d "$SKILLS_CACHE/.git" ]; then
    # 已存在 → pull 最新
    echo "  更新已缓存的仓库..."
    cd "$SKILLS_CACHE"
    git fetch origin "$GIT_BRANCH" --quiet 2>/dev/null
    git reset --hard "origin/$GIT_BRANCH" --quiet 2>/dev/null
    cd "$PROJECT_ROOT"
    echo "  ✅ 已更新到最新"
  else
    # 不存在 → clone
    echo "  克隆仓库..."
    rm -rf "$SKILLS_CACHE"
    git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_URL" "$SKILLS_CACHE" --quiet 2>/dev/null
    echo "  ✅ 克隆完成"
  fi

  echo "[$(date +%H:%M:%S)] SKILLS_SYNC: git pull from $GIT_URL ($GIT_BRANCH)" >> "$LOG_FILE"

# ------------------------------------------
# 来源 2：本地目录
# ------------------------------------------
elif [ -n "$LOCAL_PATH" ]; then
  echo "  来源: 本地 ($LOCAL_PATH)"

  if [ ! -d "$LOCAL_PATH" ]; then
    echo "  ❌ 目录不存在: $LOCAL_PATH"
    exit 1
  fi

  # 同步到缓存目录
  rm -rf "$SKILLS_CACHE"
  cp -r "$LOCAL_PATH" "$SKILLS_CACHE"
  echo "  ✅ 已同步"

  echo "[$(date +%H:%M:%S)] SKILLS_SYNC: local copy from $LOCAL_PATH" >> "$LOG_FILE"

# ------------------------------------------
# 无配置
# ------------------------------------------
else
  if [ -d "$SKILLS_CACHE" ]; then
    echo "  使用已缓存的 skills（未配置同步源）"
  else
    echo "  ⚠️ 未配置公司 skills 来源，跳过"
    echo "  配置方式："
    echo "    .env 中设置 COMPANY_SKILLS_GIT=https://github.com/your-org/skills.git"
    echo "    或 COMPANY_SKILLS_LOCAL=/path/to/local/skills"
    exit 0
  fi
fi

# ------------------------------------------
# 扫描并索引 skills
# ------------------------------------------
if [ -d "$SKILLS_CACHE" ]; then
  echo ""
  echo "  📋 可用的公司 skills："

  SKILL_COUNT=0
  SKILL_INDEX="$SKILLS_CACHE/.skill-index.json"
  echo "[" > "$SKILL_INDEX"

  find "$SKILLS_CACHE" -name "SKILL.md" -type f | sort | while read -r skill_file; do
    SKILL_DIR=$(dirname "$skill_file")
    SKILL_NAME=$(basename "$SKILL_DIR")

    # 提取 frontmatter 中的 name 和 description
    NAME=$(sed -n '/^---$/,/^---$/p' "$skill_file" | grep "^name:" | sed 's/^name:\s*//' | head -1)
    DESC=$(sed -n '/^---$/,/^---$/p' "$skill_file" | grep "^description:" | sed 's/^description:\s*//' | head -1)

    [ -z "$NAME" ] && NAME="$SKILL_NAME"
    [ -z "$DESC" ] && DESC="(无描述)"

    echo "    - $NAME: ${DESC:0:60}..."

    # 写入索引
    if [ $SKILL_COUNT -gt 0 ]; then echo "," >> "$SKILL_INDEX"; fi
    cat >> "$SKILL_INDEX" << EOF
  {
    "name": "$NAME",
    "dir": "$SKILL_DIR",
    "description": "${DESC:0:200}",
    "path": "$skill_file"
  }
EOF
    SKILL_COUNT=$((SKILL_COUNT + 1))
  done

  echo "]" >> "$SKILL_INDEX"

  TOTAL=$(find "$SKILLS_CACHE" -name "SKILL.md" -type f | wc -l)
  echo ""
  echo "  ✅ 共 $TOTAL 个公司 skills 已索引"
  echo "[$(date +%H:%M:%S)] SKILLS_INDEX: $TOTAL skills found" >> "$LOG_FILE"
fi
