---
description: 仅执行测试流程
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /test

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/test"`

执行后总结真实测试结果。
必须区分 feature-scope 是否通过，以及是否只是被全仓历史技术债拖累。
