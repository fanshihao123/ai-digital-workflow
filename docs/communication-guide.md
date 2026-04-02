# Claude / Codex / Antigravity 通信机制

> 核心结论：三个 AI 之间**没有直接通信**。Shell 脚本是唯一的编排者，通过**文件系统 + CLI stdout** 串联所有 AI。

---

## 1. 整体通信模型

```
┌─────────────────────────────────────────────────────────────────┐
│                 feishu-handler.sh (编排者)                        │
│                                                                  │
│  唯一掌控全局的角色，所有 AI 都是它的"工具"：                         │
│  - 决定什么时候调谁                                                │
│  - 把上一个 AI 的产出喂给下一个 AI                                  │
│  - 读取文件判断结果，决定下一步                                      │
│                                                                  │
│         ┌──────────┐      ┌──────────┐      ┌──────────────┐    │
│         │  Claude   │      │  Codex   │      │ Antigravity  │    │
│         │  Code CLI │      │  CLI     │      │  (浏览器AI)   │    │
│         └──────────┘      └──────────┘      └──────────────┘    │
│              ▲                  ▲                   ▲             │
│              │                  │                   │             │
│         opencli claude    codex exec          opencli antigravity│
│         --print           --full-auto         send/model/status │
│              │                  │                   │             │
│              ▼                  ▼                   ▼             │
│         写入文件系统         stdout 重定向         修改项目代码      │
│         (specs/*.md)        到文件 (>)           (浏览器内编辑)     │
└─────────────────────────────────────────────────────────────────┘
```

**关键：三个 AI 互相看不到对方，甚至不知道对方的存在。**

---

## 2. 三个 AI 的调用方式对比

```
┌──────────────┬────────────────────────┬─────────────────┬──────────────┐
│              │  Claude Code           │  OpenAI Codex    │  Antigravity │
├──────────────┼────────────────────────┼─────────────────┼──────────────┤
│ 调用方式      │ opencli claude         │ codex exec       │ opencli      │
│              │   --print              │   --full-auto    │  antigravity │
│              │   --model sonnet/opus  │                  │  send/model  │
│              │   -p "prompt"          │   "prompt"       │  "prompt"    │
├──────────────┼────────────────────────┼─────────────────┼──────────────┤
│ 输入方式      │ prompt 里嵌入文件内容    │ prompt 里嵌入     │ prompt 消息   │
│              │ 或指示它 Read 文件       │ 文件内容 $(cat)  │              │
├──────────────┼────────────────────────┼─────────────────┼──────────────┤
│ 输出方式      │ 直接写文件到 specs/     │ stdout 重定向     │ 修改项目源码   │
│              │ (有文件系统权限)         │ > spec-review.md │ (浏览器内)    │
├──────────────┼────────────────────────┼─────────────────┼──────────────┤
│ 执行权限      │ bypassPermissions      │ --full-auto      │ 浏览器沙箱内   │
│              │ (完整读写+命令)          │ (完整自动执行)    │ (只碰前端代码) │
├──────────────┼────────────────────────┼─────────────────┼──────────────┤
│ 擅长什么      │ 写代码/改文件/跑命令     │ 独立审查/打分     │ UI 还原       │
│              │ 理解项目上下文           │ (不碰文件系统)    │ (连 Figma)   │
└──────────────┴────────────────────────┴─────────────────┴──────────────┘
```

---

## 3. Step 1 通信流：Claude → Codex → Claude（三阶段交叉审查）

这是最典型的"接力赛"模式：

