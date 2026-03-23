---
name: jira-sync
description: >
  可插拔扩展。Jira 双向同步，在流水线各阶段自动回写 issue 状态和评论。
  启用方式：.env 中配置 JIRA_BASE_URL + JIRA_TOKEN。
  未配置则自动跳过。
---

# jira-sync — Jira 双向同步（可插拔扩展）

## 启用条件

`.env` 中 JIRA_BASE_URL 和 JIRA_TOKEN 都有值时自动启用。缺任一则跳过。

且仅当需求来源是 Jira URL 时同步（spec-writer 提取的 issue key）。

## 同步时机

| 流水线阶段 | Jira 操作 |
|------------|-----------|
| spec-writer 完成 | → In Analysis + 评论 |
| Claude Code 开始开发 | → In Progress |
| code-reviewer 完成 | 添加审查评论 (PASS/FAIL) |
| test-runner 完成 | 添加测试评论 (覆盖率%) |
| deploy-executor 完成 | → Done + 关联提交 |
| 回滚 | → Reopened + 评论 |

## 使用

```bash
bash scripts/sync-jira.sh {issue-key} {phase} {需求名称} [details]
```

编排器在每个阶段完成后自动调用，无需手动干预。
