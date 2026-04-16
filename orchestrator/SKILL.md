---
name: workflow-orchestrator
description: >
  AI数字员工24小时可编排工作流总控编排器。4 个核心 skill + 5 个可插拔扩展。
  飞书消息触发后按 Pipeline 模式执行：spec-writer → Claude Code 开发 →
  code-reviewer (2 rounds) → test-runner → doc-syncer → 通知。
  扩展模块按 .env 配置自动激活/跳过。
  触发条件：飞书 webhook、/start-workflow、/workflow、/hotfix。
---

# 编排器 — 4 核心 + 5 扩展

## 架构总览

```
/start-workflow {url | text}
        |
   ┌────┴────┐
   │ Step 0  │  加载 .claude/ 项目规范 + 公司 skills (侧输入)
   └────┬────┘
        |
   ┌────┴────────────────────────────────────────────┐
   │                 4 个核心 skill                    │
   │                                                   │
   │  spec-writer → Claude Code → code-reviewer        │
   │       ↑              ↕              |              │
   │       |         fix 循环            |              │
   │       |                             ↓              │
   │       |                      test-runner           │
   │       |                             |              │
   │       |                        doc-syncer          │
   │                                                   │
   └───────────────────┬─────────────────────────────┘
                       |
   ┌───────────────────┴─────────────────────────────┐
   │            5 个可插拔扩展（按需激活）              │
   │                                                   │
   │  worktree-parallel  高复杂度并行                   │
   │  ui-restorer        Antigravity+Figma UI 还原     │
   │  human-gate         安全/部署审批                  │
   │  deploy-executor    部署+回滚                     │
   │  jira-sync          Jira 状态回写                 │
   └───────────────────────────────────────────────────┘
```

## 扩展启停开关

所有扩展通过 `.env` 控制，不改代码：

```bash
# 可插拔扩展开关
ENABLE_WORKTREE_PARALLEL=true   # complexity:high 时多 Agent 并行
ENABLE_DEPLOY=true              # 部署执行 + 健康检查 + 回滚

# 以下有配置则自动启用，无配置则跳过
FEISHU_NOTIFY_TARGET=ou_xxx     # openclaw 主动通知目标（飞书 open_id 或群 chat_id）
                                 # 获取方式：openclaw directory peers list --channel feishu --query "你的名字"
FEISHU_WEBHOOK_URL=xxx          # fallback webhook（FEISHU_NOTIFY_TARGET 未配置时使用）
FEISHU_APPROVAL_CODE=xxx        # 飞书审批门控（安全+部署）
JIRA_BASE_URL=xxx               # Jira 双向同步
JIRA_TOKEN=xxx

## Claude 模型选择策略

根据任务复杂度自动选择模型，额度不足时自动降级：

```
complexity 判定 → 选择模型
                    |
              complexity: high?
               /           \
             yes             no (low/medium)
              |               |
         Opus 4.6          Sonnet
              |
         额度够？
          /     \
        yes      no
         |        |
      Opus 4.6  降级 → Sonnet（飞书通知"已降级"）
```

### 模型使用场景

| 阶段 | low/medium | high |
|------|-----------|------|
| spec-writer 生成 | Sonnet | Opus 4.6（降级 → Sonnet） |
| spec-writer 复审 | Sonnet | Opus 4.6（降级 → Sonnet） |
| 开发执行 | Sonnet | Opus 4.6（降级 → Sonnet） |
| code-reviewer fix | Sonnet | Opus 4.6（降级 → Sonnet） |
| test-runner | Sonnet | Sonnet（测试不需要 Opus） |
| doc-syncer | Sonnet | Sonnet（文档不需要 Opus） |

### 执行方式

```bash
# high complexity → 优先 Opus
opencli claude --permission-mode bypassPermissions --model opus -p "执行任务..." 2>/dev/null
if [ $? -ne 0 ]; then
  # 额度不足或 Opus 不可用 → 降级 Sonnet
  echo "⚠️ Opus 4.6 不可用，降级使用 Sonnet"
  opencli claude --permission-mode bypassPermissions --model sonnet -p "执行任务..."
