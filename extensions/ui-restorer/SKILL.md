---
name: ui-restorer
description: >
  可插拔扩展。通过 Antigravity + Figma MCP 进行 UI 设计还原，还原完成后
  交给 Claude Code + OpenCLI Codex 进行双重审查（代码质量 + UI 一致性）。
  Antigravity 只负责 UI 组件和样式生成，不碰业务逻辑。
  启用方式：.env 中设置 ENABLE_UI_RESTORER=true。
  触发条件：tasks.md 中存在 agent: antigravity 标记的任务、
  Figma URL 输入、"还原页面"、"画页面"、"UI 还原"。
---

# ui-restorer — Antigravity 设计还原 + 双重审查（可插拔扩展）

## 启用条件

`.env` 中 `ENABLE_UI_RESTORER=true`。未启用则所有任务由 Claude Code 执行。

## 三阶段流程

```
tasks.md 中 agent: antigravity 的任务
                  |
         ┌───────┴───────┐
         │ Stage 1: 还原  │  Antigravity + Figma MCP
         │ 独立 worktree  │  只生成 UI 组件 + 样式
         └───────┬───────┘
                 |
         ┌───────┴───────┐
         │ Stage 2: 审查  │  Claude Code 代码质量审查
         │               │  + OpenCLI Codex UI 一致性审查
         └───────┬───────┘
                 |
          有问题？─── yes → Antigravity 修复 → 再审查
                 |
                 no
                 |
         ┌───────┴───────┐
         │ Stage 3: 集成  │  Claude Code 接入业务逻辑
         │ API/状态/路由   │  (tasks.md 中的下一个任务)
         └───────────────┘
```

## Stage 1：Antigravity UI 还原

### 环境准备

Antigravity 在独立 worktree 中工作（如 worktree-parallel 已启用）
或在主目录中工作（如未启用 worktree 扩展）。

### Figma MCP 配置

在 Antigravity 的 `mcp_config.json` 中配置 Figma：

```jsonc
{
  "mcpServers": {
    // 方式 A：Figma 官方 Dev Mode MCP（推荐，远程零配置）
    "figma": {
      "url": "https://mcp.figma.com/mcp",
      "type": "streamable-http"
    }

    // 方式 B：社区 figma-mcp-server（本地 stdio）
    // "figma": {
    //   "command": "npx",
    //   "args": ["-y", "figma-mcp-server", "--stdio"],
    //   "env": { "FIGMA_API_KEY": "${FIGMA_API_KEY}" }
    // }

    // 方式 C：Composio Rube MCP（聚合网关）
    // "rube": {
    //   "command": "npx",
    //   "args": ["-y", "rube-mcp", "--api-key=${RUBE_API_KEY}"]
    // }
  }
}
```

### 调度 Antigravity

```bash
# 方式 1：OpenCLI CLI 化 Antigravity（推荐，编排器可自动调度）
opencli antigravity "
  打开 Figma 设计稿: ${FIGMA_URL}
  根据设计稿生成以下文件:
  - ${FILE_PATH} (React/Vue 组件)
  只生成 UI 组件和样式代码。
  不要包含: API 调用、状态管理、路由跳转、事件处理逻辑。
  遵循项目的组件命名规范和目录结构。
  使用项目已有的 design system 组件（如 Button、Input 等）。
"

# 方式 2：手动在 Antigravity IDE 中操作
# 打开 Antigravity → 粘贴 Figma URL → 生成代码 → 提交到 worktree 分支
```

### Antigravity 生成规范

指导 Antigravity 生成代码时遵循这些规则：

```
Antigravity 生成提示词模板:

你只负责 UI 还原。根据 Figma 设计稿 {figma_url} 生成代码。

必须遵循:
1. 使用项目的 design system 组件（检查 src/components/ui/）
2. 使用项目的 CSS 变量 / Tailwind 配置（检查 tailwind.config）
3. 组件文件放在 {file_path} 路径
4. Props 接口定义在组件文件顶部
5. 响应式断点: mobile(375) / tablet(768) / desktop(1440)

不要包含:
- API 调用（用 TODO 注释标记数据来源）
- 状态管理逻辑（用 props 传入，不用 useState/Redux）
- 路由跳转（用 onClick props 代替 router.push）
- 硬编码文字（用 props 或 i18n key）
- 内联颜色值（用 design token / CSS 变量）
```

