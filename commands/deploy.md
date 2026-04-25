---
description: 部署指定需求（Step 6，需 ENABLE_DEPLOY=true）
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /deploy

## 作用

手动触发部署流程（Step 6）。执行部署脚本、健康检查，失败时自动回滚。

## 前置条件

- `.env` 中 `ENABLE_DEPLOY=true`
- 需求已通过审查和测试（Step 3 + Step 4）
- 如配置了 `FEISHU_APPROVAL_CODE`，部署前需飞书审批通过

## 适用场景

- 流水线跑完但跳过了部署（`ENABLE_DEPLOY=false` 时），后来想手动部署
- 需要重新部署某个已完成的需求

## 部署流程

1. human-gate 审批检查（如启用）
2. 执行部署脚本（`DEPLOY_STRATEGY`）
3. 健康检查（`DEPLOY_HEALTH_URL`）
4. 失败 → 自动回滚到上一版本

## 用法

```
/deploy
/deploy user-login
```

---

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/deploy $ARGUMENTS"`

执行后总结部署结果，包含健康检查状态。
