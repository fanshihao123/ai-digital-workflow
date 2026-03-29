---
name: ui-restorer
description: >
  可插拔扩展。通过 Antigravity（Gemini 3 多模态）+ Figma MCP 进行分块 UI 设计还原。
  还原流程：dev server 检查 → 分块还原（2轮自动重试 + 截图视觉反馈闭环）→ 人工确认节点
  → Codex 代码规范审查。Antigravity 按场景切换 Thinking/Pro/Fast 三种模式。
  启用方式：.env 中设置 ENABLE_UI_RESTORER=true。
  触发条件：tasks.md 中存在 agent: antigravity 标记的任务。
---

# ui-restorer — Antigravity 分块还原 + 视觉反馈闭环（可插拔扩展）

## 启用条件

`.env` 中 `ENABLE_UI_RESTORER=true`。未启用则所有任务由 Claude Code 执行。

## Antigravity 模式策略

| 场景 | 模式 | 当前落地方式 |
|------|------|-------------|
| 生成 UI 代码 / 带 diff 定向修复（复杂改动） | **Thinking** | 优先 `Claude Opus 4.6 (Thinking)`，额度/不可用时顺延降级到 `Gemini 3.1 Pro (High)`，再降到 `Gemini 3 Flash` |
| 截图对比 Figma → 视觉打分 + 找 diff | **Codex 评分** | 用 `chrome-cdp-skill` 截图后交给 Codex 输出 `SCORE / DIFF_COMPLEXITY / FIXES / PASS` |
| 微调修复（颜色值/字号/间距等小改动） | **Fast** | 优先 `Gemini 3.1 Pro (High)`，不可用时降级到 `Gemini 3 Flash`，用更短、更聚焦的 diff 修复提示词驱动 `send` |

**模式切换规则：**
- Codex 评分时输出 `DIFF_COMPLEXITY: minor|major`
- `minor` → Round 2 用 Fast 模式执行修复（颜色/字号/间距等数值调整）
- `major` → Round 2 用 Thinking 模式执行修复（布局重构/组件替换）

## 完整流程

```
tasks.md 中所有 agent: antigravity 任务
    ↓
[Phase 0] dev server 检查
    ↓
[Phase 1] 逐任务分块还原（含 2 轮自动重试 + 视觉反馈闭环）
    ↓
[Phase 2] 人工确认节点（按模块数量决定汇报粒度）
    ↓
[Phase 3] Codex 代码规范审查（一轮）
    ↓
[Phase 4] claude-code 接入业务逻辑
```

---

## Phase 0：dev server 检查

### 检查逻辑

```bash
# 检查常见端口（按 package.json 中的 dev 脚本端口优先）
DEV_PORT=$(node -e "
  const pkg = require('./package.json');
  const devScript = pkg.scripts?.dev || '';
  const match = devScript.match(/--port[= ](\d+)/);
  console.log(match ? match[1] : '3000');
" 2>/dev/null || echo "3000")

if lsof -i :"$DEV_PORT" | grep -q LISTEN 2>/dev/null; then
  echo "RUNNING:$DEV_PORT"
else
  echo "STOPPED:$DEV_PORT"
fi
```

### 三种情况处理

**情况 1：dev server 已开启**
```
→ cdp nav 到对应 Task 的预览路由
→ feishu_notify "dev server 已在 http://localhost:{PORT} 运行，
   正在打开 {PREVIEW_ROUTE} 进行 UI 还原..."
```

**情况 2：dev server 未开启**
```
→ 后台启动: nohup npm run dev > /tmp/devserver-{feature}.log 2>&1 &
→ 等待端口就绪（最多 60s，每 2s 检查一次）
→ 就绪后 feishu_notify "dev server 已启动: http://localhost:{PORT}{PREVIEW_ROUTE}"
→ cdp nav 到预览路由
```

**情况 3：启动失败（60s 超时）**
```
→ agent_notify:
  "dev server 启动失败，日志: /tmp/devserver-{feature}.log
   请手动启动后执行 /resume {feature}"
→ 流水线暂停（return 1）
```

---

## Phase 1：分块还原（核心循环）

tasks.md 中每个 `agent: antigravity` 任务包含分块策略（由 spec-writer Stage 1b 通过
Figma MCP 提取生成）。按块顺序执行，每块独立走完 Round 1 → Round 2 → 人工节点流程。

### 结构化提示词模板（Round 1，Thinking 模式）

