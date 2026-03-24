---
description: 仅执行代码审查流程
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /review

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/review"`

执行后总结真实审查结果，并包含两轮审查信息。
