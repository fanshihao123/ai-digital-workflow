#!/bin/bash
# testing.sh — Test extraction and execution
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

extract_feature_scopes() {
  local feature_name="$1"
  local tasks_file="$WORKFLOW_DATA_DIR/$feature_name/tasks.md"
  local declared_scopes=""

  if [ -f "$tasks_file" ]; then
    declared_scopes=$(sed -n 's/.*文件范围：[[:space:]]*`\([^`]*\)`.*/\1/p' "$tasks_file" | awk 'NF')
  fi

  if [ -n "$declared_scopes" ]; then
    printf '%s\n' "$declared_scopes"
    return
  fi

  # fallback：tasks.md 没有声明文件范围时，从 git diff 推断本次变更的源文件
  # 排除测试文件本身，让 extract_feature_tests 去推断对应测试
  git -C "$PROJECT_ROOT" diff --name-only HEAD 2>/dev/null \
    | grep -E '\.(ts|tsx|js|jsx)$' \
    | grep -v '\.\(test\|spec\)\.' \
    | grep -v '__tests__' \
    || true
}

extract_feature_tests() {
  local feature_name="$1"
  local scopes
  local files=()
  local scope
  local scope_dir
  local scope_base
  local project_relative

  scopes=$(extract_feature_scopes "$feature_name")
  for scope in $scopes; do
    scope_dir=$(dirname "$scope")
    scope_base=$(basename "$scope")
    scope_base="${scope_base%.*}"
    project_relative="${PROJECT_ROOT}/${scope_dir}"

    for candidate in \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.ts" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.jsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.test.js" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.jsx" \
      "$PROJECT_ROOT/${scope_dir}/${scope_base}.spec.js" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.test.ts" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.test.jsx" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.test.js" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.spec.jsx" \
      "$PROJECT_ROOT/${scope_dir}/__tests__/${scope_base}.spec.js" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.test.ts" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/src/__tests__/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/tests/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/tests/${scope_base}.test.ts" \
      "$PROJECT_ROOT/tests/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/tests/${scope_base}.spec.ts" \
      "$PROJECT_ROOT/test/${scope_base}.test.tsx" \
      "$PROJECT_ROOT/test/${scope_base}.test.ts" \
      "$PROJECT_ROOT/test/${scope_base}.spec.tsx" \
      "$PROJECT_ROOT/test/${scope_base}.spec.ts"; do
      if [ -f "$candidate" ]; then
        files+=("$candidate")
      fi
    done

    if [ -d "$project_relative" ]; then
      while IFS= read -r matched; do
        [ -n "$matched" ] && files+=("$matched")
      done < <(
        if command -v rg >/dev/null 2>&1; then
          rg --files "$project_relative" 2>/dev/null | rg "(^|/)${scope_base}\\.(test|spec)\\.(ts|tsx|js|jsx)$" || true
        else
          find "$project_relative" -type f 2>/dev/null | grep -E "(^|/)${scope_base}\\.(test|spec)\\.(ts|tsx|js|jsx)$" || true
        fi
      )
    fi
  done

  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi

  printf '%s\n' "${files[@]}" | awk 'NF && !seen[$0]++'
}

