# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI 数字员工 24 小时可编排工作流框架。通过飞书消息触发，经 OpenClaw 网关 → OpenCLI → Claude Code CLI 执行完整开发流水线：需求分析 → 技术设计 → 编码 → 审查 → 测试 → 文档 → 部署。

**这不是传统代码项目**——本仓库是一套工作流编排框架（Shell 脚本 + SKILL.md 规范文件），用于安装到目标项目的 `.claude/` 目录中。

## Setup & Usage

```bash
# 安装到目标项目
bash init-project.sh /path/to/your/project

# 配置环境变量（直接编辑，无需复制）
vim .env.ai-digital-workflow

# 本地触发完整流水线
opencli claude --permission-mode bypassPermissions -p '/start-workflow 添加用户注册页面'

# 飞书触发
@龙虾 /start-workflow 添加用户注册页面
```

## Architecture

### Pipeline (7 阶段顺序执行)

```
Step 0: 环境准备 + 知识加载 (.claude/ + 公司 skills)
Step 1: spec-writer → 需求/设计/任务三文档 (Claude→Codex→Claude 三阶段交叉审查)
        ⚠️ 若检测到 [UNCERTAIN] 开放问题 → 自动暂停，飞书询问用户
        ✅ 用户通过 /answer 答复后 → 重新生成并继续
Step 2: 开发执行
        Step 2a: Antigravity UI 还原（仅当 tasks.md 含 agent: antigravity 且 ENABLE_UI_RESTORER=true 时执行）
                 分块还原 + 视觉反馈闭环 + Codex 代码审查
        Step 2b: Claude Code 业务逻辑开发（始终执行，跳过已由 2a 完成的任务）
Step 3: code-reviewer → 2 轮审查 + fix 循环
Step 4: test-runner → 特性范围测试 vs 全仓库债务分离
Step 5: doc-syncer → 文档同步 + 迭代归档
Step 6: 部署(可选) + 飞书通知
```

### 核心目录职责

- `orchestrator/` — 编排引擎入口。`feishu-handler.sh` 是主流程控制器，按 7 阶段驱动整个 pipeline
- `skills/` — 4 个核心 Skill（必选），每个 Skill 一个 `SKILL.md` 定义其行为
- `extensions/` — 5 个可插拔扩展，通过 `.env` 开关激活，不改代码只改配置
- `commands/` — 9 个飞书斜杠命令定义（含 `/answer`、`/resume`、`/pause`、`/restart`）

### 工作流管家 Agent

通过 openclaw 创建的对话式 Agent，让用户在飞书里用自然语言驱动工作流，无需记忆斜杠命令。

**核心能力：**
- **状态感知**：每次收到消息先读 `workflow-log`、`paused.json`、`awaiting-clarification.json`，判断当前状态
- **意图识别**：把自然语言翻译成正确命令（"先停一下" → `/pause`，"改好了" → `/restart`）
- **主动发起对话**：工作流关键节点自动触发，Agent 主动问用户问题，等回复后继续执行

**关键节点 Agent 主动介入：**

| 节点 | Agent 问什么 | 用户回复后执行 |
|------|------------|-------------|
| `[UNCERTAIN]` 开放问题 | 逐一列出问题 | `/answer` |
| Spec 审查 CRITICAL | 自动修复还是人工处理？ | `/restart` 或等待 |
| 测试失败进修复回路 | 告知正在自动修复 | 无需操作 |
| 自动修复也失败 | 帮你分析还是人工修？ | `/resume` |
| 流水线异常崩溃 | 帮你排查还是直接继续？ | `/resume` |

**配置（`.env.ai-digital-workflow`）：**
```bash
OPENCLAW_BIN=/Users/xiaofan/.nvm/versions/node/v22.22.1/bin/openclaw  # openclaw 绝对路径（which openclaw 获取）
OPENCLAW_AGENT_ID=ai-react           # openclaw Agent ID
FEISHU_NOTIFY_TARGET=ou_xxxxxxxxxx   # 你的飞书 open_id
```

**Agent 安装：**
```bash
# 使用已有 Agent（推荐）
cp ~/.openclaw/agents/ai-digital-workflow/agent/instructions.md \
   ~/.openclaw/agents/ai-react/agent/instructions.md

# 绑定飞书账号
openclaw agents bind ai-react --channel feishu --peer ou_xxxxxxxxxx
```

### 知识注入双层模型

