# AI数字员工24小时可编排工作流架构设计

> 4 核心 Skill + 5 可插拔扩展 · 飞书 OpenClaw 触发 · OpenCLI 包装的 Claude Code 执行 · 全自动 / 人机协同

## 一句话定义

在飞书里发一句话需求，AI 数字员工自动完成 **需求分析 → 技术设计 → 编码 → 审查 → 测试 → 文档 → 部署** 全流程。7×24 无休，可编排，可插拔，**飞书实时进度推送**。

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
| **人机协同** | 需求不确定时主动暂停询问；安全变更/生产部署通过飞书审批阻塞 |
| **知识驱动** | .claude/ 项目规范 + 公司 skills 仓库双层知识注入 |
| **进度透明** | 每个 Step 实时推送飞书，产物文件持久化，/status 随时查看 |

## 快速开始

```bash
# 1. 在任何项目中安装
bash init-project.sh /path/to/your/project

# 2. 填写项目知识库
vim .claude/CLAUDE.md          # 技术栈、命令、约定
vim .claude/ARCHITECTURE.md    # 架构、模块、数据流
vim .claude/SECURITY.md        # 安全规范
vim .claude/CODING_GUIDELINES.md  # 编码规范

# 3. 配置环境变量（直接编辑，无需复制）
vim .env.ai-digital-workflow

# 4. 本地触发
opencli claude --permission-mode bypassPermissions -p '/start-workflow 添加用户注册页面'

# 5. 在飞书中使用
@龙虾 /start-workflow 添加用户注册页面
```

## Pipeline（7 阶段 + 飞书实时进度）

```
Step 0: 环境准备 + 知识加载
Step 1: spec-writer → 需求/设计/任务三文档 (Claude→Codex→Claude 三阶段交叉审查)
        ⚠️ 若检测到 [UNCERTAIN] 开放问题 → 自动暂停，飞书询问用户
        ⚠️ 若 Codex 审查 CRITICAL >= 3 → 自动暂停，飞书通知用户
Step 2: 开发执行
        Step 2a: Antigravity UI 还原（可选，需 ENABLE_UI_RESTORER=true）
        Step 2b: Claude Code 业务逻辑开发（始终执行）
Step 3: code-reviewer → 2 轮审查 + fix 循环
Step 4: test-runner → 特性范围测试（失败自动修复重试）
Step 5: doc-syncer → 文档同步 + 迭代归档
Step 6: 部署(可选) + 飞书通知
Step 7: 完成汇总通知
```

**飞书实时进度推送** — 每个 Step 开始/完成时自动推送到飞书，无需连接终端：

```
🚀 multiply-function 流水线已启动
   需求: 添加 multiply 乘法函数...

✅ [Stage 1a] requirements.md 生成完毕，无开放问题
⏳ [Stage 1b] 开始生成 design.md + tasks.md...
✅ [Stage 1b] design.md + tasks.md 生成完毕 (3 个任务, complexity: low)
⏳ [Stage 2] 开始 Codex spec 审查...
✅ [1/7] 需求分析 完成 (45s)

⏳ [2/7] 开发执行 开始...
✅ [2/7] 开发执行 完成 (1m 20s) — complexity: low

⏳ [3/7] 代码审查 开始...
✅ [3/7] 代码审查 完成 (30s)

⏳ [4/7] 测试 开始...
✅ [4/7] 测试 完成 (25s)

✅ [5/7] 文档同步 完成 (10s)
⏭️ [6/7] 部署 跳过 (ENABLE_DEPLOY=false)

🎉 multiply-function 流水线完成！
   审查: PASS | 覆盖率: 85%
```

同时 `specs/{feature}/progress.md` 保存完整进度表格，`/status` 随时查看。

## v4 模块化架构（默认）

