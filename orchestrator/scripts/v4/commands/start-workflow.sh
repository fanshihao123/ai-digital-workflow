#!/bin/bash
# start-workflow.sh — /start-workflow and /workflow command: launch the full pipeline
# Sourced by v4/handler.sh; all lib and step modules already loaded

cmd_start_workflow() {
  run_full_pipeline "$@"
}
