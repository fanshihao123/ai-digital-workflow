---
description: 启动 hotfix 快速修复流程
argument-hint: <修复描述>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /hotfix

如果 `$ARGUMENTS` 为空，提示用户补充修复描述并停止。

必须真实转发到编排器脚本，而不是手工模拟：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/hotfix $ARGUMENTS"`

执行后总结真实产物与结果，并给出阶段性信息。
