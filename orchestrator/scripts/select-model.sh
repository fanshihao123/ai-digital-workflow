#!/bin/bash
# select-model.sh — 根据复杂度选择 Claude 模型，额度不足自动降级
# 用法: source select-model.sh <complexity>
# 输出: CLAUDE_MODEL 环境变量
#
# 策略：高复杂度先选 opus，实际执行时如果失败再由调用方 fallback 到 sonnet。
# 不再做空探测请求浪费 token。

COMPLEXITY="${1:-low}"

if [ "$COMPLEXITY" = "high" ]; then
  export CLAUDE_MODEL="opus"
  echo "🧠 模型选择: Claude Opus 4.6 (complexity: high，执行失败时自动降级)"
else
  export CLAUDE_MODEL="sonnet"
  echo "🧠 模型选择: Claude Sonnet (complexity: $COMPLEXITY)"
fi
