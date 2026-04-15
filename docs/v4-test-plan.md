# v4 全流程验证测试方案

> 目标：在一个真实或 demo 项目上逐步验证 v4 模块化编排器的所有环节。
> 建议在一个 **干净的 Git 仓库** 上执行，避免污染正式项目。

---

## 前置准备

### 1. 创建测试项目

```bash
# 新建一个 demo 项目
mkdir -p ~/Desktop/test-v4-workflow && cd ~/Desktop/test-v4-workflow
git init
npm init -y

# 创建最小可运行代码（后续流水线需要有文件可改）
mkdir -p src
cat > src/index.ts << 'EOF'
export function hello(name: string): string {
  return `Hello, ${name}!`;
}
EOF

cat > src/index.test.ts << 'EOF'
import { hello } from './index';
test('hello returns greeting', () => {
  expect(hello('World')).toBe('Hello, World!');
});
EOF

git add -A && git commit -m "init: minimal project"
```

### 2. 安装工作流

```bash
bash ~/Desktop/ai-digital-workflow/init-project.sh ~/Desktop/test-v4-workflow
```

### 3. 最小配置

编辑 `~/Desktop/test-v4-workflow/.env.ai-digital-workflow`：

```bash
# 最小可用配置（本地模式，无飞书）
HANDLER_VERSION=v4

# 如果有 openclaw，填上：
# OPENCLAW_BIN=$(which openclaw)
# OPENCLAW_AGENT_ID=your-agent-id
# FEISHU_NOTIFY_TARGET=ou_xxx

# 如果有 Codex（用于审查），填上：
# OPENAI_API_KEY=sk-xxx
```

### 4. 填写项目知识库

```bash
cat > ~/Desktop/test-v4-workflow/.claude/CLAUDE.md << 'EOF'
# Test Project

一个用于验证 AI 工作流的最小 TypeScript 项目。

## 技术栈
- TypeScript
- Jest（测试）

## 目录结构
- src/ — 源代码
- src/*.test.ts — 测试文件
EOF
```

---

## 测试矩阵

> 按顺序执行。每个测试标注了验证的模块和预期结果。

### Phase 1: 基础命令验证

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 1.1 | 版本路由 | `bash .claude/orchestrator/scripts/feishu-handler.sh '/status'` | `feishu-handler.sh` → v4 路由 | 输出 Git log、specs 状态、扩展开关 |
| 1.2 | 未知命令 | `bash .claude/orchestrator/scripts/feishu-handler.sh '/foobar'` | 命令路由错误处理 | 输出 "Unknown command" + 可用命令列表 |
| 1.3 | 状态查看 | `bash .claude/orchestrator/scripts/feishu-handler.sh '/status'` | `cmd_status()` | 显示无活跃 feature |

### Phase 2: 完整流水线（Happy Path）

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 2.1 | 启动工作流 | 见下方详细步骤 | Step 0~7 全流程 | 生成 $WORKFLOW_DATA_DIR/{feature}/ 三文档，执行开发、审查、测试、文档 |

**详细步骤：**

```bash
cd ~/Desktop/test-v4-workflow

# 启动完整流水线（用一个简单需求）
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加一个 multiply 乘法函数到 src/index.ts，接收两个数字参数返回乘积'
```

**逐 Step 检查清单：**

- [ ] **Step 0 (prepare)**: `.claude/` 目录存在，知识库文件加载
- [ ] **Step 1 (spec-writer)**:
  - `$WORKFLOW_DATA_DIR/{feature}/requirements.md` 已生成
  - `$WORKFLOW_DATA_DIR/{feature}/design.md` 已生成，含 `complexity` 评级
  - `$WORKFLOW_DATA_DIR/{feature}/tasks.md` 已生成，含原子任务列表
  - 无 `[UNCERTAIN]` 标记（简单需求不应有）
- [ ] **Step 2 (develop)**: `src/index.ts` 新增 `multiply` 函数
- [ ] **Step 3 (review)**: `$WORKFLOW_DATA_DIR/{feature}/code-review.md` 或 `spec-review.md` 生成
- [ ] **Step 4 (test)**: 测试通过，`$WORKFLOW_DATA_DIR/{feature}/test-report.md` 生成
- [ ] **Step 5 (doc-sync)**: 文档更新
- [ ] **Step 6 (deploy)**: 跳过（`ENABLE_DEPLOY=false`）
- [ ] **Step 7 (notify)**: 完成日志写入 `$WORKFLOW_DATA_DIR/.workflow-log`
- [ ] **state.json**: `$WORKFLOW_DATA_DIR/{feature}/state.json` 状态为 `done`