```
Shell 脚本 (编排者)
     │
     │ ① 调用 Claude: "生成 requirements.md + design.md + tasks.md"
     │
     ▼
┌─────────────┐    写入文件
│  Claude Code │──────────────→  specs/feature/requirements.md
│  (Stage 1)   │──────────────→  specs/feature/design.md
│              │──────────────→  specs/feature/tasks.md
└─────────────┘
     │
     │ Shell 用 $(cat) 读取三个文件内容
     │
     │ ② 调用 Codex: "审查这三个文档"（把文件内容嵌在 prompt 里）
     │
     ▼
┌─────────────┐    stdout 重定向
│  Codex       │──────────────→  specs/feature/spec-review.md
│  (Stage 2)   │                 (DIMENSION/VERDICT/CRITICAL_ISSUES)
└─────────────┘
     │
     │ Shell 把 spec-review.md 路径告诉 Claude
     │
     │ ③ 调用 Claude: "读 spec-review.md，按建议修改三文档"
     │
     ▼
┌─────────────┐    覆写文件
│  Claude Code │──────────────→  specs/feature/requirements.md (updated)
│  (Stage 3)   │──────────────→  specs/feature/design.md (updated)
│              │──────────────→  specs/feature/tasks.md (updated)
└─────────────┘
     │
     │ Shell 读 spec-review.md 里的 CRITICAL_ISSUES 数字
     │ 判断是否 >= 3 → 暂停或继续
     ▼
```

**实际代码**（简化）：
```bash
# Stage 1: Claude 写文件
opencli claude --print -p "生成 requirements/design/tasks..."
# → Claude 直接写 specs/feature/*.md

# Stage 2: Codex 审查（文件内容嵌入 prompt）
codex exec --full-auto "
  requirements.md:
  $(cat specs/feature/requirements.md)    ← Shell 把文件读出来塞进 prompt
  design.md:
  $(cat specs/feature/design.md)
  tasks.md:
  $(cat specs/feature/tasks.md)
  请审查..." > specs/feature/spec-review.md   ← stdout 写入文件

# Stage 3: Claude 读 Codex 的审查结果，修改文档
opencli claude --print -p "
  Read specs/feature/spec-review.md       ← 告诉 Claude 去读这个文件
  Read specs/feature/requirements.md
  按审查意见修改..."
# → Claude 自己读文件、自己改文件
```

---

## 4. Step 2a 通信流：Antigravity → Codex 视觉闭环

```
Shell 脚本 (编排者)
     │
     │ ① 调用 Antigravity: "生成这块 UI 代码"
     │
     ▼
┌──────────────┐    修改源码
│ Antigravity   │──────────────→  src/components/xxx.tsx
│ (浏览器内AI)   │                 (热更新到 dev server)
└──────────────┘
     │
     │ Shell 等 3 秒让热更新生效
     │
     │ ② Shell 调 chrome-cdp-skill 截图
     │
     ▼
┌──────────────┐    截图文件
│ cdp.mjs      │──────────────→  /tmp/ui-restore-xxx.png
│ (CDP 截图)    │
└──────────────┘
     │
     │ Shell 把截图路径 + 设计规格嵌入 prompt
     │
     │ ③ 调用 Codex: "对比截图和设计稿，打分"
     │
     ▼
┌──────────────┐    stdout
│  Codex        │──────────────→  SCORE: 7
│ (视觉打分)     │                 DIFF_COMPLEXITY: minor
│               │                 FIXES: 按钮颜色偏蓝
└──────────────┘
     │
     │ Shell 解析 stdout: score < 8？
     │
     │ ④ 再次调用 Antigravity: "修复这些 diff"（把 Codex 的 FIXES 喂进去）
     │
     ▼
┌──────────────┐
│ Antigravity   │──→ 修改代码 → 再截图 → 再让 Codex 打分 → 循环
└──────────────┘
```

**实际代码**（简化）：
```bash
# ① Antigravity 生成 UI
antigravity_send_message "生成 $block_name 的代码..." "thinking"

sleep 3  # 等热更新

# ② CDP 截图
node scripts/cdp.mjs shot "$cdp_target" "$screenshot"

# ③ Codex 打分（截图路径 + 设计规格塞进 prompt）
score_output=$(codex_score_ui "$figma_url" "$block_name" "$screenshot" "$design_spec")
#              ↑ 内部: codex exec --full-auto "...截图文件: $screenshot..."

# ④ Shell 解析打分结果
score=$(echo "$score_output" | grep "^SCORE:" | ...)
fixes=$(echo "$score_output" | awk '/^FIXES:/,/^PASS:/' | ...)

if [ "$score" -lt 8 ]; then
  # 把 Codex 的 FIXES 反馈给 Antigravity
  antigravity_send_message "修复: $fixes" "fast"
fi
```

