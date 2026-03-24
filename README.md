# AI数字员工24小时可编排工作流架构设计

> 4 核心 Skill + 5 可插拔扩展 · 飞书 OpenClaw 触发 · OpenCLI 包装的 Claude Code 执行 · 全自动 / 人机协同

## 一句话定义

在飞书里发一句话需求，AI 数字员工自动完成 **需求分析 → 技术设计 → 编码 → 审查 → 测试 → 文档 → 部署** 全流程。7×24 无休，可编排，可插拔。

## 架构总览

```
飞书消息 ──→ OpenClaw (7×24 在线)
                │
                ↓
   OpenCLI → Claude Code CLI
                │  工作目录 = 你的项目
                │  自动加载 .claude/ 下全套 skill
                ↓
    ┌─────────────────────────────┐
    │     4 个核心 Skill (必选)     │
    │                              │
    │  spec-writer ──→ 需求+设计+任务 │
    │  Claude Code ──→ 逐任务编码    │
    │  code-reviewer ─→ 2轮审查+fix │
    │  test-runner ──→ 测试+覆盖率   │
    │  doc-syncer ───→ 文档+归档    │
    └──────────────┬──────────────┘
                   │
    ┌──────────────┴──────────────┐
    │   5 个可插拔扩展 (.env 开关)   │
    │                              │
    │  worktree-parallel  多Agent并行│
    │  ui-restorer   Antigravity还原│
    │  human-gate    飞书审批门控    │
    │  deploy-executor  部署+回滚   │
    │  jira-sync     Jira双向同步   │
    └─────────────────────────────┘
```

## 核心设计原则

| 原则 | 实现 |
|------|------|
| **少即是多** | 4 个 skill 覆盖核心开发循环 80%，不过度拆分 |
| **可插拔** | 扩展通过 .env 开关激活，不改代码只改配置 |
| **可编排** | 编排器按 Pipeline 模式顺序执行，每步有门控产物 |
| **人机协同** | 安全变更/生产部署通过飞书审批阻塞，其余全自动 |
| **知识驱动** | .claude/ 项目规范 + 公司 skills 仓库双层知识注入 |

## 快速开始

```bash
# 1. 在任何项目中安装
bash init-project.sh /path/to/your/project

# 2. 填写项目知识库
vim .claude/CLAUDE.md          # 技术栈、命令、约定
vim .claude/ARCHITECTURE.md    # 架构、模块、数据流
vim .claude/SECURITY.md        # 安全规范
vim .claude/CODING_GUIDELINES.md  # 编码规范

# 3. 配置 .env
cp .env.ai-digital-workflow .env && vim .env

# 4. 推荐本地命令入口（统一 OpenCLI 风格）
opencli claude --permission-mode bypassPermissions -p '/start-workflow 添加用户注册页面'

# 5. 在飞书中使用
@龙虾 /start-workflow 添加用户注册页面
```

## 文件布局

```
.claude/
├── skills/                     ← 4 个核心 skill（必选）
│   ├── spec-writer/SKILL.md       需求+设计+任务一站式生成
│   ├── code-reviewer/SKILL.md     OpenCLI→Codex 两轮审查
│   ├── test-runner/SKILL.md       Vitest + Playwright + Chrome MCP
│   └── doc-syncer/SKILL.md        文档同步 + 迭代归档
├── extensions/                 ← 5 个可插拔扩展（按需启用）
│   ├── worktree-parallel/         Git worktree 多 Agent 并行
│   ├── ui-restorer/               Antigravity + Figma MCP UI 还原
│   ├── human-gate/                飞书审批门控（安全+部署）
│   ├── deploy-executor/           部署 + 健康检查 + 自动回滚
│   └── jira-sync/                 Jira 双向同步 7 个时机
├── orchestrator/               ← 编排器 + hooks + 脚本
│   ├── SKILL.md
│   ├── scripts/
│   └── assets/
├── CLAUDE.md                   ← 项目指令（每个项目不同）
├── ARCHITECTURE.md             ← 架构文档
├── SECURITY.md                 ← 安全规范
├── CODING_GUIDELINES.md        ← 编码规范
└── hooks.json                  ← Claude Code hooks
specs/
├── {需求名称}/                  ← 当前需求的 spec 文件
│   ├── requirements.md
│   ├── design.md
│   └── tasks.md
└── archive/                    ← 已完成迭代的归档
```

## 扩展开关

| 扩展 | 启用方式 | 说明 |
|------|---------|------|
| worktree-parallel | `ENABLE_WORKTREE_PARALLEL=true` | complexity:high 时自动多 Agent 并行 |
| ui-restorer | `ENABLE_UI_RESTORER=true` | Antigravity + Figma MCP 页面还原 |
| human-gate | 配置 `FEISHU_APPROVAL_CODE` | 安全变更/部署前飞书审批阻塞 |
| deploy-executor | `ENABLE_DEPLOY=true` | CI/CD + 健康检查 + 自动回滚 |
| jira-sync | 配置 `JIRA_BASE_URL` + `JIRA_TOKEN` | 7 个时机自动回写 Jira 状态 |

## 飞书斜杠命令

| 命令 | 动作 |
|------|------|
| `/start-workflow <描述>` | 完整流水线 |
| `/hotfix <描述>` | 跳过设计，快速修复 |
| `/review` | 仅代码审查 |
| `/test` | 仅运行测试 |
| `/status` | 查看当前状态 |

## 技术栈依赖

- **OpenCLI + Claude Code** — 核心执行引擎（统一入口：`opencli claude ...`）
- **OpenClaw** — 飞书消息网关（7×24 在线）
- **OpenCLI + Codex** — 代码审查（可选）
- **Antigravity + Figma MCP** — UI 设计还原（可选）
- **Playwright** — E2E 测试
- **Git worktree** — 多 Agent 隔离并行

## License

MIT
