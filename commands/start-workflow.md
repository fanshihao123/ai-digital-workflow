---
description: 启动完整 ai-digital-workflow 流水线
argument-hint: <需求描述或URL>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
model: sonnet
---

# /start-workflow

如果 `$ARGUMENTS` 为空，提示用户补充需求描述或 URL 并停止。

不要手工模拟 workflow，也不要只“参考”流程自己做一遍。
必须把本命令**真实转发**到项目编排器脚本：

!`bash .claude/orchestrator/scripts/feishu-handler.sh "/start-workflow $ARGUMENTS"`

执行后：
1. 读取并总结真实产物（specs、review-report、test-report、代码改动）
2. 明确说明哪些阶段真实完成了，哪些阶段被跳过或失败了
3. 给出每个阶段的关键信息，而不是只给最后总结果
4. 如有可访问链接，给出链接；如没有，就说明原因
5. 不要编造未实际生成的报告或结果
