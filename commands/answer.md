---
description: 答复 Step 1 开放问题（[UNCERTAIN]），恢复暂停的工作流
argument-hint: <需求名称> <你的答复>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /answer — 答复 Step 1 开放问题，恢复暂停的工作流

## 触发条件

当 Step 1 生成的 `requirements.md` 中存在 `[UNCERTAIN]` 问题时，工作流自动暂停并通过飞书发送待确认问题列表。收到通知后，使用此命令提供答复。

## 用法

```
/answer {需求名称} {你的答复}
```

## 示例

飞书通知：
```
⏸️ Step 1 已暂停 — 需确认 2 个问题后才能继续

1. 用户认证方式是 OAuth（Google/GitHub）还是自建账号系统？
2. 是否有 Figma 设计稿，还是需要 AI 自行设计 UI？

回复: `/answer user-register-page 1.你的答案 2.你的答案`
```

用户回复：
```
/answer user-register-page 1.自建账号，支持邮箱+密码注册 2.没有设计稿，AI 自行设计
```

工作流自动恢复，将答复融入文档后继续执行。

## 注意

- `{需求名称}` 必须与暂停通知中提示的名称完全一致（英文 kebab-case）
- 答复按问题编号顺序提供，用空格分隔
- 如果答复后仍有未解决的问题，工作流会再次暂停并询问
- 使用 `/status` 可查看当前哪些需求处于暂停等待状态