```bash
# 验证产物
ls $WORKFLOW_DATA_DIR/*/
cat $WORKFLOW_DATA_DIR/*/state.json
cat $WORKFLOW_DATA_DIR/.workflow-log | tail -20
```

### Phase 3: 开放问题 → 暂停 → /answer 恢复

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 3.1 | 触发 [UNCERTAIN] | 见下方 | clarification.sh + state.sh | 流水线暂停在 Step 1 |
| 3.2 | /answer 恢复 | 见下方 | answer.sh | 流水线从 Step 1 继续 |

```bash
# 3.1 用模糊需求触发 [UNCERTAIN]
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加用户系统'
# 预期：需求模糊 → spec-writer 标记 [UNCERTAIN] → 暂停

# 检查状态
cat $WORKFLOW_DATA_DIR/*/state.json   # status 应为 "awaiting-answer"
cat $WORKFLOW_DATA_DIR/*/requirements.md  # 搜索 [UNCERTAIN] 和 [ ] 未勾选项

# 3.2 回答问题恢复
FEATURE=$(ls $WORKFLOW_DATA_DIR/ | grep -v archive | grep -v .workflow-log | head -1)
opencli claude --permission-mode bypassPermissions \
  -p "/answer $FEATURE 1.用户系统只需要注册和登录 2.使用邮箱验证 3.密码用bcrypt加密 4.不需要OAuth"

# 检查恢复
cat $WORKFLOW_DATA_DIR/$FEATURE/state.json  # status 应变为 "running" 或最终 "done"
```

### Phase 4: /pause → /restart 流程

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 4.1 | 主动暂停 | `/pause` | pause.sh + state.sh | 状态变为 paused，进程终止 |
| 4.2 | 修改需求后重启 | `/restart` | restart.sh + spec diff | 检测 diff 并最小粒度更新 |

```bash
# 4.1 启动一个新需求，然后快速暂停
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加一个 divide 除法函数，支持除零检查' &
PIPELINE_PID=$!
sleep 30  # 等 Step 1 开始
opencli claude --permission-mode bypassPermissions \
  -p '/pause'

# 检查
FEATURE=$(ls $WORKFLOW_DATA_DIR/ | grep divide | head -1)
cat $WORKFLOW_DATA_DIR/$FEATURE/state.json  # status: "paused", step 记录断点

# 4.2 修改需求后重启
# 编辑 requirements.md，加一条需求
echo "- 新增：支持取模运算" >> $WORKFLOW_DATA_DIR/$FEATURE/requirements.md
opencli claude --permission-mode bypassPermissions \
  -p "/restart $FEATURE 新增取模运算支持"

# 预期：检测到 requirements diff → 更新 design.md + tasks.md → 从断点继续
cat $WORKFLOW_DATA_DIR/$FEATURE/state.json
```

### Phase 5: 崩溃恢复 /resume

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 5.1 | 模拟崩溃 | kill 进程 | — | 流水线中断 |
| 5.2 | /resume 恢复 | `/resume` | resume.sh | 读日志找断点，从下一步继续 |

```bash
# 5.1 启动流水线并模拟崩溃
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加一个 subtract 减法函数' &
PIPELINE_PID=$!
sleep 60  # 等进入 Step 2+
kill $PIPELINE_PID

# 5.2 恢复
FEATURE=$(ls $WORKFLOW_DATA_DIR/ | grep subtract | head -1)
cat $WORKFLOW_DATA_DIR/$FEATURE/state.json  # status: "failed" 或 "running"（取决于 trap 是否执行）

opencli claude --permission-mode bypassPermissions \
  -p "/resume $FEATURE"

# 预期：从 workflow-log 判断断点 → 从下一 step 继续
```

### Phase 6: Spec 审查阻断 → /fix-spec

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 6.1 | 触发 CRITICAL 阻断 | — | spec-review.sh | 自动暂停，状态 awaiting-fix |
| 6.2 | /fix-spec 修复 | `/fix-spec` | fix-spec.sh | Claude 自动修改 → 重新审查 |

