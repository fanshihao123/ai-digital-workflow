---
description: 仅执行测试流程（Step 4）
argument-hint: [需求名称]（可选，不填自动检测）
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /test

## 作用

单独触发测试（Step 4），不启动完整流水线。执行 feature-scope 测试，区分特性测试失败和全仓历史技术债。

## 适用场景

- 测试失败修完代码后，只想重跑测试
- 想验证某个 feature 的测试是否通过
- 配合 `/review` 使用，先审查再测试

## 测试执行顺序

1. Playwright e2e（如有）
2. vitest / jest feature-scope
3. npm test 全仓
4. feature-scope 失败 → 自动修复一轮 → 重试

## 用法

```
/test
/test user-login
```

不传参数时自动检测当前活跃的需求。

---

必须真实转发到编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/test $ARGUMENTS"`

执行后总结真实测试结果。
必须区分 feature-scope 是否通过，以及是否只是被全仓历史技术债拖累。
