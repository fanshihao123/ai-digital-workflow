---
description: 启动完整流水线（别名: /start-workflow, /workflow）
argument-hint: <需求描述或URL>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /start

## 作用

启动完整的 7 步流水线：环境准备 → 需求分析 → 开发 → 审查 → 测试 → 文档 → 部署/通知。

## 适用场景

- 新功能开发
- 正常需求迭代
- 从 URL（飞书文档、Jira 等）提取需求并执行

## 输入类型

- **文字描述**：`/start 添加用户注册页面，支持邮箱和手机号`
- **URL**：`/start https://your-jira.atlassian.net/browse/PROJ-123`（自动 Chrome MCP 抓取）

## 与 `/hotfix` 的区别

| | `/start` | `/hotfix` |
|---|---|---|
| Spec 三阶段审查 | ✅ Claude → Codex → Claude | ❌ 跳过 |
| 开放问题暂停 | ✅ 检测 [UNCERTAIN] | ❌ 跳过 |
| 适用场景 | 正常需求 | 紧急修复 |

## 用法

```
/start 添加用户注册页面
/start https://jira.example.com/browse/PROJ-123
```

---

如果 `$ARGUMENTS` 为空，提示用户补充需求描述或 URL 并停止。

不要手工模拟 workflow，也不要只"参考"流程自己做一遍。
必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/start $ARGUMENTS"`

执行后：
1. 读取并总结真实产物（specs、review-report、test-report、代码改动）
2. 明确说明哪些阶段真实完成了，哪些阶段被跳过或失败了
3. 给出每个阶段的关键信息，而不是只给最后总结果
4. 如有可访问链接，给出链接；如没有，就说明原因
5. 不要编造未实际生成的报告或结果
