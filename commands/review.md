---
description: 仅执行代码审查流程（Step 3）
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /review

## 作用

单独触发代码审查（Step 3），不启动完整流水线。执行两轮 Codex 审查 + Claude 修复循环。

## 适用场景

- 审查失败修完代码后，只想重跑审查而不重跑整个流程
- 只想审查现有代码，不涉及 spec 和测试
- 配合 `/test` 使用，先审查再测试

## 与其他命令的区别

| 命令 | 适用情况 |
|------|---------|
| `/review` | 只跑 Step 3 代码审查 |
| `/test` | 只跑 Step 4 测试 |
| `/start` | 从 Step 0 开始跑完整流水线（含审查） |

## 用法

```
/review
/review user-login
```

不传参数时自动检测当前活跃的需求。

---

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/review $ARGUMENTS"`

执行后总结真实审查结果，包含两轮审查的详细信息。
