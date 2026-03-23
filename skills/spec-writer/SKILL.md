---
name: spec-writer
description: >
  需求→设计→任务一站式生成。接收 URL 或文字描述，通过 Chrome MCP 抓取页面内容
  或直接解析文字，结合 .claude/ 项目规范和公司 skills 知识库，一次性输出
  requirements.md + design.md + tasks.md 三个文件到 specs/{feature-name}/ 目录。
  触发条件：/start-workflow、/workflow、新需求、Jira URL、飞书消息、
  "写 spec"、"生成设计"、"分解任务"。
---

# spec-writer — 需求·设计·任务一站式生成

你是规格文档撰写代理。你的职责是将模糊的输入（URL 或文字描述）转化为
三个结构化文档，一次性完成，不分步。

## 输入解析

```
/start-workflow {url | text description}
                    |
              URL 还是文字？
             /            \
           yes              no
            |                |
     Chrome MCP 抓取       直接解析文字
     页面标题/描述/          提取意图和范围
     验收标准/优先级
            \              /
             汇合 → 结构化需求上下文
```

### URL 输入（Jira / 飞书文档 / Confluence / 任意网页）

通过 Chrome MCP 抓取，复用浏览器登录态，无需额外 API Token：

```bash
# Claude Code 中调用 Chrome MCP 读取页面
# 自动读取页面标题、正文、表单字段、评论等
```

抓取后提取：标题、描述、验收标准、优先级、关联链接。
如果是 Jira URL，额外提取 issue key（后续 jira-sync 扩展使用）。

### 文字输入

直接解析用户描述，推断 What/Who/Why/Where。
信息不足的部分标记 `[INFERRED]` 并合理推断默认值。

## 知识注入

在生成前加载两层知识：

**Layer 1：项目规范（.claude/ 下）**
- CLAUDE.md → 项目指令和约定
- ARCHITECTURE.md → 模块边界和数据流
- SECURITY.md → 安全策略
- CODING_GUIDELINES.md → 编码规范

**Layer 2：公司 skills 知识库（侧输入）**
- 编排器自动匹配并注入当前任务相关的公司 skill
- 例如 React 相关需求 → 注入 `react-conventions` skill
- 公司 skill 中的模式和约定必须遵循

优先级：.claude/ 项目规范 > 公司 skills > Claude 自身知识

## 输出：三个文件一次性生成

所有输出保存到 `specs/{feature-name}/` 目录。
需求名称使用英文 kebab-case，如 `specs/user-login-oauth/`。

### 1. requirements.md

```markdown
# 需求：{需求名称}

> 生成时间：{YYYY-MM-DD HH:mm}
> 来源：{url | 飞书消息 | 手动描述}
> Jira：{issue-key | 无}

## 概述
{2-3 句话概括}

## 用户故事
- 作为{角色}，我希望{行为}，以便{价值}

## 功能需求
- FR-001：{描述} | 优先级：P0/P1/P2 | 验收：{可量化标准}

## 非功能需求
- NFR-001：性能 — {具体指标}
- NFR-002：安全 — {具体要求}

## 范围外
- {明确排除的内容}

## 开放问题
- [ ] {标记 [INFERRED] 的待确认项}
```

### 2. design.md

```markdown
# 设计：{需求名称}

> 需求：specs/{feature-name}/requirements.md
> 复杂度：low | medium | high
> 预估：{N 个任务}

## 受影响模块
- {模块名}：{变更内容和原因}

## 数据模型变更
{SQL migration 或 "无"}

## API 变更
{新增/修改的端点或 "无"}

## 安全考虑
{认证/授权/输入验证或 "无特殊要求"}

## 测试策略
- 单元测试：{重点覆盖}
- E2E：{关键用户流}

## 回滚方案
{如何安全回退}
```

### 3. tasks.md

```markdown
# 任务：{需求名称}

> 设计：specs/{feature-name}/design.md
> 总任务数：{N}
> 状态：pending

### Task 1：{简短描述}
- agent: claude-code
- 状态：pending
- 文件范围：{具体文件路径}
- 依赖：无
- 指令：{具体步骤}
- 验证：
  - [ ] {检查项}

### Task 2：{页面名} UI 还原
- agent: antigravity
- figma: {figma-design-url}
- 状态：pending
- 文件范围：{组件文件路径}
- 依赖：Task 1
- 指令：根据 Figma 设计稿还原页面，只生成 UI 组件和样式
- 不要包含：API 调用、状态管理、路由逻辑

### Task 3：{页面名} 业务集成
- agent: claude-code
- 状态：pending
- 依赖：Task 2
- 指令：将 Task 2 的 UI 组件接入 API、状态管理、路由
```

**agent 标记规则**：
- `agent: claude-code`（或省略）→ Claude Code Sonnet 执行
- `agent: antigravity` → Antigravity + Figma MCP 执行（需 ENABLE_UI_RESTORER=true）
- 涉及 Figma 设计稿的纯 UI 还原任务 → 标记 `agent: antigravity` + 附带 `figma:` URL
- UI 任务之后紧跟一个 `agent: claude-code` 的集成任务

## 复杂度评估规则

在 design.md 中设定 complexity：
- **low**：≤ 4 任务，1-2 模块，无数据模型变更
- **medium**：5-8 任务，3-4 模块，小规模数据变更
- **high**：> 8 任务，5+ 模块，新服务/大规模数据迁移

`complexity: high` 会触发 worktree-parallel 扩展（如已启用）。

## 三阶段交叉审查（核心质量保障）

spec-writer 的输出必须经过**三阶段交叉审查**才算完成。
不同模型看问题的角度不同，交叉审查能捕获单模型的盲区。

