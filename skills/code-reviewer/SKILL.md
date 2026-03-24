---
name: code-reviewer
description: >
  通过 OpenCLI 调度 Codex 进行两轮代码审查。第一轮发现问题并生成修复指令，
  Claude Code 修复后第二轮验证修复是否引入新问题。使用可替换的 checklist 评分。
  触发条件：代码审查、PR review、"review code"、"审查"、编排器 review 阶段。
---

# code-reviewer — 两轮审查 + 修复循环

你是代码审查代理。你执行**两轮**独立审查，确保修复不引入新问题。

## 审查流程

```
Claude Code 提交代码
       |
  Round 1：发现问题
       |
  有 CRITICAL/ERROR？
     /        \
   yes          no
    |            |
  生成修复指令     记录 Round 1 无阻断问题
  → Claude Code 修复   |
    |                  |
    └──────→ Round 2：验证修复/验证无问题结论 + 检查新问题
    |
  仍有问题？
     /        \
   yes          no → PASS
    |
  报告给编排器（人工介入或重试）
```

## Round 1：完整审查

```bash
# 获取变更 diff
git diff --name-only HEAD~{n}..HEAD > /tmp/changed-files.txt
git diff HEAD~{n}..HEAD > /tmp/changes.diff

# OpenCLI 调度 Codex 第一轮审查
codex exec --full-auto "
  审查以下代码变更。
  
  Diff:
  $(cat /tmp/changes.diff)

  审查标准:
  $(cat references/review-checklist.md)

  项目安全规范:
  $(cat .claude/SECURITY.md)

  项目编码规范:
  $(cat .claude/CODING_GUIDELINES.md)

  对每个发现，按以下格式输出:
  SEVERITY: CRITICAL | ERROR | WARNING | INFO
  FILE: {filepath}:{line}
  RULE: {rule-id}
  DESCRIPTION: {问题描述}
  FIX: {具体修复指令，Claude Code 可直接执行}
"
```

## Fix 阶段

Round 1 发现 CRITICAL 或 ERROR 时，生成修复任务：

```markdown
### Fix-001：{来自 Round 1 的问题描述}
- 文件：{filepath}:{line}
- 修复指令：{具体操作}
```

将修复任务交给 Claude Code 执行，修复后进入 Round 2。

## Round 2：验证审查

Round 2 是**强制阶段**，即使 Round 1 没有 CRITICAL/ERROR 也必须执行。
第二轮至少要做两件事：
- 验证 Round 1 的结论是否站得住
- 再扫一遍，确认没有遗漏和修复引入的新问题

```bash
# 对比 Round 1 和修复后的 diff；如果 Round 1 无修复，也重新审查当前 diff
git diff HEAD~1..HEAD > /tmp/fix-diff.diff

# OpenCLI 调度 Codex 第二轮审查
codex exec --full-auto "
  这是第二轮审查。上一轮发现了以下问题并已修复：
  {Round 1 的 CRITICAL/ERROR 列表}

  当前修复的 diff:
  $(cat /tmp/fix-diff.diff)

  检查:
  1. 上轮的问题是否已正确修复
  2. 修复是否引入了新的 CRITICAL 或 ERROR
  3. 其他区域是否受到影响

  仅输出新发现或未修复的问题。
  如果全部修复且无新问题，输出: ALL_CLEAR
"
```

## 审查报告

```markdown
# 审查报告：{需求名称}

> 时间：{YYYY-MM-DD HH:mm}
> 审查工具：opencli → codex
> 轮次：{1 或 2}

## Round 1
- CRITICAL: {count}
- ERROR: {count}
- WARNING: {count}

## 修复
- 修复了 {count} 个 CRITICAL/ERROR

## Round 2
- 新增问题: {count}
- 未修复: {count}

## 结论：PASS | FAIL

ROUND_1_STATUS: PASS | FAIL
ROUND_2_STATUS: PASS | FAIL
FINAL_VERDICT: PASS | FAIL
```

## Checklist 替换

`references/` 下可用的 checklist：
- `review-checklist.md` — 标准代码审查（默认）
- `security-checklist.md` — OWASP 安全审计
- `performance-checklist.md` — 性能审查

替换 checklist 即可获得不同类型的审计，skill 逻辑不变。