```
orchestrator/scripts/
├── feishu-handler.sh          ← 入口
├── lib/common.sh              ← 公共函数库
└── v4/
    ├── handler.sh             ← v4 入口：初始化 → source 模块 → 命令路由
    ├── lib/                   ← 12 个工具模块
    │   ├── state.sh              统一状态机引擎（state.json）
    │   ├── progress.sh           飞书实时进度推送引擎
    │   ├── utils.sh              select_model, detect_feature_name 等
    │   ├── clarification.sh      开放问题/澄清状态管理
    │   ├── spec-review.sh        Spec 审查阻断状态管理
    │   ├── pause.sh              暂停/恢复 + 进程终止
    │   ├── testing.sh            测试提取（feature-scope）和执行
    │   ├── review.sh             代码审查执行（两轮 + fallback）
    │   ├── doc-sync.sh           文档同步 + 迭代归档
    │   ├── dev-server.sh         Dev server 生命周期管理
    │   ├── antigravity.sh        Antigravity UI 还原
    │   └── integrations.sh       Jira 同步 + human-gate 门控
    ├── steps/                 ← 9 个流水线阶段
    │   ├── step0-prepare.sh ~ step7-notify.sh
    │   └── pipeline.sh          run_full_pipeline + run_pipeline_steps_2_to_7
    └── commands/              ← 12 个斜杠命令处理器
        ├── start-workflow.sh, hotfix.sh, pause.sh, restart.sh
        ├── resume.sh, answer.sh, fix-spec.sh
        ├── review.sh, test.sh, status.sh, deploy.sh, rollback.sh
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
│   ├── tasks.md
│   ├── state.json                ← v4 统一状态机
│   ├── progress.md               ← 流水线进度表格
│   ├── progress.json             ← 进度机器可读数据
│   ├── review-report.md          ← 代码审查报告
│   └── test-report.md            ← 测试报告
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
| `/start-workflow <描述>` | 启动完整流水线 |
| `/hotfix <描述>` | 跳过设计，快速修复（跳过澄清和审查阻断） |
| `/pause [feature]` | 主动暂停工作流，保存断点 |
| `/restart [feature] [变更描述]` | 从 `/pause` 恢复，自动 diff 需求并最小粒度更新 |
| `/resume [feature]` | 从崩溃/意外中断恢复，读日志找断点继续 |
| `/answer <需求名> <答复>` | 答复 Step 1 开放问题，恢复暂停的工作流 |
| `/fix-spec <需求名> <修改指导>` | 答复 Spec 审查严重问题，Claude 自动修改并重新审查 |
| `/review [feature]` | 单独触发代码审查 |
| `/test [feature]` | 单独触发测试 |
| `/status` | 查看流水线进度、Git log、扩展状态 |
| `/deploy [feature]` | 手动触发部署 |
| `/rollback` | 回滚部署 |

### 命令选择决策树

```
有新需求？ → /start-workflow
线上 bug 紧急修？ → /hotfix
工作流跑着，需求要改？ → /pause → 改需求 → /restart
工作流意外中断？ → /resume
收到开放问题询问？ → /answer
收到 Spec 审查阻断通知？ → /fix-spec
只想重跑审查或测试？ → /review 或 /test
不知道跑到哪了？ → /status
```

### Step 1 暂停与澄清

当需求描述存在影响架构决策的不确定点时，Step 1 会自动暂停并通过飞书发送问题列表：

```
⏸️ Step 1 已暂停 — 需确认 2 个问题后才能继续

1. 用户认证方式是 OAuth 还是自建账号系统？
2. 是否有 Figma 设计稿？

回复: /answer user-register-page 1.你的答案 2.你的答案
```

收到答复后工作流自动恢复，将答复融入文档并继续执行。`/hotfix` 命令跳过此机制。

### Spec 审查阻断与 /fix-spec

当 Codex 审查发现 3 个以上 CRITICAL 问题时，流水线自动暂停并推送问题摘要：

```
❌ Spec 审查发现 4 个严重问题，流水线已暂停

1. 密码存储方案不安全
2. ...

回复: /fix-spec user-auth 密码必须用 bcrypt 哈希存储
```

Claude 自动根据你的指导修改三文档并重新审查，支持多轮修复，通过后自动继续。

## 环境要求

- **Bash 3.2+** — 兼容 macOS 自带 bash（不依赖 bash 4+ 特性如 `declare -A`）
- **jq** — JSON 处理（状态机、飞书通知、进度追踪均依赖）
- **Git** — 分支管理、变更检测、worktree 并行

## 技术栈依赖

- **OpenCLI + Claude Code** — 核心执行引擎（统一入口：`opencli claude ...`）
- **OpenClaw** — 飞书消息网关（7×24 在线）
- **OpenCLI + Codex** — 代码审查（可选）
- **Antigravity + Figma MCP** — UI 设计还原（可选）
- **Playwright** — E2E 测试
- **Git worktree** — 多 Agent 隔离并行

## Changelog

### 2026-04-02

- **Fix: bash 3.2 兼容性** — `state.sh` 状态转移表从 `declare -A`（bash 4+）改为 `case` 函数，修复 macOS 默认 bash 下 `unbound variable` 崩溃
- **Fix: 异常通知三级降级** — handler.sh 的 cleanup trap 增加安全检查，即使模块加载阶段崩溃也能通过 openclaw/webhook 发出飞书通知（`agent_notify` → `feishu_notify` → 直接调用 openclaw/curl）
- **Fix: spec-writer 失败通知** — pipeline.sh 中 spec-writer 失败时的通知调用补全 feature_name 参数

## License

MIT