---

## 5. 数据流总结：谁产出什么，谁消费什么

```
┌─────────────────────────────────────────────────────────────────────┐
│                          文件系统 (中间层)                            │
│                                                                      │
│  specs/{feature}/                                                    │
│  ├── requirements.md  ←── Claude 写 ──→ Codex 读(via prompt嵌入)     │
│  ├── design.md        ←── Claude 写 ──→ Codex 读(via prompt嵌入)     │
│  ├── tasks.md         ←── Claude 写 ──→ Codex 读(via prompt嵌入)     │
│  ├── spec-review.md   ←── Codex 写(stdout>) ──→ Claude 读(Read)     │
│  ├── review-report.md ←── Claude 写                                  │
│  ├── test-report.md   ←── Shell 写(heredoc)                          │
│  └── state.json       ←── Shell 写/读(jq)                            │
│                                                                      │
│  src/components/*.tsx  ←── Antigravity 写 ──→ Codex 看截图评分        │
│  /tmp/*.png           ←── cdp.mjs 写 ──→ Codex 读(prompt嵌入路径)    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 为什么这样设计？

```
┌──────────────────────────────────────────────────────────────┐
│  设计原则                                                     │
│                                                               │
│  1. 松耦合：三个 AI 互不依赖，任何一个挂了不影响其他              │
│     → Codex 挂了？Claude fallback 自己审查                     │
│     → Antigravity 挂了？Claude Code 接管 UI 任务               │
│                                                               │
│  2. 可审计：所有中间产物都是文件，人可以随时查看                   │
│     → spec-review.md 可以直接打开看 Codex 怎么评的              │
│     → 截图 PNG 可以直接看 UI 还原效果                           │
│                                                               │
│  3. 可恢复：进程崩了，文件还在，从断点继续                        │
│     → /resume 读 workflow-log 找断点                           │
│     → /restart 读 requirements.md.snapshot 做 diff             │
│                                                               │
│  4. Shell 是唯一指挥官：                                       │
│     → AI 不做决策（不决定下一步是什么）                           │
│     → Shell 读文件、解析字段、判断分支、调用下一个 AI              │
│     → 例: Shell 读 CRITICAL_ISSUES 数字决定暂停还是继续          │
└──────────────────────────────────────────────────────────────┘
```

---

## 7. 通信方式对比表

| 通信路径 | 方式 | 举例 |
|---------|------|------|
| Shell → Claude | CLI 调用 + prompt | `opencli claude -p "Read xxx, 执行 yyy"` |
| Claude → Shell | 写文件到 specs/ | Claude 直接写 `requirements.md` |
| Shell → Codex | CLI 调用 + prompt 嵌入文件内容 | `codex exec "$(cat file)" > output.md` |
| Codex → Shell | stdout 重定向到文件 | `> spec-review.md` |
| Shell → Antigravity | CLI 发消息 | `opencli antigravity send "prompt"` |
| Antigravity → Shell | 修改源码 → Shell 截图后读取 | 热更新 → `cdp.mjs shot` → Codex 打分 |
| Shell → cdp.mjs | Node CLI 调用 | `node scripts/cdp.mjs shot target file.png` |
| Claude ↔ Codex | **无直接通信** | Shell 做中间人，文件做信使 |
| Claude ↔ Antigravity | **无直接通信** | Shell 做中间人 |
| Codex ↔ Antigravity | **无直接通信** | Shell 做中间人，截图做信使 |

---

## 一句话

> **Shell 是导演，AI 是演员，文件系统是剧本传递台。演员之间不交流，都听导演的。**
