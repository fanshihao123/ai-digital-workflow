---
description: 查看当前 workflow 状态
allowed-tools: Read, Glob, Grep, Bash
model: haiku
---

# /status

读取当前项目的 `specs/`、最近任务文件、测试报告和相关日志，给出当前 workflow 状态摘要：
- 当前 feature
- 总任务数 / 已完成 / 失败 / pending
- 最近一次测试结果
- 最近一次审查结果
- 当前阻塞点

优先读取：
- `specs/*/tasks.md`
- `specs/*/test-report.md`
- `.claude/logs/`
- `.claude/orchestrator/SKILL.md`
