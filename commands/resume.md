---
description: 从断点恢复工作流，跳过已完成的步骤继续执行
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /resume

## 作用

从上次中断的地方继续执行工作流，跳过已完成的步骤，不重头来过。
通过读取 `$WORKFLOW_DATA_DIR/.workflow-log` 判断最后完成的 Step，从下一步继续。

## 适用场景

- **网络抖动/超时**：某个 Step 因网络问题崩溃，已完成的步骤不需要重跑
- **进程被强杀**：服务器重启或手动 Ctrl+C 中断后恢复
- **不确定进度**：不知道跑到哪里了，自动检测断点继续

## 与其他命令的区别

| 命令 | 适用情况 |
|------|---------|
| `/resume` | 进程崩溃/中断，从断点继续 |
| `/answer` | 因 `[UNCERTAIN]` 主动暂停，提供澄清后继续 |
| `/start-workflow` | 全新需求，从头开始 |

## 用法

```
# 自动检测当前活跃需求的断点并继续
/resume

# 指定需求名称
/resume user-registration
```

## 特殊情况

若需求处于等待澄清暂停状态，`/resume` 不会强行继续，
而是展示待回答的问题并提示使用 `/answer`：

```
⏸️ 'user-registration' 正在等待需求澄清，请用 /answer 回复：
1. 注册是否需要手机号验证码？
2. 是否需要第三方登录？

用法: /answer user-registration 1.你的答案 2.你的答案
```

---

不要手工模拟 workflow，必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/resume $ARGUMENTS"`

执行后：
1. 说明从哪个 Step 恢复的，以及跳过了哪些已完成的步骤
2. 如果是等待澄清暂停状态，展示待回答的问题并提示用 /answer
3. 如果已全部完成，明确告知用户无需恢复
