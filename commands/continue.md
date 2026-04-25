---
description: 从 /pause 状态继续，自动检测需求变更并最小粒度更新（别名: /restart）
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /continue

## 作用

从 `/pause` 暂停状态继续工作流。自动 diff requirements.md 与快照，
有变更则最小粒度更新 design.md + tasks.md，无变更则直接从断点继续。

## 流程

```
/continue
    ↓
对比 requirements.md vs 快照
    ↓
有变更？
  ├── 是 → Stage 1a': 模型润色规范化 requirements.md
  │              ↓
  │         检测 [UNCERTAIN] → 有则暂停询问（/answer 后再 /continue）
  │              ↓
  │         Stage 1b': 最小粒度更新 design.md + tasks.md（diff 驱动）
  │              ↓
  │         从 Step 2 继续
  └── 否 → 直接从断点继续
```

## 最小粒度更新说明

Stage 1b' 只修改受 diff 影响的部分：
- 新增需求 → 追加对应 design 章节和 task 条目
- 删除需求 → 移除对应内容
- 修改需求 → 就地更新受影响部分
- 未变动部分 → 原样保留，不重写

## 用法

```
# 自动检测
/continue

# 指定需求名称
/continue user-registration
```

## 注意

- 必须先执行 `/pause` 才能 `/continue`
- 若处于 `/answer` 等待澄清状态，需先回复 `/answer` 再 `/continue`

---

不要手工模拟 workflow，必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/continue $ARGUMENTS"`

执行后说明：需求是否有变更、从哪个 Step 继续、跳过了哪些步骤。
