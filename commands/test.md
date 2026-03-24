---
description: 仅执行测试流程
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /test

仅执行测试阶段。

必须读取并遵循：
- `.claude/CLAUDE.md`
- `.claude/skills/test-runner/SKILL.md`

输出：
- 执行了哪些测试
- 通过/失败统计
- 覆盖率（如可得）
- 关键失败项
- 最终 PASS / FAIL
