---
description: 启动 hotfix 快速修复流程
argument-hint: <修复描述>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /hotfix

用户请求：$ARGUMENTS

按 `.claude/CLAUDE.md` 和 `.claude/orchestrator/SKILL.md` 的 hotfix 语义执行：跳过完整设计评审，以最短路径完成修复、验证、汇报。

必须读取：
- `.claude/CLAUDE.md`
- `.claude/SECURITY.md`
- `.claude/CODING_GUIDELINES.md`
- `.claude/orchestrator/SKILL.md`
- `.claude/skills/code-reviewer/SKILL.md`
- `.claude/skills/test-runner/SKILL.md`

如果 `$ARGUMENTS` 为空，要求用户补充修复描述。
