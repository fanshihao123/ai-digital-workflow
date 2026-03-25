# AI 数字员工工作流架构优化报告

> 日期：2026-03-25
> 优化范围：全部 shell 脚本 + 配置文件
> 变更统计：14 个文件，+397 行，-285 行（含 1 个新建文件）

---

## 一、优化总览

经过三轮深度审查，共发现并修复 **37 处问题**，涵盖安全漏洞、逻辑 bug、规范偏差、健壮性不足四大类：


| 类别     | 数量  | 典型问题                                          |
| ------ | --- | --------------------------------------------- |
| 安全漏洞   | 12  | JSON 注入、路径遍历、分支名注入、sed 注入、敏感信息泄露              |
| 逻辑 Bug | 6   | git revert 范围反写、测试判定违反规范、管道变量作用域丢失            |
| 规范偏差   | 5   | CRITICAL_ISSUES 未阻断、简单任务跳过条件缺失、reviewed 状态未验证 |
| 健壮性    | 14  | curl 无超时、awk 类型未校验、jq 返回值未检查、重复通知、缺乏日志        |


---

## 二、新建文件

### `orchestrator/scripts/lib/common.sh`（新建，287 行）

公共函数库，消除各脚本间的重复代码，提供统一的安全基础设施：


| 函数                               | 用途                                      |
| -------------------------------- | --------------------------------------- |
| `validate_feature_name()`        | 防路径遍历（禁止 `../`、`/`、控制字符）                |
| `validate_branch_name()`         | 防分支名注入（禁止 `..`、`~`、`^`、`:` 等）           |
| `validate_url()`                 | URL 格式校验（必须以 `http://` 或 `https://` 开头） |
| `is_numeric()`                   | 数值类型安全检查（防 awk/bash 对非数字输入报错）           |
| `get_project_root()`             | 获取项目根目录                                 |
| `load_env()`                     | 安全加载 `.env` 环境变量                        |
| `require_vars()`                 | 检查必要环境变量是否存在                            |
| `get_default_branch()`           | 自动检测默认分支名（不硬编码 `main`）                  |
| `json_escape()`                  | JSON 字符串安全转义                            |
| `log()`                          | 统一日志格式（带时间戳，可选写文件）                      |
| `feishu_notify()`                | 统一飞书通知（用 jq 构建安全 JSON，自动选颜色）            |
| `pipeline_state_set/get/check()` | Pipeline 状态持久化（用 awk 替代 sed 防注入）        |
| `retry_curl()`                   | HTTP 请求指数退避重试                           |
| `validate_config()`              | 启动时校验 URL 配置格式                          |


---

## 三、逐文件改动说明

### 1. `orchestrator/scripts/feishu-handler.sh`（核心编排器）

**变更量：** +164 行，-113 行


| 改动项                                                | 原因                                                                              |
| -------------------------------------------------- | ------------------------------------------------------------------------------- |
| 引入 `common.sh` 公共库                                 | 消除重复代码（日志、通知、环境加载），统一安全基础设施                                                     |
| 添加 `validate_config()` 调用                          | 启动时校验 URL 配置，提前发现错误配置                                                           |
| `cleanup()` 添加 `_NOTIFIED_ERROR` 标志                | ERR trap 和 step 内部可能重复发送飞书失败通知，添加标志位避免                                          |
| `notify()` 改用 `feishu_notify()`                    | 原实现调用外部脚本，现用 common.sh 中的安全版本，统一 JSON 构建                                        |
| `step1_spec_writer` 添加 `validate_feature_name()`   | 防止 Claude Code 生成的 feature name 包含 `../` 导致路径遍历                                 |
| `step1_spec_writer` 支持简单任务跳过审查                     | 规范要求「任务数 <= 2 且 complexity: low」可跳过 Codex 审查，原实现只支持 hotfix                      |
| `step1_spec_writer` CRITICAL_ISSUES >= 3 **阻断流水线** | 原实现仅通知人工，不阻断后续 step，违反规范                                                        |
| `step1_spec_writer` 添加 reviewed 状态验证               | Stage 3 完成后检查三个 spec 文件是否标记为 reviewed                                           |
| `run_local_review()` 重写                            | 原 fallback 只做文件存在性检查，不是真正的代码审查。改为调用 Claude Code 执行完整两轮审查                        |
| `run_local_doc_sync()` 重写                          | 原实现只往 ITERATIONS.md 追加一行。改为调用 Claude Code 执行真正的文档分析和归档                          |
| `step7_notify()` JSON 安全化                          | 原实现直接拼接 `$feature_name`、`$commit_msg` 等变量到 JSON 字符串，引号/换行会破坏 JSON               |
| `WORKFLOW_VERDICT` 逻辑修正                            | **原 bug：** 要求 `full_repo_status` 也通过才算 PASS，违反规范「feature-scope 通过即 PASS，旧债单独记录」 |
| `awk` 覆盖率比较添加类型校验                                  | 原实现在 `coverage_statements` 为 `N/A` 时会导致 awk 报错                                  |
| `run_full_pipeline()` 添加 step 计时日志                 | 原实现整个流水线无本地日志，失败后无法追踪耗时和失败位置                                                    |


