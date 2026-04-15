---
name: doc-syncer
description: >
  文档同步技能。开发完成后更新 .claude/ 下的项目规范文件和 README，
  将本次迭代的 specs 归档。保持项目文档与代码实际状态一致。
  触发条件："更新文档"、"sync docs"、"归档"、编排器 doc-sync 阶段。
---

# doc-syncer — 文档同步 + 迭代归档

你是文档维护代理。每次功能完成后同步项目文档，归档本次迭代记录。

## 同步流程

### Step 1：分析本次变更

读取当前功能的全部产物：
- `$WORKFLOW_DATA_DIR/{feature-name}/requirements.md` — 做了什么
- `$WORKFLOW_DATA_DIR/{feature-name}/design.md` — 怎么设计的
- `$WORKFLOW_DATA_DIR/{feature-name}/tasks.md` — 改了哪些文件
- `git log --oneline` — 实际代码变更

### Step 2：更新项目文档

逐文件检查是否需要更新：

| 文件 | 更新时机 |
|------|---------|
| README.md | 新功能、新依赖、新命令 |
| .claude/ARCHITECTURE.md | 新模块、边界变更、数据流变更 |
| .claude/SECURITY.md | 新认证方式、新 API 暴露、权限变更 |
| .claude/CODING_GUIDELINES.md | 新模式建立、新反模式发现 |
| .claude/CLAUDE.md | 新斜杠命令、新构建指令 |

规则：
- 只添加变更的部分，不重写整个文件
- 保持与现有文档的风格一致
- 新模式必须附带代码示例

### Step 3：归档迭代

```bash
DATE=$(date +%Y-%m-%d)
ARCHIVE="$WORKFLOW_DATA_DIR/archive/${DATE}-{需求名称}"
mkdir -p "$ARCHIVE"
cp $WORKFLOW_DATA_DIR/{feature-name}/requirements.md "$ARCHIVE/"
cp $WORKFLOW_DATA_DIR/{feature-name}/design.md "$ARCHIVE/"
cp $WORKFLOW_DATA_DIR/{feature-name}/tasks.md "$ARCHIVE/"
cp $WORKFLOW_DATA_DIR/{feature-name}/test-report.md "$ARCHIVE/" 2>/dev/null || true
```

### Step 4：更新迭代记录

追加到 `$WORKFLOW_DATA_DIR/ITERATIONS.md`：

```markdown
| {日期} | {需求名称} | {任务数} | {覆盖率} | 完成 |
```

### Step 5：提交

```bash
git add README.md .claude/
git commit -m "docs({需求名称}): 同步文档"
```
