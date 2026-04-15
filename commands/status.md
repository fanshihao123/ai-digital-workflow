---
description: 查看当前 workflow 状态
allowed-tools: Read, Glob, Grep, Bash
model: haiku
---

# /status

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/status"`

如果脚本输出不足，再读取 `$WORKFLOW_DATA_DIR/` 和相关日志补充总结。