run_local_test() {
  local feature_name="$1"
  local test_report="$WORKFLOW_DATA_DIR/$feature_name/test-report.md"
  local feature_tests
  local feature_scopes
  local feature_file=""
  local feature_command="N/A"
  local repo_command="N/A"
  local e2e_command="N/A"
  local typecheck_command="N/A"
  local lint_command="N/A"
  local build_command="N/A"
  local feature_output=""
  local repo_output=""
  local e2e_output=""
  local typecheck_output=""
  local lint_output=""
  local build_output=""
  local feature_status="FAIL"
  local full_repo_status="NOT_RUN"
  local repo_debt_status="NOT_RUN"
  local workflow_verdict="FAIL"
  local coverage_file="$PROJECT_ROOT/coverage/coverage-summary.json"
  local typecheck_status="NOT_RUN"
  local lint_status="NOT_RUN"
  local build_status="NOT_RUN"
  local e2e_status="NOT_RUN"
  local coverage_statements="N/A"
  local coverage_branches="N/A"
  local coverage_functions="N/A"
  local coverage_lines="N/A"
  local vitest_config=""
  local vitest_config_rel=""
  local jest_config=""
  local feature_exit=1
  local repo_exit=1
  local e2e_exit=1
  local has_feature_scope_runner="false"
  local has_playwright_runner="false"
  local blockers=""

  feature_tests=$(extract_feature_tests "$feature_name")
  feature_scopes=$(extract_feature_scopes "$feature_name")
  feature_file=$(printf '%s\n' "$feature_scopes" | head -1)
  vitest_config=$(first_existing_file \
    "$PROJECT_ROOT/vitest.feature.config.ts" \
    "$PROJECT_ROOT/vitest.feature.config.mts" \
    "$PROJECT_ROOT/vitest.feature.config.js" \
    "$PROJECT_ROOT/vitest.config.ts" \
    "$PROJECT_ROOT/vitest.config.mts" \
    "$PROJECT_ROOT/vitest.config.js" || true)
  vitest_config_rel="${vitest_config#$PROJECT_ROOT/}"
  jest_config=$(first_existing_file \
    "$PROJECT_ROOT/jest.config.ts" \
    "$PROJECT_ROOT/jest.config.js" \
    "$PROJECT_ROOT/jest.config.cjs" || true)

  if [ ! -f "$PROJECT_ROOT/package.json" ]; then
    blockers="${blockers}- 缺少 package.json，无法执行 npm 级本地测试"$'\n'
  fi

  rm -rf "$PROJECT_ROOT/coverage"

  if has_package_script "typecheck"; then
    typecheck_command="npm run typecheck"
    set +e
    typecheck_output=$(npm run typecheck 2>&1)
    [ $? -eq 0 ] && typecheck_status="PASS" || typecheck_status="FAIL"
    set -e
  elif [ -f "$PROJECT_ROOT/tsconfig.json" ]; then
    typecheck_command="npx tsc --noEmit"
    set +e
    typecheck_output=$(npx tsc --noEmit 2>&1)
    [ $? -eq 0 ] && typecheck_status="PASS" || typecheck_status="FAIL"
    set -e
  fi

  if has_package_script "lint"; then
    # 优先只 lint 本次变更的文件，减少噪音；若无变更文件则全量 lint
    local lint_files=""
    lint_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD 2>/dev/null \
      | grep -E '\.(ts|tsx|js|jsx)$' | xargs 2>/dev/null || true)
    if [ -n "$lint_files" ]; then
      lint_command="npm run lint -- $lint_files"
      set +e
      # shellcheck disable=SC2086
      lint_output=$(npm run lint -- $lint_files 2>&1)
      [ $? -eq 0 ] && lint_status="PASS" || lint_status="FAIL"
      set -e
    else
      lint_command="npm run lint"
      set +e
      lint_output=$(npm run lint 2>&1)
      [ $? -eq 0 ] && lint_status="PASS" || lint_status="FAIL"
      set -e
    fi
  fi

  if has_package_script "build"; then
    build_command="npm run build"
    set +e
    build_output=$(npm run build 2>&1)
    [ $? -eq 0 ] && build_status="PASS" || build_status="FAIL"
    set -e
  fi

  if has_package_script "test:e2e" && [ -n "$(first_existing_file "$PROJECT_ROOT/playwright.config.ts" "$PROJECT_ROOT/playwright.config.js" || true)" ]; then
    has_playwright_runner="true"
    feature_command="npm run test:e2e"
    e2e_command="$feature_command"
    set +e
    feature_output=$(npm run test:e2e 2>&1)
    feature_exit=$?
    e2e_output="$feature_output"
    e2e_exit=$feature_exit
    set -e
    if [ "$e2e_exit" -eq 0 ]; then
      e2e_status="PASS"
    elif printf '%s' "$e2e_output" | grep -q "operation not permitted\|Executable doesn't exist\|browserType.launch"; then
      e2e_status="NOT_RUN"
    else
      e2e_status="FAIL"
    fi

    if [ "$e2e_status" = "PASS" ] \
      && [ "$lint_status" != "FAIL" ] \
      && [ "$build_status" != "FAIL" ]; then
      feature_status="PASS"
    fi
  elif [ -n "$feature_file" ] && [ -n "$feature_tests" ] && [ -n "$vitest_config" ]; then
    has_feature_scope_runner="true"
    feature_command="FEATURE_COVERAGE_INCLUDE=$feature_file npx vitest run --config $vitest_config_rel $(printf '%s ' $feature_tests)--coverage"
    set +e
    feature_output=$(FEATURE_COVERAGE_INCLUDE="$feature_file" npx vitest run --config "$vitest_config_rel" $feature_tests --coverage 2>&1)
    feature_exit=$?
    set -e

    if [ -f "$coverage_file" ]; then
      coverage_statements=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.statements&&v.statements.pct)!=null?v.statements.pct:'N/A')")
      coverage_branches=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.branches&&v.branches.pct)!=null?v.branches.pct:'N/A')")
      coverage_functions=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.functions&&v.functions.pct)!=null?v.functions.pct:'N/A')")
      coverage_lines=$(node -e "const f=require('$coverage_file'); const v=f['$feature_file']||f.total||{}; console.log((v.lines&&v.lines.pct)!=null?v.lines.pct:'N/A')")
    fi

    if [ "$feature_exit" -eq 0 ] \
      && [ "$typecheck_status" != "FAIL" ] \
      && is_numeric "$coverage_statements" \
      && is_numeric "$coverage_branches" \
      && is_numeric "$coverage_functions" \
      && is_numeric "$coverage_lines" \
      && awk "BEGIN {exit !($coverage_statements >= 80 && $coverage_branches >= 75 && $coverage_functions >= 80 && $coverage_lines >= 80)}"; then
      feature_status="PASS"
    fi
  elif has_package_script "test"; then
    has_feature_scope_runner="false"
    feature_command="npm test -- --runInBand"
    set +e
    feature_output=$(npm test -- --runInBand 2>&1)
    feature_exit=$?
    set -e
    if [ "$feature_exit" -eq 0 ] \
      && [ "$lint_status" != "FAIL" ] \
      && [ "$build_status" != "FAIL" ]; then
      feature_status="PASS"
    fi
  else
    blockers="${blockers}- 未找到可执行的测试入口（既没有 Playwright，也没有 vitest feature-scope 运行条件，也没有 package.json 的 test script）"$'\n'
  fi

  if [ -n "$blockers" ]; then
    cat > "$test_report" <<EOF
