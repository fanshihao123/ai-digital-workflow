---
description: 回滚指定需求的部署（需 ENABLE_DEPLOY=true）
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /rollback

## 作用

回滚指定需求的部署，恢复到部署前的版本。

## 前置条件

- `.env` 中 `ENABLE_DEPLOY=true`
- 该需求已经通过 `/deploy` 部署过

## 适用场景

- 部署后发现线上问题，需要紧急回滚
- 健康检查通过但业务异常，需要手动触发回滚

## 与 `/hotfix` 的区别

| 命令 | 用途 |
|------|------|
| `/rollback` | 回退到上一版本代码，不修改任何代码 |
| `/hotfix` | 紧急修复 bug，生成新代码部署上去 |

## 用法

```
/rollback
/rollback user-login
```

---

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/rollback $ARGUMENTS"`

执行后总结回滚结果。
