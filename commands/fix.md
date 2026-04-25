---
description: 根据用户指导修复 Spec 审查严重问题（别名: /fix-spec）
argument-hint: <需求名称> <修改指导>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /fix

## 作用

当 Codex 审查发现严重问题（CRITICAL >= 3）并自动暂停后，用自然语言描述修改方向，
Claude 自动修改三文档（requirements.md, design.md, tasks.md）并重新审查。

## 用法

```
/fix user-login 1.去掉短信验证 2.用JWT替换session
```

## 流程

```
/fix {需求名称} {修改指导}
    ↓
Claude 读取 spec-review.md + 用户指导
    ↓
自动修改三文档
    ↓
重新 Codex 审查
    ↓
通过？ → 继续 Steps 2-7
不通过？ → 再次通知用户，可继续 /fix
```

---

不要手工模拟 workflow，必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/fix $ARGUMENTS"`

执行后说明修复结果和审查是否通过。
