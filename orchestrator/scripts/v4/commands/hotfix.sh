#!/bin/bash
# hotfix.sh — /hotfix command: run full pipeline with hotfix flag (skip spec review and open-question detection)
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_hotfix() {
  local ARGS="$1"
  run_full_pipeline "$ARGS" "true"
}