fi

# low/medium → 直接 Sonnet
opencli claude --permission-mode bypassPermissions --model sonnet -p "执行任务..."
```

# 公司 skills（有配置则加载）
COMPANY_SKILLS_GIT=xxx          # Git 仓库
COMPANY_SKILLS_BRANCH=main
```

## 完整执行流程

### Step 0：环境准备 + 知识加载

```bash
# A. 自动打开 VSCode（让用户实时看到代码变更）
open -a "Visual Studio Code" .
```

```
B. 读取 .claude/ 下 4 个项目规范文件 → 注入全局上下文
C. 如配置了 COMPANY_SKILLS_GIT → git pull 公司 skills 仓库
   按当前任务关键词匹配 → 作为侧输入注入
```

### Step 1：spec-writer（核心 skill 1 · 三阶段交叉审查）

```
输入 → URL? → Chrome MCP 抓取页面 / 直接解析文字
                          |
              Stage 1: Claude 生成初稿 (v1)
                          |
            ┌─────────────┼─────────────┐
     requirements.md   design.md    tasks.md     → $WORKFLOW_DATA_DIR/{feature-name}/
            └─────────────┼─────────────┘
                          |
              Stage 2: OpenAI Codex / GPT-5.4 审查
                          |  codex exec → 13 维度审查
                          |  输出 spec-review.md
                          |
              Stage 3: Claude 复审 + 定稿
                          |  综合审查意见 → 修正/否决 → 标记 reviewed
                          |
                  三个文件 status: reviewed → 进入 Step 2
```

**审查策略**：默认所有 `/start-workflow` 任务都必须执行 Stage 2（Codex spec 审查）+ Stage 3（Claude 复审定稿）；只有 `/hotfix` 模式允许跳过完整 spec 审查。

**审查失败兜底**：3+ CRITICAL_ISSUES 未解决 → 飞书通知人工介入。

**扩展触发点**：
- jira-sync（如启用）：`sync-jira.sh {key} requirements-done`
- design.md 中 complexity: high → 标记 worktree 模式

### Step 2：开发执行（Agent 路由）

```
读取 tasks.md → 逐任务检查 agent 标记
                    |
    ┌───── agent: antigravity?（且 ENABLE_UI_RESTORER=true）
    |               |
   yes              no → 正常 Claude Code 执行
    |
 ui-restorer 扩展:
   Antigravity + Figma MCP 还原 UI
       ↓
   Claude Code + Codex 双重审查（代码质量 + a11y）
       ↓
   审查通过 → 标记 done → 下一任务（集成）
```

同时检查并行模式：
```
complexity: high 且 ENABLE_WORKTREE_PARALLEL=true?
    |                                    |
   yes                                  no
    |                                    |
 worktree-parallel 扩展              顺序执行
 (独立 worktree + 并行 Agent)      (单 Agent 逐任务)
    |                                    |
    └──────────── 汇合 ────────────────┘
```

**Agent 路由规则**：
- `agent: antigravity` → ui-restorer 扩展（Antigravity + Figma MCP）
- `agent: claude-code` 或无标记 → Claude Code Sonnet
- 两种 agent 可混合出现在同一个 tasks.md 中，按依赖顺序执行

开发时公司 skills 作为侧输入（FE/BE/DB/Pay 等），Claude Code 直接引用。

**扩展触发点**：
- jira-sync（如启用）：`sync-jira.sh {key} dev-start`

### Step 3：code-reviewer（核心 skill 2）

```
代码提交
    |
 Round 1: codex exec --full-auto "审查"
    |
 CRITICAL/ERROR?
   / \
 yes   no
  |     |
 修复     记录 Round 1 无阻断问题
  |     |
  └──→ Round 2: codex exec --full-auto "验证修复/验证无问题结论"
          |
      仍有问题？ → 报告给编排器
          |
      ALL_CLEAR → PASS
```

**强制规则**：Round 2 必须真实执行，不能因为 Round 1 “没有严重问题”就跳过。

