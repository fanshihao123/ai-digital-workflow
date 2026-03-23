---
name: deploy-executor
description: >
  可插拔扩展。部署执行 + 健康检查 + 自动回滚。
  启用方式：.env 中设置 ENABLE_DEPLOY=true。
  未启用时流水线在 doc-syncer 之后直接通知完成。
---

# deploy-executor — 部署+健康检查+回滚（可插拔扩展）

## 启用条件

`.env` 中 `ENABLE_DEPLOY=true`。未启用则跳过。

## 流程

```
doc-syncer 完成
     |
(human-gate 部署审批，如已启用)
     |
  生成 deploy-manifest.json
     |
  执行部署 (git push / CI trigger / 自定义命令)
     |
  健康检查 (10次 × 15s)
     |
  通过？
   / \
 yes   no → scripts/rollback.sh 自动回滚
  |
 完成
```

## 部署方式（.env 配置）

```bash
DEPLOY_STRATEGY=push      # push | ci-trigger | command
DEPLOY_HEALTH_URL=http://localhost:3000/health
DEPLOY_TIMEOUT=150
```

## 回滚

自动回滚：健康检查失败时 `git revert + push`。
手动回滚：`/rollback {需求名称}`。

脚本：`scripts/rollback.sh`