```bash
# 这个场景较难手动触发（需要 Codex 审查出 3+ CRITICAL）
# 可以用一个故意含安全问题的需求：
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加用户密码重置功能，密码明文存储在数据库中'

# 如果触发了 CRITICAL 审查阻断：
FEATURE=$(ls $WORKFLOW_DATA_DIR/ | grep -v archive | grep -v .workflow-log | sort -t/ -k1 | tail -1)
cat $WORKFLOW_DATA_DIR/$FEATURE/state.json  # 检查是否 "awaiting-fix"

# 修复
opencli claude --permission-mode bypassPermissions \
  -p "/fix-spec $FEATURE 密码必须用bcrypt哈希存储，禁止明文"
```

### Phase 7: /hotfix 快速通道

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 7.1 | hotfix | `/hotfix` | hotfix.sh | 跳过 spec 审查和 [UNCERTAIN] 检测 |

```bash
opencli claude --permission-mode bypassPermissions \
  -p '/hotfix 修复 multiply 函数当参数为 0 时返回 NaN 的 bug'

# 预期：不暂停，直接走 spec → develop → review → test → done
```

### Phase 8: 单独触发审查和测试

| # | 测试 | 命令 | 验证目标 | 预期结果 |
|---|------|------|---------|---------|
| 8.1 | 单独审查 | `/review` | cmd_review | 只跑 Step 3 |
| 8.2 | 单独测试 | `/test` | cmd_test | 只跑 Step 4 |

```bash
# 先确保有一个已完成开发的 feature
FEATURE=$(ls $WORKFLOW_DATA_DIR/ | grep multiply | head -1)

opencli claude --permission-mode bypassPermissions \
  -p "/review $FEATURE"

opencli claude --permission-mode bypassPermissions \
  -p "/test $FEATURE"
```

### Phase 9: 状态机验证

```bash
# 检查所有 feature 的状态
for d in $WORKFLOW_DATA_DIR/*/; do
  if [ -f "$d/state.json" ]; then
    echo "=== $(basename $d) ==="
    cat "$d/state.json" | jq '{status, step, updated_at}'
  fi
done

# 检查 workflow-log 时间线
cat $WORKFLOW_DATA_DIR/.workflow-log
```

### Phase 10: 扩展功能（可选）

| # | 测试 | 前置配置 | 验证目标 |
|---|------|---------|---------|
| 10.1 | Worktree 并行 | `ENABLE_WORKTREE_PARALLEL=true` | 高复杂度任务走 worktree 并行开发 |
| 10.2 | UI 还原 | `ENABLE_UI_RESTORER=true` + Figma URL | Antigravity 分块还原 + 视觉反馈闭环 |
| 10.3 | 部署 | `ENABLE_DEPLOY=true` | Step 6 实际执行部署 |
| 10.4 | Jira 同步 | `JIRA_BASE_URL` + `JIRA_TOKEN` | 任务状态同步到 Jira |
| 10.5 | 飞书审批 | `FEISHU_APPROVAL_CODE` | 人工审批门控 |

---

## 快速冒烟测试（5 分钟版）

如果只想快速验证 v4 能跑通，执行以下最小集：

```bash
cd ~/Desktop/test-v4-workflow

# 1. 状态检查
bash .claude/orchestrator/scripts/feishu-handler.sh '/status'

# 2. Happy path
opencli claude --permission-mode bypassPermissions \
  -p '/start-workflow 添加一个 multiply(a, b) 函数到 src/index.ts'

# 3. 检查产物
ls $WORKFLOW_DATA_DIR/*/
cat $WORKFLOW_DATA_DIR/*/state.json | jq .status
```

---

## 故障排查

| 症状 | 可能原因 | 排查方式 |
|------|---------|---------|
| "部分配置无效" | `.env.ai-digital-workflow` 缺少必要变量 | 这只是警告，不影响本地执行 |
| Step 1 卡住 | Claude Code 权限模式未设置 | 确保用 `--permission-mode bypassPermissions` |
| Codex 审查跳过 | `OPENAI_API_KEY` 未配置 | 审查会 fallback 到 Claude，不阻塞 |
| 飞书通知无效 | `FEISHU_NOTIFY_TARGET` 未配置 | 本地验证可忽略，通知会静默跳过 |
| state.json 不存在 | 流水线还没跑到写状态的阶段 | 检查 `$WORKFLOW_DATA_DIR/.workflow-log` 看进度 |
| `/pause` 后 `/restart` 被拒 | 有未解决的 spec review CRITICAL | 改用 `/fix-spec` 先解决审查问题 |
