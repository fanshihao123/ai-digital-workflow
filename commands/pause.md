---
description: 手动暂停工作流，保存断点和 requirements.md 快照
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /pause

## 作用

主动暂停正在运行的工作流，保存当前断点位置和 requirements.md 快照。
暂停后可以修改需求，然后用 `/restart` 恢复。

## 适用场景

- 需求有变化，想修改 requirements.md 后再继续
- 临时中止当前工作流，稍后再处理

## 与其他命令的区别

| 命令 | 适用情况 |
|------|---------|
| `/pause` | 主动暂停，准备修改需求或稍后继续 |
| `/restart` | 从 `/pause` 状态恢复，自动检测需求是否有变更 |
| `/resume` | 从崩溃/意外中断恢复，不涉及需求变更 |

## 用法

```
# 自动检测当前活跃需求并暂停
/pause

# 指定需求名称
/pause user-registration
```

暂停后：
- 如需改需求：编辑 `$WORKFLOW_DATA_DIR/{feature}/requirements.md`，然后 `/restart {feature}`
- 不改需求：直接 `/restart {feature}`

---

不要手工模拟 workflow，必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/pause $ARGUMENTS"`

执行后说明暂停了哪个需求、断点在哪个 Step。