```
Stage 1: Claude 生成初稿
    │  输出 requirements.md + design.md + tasks.md (v1)
    ↓
Stage 2: OpenAI Codex / GPT-5.4 审查
    │  审查 spec 质量 → 输出审查意见 + 修改建议
    ↓
Stage 3: Claude 复审 + 定稿
    │  综合审查意见 → 修正 → 输出最终版 (final)
    ↓
三个文件标记为 reviewed，进入下一阶段
```

### Stage 1：Claude 生成初稿

Claude 按照上面的模板，一次性生成三个文件的 v1 版本。
保存到 `specs/{feature-name}/` 目录，文件头部标记：

```markdown
> 状态：draft-v1
> 生成模型：claude
> 审查状态：pending-codex-review
```

### Stage 2：OpenAI Codex / GPT-5.4 审查

通过 OpenCLI 调度 Codex 审查 spec 质量：

```bash
opencli codex exec --full-auto "
你是一个资深技术架构师，负责审查以下 spec 文档的质量。

requirements.md:
$(cat specs/{feature-name}/requirements.md)

design.md:
$(cat specs/{feature-name}/design.md)

tasks.md:
$(cat specs/{feature-name}/tasks.md)

项目架构参考:
$(cat .claude/ARCHITECTURE.md)

请从以下维度逐项审查，对每项给出 PASS / ISSUE 判定：

【requirements.md 审查】
R1. 完整性 — 是否覆盖了需求描述中的所有功能点？有无遗漏？
R2. 可量化 — 每个验收标准是否可测试、可量化？是否有模糊表述（如'性能好'、'用户友好'）？
R3. 边界清晰 — 范围外是否明确？是否有可能被误解为包含的内容？
R4. 一致性 — 功能需求之间是否有矛盾？

【design.md 审查】
D1. 架构一致 — 设计是否符合项目现有架构（ARCHITECTURE.md）？是否引入不必要的新模式？
D2. 安全 — 安全考虑是否充分？认证/授权/输入验证是否遗漏？
D3. 复杂度准确 — complexity 评估与实际任务量是否匹配？
D4. 回滚可行 — 回滚方案是否真的可执行？

【tasks.md 审查】
T1. 原子性 — 每个任务是否足够小（≤5 文件）？是否有任务太大需要拆分？
T2. 依赖正确 — 任务依赖链是否正确？是否有循环依赖或遗漏依赖？
T3. 可执行 — 每个任务的指令是否具体到 Claude Code 可直接执行？
T4. 文件范围 — 文件范围是否准确？是否有遗漏或重叠？
T5. agent 标记 — UI 还原任务是否正确标记 agent: antigravity？

输出格式：
DIMENSION: R1
VERDICT: PASS | ISSUE
DETAIL: {具体问题描述，PASS 则为空}
SUGGESTION: {修改建议，PASS 则为空}

最后给出总结：
OVERALL: PASS | NEEDS_REVISION
CRITICAL_ISSUES: {数量}
SUMMARY: {一句话总结}
"
```

将审查结果保存到 `specs/{feature-name}/spec-review.md`：

```markdown
# Spec 审查报告

> 审查模型：openai-codex / gpt-5.4
> 时间：{YYYY-MM-DD HH:mm}

## requirements.md
| 维度 | 判定 | 问题 | 建议 |
|------|------|------|------|
| R1 完整性 | PASS/ISSUE | ... | ... |
| R2 可量化 | PASS/ISSUE | ... | ... |
| R3 边界清晰 | PASS/ISSUE | ... | ... |
| R4 一致性 | PASS/ISSUE | ... | ... |

## design.md
| D1 架构一致 | ... | ... | ... |
...

## tasks.md
| T1 原子性 | ... | ... | ... |
...

## 总结
- OVERALL：PASS / NEEDS_REVISION
- CRITICAL_ISSUES：{N}
```

### Stage 3：Claude 复审 + 定稿

Claude 读取 Codex 的审查报告，执行最终修订：

```
读取 specs/{feature-name}/spec-review.md

if OVERALL == "PASS" 且 CRITICAL_ISSUES == 0:
    → 将三个文件状态更新为 reviewed
    → 不做修改，直接进入下一阶段

if OVERALL == "NEEDS_REVISION":
    → 逐条处理 Codex 的 ISSUE：
       - 同意：按 SUGGESTION 修改对应文件
       - 不同意：在 spec-review.md 中标注理由（Claude 有权否决，但必须给出理由）
    → 更新三个文件为最终版
    → 文件头部标记更新为：

    > 状态：reviewed
    > 生成模型：claude
    > 审查模型：openai-codex / gpt-5.4
    > 审查轮次：1
    > 审查结论：{PASS / REVISED}
    > 修改项：{修改了哪些维度}
```

### 审查失败兜底

如果 Codex 审查发现 3 个以上 CRITICAL_ISSUES，Claude 复审后仍有未解决项：
1. 在飞书通知人工介入
2. 附上 spec-review.md 链接
3. 等待人工确认后才进入开发阶段

### 跳过审查的条件

以下场景跳过 Stage 2 + 3（节省时间和 token）：
- `/hotfix` 命令 — 紧急修复不需要完整 spec 审查
- 任务数 ≤ 2 且 complexity: low — 太简单不值得审查

## 自检清单（Stage 1 生成后、Stage 2 之前）

Claude 在提交给 Codex 审查之前，先过一遍基础自检：
- [ ] 每个功能需求有可量化的验收标准
- [ ] 每个任务只涉及有限的文件（≤ 5 个）
- [ ] 任务间依赖关系明确
- [ ] 安全需求和范围外都不为空
- [ ] 复杂度评估与任务数一致
- [ ] UI 任务正确标记 agent: antigravity