## Stage 2：双重审查

Antigravity 提交代码后，分两步审查：

### 审查 A：Claude Code 代码质量审查

```bash
opencli claude --permission-mode bypassPermissions --model sonnet --print "
  审查 Antigravity 生成的 UI 代码。
  
  变更文件: $(git diff --name-only HEAD~1..HEAD)
  
  审查重点（与纯逻辑审查不同）:
  1. 是否使用项目已有的 design system 组件（不要重复造轮子）
  2. 是否有硬编码颜色/字号/间距（应使用 design token）
  3. 组件命名是否符合项目规范
  4. Props 接口是否合理（纯 UI 组件不应依赖业务类型）
  5. 响应式实现是否正确
  6. 是否有不必要的 div 嵌套层级
  7. 图片/图标是否使用了正确的导入方式
  
  项目组件规范: $(cat .claude/CODING_GUIDELINES.md | grep -A 50 '组件\|component')
"
```

### 审查 B：OpenCLI Codex UI 一致性 + a11y 审查

```bash
codex exec --full-auto "
  审查以下 UI 代码的可访问性和设计一致性。
  
  Diff: $(git diff HEAD~1..HEAD)
  
  检查:
  1. 所有交互元素是否有 aria-label 或 alt 文本
  2. 颜色对比度是否满足 WCAG AA 标准
  3. 键盘导航是否可用（tabIndex, focus 管理）
  4. 表单是否有 label 关联
  5. 语义化 HTML（不要全是 div）
  6. 图片是否有适当的 loading 策略（lazy）
"
```

### 审查结果处理

```
两个审查都 PASS → Stage 3 集成
任一审查 FAIL → 生成修复指令 → Antigravity 修复 → 再审查（最多 2 轮）
2 轮后仍 FAIL → Claude Code 接管修复
```

## Stage 3：集成（由 Claude Code 执行）

审查通过后，tasks.md 中 `agent: antigravity` 任务标记为 done，
下一个依赖任务（`agent: claude-code`）负责业务集成：

```markdown
### Task 4：登录页面集成
- agent: claude-code
- 依赖：Task 3（UI 还原）
- 指令：
  - 将 LoginForm 组件接入 /login 路由
  - 绑定 POST /api/auth/login API
  - 添加表单验证（邮箱格式 + 密码长度）
  - 接入全局 auth 状态管理
  - 添加登录失败错误提示
```

## tasks.md 标记规范

spec-writer 在生成 tasks.md 时，UI 还原任务使用以下格式：

```markdown
### Task N：{页面名称} UI 还原
- agent: antigravity
- figma: {figma-url}
- 文件范围：{生成文件路径}
- 指令：根据 Figma 设计稿还原 {页面名称}，只生成 UI 组件和样式
- 不要包含：API 调用、状态管理、路由逻辑

### Task N+1：{页面名称} 业务集成
- agent: claude-code
- 依赖：Task N
- 指令：将 Task N 的 UI 组件接入业务逻辑（API/状态/路由）
```

编排器看到 `agent: antigravity` 就调度本扩展，`agent: claude-code`（或无标记）走正常 Claude Code 执行。

## Figma 设计稿准备建议

提高 Antigravity 还原质量的 Figma 规范：

1. **命名图层** — 用有意义的名称如 `login-form-email-input` 而不是 `Frame 42`
2. **使用 Auto Layout** — Antigravity 能更好地理解 flex 布局意图
3. **定义 Design Token** — 颜色、字号、间距用 Figma Variables，不用裸值
4. **标注交互状态** — hover、active、disabled 做成 Variant
5. **开启 Dev Mode 注释** — 在 Figma Dev Mode 中为关键元素添加注释，Figma MCP 会读取

## 环境变量

| 变量 | 说明 |
|------|------|
| `ENABLE_UI_RESTORER` | 启用本扩展 (true/false) |
| `FIGMA_API_KEY` | Figma Personal Access Token（方式 B/C 需要） |
| `RUBE_API_KEY` | Composio Rube API Key（方式 C 需要） |
| `UI_REVIEW_ROUNDS` | 审查轮次上限，默认 2 |
