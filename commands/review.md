---
description: 仅执行代码审查流程
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /review

仅执行代码审查阶段。

必须读取并遵循：
- `.claude/CLAUDE.md`
- `.claude/SECURITY.md`
- `.claude/CODING_GUIDELINES.md`
- `.claude/skills/code-reviewer/SKILL.md`

输出两轮审查结果、发现的问题、修复状态和最终结论。
