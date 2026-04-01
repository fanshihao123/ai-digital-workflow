#!/bin/bash
# step5-doc-sync.sh — Step 5: doc-syncer（文档同步 + 迭代归档）
# Sourced by v4/handler.sh; all lib modules already loaded

step5_doc_sync() {
  local feature_name="$1"

  ensure_not_paused "$feature_name" "step5_doc_sync" || return 0

  echo "=== Step 5: doc-syncer ==="
  notify "📚 Step 5: 开始同步文档 $feature_name"
  run_local_doc_sync "$feature_name"
  notify "✅ Step 5 完成: 文档已同步 ($feature_name)"
}