```
opencli antigravity send "
你只负责 UI 还原，不碰业务逻辑。

## 当前任务
页面：{TASK_NAME}
当前分块：{BLOCK_NAME}（第 {BLOCK_INDEX}/{BLOCK_TOTAL} 块）
生成文件：{FILE_PATH}
预览路由：{PREVIEW_ROUTE}

## Figma 设计规格（已从 Figma MCP 提取）
{DESIGN_SPEC}
（包含：布局结构 / 间距 / 颜色 / 字体 / 组件层级）

## 项目约束
- 使用项目已有的 design system 组件（src/components/ui/）
- 使用项目的 CSS 变量 / Tailwind 配置（检查 tailwind.config）
- 响应式断点：mobile(375) / tablet(768) / desktop(1440)
- Props 接口定义在组件顶部
- 禁止：API 调用 / 状态管理 / 路由跳转 / 硬编码颜色值 / 内联样式

## 分块还原顺序
$(cat tasks.md 中对应 task 的 还原策略 字段)

请生成 {BLOCK_NAME} 的代码，写入 {FILE_PATH}。
"
```

### 截图 + 视觉打分（Pro 模式）

每轮生成后：

```bash
# 1. 用 chrome-cdp-skill 截图
node scripts/cdp.mjs shot {TAB_TARGET} /tmp/ui-restore-{feature}-{block}-round{N}.png

# 2. 用 Codex 做结构化视觉评分
codex exec --full-auto "
请基于以下信息评估 UI 还原质量：

Figma 设计稿：{FIGMA_URL}
目标区域：{NODE_ID 或 BLOCK_NAME}
当前渲染截图文件：/tmp/ui-restore-{feature}-{block}-round{N}.png

评估维度：
1. 整体布局结构是否一致
2. 间距/padding/margin 是否准确
3. 颜色/字体/字号是否匹配
4. 组件细节（圆角/阴影/边框）是否还原
5. 响应式是否正确

输出格式（严格遵循）：
SCORE: {1-10}
DIFF_COMPLEXITY: minor|major
FIXES:
  - {具体修复项1，格式: 元素.属性: 实际值 → 设计值}
  - {具体修复项2}
PASS: true|false  （SCORE >= 8 为 true）
"
```

### Round 1 → Round 2 决策树

```
Round 1 完成
    ↓
截图 → Pro 模式打分
    ↓
SCORE >= 8？
  ├── YES → 该块 PASS，进入下一块
  └── NO  → 读取 DIFF_COMPLEXITY
              ├── minor → Round 2: 精确微调
              │     opencli antigravity send \
              │       "根据以下 diff 进行精确修复：{FIXES 列表}"
              └── major → Round 2: 结构性重构
                    opencli antigravity send \
                      "根据以下 diff 进行修复：{FIXES 列表}
                       Figma 设计规格参考：{DESIGN_SPEC}"
                ↓
            再次截图 → Pro 模式打分
                ↓
            SCORE >= 8？
              ├── YES → 该块 PASS
              └── NO  → 记录为 NEEDS_HUMAN_REVIEW
                         附: 截图路径 + FIXES 列表 + 当前得分
```

---

## Phase 2：人工确认节点

### 汇报粒度决策

```
当前任务总块数 = tasks.md 中 还原策略 的分块数量

块数 <= 3：
  → 所有块完成后一次汇报

块数 > 3：
  → 每完成 3 块汇报一次（3块、6块、9块...）
  → 最后不足 3 块的余量在全部完成后汇报
```

### agent_notify 消息格式

```
# 汇报消息内容
context="UI 还原进度报告 — {TASK_NAME}

已完成分块：{已完成块列表}
自动通过（SCORE >= 8）：{通过块数}/{总块数}

{如有需人工确认的块}：
─ {块名}：当前得分 {SCORE}/10
  主要问题：{FIXES 列表}
  截图已保存：{截图路径}

{附所有截图路径供查看}"

question="请查看截图后回复：
1. 满意 → 回复「继续」
2. 不满意 → 描述具体问题（如：按钮颜色不对/间距太大），
   我会带着你的反馈让 Antigravity 重新修复"
```

### 用户回复处理

```
用户回复「继续」→ 进入 Phase 3 Codex 审查
用户回复具体反馈 → Antigravity Thinking 模式带反馈重试
                    重试后再次截图 → 再次汇报（不再计入自动重试轮次）
```

---

## Phase 3：Codex 代码规范审查（一轮）

所有块还原完成并通过人工确认后，执行一轮 Codex 代码审查：

