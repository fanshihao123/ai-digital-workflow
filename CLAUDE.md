# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI 数字员工 24 小时可编排工作流框架。通过飞书消息触发，经 OpenClaw 网关 → OpenCLI → Claude Code CLI 执行完整开发流水线：需求分析 → 技术设计 → 编码 → 审查 → 测试 → 文档 → 部署。

**这不是传统代码项目**——本仓库是一套工作流编排框架（Shell 脚本 + SKILL.md 规范文件），用于安装到目标项目的 `.claude/` 目录中。

## Setup & Usage

```bash
# 安装到目标项目
bash init-project.sh /path/to/your/project

# 配置环境变量
cp .env.ai-digital-workflow .env && vim .env

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
Step 2: Claude Code 逐任务编码 (可选: UI 还原 / worktree 并行)
Step 3: code-reviewer → 2 轮审查 + fix 循环
Step 4: test-runner → 特性范围测试 vs 全仓库债务分离
Step 5: doc-syncer → 文档同步 + 迭代归档
Step 6: 部署(可选) + 飞书通知
```

### 核心目录职责

- `orchestrator/` — 编排引擎入口。`feishu-handler.sh` (~1250 行) 是主流程控制器，按 7 阶段驱动整个 pipeline
- `skills/` — 4 个核心 Skill（必选），每个 Skill 一个 `SKILL.md` 定义其行为
- `extensions/` — 5 个可插拔扩展，通过 `.env` 开关激活，不改代码只改配置
- `commands/` — 5 个飞书斜杠命令定义

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

### 任务 Agent 标记

- `agent: claude-code`（或省略）→ Claude Code 执行
- `agent: antigravity` → Figma MCP UI 还原（需 `ENABLE_UI_RESTORER=true`）

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
