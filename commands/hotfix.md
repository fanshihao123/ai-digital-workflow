---
description: 启动 hotfix 快速修复流程（跳过 Spec 审查和澄清机制）
argument-hint: <修复描述>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /hotfix

## 作用

启动精简版流水线，专为紧急修复设计。跳过以下环节：
- ❌ Codex Spec 审查（Stage 2）
- ❌ `[UNCERTAIN]` 开放问题检测和暂停
- ❌ Claude 复审定稿（Stage 3）

保留的环节：
- ✅ 生成 requirements.md + design.md + tasks.md
- ✅ 开发执行（Step 2）
- ✅ 代码审查（Step 3）
- ✅ 测试（Step 4）
- ✅ 文档同步 + 部署 + 通知（Step 5-7）

## 适用场景

- 线上 bug 紧急修复，不想等完整 Spec 审查
- 已经非常明确的小修改，不需要三阶段交叉审查
- 时间紧迫，快速走完流水线

## 与 `/start` 的区别

| | `/start` | `/hotfix` |
|---|---|---|
| Spec 审查 | ✅ 三阶段交叉审查 | ❌ 跳过 |
| 开放问题暂停 | ✅ 检测 [UNCERTAIN] | ❌ 跳过 |
| 适用场景 | 正常需求 | 紧急修复 |
| 速度 | 慢（完整审查） | 快（直接开发） |

## 用法

```
/hotfix 修复用户登录页面500报错
/hotfix Fix TypeError in payment processing
```

如果 `$ARGUMENTS` 为空，提示用户补充修复描述并停止。

---

必须真实转发到编排器脚本，而不是手工模拟：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/hotfix $ARGUMENTS"`

执行后总结真实产物与结果，并给出阶段性信息。