- **Layer 1 (项目级):** 目标项目 `.claude/` 下的 CLAUDE.md, ARCHITECTURE.md, SECURITY.md, CODING_GUIDELINES.md
- **Layer 2 (公司级):** 通过 `COMPANY_SKILLS_GIT` 或 `COMPANY_SKILLS_LOCAL` 配置的公司统一 skills 仓库

### 模型选择策略

- `complexity: high` → 优先 Opus，配额不足自动降级 Sonnet
- `complexity: low/medium` → 默认 Sonnet

### 扩展激活条件

| 扩展 | 激活条件 |
|------|---------|
| worktree-parallel | `ENABLE_WORKTREE_PARALLEL=true` + `complexity: high` |
| ui-restorer | `ENABLE_UI_RESTORER=true` + tasks 中含 `agent: antigravity` |
| human-gate | 配置了 `FEISHU_APPROVAL_CODE` |
| deploy-executor | `ENABLE_DEPLOY=true` |
| jira-sync | 配置了 `JIRA_BASE_URL` + `JIRA_TOKEN` |

## 飞书斜杠命令

| 命令 | 用途 | 典型场景 |
|------|------|---------|
| `/start-workflow {需求}` | 启动完整流水线 | 新功能、正常需求 |
| `/hotfix {描述}` | 紧急修复，跳过 spec 审查和开放问题检测 | 线上 bug，不想等完整流水线 |
| `/pause [feature]` | 主动暂停，保存断点和 requirements.md 快照 | 需求有变化，想改完再继续 |
| `/restart [feature] [变更描述]` | 从 `/pause` 恢复，自动 diff 需求，最小粒度更新 | 改完需求后继续；不改则直接从断点继续 |
| `/resume [feature]` | 从崩溃/意外中断恢复，读日志找断点继续 | 网络抖动、进程被杀、手动 Ctrl+C |
| `/answer {feature} {答复}` | 回复 `[UNCERTAIN]` 开放问题，恢复被暂停的流水线 | Step 1 检测到不确定项时自动触发暂停 |
| `/review [feature]` | 单独触发代码审查（Step 3） | 审查失败修完代码后重跑；或只想审查不跑完整流程 |
| `/test [feature]` | 单独触发测试（Step 4） | 测试失败修完后重跑 |
| `/status` | 查看 Git log、活跃 specs、扩展开关状态 | 不知道跑到哪了；确认扩展是否生效 |

### 命令选择决策树

```
有新需求？
  └── /start-workflow

线上 bug 紧急修？
  └── /hotfix

工作流跑着，需求要改？
  └── /pause → 改 requirements.md → /restart

工作流意外中断（崩溃/网络/Ctrl+C）？
  └── /resume

收到开放问题询问，需要答复？
  └── /answer

只想重跑审查或测试？
  └── /review 或 /test

不知道现在什么状态？
  └── /status
```

## Key Patterns

### SKILL.md 格式

所有 Skill 和扩展使用 YAML frontmatter + Markdown body：
```yaml
---
name: skill-name
description: 触发条件描述
---
```

### Spec 输出三文档

spec-writer 产出固定结构：`requirements.md`（需求）、`design.md`（设计，含 complexity 评级）、`tasks.md`（原子任务列表，含 agent 标记和依赖关系）

### Step 1 开放问题与澄清机制

spec-writer 在生成文档时使用两级标记处理信息不足的情况：

- `[INFERRED]` — 有把握的合理推断，直接写入文档，**不暂停**
- `[UNCERTAIN]` — 影响架构或关键功能的不确定项，写入 `requirements.md` 的"开放问题"部分，**触发暂停**

工作流在 Stage 1a（仅生成 requirements.md）完成后自动检测未勾选的 `[ ]` 项，若存在则：
1. 保存状态到 `specs/{feature}/awaiting-clarification.json`
2. 飞书发送问题列表并暂停（`/hotfix` 跳过此机制）
3. 用户通过 `/answer {feature} 1.答案 2.答案` 答复
4. 工作流仅更新 requirements.md，确认无歧义后才进入 Stage 1b 生成 design.md + tasks.md
5. 若答复后仍有未解决项，重复上述流程（支持多轮）

> **设计意图**：`[UNCERTAIN]` 只会导致 requirements.md 重新生成，不会浪费 design.md + tasks.md 的 token。

### 任务 Agent 标记

- `agent: claude-code`（或省略）→ Claude Code 执行（Step 2b）
- `agent: antigravity` → Antigravity + Figma MCP UI 还原（Step 2a，需 `ENABLE_UI_RESTORER=true`）

