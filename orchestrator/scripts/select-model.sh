#!/bin/bash
# select-model.sh — 根据复杂度选择 Claude 模型，额度不足自动降级
# 用法: source select-model.sh <complexity>
# 输出: CLAUDE_MODEL 环境变量

COMPLEXITY="${1:-low}"

if [ "$COMPLEXITY" = "high" ]; then
  # 高复杂度 → 尝试 Opus 4.6
  opencli claude --permission-mode bypassPermissions --model opus -p "echo ok" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    export CLAUDE_MODEL="opus"
    echo "🧠 模型选择: Claude Opus 4.6 (complexity: high)"
  else
    export CLAUDE_MODEL="sonnet"
    echo "⚠️ Opus 4.6 不可用(额度不足)，降级: Claude Sonnet"
  fi
else
  # 低/中复杂度 → 直接 Sonnet
  export CLAUDE_MODEL="sonnet"
  echo "🧠 模型选择: Claude Sonnet (complexity: $COMPLEXITY)"
fi