```bash
codex exec --full-auto "
审查 Antigravity 生成的 UI 代码（代码规范审查，非视觉审查）。

变更文件：
$(git diff --name-only HEAD)

审查清单：
1. 是否有硬编码颜色/字号/间距（必须使用 design token / CSS 变量）
2. 是否重复造轮子（项目已有的 design system 组件是否被正确使用）
3. Props 接口是否合理（纯 UI 组件不应依赖业务类型）
4. 是否有不必要的 div 嵌套（超过 4 层需说明）
5. 所有交互元素是否有 aria-label 或 alt 文本（a11y）
6. 表单元素是否有 label 关联
7. 图片是否使用 lazy loading
8. 组件命名是否符合项目规范（检查 .claude/CODING_GUIDELINES.md）

输出格式：
CODEX_VERDICT: PASS|FAIL
ISSUES:
  - SEVERITY: WARNING|ERROR
    FILE: {文件路径}
    LINE: {行号}
    ISSUE: {问题描述}
    FIX: {修复建议}
"
```

### 审查结果处理

```
CODEX_VERDICT: PASS → 继续 Phase 4
CODEX_VERDICT: FAIL →
  ERROR 级别问题 → Antigravity Fast/Thinking 模式修复后再次审查
  WARNING 级别问题 → feishu_notify 列出警告，继续 Phase 4（不阻塞）
```

---

## Phase 4：业务集成（claude-code 执行）

Antigravity 任务标记为 done，触发 tasks.md 中依赖该任务的 `agent: claude-code` 任务：

```markdown
### Task N+1：{页面名称} 业务集成
- agent: claude-code
- 依赖：Task N（UI 还原）
- 指令：
  - 将 {组件名} 接入 {路由}
  - 绑定 {API 端点}
  - 接入状态管理
  - 添加表单验证
  - 添加错误处理
```

---

## tasks.md 任务格式规范

spec-writer Stage 1b 通过 Antigravity + Figma MCP 提取设计规格后，
antigravity 任务必须包含以下字段：

```markdown
### Task N：{页面名称} UI 还原
- agent: antigravity
- figma: {figma-url}
- 预览路由: /{route-path}
- 状态：pending
- 文件范围：`{组件文件路径}`
- 依赖：Task {前置任务编号}
- 设计规格：
  - 布局：{整体布局描述，如：垂直居中，max-width 480px}
  - 容器：{padding, border-radius, shadow}
  - 主色：{颜色值或 design token}
  - 字体：{标题/正文/标签的字号和字重}
  - 间距：{主要元素间距规律}
  - 组件：{使用到的 design system 组件列表}
- 还原策略：
  - 块1: {区块名称}（如：整体布局框架）
  - 块2: {区块名称}（如：表单输入区域）
  - 块3: {区块名称}（如：按钮和操作区）
  - 块4: {区块名称}（如：响应式适配）
- 指令：只生成 UI 组件和样式，不包含 API 调用、状态管理、路由逻辑
```

---

## chrome-cdp-skill 集成

本扩展使用 chrome-cdp-skill 作为截图工具，默认走项目内置入口 `scripts/cdp.mjs`。

### 安装

```bash
# 将 chrome-cdp-skill 的 cdp.mjs 放到目标项目根目录
# 目标路径：scripts/cdp.mjs
# 并确保 Chrome 已开启 remote debugging（chrome://inspect/#remote-debugging）
```

### 常用命令

> 注：当前 `opencli 1.3.x` 下，`opencli antigravity send` 负责发消息；若要读取 AI 回复，需额外调用 `opencli antigravity read` 或 `watch`。`send` 不再支持 `--model` / `--variant` 参数。

```bash
# 列出所有 tab
node scripts/cdp.mjs list

# 截图（返回 PNG 文件）
node scripts/cdp.mjs shot {target} {output.png}

# 导航到指定 URL
node scripts/cdp.mjs nav {target} http://localhost:3000/login

# 获取 computed styles（辅助 diff 分析）
node scripts/cdp.mjs eval {target} "
  JSON.stringify([...document.querySelectorAll('[class]')].slice(0,20).map(el => ({
    tag: el.tagName,
    class: el.className,
    styles: {
      height: getComputedStyle(el).height,
      padding: getComputedStyle(el).padding,
      color: getComputedStyle(el).color,
      fontSize: getComputedStyle(el).fontSize
    }
  })))
"
```

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `ENABLE_UI_RESTORER` | 启用本扩展 (true/false) |
| `FIGMA_API_KEY` | Figma Personal Access Token（Figma MCP 本地模式需要） |
| `DEV_SERVER_PORT` | dev server 端口，默认自动检测（fallback 3000） |
| `UI_RESTORE_SCORE_THRESHOLD` | 自动通过分数阈值，默认 8 |
| `UI_RESTORE_REPORT_BATCH_SIZE` | 分批汇报块数，默认 3 |
