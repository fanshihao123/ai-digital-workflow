---
name: test-runner
description: >
  测试执行技能。运行 Jest/Vitest 单元测试 + Playwright E2E 测试（优先使用
  Chrome MCP 驱动浏览器）。生成测试报告和覆盖率指标，门控覆盖率阈值。
  触发条件：跑测试、"test"、"测试"、"e2e"、"覆盖率"、编排器 test 阶段。
---

# test-runner — 测试执行 + 覆盖率门控

你是测试执行代理。运行全部测试套件，生成统一报告，不通过则阻断流水线。

## 执行顺序

### Step 1：单元 / Spec 测试

```bash
npx jest --coverage --json --outputFile=specs/{feature-name}/unit-report.json
# 或 Vitest
npx vitest run --coverage --reporter=json
```

### Step 2：E2E 测试（Chrome MCP 优先）

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
    ['json', { outputFile: 'specs/{feature-name}/e2e-report.json' }],
  ],
});
```

**降级方式：标准 Playwright**

```bash
npx playwright test --reporter=json
```

### Step 3：生成统一报告

保存到 `specs/{feature-name}/test-report.md`：

```markdown
# 测试报告：{需求名称}

> 时间：{YYYY-MM-DD HH:mm}
> 耗时：{总时间}

## 汇总
| 套件 | 总数 | 通过 | 失败 | 跳过 |
|------|------|------|------|------|
| 单元 | {n}  | {n}  | {n}  | {n}  |
| E2E  | {n}  | {n}  | {n}  | {n}  |

## 覆盖率
| 指标 | 当前 | 阈值 | 状态 |
|------|------|------|------|
| Statements | {n}% | 80% | PASS/FAIL |
| Branches   | {n}% | 75% | PASS/FAIL |
| Functions  | {n}% | 80% | PASS/FAIL |

## 失败的测试
{列出每个失败测试的名称、错误信息和文件位置}

## 结论：PASS | FAIL
```

### Step 4：门控判断

- **PASS**：全部测试通过 + 覆盖率达标 → 进入下一阶段
- **FAIL**：报告失败详情给编排器 → 不自动回退（由编排器决定）
