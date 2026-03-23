---
name: worktree-parallel
description: >
  可插拔扩展。当 spec-writer 输出 complexity: high 时自动激活。
  通过 Git worktree 为每个并行 Agent 创建隔离工作环境。
  启用方式：.env 中设置 ENABLE_WORKTREE_PARALLEL=true。
---

# worktree-parallel — 多 Agent Git worktree 隔离（可插拔扩展）

## 启用条件

同时满足才激活：
1. `.env` 中 `ENABLE_WORKTREE_PARALLEL=true`
2. `specs/{feature-name}/design.md` 中 `complexity: high`

未启用时，编排器跳过此扩展，走顺序执行。

## 工作流程

```
design.md complexity: high
       |
  解析 tasks.md → 识别无互相依赖的任务 → 分为 parallel group
       |
  为每个 group 中的 Agent 创建 worktree
       |
  并行启动:
    claude --worktree {名称}-auth  "Task 1" &
    claude --worktree {名称}-api   "Task 2" &
    opencli codex exec "实时审查"   &  (只读 worktree)
       |
  wait → 按 merge_order 顺序 no-ff 合并
       |
  冲突？→ 冲突解决 Agent（独立 worktree）
       |
  清理 worktree + 临时分支
```

## 脚本

- `scripts/spawn-worktree-agents.sh` — 创建 worktree + 调度 Agent
- `scripts/merge-worktrees.sh` — 有序合并 + 冲突检测
- `scripts/cleanup-worktrees.sh` — 清理 worktree + 临时分支

## Agent 角色

| 角色 | 工具 | 权限 |
|------|------|------|
| 开发 Agent | claude --worktree --model sonnet | 只改 file_scope 内的文件 |
| 审查 Agent | opencli codex exec | 只读，不修改任何文件 |
| 冲突解决 Agent | claude --worktree --model sonnet | 只处理冲突标记 |
