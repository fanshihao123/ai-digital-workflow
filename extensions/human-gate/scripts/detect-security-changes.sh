#!/bin/bash
# detect-security-changes.sh — 检测当前变更是否涉及安全敏感文件/代码
# 用法: bash detect-security-changes.sh <feature-name> [base-branch]
# 返回值: 0=需要安全门控, 1=不需要

set -euo pipefail

FEATURE_NAME="${1:?用法: detect-security-changes.sh <feature-name> [base-branch]}"
BASE_BRANCH="${2:-}"
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# 获取默认分支（不硬编码 main）
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
fi

# 安全敏感路径模式
SECURITY_PATTERNS=(
  'src/auth/'
  'src/middleware/auth'
  'src/middleware/cors'
  'src/middleware/csrf'
  'src/middleware/rate-limit'
  'src/security/'
  'src/crypto/'
  'config/security'
  'config/cors'
  'config/auth'
  '\.env'
  'docker-compose.*\.yml'
  'nginx.*\.conf'
  'Dockerfile'
  'src/guards/'
  'src/interceptors/auth'
  'lib/auth'
  'lib/security'
  'lib/crypto'
  'utils/auth'
  'utils/hash'
  'utils/encrypt'
  'utils/token'
)

# 安全敏感代码模式（更精确，减少误报）
SECURITY_CODE_PATTERNS=(
  'password\s*='
  'password\s*:'
  'setPassword\('
  'secret\s*='
  'secret\s*:'
  'SECRET_KEY'
  'private\.key'
  'jwt\.sign\('
  'jwt\.verify\('
  'bcrypt\.(hash|compare)'
  'crypto\.create'
  'createCipher\('
  'createHash\('
  'cors\(\{'
  'helmet\(\{'
  'csrf\('
  'sanitize\('
  'escape\('
  'sql.*\$\{'
  '\beval\('
  '\bexec\('
  'dangerouslySetInnerHTML'
  'innerHTML\s*='
  'document\.write\('
)

CHANGED_FILES=$(git diff --name-only "${BASE_BRANCH}..HEAD" 2>/dev/null || echo "")
DIFF_CONTENT=$(git diff "${BASE_BRANCH}..HEAD" 2>/dev/null || echo "")

TRIGGERED=false
SECURITY_FILES=""
SECURITY_CODE=""
REASONS=""

# 检查安全敏感文件路径
for pattern in "${SECURITY_PATTERNS[@]}"; do
  MATCHES=$(echo "$CHANGED_FILES" | grep -iE "$pattern" || true)
  if [ -n "$MATCHES" ]; then
    SECURITY_FILES="${SECURITY_FILES}${MATCHES}\n"
    TRIGGERED=true
  fi
done

# 检查 diff 中的安全敏感代码模式（排除测试文件和注释）
for pattern in "${SECURITY_CODE_PATTERNS[@]}"; do
  # 只检查新增行（^\+），排除测试文件、注释行
  MATCHES=$(echo "$DIFF_CONTENT" | grep -E "^\+.*${pattern}" | \
    grep -v -E '(__tests__|\.test\.|\.spec\.|\.md$)' | \
    grep -v -E '^\+\s*(//|#|\*|/\*)' || true)

  if [ -n "$MATCHES" ]; then
    SECURITY_CODE="${SECURITY_CODE}  - 检测到: ${pattern}\n"
    TRIGGERED=true
  fi
done

# 检查审查报告中的 SEC 发现
REVIEW_REPORT="$PROJECT_ROOT/specs/${FEATURE_NAME}/review-report.md"
if [ -f "$REVIEW_REPORT" ]; then
  SEC_COUNT=$(grep -c "SEC-" "$REVIEW_REPORT" 2>/dev/null || echo 0)
  if [ "$SEC_COUNT" -gt 0 ]; then
    REASONS="${REASONS}审查报告中有 ${SEC_COUNT} 个安全相关发现\n"
    TRIGGERED=true
  fi
fi

# 检查 design.md 安全章节
DESIGN_FILE="$PROJECT_ROOT/specs/${FEATURE_NAME}/design.md"
if [ -f "$DESIGN_FILE" ] && grep -qiE "安全考虑|Security Considerations" "$DESIGN_FILE"; then
  CONTENT=$(sed -n '/安全考虑\|Security Considerations/,/^##/p' "$DESIGN_FILE" | grep -v '^##' | grep -v '^$' | head -3)
  if [ -n "$CONTENT" ]; then
    REASONS="${REASONS}设计文档包含安全考虑章节\n"
    TRIGGERED=true
  fi
fi

# 输出结果
if [ "$TRIGGERED" = true ]; then
  echo "SECURITY_GATE_REQUIRED"
  echo "---"
  [ -n "$SECURITY_FILES" ] && echo -e "安全敏感文件:\n${SECURITY_FILES}"
  [ -n "$SECURITY_CODE" ] && echo -e "安全敏感代码:\n${SECURITY_CODE}"
  [ -n "$REASONS" ] && echo -e "其他原因:\n${REASONS}"
  exit 0
else
  echo "NO_GATE_REQUIRED"
  exit 1
fi
