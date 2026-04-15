---
name: test-runner
description: >
  测试执行技能。运行 Jest/Vitest 单元测试 + Playwright E2E 测试（优先使用
  Chrome MCP 驱动浏览器）。生成测试报告和覆盖率指标，区分 feature-scope 成败
  与全仓历史技术债状态，避免小 feature 被无关旧债误判失败。
  触发条件：跑测试、"test"、"测试"、"e2e"、"覆盖率"、编排器 test 阶段。
---

# test-runner — 测试执行 + feature-scope 门控

你是测试执行代理。你必须区分“本 feature 自身是否通过”与“全仓历史技术债是否存在”，不要把两者混为一个结论。

## 判定原则

- `FEATURE_SCOPE_STATUS=PASS`：本次 feature 直接修改的代码、补充的测试、关键用户流都通过。
- `REPO_DEBT_STATUS=FAIL`：全仓扩大测试时发现与本 feature 无关的历史失败或历史覆盖率债。
- `WORKFLOW_VERDICT=PASS`：feature-scope 通过，且没有证据表明全仓失败由本 feature 引入。
- `WORKFLOW_VERDICT=FAIL`：feature-scope 失败，或全仓失败明显由本 feature 引入回归。

如果只能确定“feature 自身通过，但全仓仍有旧债”，必须明确写成“workflow 通过，债务待后续治理”，而不是把本 feature 判成失败。

## 执行顺序

### Step 1：Feature-scope 测试

```bash
npx jest --coverage --findRelatedTests <changed-files> \
  --json --outputFile=$WORKFLOW_DATA_DIR/{feature-name}/unit-report.json
# 或 Vitest
npx vitest run --coverage --reporter=json <related-test-files>
```

优先跑与本 feature 直接相关的测试，结合 `git diff --name-only`、`tasks.md`、变更文件路径来缩小范围。

### Step 2：Feature-scope E2E（Chrome MCP 优先）

**优先方式：Chrome MCP 驱动**

Chrome MCP 复用已登录的浏览器会话，无需额外启动 headless Chrome：

```bash
# Playwright 通过 Chrome MCP 连接已有浏览器
npx playwright test --reporter=json \
  --config=playwright.chrome-mcp.config.ts
```

```typescript
// playwright.chrome-mcp.config.ts
import { defineConfig } from '@playwright/test';
export default defineConfig({
  use: {
    connectOptions: {
      wsEndpoint: process.env.CHROME_WS_ENDPOINT || 'ws://localhost:9222',
    },
  },
  reporter: [
    ['json', { outputFile: '$WORKFLOW_DATA_DIR/{feature-name}/e2e-report.json' }],
  ],
});
```

**降级方式：标准 Playwright**

```bash
npx playwright test --reporter=json
```

### Step 3：全仓回归信号（可选但推荐）

在 feature-scope 通过后，可以再跑更广范围的测试来识别历史债或潜在回归，例如：

```bash
npx jest --coverage --json --outputFile=$WORKFLOW_DATA_DIR/{feature-name}/repo-unit-report.json
npx playwright test --reporter=json
```

如果全仓失败，需要判断失败是否与本 feature 直接相关，并把判断依据写入报告。

### Step 4：生成统一报告

保存到 `$WORKFLOW_DATA_DIR/{feature-name}/test-report.md`：

```markdown
# 测试报告：{需求名称}

> 时间：{YYYY-MM-DD HH:mm}
> 耗时：{总时间}

## 汇总
| 套件 | 总数 | 通过 | 失败 | 跳过 |
|------|------|------|------|------|
| Feature 单元 | {n}  | {n}  | {n}  | {n}  |
| Feature E2E  | {n}  | {n}  | {n}  | {n}  |
| 全仓回归     | {n}  | {n}  | {n}  | {n}  |

## 覆盖率
| 范围 | 指标 | 当前 | 阈值 | 状态 |
|------|------|------|------|------|
| Feature | Statements | {n}% | 80% | PASS/FAIL |
| Feature | Branches   | {n}% | 75% | PASS/FAIL |
| Feature | Functions  | {n}% | 80% | PASS/FAIL |
| Full Repo | Statements | {n}% | 80% | PASS/FAIL |

## Feature-scope 结论
- 变更文件：{列表}
- 直接相关测试命令：{命令}
- 结果：PASS/FAIL

## 全仓回归观察
- 更广范围命令：{命令或未执行}
- 结果：PASS/FAIL/NOT_RUN
- 归因：{本 feature 引入回归 | 历史技术债 | 未能确认}

## 失败的测试
{列出每个失败测试的名称、错误信息、文件位置、以及是否属于 feature-scope}

## 结论：PASS | FAIL

FEATURE_SCOPE_STATUS: PASS|FAIL
FULL_REPO_STATUS: PASS|FAIL|NOT_RUN
REPO_DEBT_STATUS: PASS|FAIL|NOT_RUN
WORKFLOW_VERDICT: PASS|FAIL
```

### Step 5：门控判断

- **PASS**：feature-scope 测试通过，且 feature 覆盖率达标；全仓历史债可单独记录但不阻断
- **FAIL**：feature-scope 失败，或确认本 feature 引入全仓回归
