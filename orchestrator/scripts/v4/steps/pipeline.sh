#!/bin/bash
# pipeline.sh — 流水线编排：run_pipeline_steps_2_to_7() + run_full_pipeline()
# Sourced by v4/handler.sh; all lib modules already loaded

# ============================================================
# 流水线 Steps 2-7（开发 → 审查 → 测试 → 文档 → 部署 → 通知）
# 独立提取，供完整流水线和澄清恢复流程共同调用
# ============================================================
run_pipeline_steps_2_to_7() {
  local feature_name="$1"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"
  local step_start
  local complexity

  ensure_not_paused "$feature_name" "before step2-to-step7" || return 0

  complexity=$(get_complexity "$feature_name")
  echo "  复杂度: $complexity"

  # Step 2：开发执行（Agent 路由）
  step_start=$(date +%s)
  log "STEP_2_START: 开发执行 ($feature_name)" "$pipeline_log"
  step2_develop "$feature_name"
  log "STEP_2_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 3：code-reviewer（两轮审查）
  step_start=$(date +%s)
  log "STEP_3_START: 代码审查 ($feature_name)" "$pipeline_log"
  step3_review "$feature_name" || {
    echo "  ❌ 审查阶段被阻断"
    log "STEP_3_BLOCKED: $(($(date +%s) - step_start))s" "$pipeline_log"
    return 1
  }
  log "STEP_3_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 4：test-runner（测试 + 覆盖率）
  step_start=$(date +%s)
  log "STEP_4_START: 测试 ($feature_name)" "$pipeline_log"
  step4_test "$feature_name" || {
    echo "  ⚠️ 测试失败，进入自动修复回路"
    agent_notify \
      "需求 '$feature_name' 的测试（Step 4）失败，正在进入自动修复回路，我会尝试自动修复后重跑测试。" \
      "如果自动修复失败我会再通知你，你可以随时发 /status 查看进展。" \
      "$feature_name"
    step4_fix_and_retry "$feature_name" || {
      echo "  ❌ 自动修复回路失败，流水线终止"
      agent_notify \
        "需求 '$feature_name' 的自动修复回路也失败了，无法自动解决测试问题，流水线已终止。详见 specs/$feature_name/test-report.md。" \
        "需要我帮你分析失败原因吗？还是你来人工修复后执行 /resume $feature_name 继续？" \
        "$feature_name"
      log "STEP_4_FAILED: $(($(date +%s) - step_start))s" "$pipeline_log"
      return 1
    }
  }
  log "STEP_4_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 5：doc-syncer（文档同步 + 迭代归档）
  step_start=$(date +%s)
  log "STEP_5_START: 文档同步 ($feature_name)" "$pipeline_log"
  step5_doc_sync "$feature_name"
  log "STEP_5_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 6：部署（扩展 — 按需）
  step_start=$(date +%s)
  log "STEP_6_START: 部署 ($feature_name)" "$pipeline_log"
  step6_deploy "$feature_name"
  log "STEP_6_DONE: $(($(date +%s) - step_start))s" "$pipeline_log"

  # Step 7：通知
  log "STEP_7_START: 通知 ($feature_name)" "$pipeline_log"
  step7_notify "$feature_name"
  log "PIPELINE_COMPLETE: $feature_name" "$pipeline_log"
}

# ============================================================
# 完整流水线（Step 0 → Step 7）
# ============================================================
run_full_pipeline() {
  local input="$1"
  local is_hotfix="${2:-false}"
  local pipeline_log="$PROJECT_ROOT/specs/.workflow-log"
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
    notify "❌ 流水线终止: spec-writer 失败"
    return 1
  fi
  # 检测暂停状态（等待用户澄清开放问题）
  if [ "$feature_name" = "__PAUSED__" ]; then
    echo "⏸️ 流水线已暂停：等待用户答复开放问题"
    log "PIPELINE_PAUSED: 等待用户澄清" "$pipeline_log"
    return 0
  fi
  log "STEP_1_DONE: $feature_name ($(($(date +%s) - step_start))s)" "$pipeline_log"

  run_pipeline_steps_2_to_7 "$feature_name"
}