# 测试报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 执行方式：local workflow fallback

## Feature-scope 阻断项
$blockers

FEATURE_SCOPE_STATUS: FAIL
FULL_REPO_STATUS: NOT_RUN
REPO_DEBT_STATUS: NOT_RUN
WORKFLOW_VERDICT: FAIL
EOF
    return 1
  fi

  if has_package_script "test"; then
    repo_command="npm test"
    if [ "$feature_command" = "npm test -- --runInBand" ]; then
      repo_output="$feature_output"
      repo_exit=$feature_exit
    else
      set +e
      repo_output=$(npm test 2>&1)
      repo_exit=$?
      set -e
    fi
    if [ "$repo_exit" -eq 0 ]; then
      full_repo_status="PASS"
      repo_debt_status="PASS"
    else
      full_repo_status="FAIL"
      repo_debt_status="FAIL"
    fi
  fi

  if [ "$feature_status" = "PASS" ] && [ "$e2e_status" != "FAIL" ]; then
    workflow_verdict="PASS"
  fi

  cat > "$test_report" <<EOF
# 测试报告：$feature_name

> 时间：$(date '+%Y-%m-%d %H:%M')
> 执行方式：local workflow fallback

## 汇总
| 套件 | 状态 |
|------|------|
| Feature 单元 | $feature_status |
| Feature E2E | $e2e_status |
| 全仓回归 | $full_repo_status |
| 类型检查 | $typecheck_status |
| Lint | $lint_status |
| Build | $build_status |

