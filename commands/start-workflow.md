---
description: 启动完整 ai-digital-workflow 流水线
argument-hint: <需求描述或URL>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /start-workflow

用户请求：$ARGUMENTS

按本项目的 ai-digital-workflow 编排执行完整流水线。

## 必须遵守

1. 先读取并遵循以下文件：
   - `.claude/CLAUDE.md`
   - `.claude/ARCHITECTURE.md`
   - `.claude/SECURITY.md`
   - `.claude/CODING_GUIDELINES.md`
   - `.claude/orchestrator/SKILL.md`
2. 然后读取并遵循核心 skill：
   - `.claude/skills/spec-writer/SKILL.md`
   - `.claude/skills/code-reviewer/SKILL.md`
   - `.claude/skills/test-runner/SKILL.md`
   - `.claude/skills/doc-syncer/SKILL.md`
3. 不要把 `/start-workflow` 当成普通聊天指令；它是流水线入口。
4. 如果参数为空，先要求用户补充需求描述或 URL。
5. 不要假装完成。每个阶段是否真的执行，要明确区分。

## 执行顺序

### Step 0: 环境与入口检查
- 确认当前目录是项目根目录。
- 检查 `.claude/`、`specs/` 是否存在。
- 如缺少必要目录/文件，明确报错并停止。

### Step 1: spec-writer
- 基于用户输入 `$ARGUMENTS` 生成本次需求的：
  - `specs/{feature-name}/requirements.md`
  - `specs/{feature-name}/design.md`
  - `specs/{feature-name}/tasks.md`
- 若适用，执行 spec 自检与审查流程。

### Step 2: 开发执行
- 读取 `tasks.md`，按依赖顺序逐项执行。
- 涉及 UI 还原且启用了相关扩展时，遵循扩展约定。
- 每完成一个任务，更新任务状态。

### Step 3: code-reviewer
- 执行两轮审查。
- 若发现 CRITICAL/ERROR，先修复，再复审。

### Step 4: test-runner
- 运行项目定义的必要测试。
- 输出通过/失败、覆盖率和关键失败项。

### Step 5: doc-syncer
- 同步文档与归档本次 specs。

### Step 6: 汇报
- 输出：
  - 需求名 / feature-name
  - 变更摘要
  - 审查结果
  - 测试结果
  - 是否已可运行 / 可访问链接
  - 若失败，给出阻塞点
