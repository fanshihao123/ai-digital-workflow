---
description: 查看当前 workflow 状态（进度、Git log、扩展开关）
allowed-tools: Read, Glob, Grep, Bash
model: haiku
---

# /status

## 作用

查看当前工作流的整体状态，包括流水线进度、Git log、活跃需求、扩展开关等。只读查询，不会修改任何状态。

## 适用场景

- 不知道当前流水线跑到哪一步了
- 确认某个需求是否处于暂停/等待状态
- 检查扩展（部署、审批等）是否生效
- 查看最近的 Git 提交记录

## 输出内容

- 📋 活跃需求列表及其当前状态（running / paused / awaiting-answer / awaiting-fix）
- 📊 流水线进度表（progress.md）
- 🔧 扩展开关状态（哪些已启用/未启用）
- 📝 最近 Git log（5 条）

## 用法

```
/status
```

无需任何参数。

---

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/status"`

如果脚本输出不足，再读取 `$WORKFLOW_DATA_DIR/` 和相关日志补充总结。
