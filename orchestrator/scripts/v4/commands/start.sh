#!/bin/bash
# start.sh — /start command (aliases: /start-workflow, /workflow): launch the full pipeline
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_start_workflow() {
  run_full_pipeline "$@"
}
