#!/bin/bash
# pipeline.sh — 流水线编排：run_pipeline_steps_2_to_7() + run_full_pipeline()
# Sourced by v4/handler.sh; all lib modules already loaded

# ============================================================
# 流水线 Steps 2-7（开发 → 审查 → 测试 → 文档 → 部署 → 通知）
# 独立提取，供完整流水线和澄清恢复流程共同调用
# ============================================================
run_pipeline_steps_2_to_7() {
  local feature_name="$1"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"
  local step_start
  local complexity

  ensure_not_paused "$feature_name" "before step2-to-step7" || return 0

  complexity=$(get_complexity "$feature_name")
  echo "  复杂度: $complexity"

  # Step 2：开发执行（Agent 路由）
  step_start=$(date +%s)
  log "STEP_2_START: 开发执行 ($feature_name)" "$pipeline_log"
  progress_step_start "$feature_name" 2
  step2_develop "$feature_name"
  progress_step_done "$feature_name" 2 "" "complexity: $complexity"
  log "STEP_2_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # 关键节点：开发完成，推送当前进度快照
  local _progress_snapshot
  _progress_snapshot=$(progress_render "$feature_name" 2>/dev/null || true)
  [ -n "$_progress_snapshot" ] && feishu_notify "📊 **$feature_name** 开发完成，当前进度:\n$_progress_snapshot" "$feature_name"

  # Step 3：code-reviewer（两轮审查）
  step_start=$(date +%s)
  log "STEP_3_START: 代码审查 ($feature_name)" "$pipeline_log"
  progress_step_start "$feature_name" 3
  step3_review "$feature_name" || {
    echo "  ❌ 审查阶段被阻断"
    local review_ctx=""
    if [ -f "$WORKFLOW_DATA_DIR/$feature_name/review-report.md" ]; then
      review_ctx=$(grep -E "CRITICAL|FAIL|ERROR" "$WORKFLOW_DATA_DIR/$feature_name/review-report.md" 2>/dev/null | head -5)
    fi
    progress_step_fail "$feature_name" 3 "" "审查阻断${review_ctx:+: $review_ctx}"
    log "STEP_3_BLOCKED: $(($(date +%s) - step_start))s" "$pipeline_log"
    return 1
  }
  progress_step_done "$feature_name" 3
  log "STEP_3_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 4：test-runner（测试 + 覆盖率）
  step_start=$(date +%s)
  log "STEP_4_START: 测试 ($feature_name)" "$pipeline_log"
  progress_step_start "$feature_name" 4
  step4_test "$feature_name" || {
    echo "  ⚠️ 测试失败，进入自动修复回路"
    progress_substep "$feature_name" 4 "首轮测试失败，进入自动修复" "fail"
    agent_notify \
      "需求 '$feature_name' 的测试（Step 4）失败，正在进入自动修复回路，我会尝试自动修复后重跑测试。" \
      "如果自动修复失败我会再通知你，你可以随时发 /status 查看进展。" \
      "$feature_name"
    step4_fix_and_retry "$feature_name" || {
      echo "  ❌ 自动修复回路失败，流水线终止"
      local test_ctx=""
      if [ -f "$WORKFLOW_DATA_DIR/$feature_name/test-report.md" ]; then
        test_ctx=$(grep -E "FAIL|Error|✗|✘|failed" "$WORKFLOW_DATA_DIR/$feature_name/test-report.md" 2>/dev/null | head -8)
      fi
      progress_step_fail "$feature_name" 4 "" "自动修复失败${test_ctx:+: $test_ctx}"
      agent_notify \
        "需求 '$feature_name' 的自动修复回路也失败了，无法自动解决测试问题，流水线已终止。\n\n失败摘要:\n${test_ctx:-详见 $WORKFLOW_DATA_DIR/$feature_name/test-report.md}" \
        "需要我帮你分析失败原因吗？还是你来人工修复后执行 /resume $feature_name 继续？" \
        "$feature_name"
      log "STEP_4_FAILED: $(($(date +%s) - step_start))s" "$pipeline_log"
      progress_finish "$feature_name" "fail"
      return 1
    }
    progress_substep "$feature_name" 4 "自动修复后重测通过" "done"
  }
  progress_step_done "$feature_name" 4
  log "STEP_4_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # 关键节点：测试通过，推送当前进度快照
  _progress_snapshot=$(progress_render "$feature_name" 2>/dev/null || true)
  [ -n "$_progress_snapshot" ] && feishu_notify "📊 **$feature_name** 测试通过，当前进度:\n$_progress_snapshot" "$feature_name"

  # Step 5：doc-syncer（文档同步 + 迭代归档）
  step_start=$(date +%s)
  log "STEP_5_START: 文档同步 ($feature_name)" "$pipeline_log"
  progress_step_start "$feature_name" 5
  step5_doc_sync "$feature_name"
  progress_step_done "$feature_name" 5
  log "STEP_5_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 6：部署（扩展 — 按需）
  step_start=$(date +%s)
  log "STEP_6_START: 部署 ($feature_name)" "$pipeline_log"
  if [ "${ENABLE_DEPLOY:-false}" = "true" ]; then
    progress_step_start "$feature_name" 6
    step6_deploy "$feature_name"
    progress_step_done "$feature_name" 6
  else
    step6_deploy "$feature_name"
    progress_step_skip "$feature_name" 6 "" "ENABLE_DEPLOY=false"
  fi
  log "STEP_6_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 7：通知
  log "STEP_7_START: 通知 ($feature_name)" "$pipeline_log"
  progress_step_start "$feature_name" 7
  step7_notify "$feature_name"
  progress_step_done "$feature_name" 7
  progress_finish "$feature_name" "done"
  log "PIPELINE_COMPLETE: $feature_name" "$pipeline_log"
}

