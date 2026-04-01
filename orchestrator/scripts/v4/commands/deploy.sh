#!/bin/bash
# deploy.sh — /deploy command: run deployment (Step 6) for a feature
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_deploy() {
  local feature_name="$1"
  if [ -z "$feature_name" ]; then
    feature_name=$(detect_feature_name)
  fi
  if [ -z "$feature_name" ]; then
    echo "❌ 未找到活跃的需求。用法: /deploy {需求名称}"
    return 1
  fi

  echo "Starting deploy for: $feature_name"
  step6_deploy "$feature_name"
  step7_notify "$feature_name"
}