### ui-restorer 扩展（Step 2a）

`agent: antigravity` 任务按以下流程执行：

**Phase 0 — dev server 检查**
- 已运行 → cdp 导航到预览路由，通知用户访问链接
- 未运行 → 自动 `npm run dev`，等待端口就绪，通知用户链接
- 启动失败 → `agent_notify` 告知用户，流水线暂停

**Phase 1 — 分块还原（视觉反馈闭环）**

每个 antigravity 任务按 tasks.md 中的 `还原策略` 逐块执行：
```
Round 1: Antigravity Thinking 模式 + 结构化设计规格提示词
    ↓ chrome-cdp-skill 截图（项目内置入口：`scripts/cdp.mjs`）
    ↓ Codex 视觉打分（1-10）+ 输出 DIFF_COMPLEXITY + FIXES
SCORE ≥ 8 → PASS
SCORE < 8 → Round 2:
    minor diff → Antigravity Fast 模式微调
    major diff → Antigravity Thinking 模式重构
    ↓ 再次截图打分
SCORE ≥ 8 → PASS
SCORE < 8 → 人工确认节点（agent_notify 发飞书附截图）
```

**Antigravity 三种模式**

| 模式 | 场景 | 当前落地方式 |
|------|------|------|
| Thinking | 生成 UI 代码 / major 修复 | 优先 `Claude Opus 4.6 (Thinking)`，额度/不可用时顺延降级到 `Gemini 3.1 Pro (High)`，再降到 `Gemini 3 Flash` |
| Codex 评分 | 截图视觉打分 | 用 `chrome-cdp-skill` 截图后交给 Codex 输出 `SCORE / DIFF_COMPLEXITY / FIXES / PASS` |
| Fast | minor 微调（颜色/字号/间距） | 优先 `Gemini 3.1 Pro (High)`，不可用时降级到 `Gemini 3 Flash`，发送更短、更聚焦的 diff 修复提示词 |

**Phase 2 — 人工确认汇报粒度**
- 总块数 ≤ 3 → 全部完成后一次汇报
- 总块数 > 3 → 每完成 3 块汇报一次

**Phase 3 — Codex 代码规范审查（一轮）**
- 检查：hardcode 颜色/design token/Props 接口/a11y/div 嵌套
- ERROR → Antigravity Fast 模式修复；WARNING → 通知但不阻塞

**spec-writer Stage 1b 扩展**
- 检测到 `agent: antigravity` 任务时，调 Antigravity Thinking 模式连 Figma MCP
- 自动提取设计规格（布局/间距/颜色/字体/组件层级）和分块策略，写入 tasks.md
- 无 Figma URL 时追加 `[UNCERTAIN]` 触发暂停，向用户索取链接

**tasks.md antigravity 任务必含字段**
```markdown
- agent: antigravity
- figma: {figma-url}
- 预览路由: /{route}
- 设计规格: {由 Antigravity Figma MCP 自动填充}
- 还原策略: 块1/块2/.../响应式适配
```

### Hooks 系统

`orchestrator/assets/hooks.json` 定义 4 个 Claude Code hook 时机：
- `PreToolUse` (Bash) → `pre-exec-check.sh` 预执行验证
- `PostToolUse` (Bash) → `post-exec-log.sh` 执行日志
- `Notification` → `feishu-notify.sh` 飞书推送
- `Stop` → `on-complete.sh` 完成处理

### 代码审查标准

5 维度评审（Code Quality / Security / Performance / Architecture / Testing），4 级严重性（CRITICAL / ERROR / WARNING / INFO）。3+ CRITICAL_ISSUES 触发人工介入。

### 测试标准

覆盖率阈值：Statements 80%、Branches 75%、Functions 80%。**特性范围测试与全仓库历史债务分离**——新特性测试必须通过，历史债务不阻塞新功能。

## Recent Improvements (2026-03-29 v2)