# ============================================================
# 完整流水线（Step 0 → Step 7）
# ============================================================
run_full_pipeline() {
  local input="$1"
  local is_hotfix="${2:-false}"
  local pipeline_log="$WORKFLOW_DATA_DIR/.workflow-log"
  local step_start

  # Step 0：环境准备 + 知识加载
  step_start=$(date +%s)
  log "STEP_0_START: 环境准备" "$pipeline_log"
  step0_prepare
  log "STEP_0_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 1：spec-writer（三阶段交叉审查）
  step_start=$(date +%s)
  log "STEP_1_START: spec-writer" "$pipeline_log"
  local feature_name
  feature_name=$(step1_spec_writer "$input" "$is_hotfix")
  if [ -z "$feature_name" ]; then
    echo "❌ 流水线终止：spec-writer 未产出"
    feishu_notify "❌ 流水线终止: spec-writer 失败" "unknown"
    return 1
  fi
  # 检测暂停状态（等待用户澄清开放问题）
  if [ "$feature_name" = "__PAUSED__" ]; then
    echo "⏸️ 流水线已暂停：等待用户答复开放问题"
    log "PIPELINE_PAUSED: 等待用户澄清" "$pipeline_log"
    return 0
  fi
  # 再次校验三文档是否落盘（防止 step1 内部校验被绕过或 detect_feature_name 误判）
  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  if [ ! -s "$spec_dir/requirements.md" ] || [ ! -s "$spec_dir/design.md" ] || [ ! -s "$spec_dir/tasks.md" ]; then
    echo "❌ 流水线终止：spec 三文档未完整生成"
    echo "  requirements.md: $([ -s "$spec_dir/requirements.md" ] && echo "OK" || echo "MISSING/EMPTY")"
    echo "  design.md: $([ -s "$spec_dir/design.md" ] && echo "OK" || echo "MISSING/EMPTY")"
    echo "  tasks.md: $([ -s "$spec_dir/tasks.md" ] && echo "OK" || echo "MISSING/EMPTY")"
    feishu_notify "❌ 流水线终止: spec 三文档未完整生成 ($feature_name)" "$feature_name"
    log "STEP_1_FAILED: spec 文件缺失 ($feature_name)" "$pipeline_log"
    return 1
  fi
  log "STEP_1_DONE: $feature_name ($(($(date +%s) - step_start))s)" "$pipeline_log"

  # 初始化进度面板（Step 0 和 1 已完成，从此处开始追踪）
  progress_init "$feature_name" 8 "$input"
  progress_step_done "$feature_name" 0 "" "环境就绪"
  progress_step_done "$feature_name" 1 "" "specs 三文档已生成"

  run_pipeline_steps_2_to_7 "$feature_name"
}