## 覆盖率
| 范围 | 指标 | 当前 | 阈值 | 状态 |
|------|------|------|------|------|
| Feature | Statements | ${coverage_statements}% | 80% | $( [ "$coverage_statements" != "N/A" ] && awk "BEGIN {print ($coverage_statements >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Branches | ${coverage_branches}% | 75% | $( [ "$coverage_branches" != "N/A" ] && awk "BEGIN {print ($coverage_branches >= 75 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Functions | ${coverage_functions}% | 80% | $( [ "$coverage_functions" != "N/A" ] && awk "BEGIN {print ($coverage_functions >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |
| Feature | Lines | ${coverage_lines}% | 80% | $( [ "$coverage_lines" != "N/A" ] && awk "BEGIN {print ($coverage_lines >= 80 ? \"PASS\" : \"FAIL\")}" || echo "N/A" ) |

## Feature-scope 结论
- 变更文件：${feature_file:-N/A}
- 直接相关测试文件：$(printf '%s\n' "$feature_tests" | sed 's#^'"$PROJECT_ROOT"'/##' | paste -sd ', ' -)
- 直接相关测试命令：\`$feature_command\`
- Feature runner 模式：$( [ "$has_playwright_runner" = "true" ] && echo "playwright e2e" || ([ "$has_feature_scope_runner" = "true" ] && echo "vitest feature-scope" || echo "repo test fallback") )
- 类型检查：\`$typecheck_command\` → $typecheck_status
- Lint：\`$lint_command\` → $lint_status
- Build：\`$build_command\` → $build_status
- 结果：$feature_status

## 全仓回归观察
- 更广范围命令：\`$repo_command\`
- 结果：$full_repo_status
- 归因：$( [ "$full_repo_status" = "FAIL" ] && echo "项目当前 test script 未通过，需人工判断是新回归还是历史债" || echo "未发现额外阻断信号" )

## E2E 观察
- 命令：\`$e2e_command\`
- 结果：$e2e_status
- 说明：$( [ "$e2e_status" = "NOT_RUN" ] && echo "当前环境未执行或无法启动本地浏览器服务，这不会单独阻断 fallback" || echo "见命令输出" )

## 关键命令输出

### Feature / Test
\`\`\`
$(printf '%s\n' "$feature_output" | sed -n '1,120p')
\`\`\`

### Typecheck
\`\`\`
$(printf '%s\n' "$typecheck_output" | sed -n '1,80p')
\`\`\`

### Lint
\`\`\`
$(printf '%s\n' "$lint_output" | sed -n '1,80p')
\`\`\`

### Build
\`\`\`
$(printf '%s\n' "$build_output" | sed -n '1,80p')
\`\`\`

### Repo Test
\`\`\`
$(printf '%s\n' "$repo_output" | sed -n '1,80p')
\`\`\`

### E2E
\`\`\`
$(printf '%s\n' "$e2e_output" | sed -n '1,80p')
\`\`\`

## 结论：$workflow_verdict

FEATURE_SCOPE_STATUS: $feature_status
FULL_REPO_STATUS: $full_repo_status
REPO_DEBT_STATUS: $repo_debt_status
WORKFLOW_VERDICT: $workflow_verdict
EOF

  [ "$workflow_verdict" = "PASS" ]
}