### 2. `orchestrator/scripts/feishu-notify.sh`

**变更量：** +9 行，-38 行


| 改动项                             | 原因                                                            |
| ------------------------------- | ------------------------------------------------------------- |
| 引入 `common.sh`                  | 使用公共库的 `get_project_root()`、`load_env()`、`feishu_notify()`    |
| 替换手工 JSON 拼接为 `feishu_notify()` | 原实现直接将 `$NOTIFICATION` 插入 JSON 字符串，内容含 `"`、`\`、换行符时破坏 JSON 格式 |


### 3. `orchestrator/scripts/select-model.sh`

**变更量：** +5 行，-10 行


| 改动项                                  | 原因                                                                    |
| ------------------------------------ | --------------------------------------------------------------------- |
| 移除 `opencli claude -p "echo ok"` 空探测 | 原实现每次选模型都发一次真实 API 请求探测 Opus 额度，浪费 token。改为直接选 opus，实际执行时失败再 fallback |


### 4. `orchestrator/scripts/on-complete.sh`

**变更量：** +2 行，-2 行


| 改动项           | 原因                                                                  |
| ------------- | ------------------------------------------------------------------- |
| 任务状态匹配同时支持中英文 | 原实现 `grep -c "Status.*done"` 但 tasks.md 实际格式是中文 `状态：done`，导致计数始终为 0 |


### 5. `orchestrator/scripts/load-company-skills.sh`

**变更量：** +13 行，-17 行


| 改动项                                 | 原因                                                                                        |
| ----------------------------------- | ----------------------------------------------------------------------------------------- |
| 手工 JSON 拼接改为 `jq --arg`             | 原实现手动拼 JSON，skill description 含引号时破坏 JSON 格式                                              |
| `find | while` 改为 `while < <(find)` | **管道变量作用域 bug：** `find | while` 在子 shell 中运行，循环内对 `$SKILL_INDEX` 的 jq 写入在外层不可见，导致索引文件可能为空 |


### 6. `extensions/deploy-executor/scripts/rollback.sh`

**变更量：** +1 行，-1 行


| 改动项                                                     | 原因                                           |
| ------------------------------------------------------- | -------------------------------------------- |
| `git revert` 范围从 `HEAD..${COMMIT}` 改为 `${COMMIT}..HEAD` | **逻辑 bug：** 原写法范围反了，git revert 不会回滚任何 commit |


### 7. `extensions/human-gate/scripts/detect-security-changes.sh`

**变更量：** +36 行，-22 行


| 改动项             | 原因                                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------------------- |
| 去除硬编码 `main` 分支 | 用 `git symbolic-ref` 自动检测默认分支                                                                        |
| 精确化安全检测模式       | 原模式如 `password`、`secret`、`crypto.`、`eval(` 太宽泛，测试文件、注释、文档变更都会触发。改为 `password\s*=`、`\beval\(` 等更精确的模式 |
| 排除测试文件和注释行      | 新增 `grep -v` 过滤 `__tests__/`、`.test.`、`.spec.`、注释行（`//`、`#`、`*`），降低误报率                               |


### 8. `extensions/human-gate/scripts/feishu-approval-gate.sh`

**变更量：** +68 行，-48 行


| 改动项                                              | 原因                                                                              |
| ------------------------------------------------ | ------------------------------------------------------------------------------- |
| `collect_form_data()` 用 `jq -n` 构建 JSON          | 原实现用 heredoc 拼 JSON，`$feature`、`$summary` 等变量含引号时注入                             |
| 审批实例创建用 `jq -n --argjson`                        | 原实现 `$(echo "$FORM_DATA" | jq -Rs .)` 对已是 JSON 的 `FORM_DATA` 二次转义，导致飞书 API 解析失败 |
| `get_token()` 用 `jq -n` 构建请求体                    | 原实现直接拼接 `$FEISHU_APP_SECRET` 到 JSON，消除泄露风险                                      |
| 去除硬编码 `main` 分支                                  | 用 `git symbolic-ref` 自动检测                                                       |
| 所有 `curl` 添加 `--max-time 10 --connect-timeout 5` | 原实现无超时，网络故障时无限阻塞                                                                |


### 9. `extensions/jira-sync/scripts/sync-jira.sh`

**变更量：** +28 行，-14 行


| 改动项                                           | 原因                                                             |
| --------------------------------------------- | -------------------------------------------------------------- |
| `jira_comment()` 用 `jq -n --arg` 构建 JSON body | 原实现直接拼接 `$text` 到 JSON，评论内容含引号时破坏格式                            |
| `jira_transition()` 用 `jq --arg` 查询           | 原实现 `select(.name==\"$name\")` 直接嵌入变量，transition name 含特殊字符时注入 |
| `jira_transition()` 改用 `jq -n` 构建请求体          | 原实现 `{\"transition\":{\"id\":\"$tid\"}}` 手工拼接                  |
| 去除硬编码 `main` 分支                               | 用 `git symbolic-ref` 自动检测                                      |
| 添加 URL 格式验证                                   | `$JIRA_BASE_URL` 未验证，恶意值可能导致 curl 行为异常                         |
| 所有 `curl` 添加超时                                | 原实现无超时                                                         |


### 10. `extensions/worktree-parallel/scripts/cleanup-worktrees.sh`

**变更量：** +2 行，-2 行


| 改动项                                                          | 原因                                               |
| ------------------------------------------------------------ | ------------------------------------------------ |
| grep 模式从 `"$FEATURE_NAME"` 改为 `"/worktree/${FEATURE_NAME}/"` | 原模式未锚定，`auth` 会误匹配 `auth-api`、`oauth` 等 worktree |


### 11. `extensions/worktree-parallel/scripts/spawn-worktree-agents.sh`

**变更量：** +19 行，-9 行


| 改动项                                        | 原因                                                    |
| ------------------------------------------ | ----------------------------------------------------- |
| 加载 `common.sh` + `validate_feature_name()` | 防止恶意 feature name 导致路径遍历                              |
| 添加 JSON 文件格式验证（`jq empty`）                 | 原实现不检查 `$ASSIGNMENT_FILE` 格式，畸形 JSON 导致后续所有 jq 调用静默失败 |
| jq 调用添加错误检查                                | `AGENT_COUNT`、`AGENT_ID` 等关键值提取失败时应立即中止               |
| 添加 `validate_branch_name()`                | 分支名来自 JSON 文件完全未验证，恶意分支名可能导致 git 命令注入                 |
| 临时文件从 `/tmp/assign_update.tmp` 改为 `mktemp` | 原实现多个 agent 并发时写同一个临时文件，存在竞态条件                        |


### 12. `extensions/worktree-parallel/scripts/merge-worktrees.sh`

**变更量：** +8 行，-4 行


| 改动项                      | 原因                                                                 |
| ------------------------ | ------------------------------------------------------------------ |
| 添加空 AGENT_IDS 检查         | 原实现 `IFS=',' read -ra AGENTS <<< "$AGENT_IDS"` 在空输入时创建空数组，循环无效但不报错 |
| 添加 JSON 文件验证（`jq empty`） | 防止畸形 JSON 导致静默失败                                                   |
| `jq` 查询用 `--arg` 替代字符串拼接 | 原实现 `select(.id==\"$AGENT_ID\")` 在 AGENT_ID 含特殊字符时注入               |


### 13. `init-project.sh`

**变更量：** +15 行，-8 行


| 改动项                      | 原因                           |
| ------------------------ | ---------------------------- |
| 扩展数量描述从「4 个」改为「5 个」      | 原注释与实际（5 个扩展）不一致             |
| `cp -r` 添加错误检查           | 原实现安装失败时静默继续，用户以为安装成功但实际缺少文件 |
| 确保拷贝 `lib/common.sh` 目录  | 新增的公共函数库必须随编排器一起安装           |
| `chmod +x` 覆盖 `lib/*.sh` | 确保公共库文件有执行权限                 |


---

## 四、未修复项（持续改进建议）

以下问题属于低优先级，不影响核心功能，可在后续迭代中处理：


| 类别   | 项目                                | 说明                                                                      |
| ---- | --------------------------------- | ----------------------------------------------------------------------- |
| 架构   | `feishu-handler.sh` 拆分            | 1300+ 行单文件，建议拆分为 pipeline-orchestrator + message-parser + step-executor |
| 功能缺失 | `ui-restorer` 无脚本实现               | SKILL.md 写了详细规范但无任何实现代码                                                 |
| 功能缺失 | `deploy-executor` 缺健康检查           | SKILL.md 描述的部署+健康检查逻辑不存在                                                |
| 命令定义 | `/deploy` 和 `/rollback` 缺 `.md`   | case 路由有这两个命令但 commands/ 目录下无定义文件                                       |
| 可观测性 | 日志格式标准化                           | 建议改为 JSON 结构化日志，方便机器解析                                                  |
| 测试   | 缺少脚本测试                            | 建议用 BATS 框架为核心逻辑编写测试                                                    |
| 错误传播 | `jira_sync` 失败被 `|| true` 吞掉      | 建议记录失败但不阻断，在 step7_notify 中汇报                                           |
| 代码审查 | `run_local_review` 单次 prompt 模拟两轮 | 更严格的做法是显式分两次 Claude Code 调用                                             |