### ui-restorer 全面升级（Antigravity 分块还原 + 视觉反馈闭环）
- **显式两阶段 Step 2**：Step 2a（所有 antigravity 任务）先跑完，Step 2b（claude-code 任务）再跑，依赖关系明确
- **dev server 生命周期管理**：`ensure_dev_server()` 自动检测端口、启动服务、健康等待、失败暂停
- **分块还原策略**：Antigravity 连 Figma MCP 分析设计稿，自动决定分块，逐块还原
- **视觉反馈闭环**：chrome-cdp-skill（项目内置入口：`scripts/cdp.mjs`）截图 → Codex 结构化打分 → FIXES → 定向重试，最多 2 轮
- **三模式动态切换**：Thinking（生成/重构）/ Pro（视觉打分）/ Fast（minor 微调），由打分输出的 `DIFF_COMPLEXITY` 驱动
- **分批人工确认**：≤3 块一次汇报，>3 块每 3 块汇报，agent_notify 附截图发飞书
- **Codex 代码规范审查**：UI 还原完成后一轮审查（design token/a11y/Props 规范），ERROR 自动修复，WARNING 不阻塞
- **spec-writer 扩展**：Stage 1b 生成 tasks.md 时调 Antigravity Figma MCP 提取设计规格和分块策略
- **Bug 修复**：`log()` 输出改为 stderr，修复 `feature_name=$(step1_spec_writer ...)` 捕获到日志内容导致 `__PAUSED__` 检测失败的问题

## Recent Improvements (2026-03-29)

### 工作流控制命令扩展
- **`/pause` 命令**: 主动暂停工作流，保存断点和 requirements.md 快照
- **`/restart` 命令**: 从 `/pause` 恢复，自动 diff requirements.md，有变更则 Stage 1a'（润色）+ Stage 1b'（最小粒度更新 design/tasks），无变更则直接从断点继续
- **`/resume` 命令**: 从崩溃/意外中断恢复，读取 `workflow-log` 判断最后完成的 Step，从下一步继续，不重头跑
- **openclaw 主动通知**: `feishu_notify()` 优先使用 `openclaw message send` 主动私信，配置 `FEISHU_NOTIFY_TARGET` 即可；fallback 到 webhook
- **Agent 主动对话**: 关键节点（开放问题/审查阻断/测试失败/流水线崩溃）通过 `agent_notify()` 触发 openclaw Agent 主动在飞书发起对话，等待用户决策后继续
- **环境变量简化**: 直接读取 `.env.ai-digital-workflow`，无需再 `cp` 为 `.env`

### spec-writer 两阶段生成（节省 token）
- **Stage 1a**: 仅生成 `requirements.md`，检测 `[UNCERTAIN]` 后再决定是否继续
- **Stage 1b**: 需求确认无歧义后才生成 `design.md + tasks.md`
- **效果**: 有开放问题时只重新生成 requirements.md，避免 design/tasks 被白白生成两遍

## Recent Improvements (2026-03-26)

### Step 1 暂停与澄清机制
- **开放问题检测**: Stage 1 完成后自动扫描 `requirements.md` 中未勾选的 `[ ]` 项，若存在则暂停流水线
- **两级不确定标记**: `[INFERRED]`（直接写入，不暂停）vs `[UNCERTAIN]`（必须询问用户）
- **飞书问答恢复**: 暂停时推送问题列表，用户通过 `/answer {feature} 答复` 恢复，支持多轮澄清
- **澄清状态持久化**: 等待状态保存在 `specs/{feature}/awaiting-clarification.json`，进程重启不丢失
- **`run_pipeline_steps_2_to_7()` 提取**: Steps 2-7 逻辑独立成函数，澄清恢复路径与正常路径共用

## Recent Improvements (2026-03-25)

### 安全性增强
- **JSON 注入防护**: 所有飞书通知、Jira API、审批网关统一使用 `jq` 构建 JSON，消除字符串拼接风险
- **安全检测精确化**: `detect-security-changes.sh` 优化模式匹配，排除测试文件和注释，降低误报率

### 健壮性提升
- **公共函数库**: 新增 `orchestrator/scripts/lib/common.sh`，统一错误处理、日志、通知、状态管理
- **错误恢复机制**: 主流程添加 `trap` 捕获异常，自动记录失败状态并发送通知
- **竞态条件修复**: worktree 并行脚本使用 `mktemp` 避免临时文件冲突

### 功能完善
- **文档同步增强**: `run_local_doc_sync` 调用 Claude Code 执行真正的文档分析和归档
- **代码审查 fallback**: `run_local_review` 在 Codex 不可用时调用 Claude Code 执行完整两轮审查
- **分支名自动检测**: 去除硬编码 `main`，使用 `git symbolic-ref` 自动获取默认分支

### Bug 修复
- **rollback.sh**: 修正 `git revert` 范围从 `HEAD..${COMMIT}` 到 `${COMMIT}..HEAD`
- **select-model.sh**: 移除空探测请求，改为实际执行时 fallback，节省 API 调用
- **on-complete.sh**: 任务状态匹配支持中英文格式 `状态：done` 和 `Status: done`
