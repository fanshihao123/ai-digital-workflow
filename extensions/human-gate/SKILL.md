---
name: human-gate
description: >
  可插拔扩展。在关键节点创建飞书审批流阻塞等待人工确认。
  两个门控点：(1) 安全变更 — 条件触发  (2) 生产部署 — 始终触发。
  启用方式：.env 中配置 FEISHU_APPROVAL_CODE。未配置则跳过。
---

# human-gate — 飞书审批门控（可插拔扩展）

## 启用条件

`.env` 中 `FEISHU_APPROVAL_CODE` 有值时启用。未配置则跳过（流水线全自动）。

## 两个门控点

### G1：安全门控（code-reviewer 之后，条件触发）

```bash
# 检测是否涉及安全变更
result=$(bash scripts/detect-security-changes.sh "{需求名称}")

if [ "$result" = "SECURITY_GATE_REQUIRED" ]; then
  # 创建飞书审批 → 阻塞等待
  bash scripts/feishu-approval-gate.sh security "{需求名称}" "{摘要}"
  # 通过 → 继续 | 拒绝 → 暂停
fi
# NO_GATE_REQUIRED → 直接跳过
```

检测范围：src/auth/、.env、Dockerfile、nginx、jwt/bcrypt/crypto 代码模式。

### G2：部署门控（doc-syncer 之后，始终触发）

```bash
# 无条件阻塞
bash scripts/feishu-approval-gate.sh deploy "{需求名称}" "{部署摘要}"
# 通过 → 执行部署 | 拒绝 → 不部署
```

审批表单含：变更文件、测试覆盖率、审查结论、回滚方案。

## 脚本

- `scripts/detect-security-changes.sh` — 安全变更自动检测
- `scripts/feishu-approval-gate.sh` — 创建审批 + 阻塞轮询