**扩展触发点**：
- human-gate G1（如启用）：审查通过后检测安全变更 → 条件阻塞
- jira-sync（如启用）：`sync-jira.sh {key} review-done`

### Step 4：test-runner（核心 skill 3）

```
Jest + Playwright (Chrome MCP)
         |
  先判定 feature-scope 是否通过
         |
  feature-scope 通过?
   / \
 no   yes
 |      |
FAIL   再看全仓结果是回归还是历史债
          |
   历史债? / 本 feature 回归?
      |             |
 non-blocking       FAIL → 进入 Step 4.5 自动修复一轮 → 仍失败才终止
      |
     PASS
```

**强制规则**：test-runner 必须明确区分“feature 自身通过”与“全仓技术债失败”，workflow 只因前者失败或确认回归而阻断。

**扩展触发点**：
- jira-sync（如启用）：`sync-jira.sh {key} test-done`

### Step 5：doc-syncer（核心 skill 4）

```
更新 .claude/ 规范文件 + README
归档 → $WORKFLOW_DATA_DIR/archive/{date}-{需求名称}/
更新 → $WORKFLOW_DATA_DIR/ITERATIONS.md
```

### Step 6：部署（扩展 — 按需）

```
human-gate G2（如启用）→ 飞书审批阻塞 → 通过才继续
                |
deploy-executor（如启用）→ 部署 + 健康检查 + 自动回滚
                |
      (都未启用) → 直接跳到通知
```

### 阶段通知要求（强制）

每个阶段都必须有可见输出，不允许只在最后一次性汇报：
- Step 0：已打开 VSCode / 已加载哪些规范文件
- Step 1：spec 产物路径 + Codex 审查结果
- Step 2：开发完成的任务、涉及文件
- Step 3：两轮 code review 结果
- Step 4：测试命令、feature-scope 结果、全仓技术债结果、覆盖率
- Step 5：文档同步和归档结果
- Step 6：部署/跳过原因
- Step 7：最终摘要

### Step 7：通知

```
飞书卡片通知 → 功能名 + 覆盖率 + 审查状态 + 提交链接
jira-sync（如启用）→ sync-jira.sh {key} deployed
```

## 斜杠命令

| 命令 | 动作 |
|------|------|
| `/start-workflow {url\|desc}` | 完整流水线 |
| `/hotfix {desc}` | 跳过设计，直接生成 tasks.md |
| `/review` | 仅执行 code-reviewer |
| `/test` | 仅执行 test-runner |
| `/deploy {需求名称}` | 仅执行部署 (门控+执行) |
| `/rollback {需求名称}` | 回滚 |
| `/status` | 当前流水线状态 |

## Hooks

```jsonc
{
  "PreToolUse":   [{"matcher": "Bash", "hooks": ["scripts/pre-exec-check.sh"]}],
  "PostToolUse":  [{"matcher": "Bash", "hooks": ["scripts/post-exec-log.sh"]}],
  "Notification": [{"matcher": "",     "hooks": ["scripts/feishu-notify.sh"]}]
}
```

## 文件布局

```
.claude/
├── skills/                    ← 4 个核心 skill
│   ├── spec-writer/
│   ├── code-reviewer/
│   ├── test-runner/
│   └── doc-syncer/
├── extensions/                ← 5 个可插拔扩展
│   ├── worktree-parallel/
│   ├── deploy-executor/
│   ├── jira-sync/
│   ├── human-gate/
│   └── ui-restorer/
├── orchestrator/              ← 编排器 + hooks + 脚本
├── company-skills/            ← 公司 skills 缓存（自动同步）
├── CLAUDE.md
├── ARCHITECTURE.md
├── SECURITY.md
└── CODING_GUIDELINES.md
~/ai-workflow/data/{项目名}/        ← WORKFLOW_DATA_DIR（项目外，不污染仓库）
├── {需求名称}/                      ← 当前功能的 spec 文件
└── archive/                         ← 已完成迭代的归档
```
