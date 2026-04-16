#!/bin/bash
# doc-sync.sh — Documentation sync
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

run_local_doc_sync() {
  local feature_name="$1"
  local spec_dir="$WORKFLOW_DATA_DIR/$feature_name"
  local iter_file="$WORKFLOW_DATA_DIR/ITERATIONS.md"
  local archive_dir="$WORKFLOW_DATA_DIR/archive/$(date +%Y-%m-%d)-${feature_name}"

  mkdir -p "$WORKFLOW_DATA_DIR/archive"

  # 初始化 ITERATIONS.md
  if [ ! -f "$iter_file" ]; then
    cat > "$iter_file" <<EOF
# Iterations
EOF
  fi

  # ── Phase 1: 归档 + ITERATIONS + LESSONS 汇总（纯 shell，不依赖 Claude） ──
  mkdir -p "$archive_dir"
  for f in requirements.md design.md tasks.md test-report.md review-report.md LESSONS.md; do
    [ -f "$spec_dir/$f" ] && cp "$spec_dir/$f" "$archive_dir/"
  done

  # 追加 ITERATIONS.md
  if ! grep -q "$feature_name" "$iter_file" 2>/dev/null; then
    local task_count
    task_count=$(grep -c '^\s*- \[' "$spec_dir/tasks.md" 2>/dev/null || echo "?")
    printf '\n| %s | %s | %s | - | 完成 |\n' "$(date '+%Y-%m-%d')" "$feature_name" "$task_count" >> "$iter_file"
  fi

  # 汇总 feature LESSONS → 全局 LESSONS（去重）
  if [ -f "$spec_dir/LESSONS.md" ]; then
    local global_lessons="$WORKFLOW_DATA_DIR/LESSONS.md"
    [ -f "$global_lessons" ] || echo "# Global Lessons Learned" > "$global_lessons"
    while IFS= read -r line; do
      # 只处理以 - 开头的条目行
      case "$line" in
        -\ *)
          if ! grep -qF "$line" "$global_lessons" 2>/dev/null; then
            echo "$line" >> "$global_lessons"
          fi
          ;;
      esac
    done < "$spec_dir/LESSONS.md"
  fi

  # ── Phase 2: 让 Claude 生成 .claude/ 文档的 patch，shell 负责 apply ──
  # Claude --print 只输出内容，不执行工具调用，因此不受 .claude/ 目录保护限制
  # 输出格式：JSON array，每个元素 {file, content}（完整文件内容）

  local claude_docs_dir="$PROJECT_ROOT/.claude"
  local skill_file="$PROJECT_ROOT/.claude/skills/doc-syncer/SKILL.md"

  # 收集现有文档内容供 Claude 分析
  local existing_docs=""
  for doc in CLAUDE.md ARCHITECTURE.md SECURITY.md CODING_GUIDELINES.md; do
    if [ -f "$claude_docs_dir/$doc" ]; then
      existing_docs="${existing_docs}
--- BEGIN $doc ---
$(cat "$claude_docs_dir/$doc")
--- END $doc ---
"
    fi
  done

  local specs_content=""
  for f in requirements.md design.md tasks.md; do
    if [ -f "$spec_dir/$f" ]; then
      specs_content="${specs_content}
--- BEGIN $f ---
$(cat "$spec_dir/$f")
--- END $f ---
"
    fi
  done
  if [ -f "$spec_dir/LESSONS.md" ]; then
    specs_content="${specs_content}
--- BEGIN LESSONS.md ---
$(cat "$spec_dir/LESSONS.md")
--- END LESSONS.md ---
"
  fi

  local git_log
  git_log=$(cd "$PROJECT_ROOT" && git log --oneline -20 2>/dev/null || echo "(no git log)")

  local patch_output
  patch_output=$(opencli claude --model sonnet --print --permission-mode bypassPermissions -p "
你是文档同步代理。分析本次功能变更，判断哪些 .claude/ 文档需要更新。

## 本次功能: $feature_name

## Specs 产物:
$specs_content

## 最近 git log:
$git_log

## 现有文档:
$existing_docs

## 规则:
- 只更新确实需要变更的文件，大部分情况下不需要改动
- 只添加变更相关的部分，不重写整个文件
- 保持与现有文档的风格一致
- 新模式必须附带代码示例

## 输出格式（严格遵守）:

如果没有文档需要更新，只输出:
NO_UPDATES_NEEDED

如果有文档需要更新，对每个需要更新的文件输出:
<<<FILE: 文件名（如 ARCHITECTURE.md）>>>
（该文件的完整更新后内容）
<<<END_FILE>>>

不要输出任何解释或其他内容。
" 2>&1) || true

  # 解析 Claude 输出并写入文件
  if [ -n "$patch_output" ] && ! echo "$patch_output" | grep -q "NO_UPDATES_NEEDED"; then
    local current_file=""
    local current_content=""
    local in_file=false

    while IFS= read -r line; do
      if echo "$line" | grep -q '^<<<FILE:'; then
        current_file=$(echo "$line" | sed 's/^<<<FILE:[[:space:]]*//' | sed 's/[[:space:]]*>>>$//')
        current_content=""
        in_file=true
        continue
      fi
      if echo "$line" | grep -q '^<<<END_FILE>>>'; then
        if [ -n "$current_file" ] && [ "$in_file" = true ]; then
          # 安全检查：只允许更新白名单内的文件
          case "$current_file" in
            CLAUDE.md|ARCHITECTURE.md|SECURITY.md|CODING_GUIDELINES.md)
              local target="$claude_docs_dir/$current_file"
              if [ -f "$target" ]; then
                echo "$current_content" > "$target"
                log "doc-sync: updated $current_file" >&2
              fi
              ;;
            *)
              log "doc-sync: skipped non-whitelisted file: $current_file" >&2
              ;;
          esac
        fi
        in_file=false
        current_file=""
        current_content=""
        continue
      fi
      if [ "$in_file" = true ]; then
        if [ -z "$current_content" ]; then
          current_content="$line"
        else
          current_content="${current_content}
${line}"
        fi
      fi
    done <<< "$patch_output"
  else
    log "doc-sync: no document updates needed for $feature_name" >&2
  fi

  # git commit 文档变更
  (
    cd "$PROJECT_ROOT"
    if ! git diff --quiet -- .claude/ 2>/dev/null; then
      git add .claude/
      git commit -m "docs($feature_name): 同步文档" 2>/dev/null || true
    fi
  )
}
