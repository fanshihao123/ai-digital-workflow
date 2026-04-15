---
description: 分析目标项目，智能生成 .claude/ 知识库文件（CLAUDE.md + rules/）
argument-hint: [项目路径，默认当前目录]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /init-knowledge — 项目知识库智能初始化

分析当前项目的技术栈、目录结构、配置文件，自动生成有内容的 `.claude/` 知识库文件。
替代手动填写空壳文件，借鉴 laoyuan `/yd:init` 的"先分析后生成"理念。

## 执行步骤

### 1. 分析项目

在生成任何文件之前，全面分析当前项目：

- 读取 `package.json`、`Cargo.toml`、`go.mod`、`pyproject.toml`、`pom.xml`、`composer.json` 等，判断语言和框架
- 扫描目录结构（重点 `src/`、`app/`、`lib/`、`tests/`、`migrations/`、`contracts/`）
- 读取现有 README、CI 配置（`.github/workflows/`）、lint 配置（`.eslintrc`、`prettier`）、`tsconfig.json` 等
- 识别项目是否包含前端、后端 API、数据库、智能合约等模块
- 读取 git log 最近 20 条 commit，推断 commit 风格和活跃模块

### 2. 检查现有文件

- 如果 `.claude/CLAUDE.md` 已有实质内容（超过 5 行），先读取并保留用户已写的内容
- 如果 `.claude/rules/` 已存在且有文件，询问用户是覆盖还是合并
- 新生成的内容与已有内容合并，不丢失用户手写的部分

### 3. 生成 CLAUDE.md

控制在 **150 行以内**，必须包含：

```markdown
# {项目名}

{一句话简介，从 README 或 package.json description 提取}

## 技术栈

- 语言: {lang}
- 框架: {framework}
- 包管理: {pkg manager}
- 构建工具: {build tool}
- 测试框架: {test framework}

## 常用命令

- 安装依赖: `{install cmd}`
- 开发运行: `{dev cmd}`
- 构建: `{build cmd}`
- 测试: `{test cmd}`
- Lint: `{lint cmd}`

## 目录结构

{树形结构速览，只列关键目录，不超过 20 行}

## 规则

@rules/coding-style.md
@rules/testing.md
@rules/security.md
@rules/git-workflow.md
{以下按需引入}
```

### 4. 生成 rules/ 文件

每个 rules 文件使用 frontmatter 格式：

```markdown
---
description: {规则一句话描述}
globs: {可选，如 "src/web/**"}
---

# {规则标题}

{具体规则内容，从项目实际配置中推断}
```

**按需生成（只创建与项目相关的）：**

| 文件 | 生成条件 | 内容来源 |
|------|---------|---------|
| `coding-style.md` | 始终生成 | eslint/prettier/editorconfig/rustfmt 配置推断 |
| `testing.md` | 有测试框架 | 测试框架配置 + 现有测试文件模式 |
| `security.md` | 始终生成 | .gitignore 规则 + 依赖分析 + 常见安全要求 |
| `git-workflow.md` | 始终生成 | git log 推断 commit 风格 + 分支命名 |
| `frontend.md` | 有前端代码 | 组件规范、路由约定、状态管理 |
| `backend-api.md` | 有后端 API | API 设计规范、错误处理、中间件 |
| `database.md` | 有 migration/ORM | migration 规范、查询约定 |
| `smart-contract.md` | 有合约代码 | 合约安全、审计清单、部署流程 |

### 5. 生成 ARCHITECTURE.md

从目录结构和代码分析中生成架构文档：

- 模块划分和职责
- 数据流向
- 关键接口/API 边界
- 外部依赖和集成点

### 6. 输出总结

```text
📚 知识库初始化完成

CLAUDE.md:        {生成/更新} ({N} 行)
ARCHITECTURE.md:  {生成/更新}
rules/ 文件:      {列出生成的文件}
  - coding-style.md
  - testing.md
  - security.md
  - git-workflow.md
  - {其他按需生成的...}

提示: 请审查生成的文件，补充项目特有的约定和规范。
```

## 重要约束

- 所有规则内容**必须基于项目实际情况推断**，不生成空洞的通用规则
- CLAUDE.md 严格控制在 150 行以内
- 不覆盖用户已有的实质内容，优先合并
- 只创建与项目实际相关的 rules 文件
