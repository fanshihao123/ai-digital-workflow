#!/bin/bash
# dev-server.sh — Dev server lifecycle management
# Sourced by v4/handler.sh; requires common.sh and PROJECT_ROOT to be set

# 检测 dev server 端口（从 package.json 读取，fallback 3000）
_detect_dev_port() {
  local pkg="$PROJECT_ROOT/package.json"
  local port=""
  if [ -f "$pkg" ]; then
    port=$(node -e "
      try {
        const pkg = require('$pkg');
        const devScript = pkg.scripts?.dev || '';
        const match = devScript.match(/--port[= ](\d+)/);
        console.log(match ? match[1] : '');
      } catch(e) { console.log(''); }
    " 2>/dev/null || true)
  fi
  echo "${port:-3000}"
}

# 检查 dev server 是否正在运行（多级降级：curl → nc → lsof）
_dev_server_running() {
  local port="$1"
  # 优先 curl：最通用，直接验证 HTTP 可达（加总超时，避免静默挂住）
  if command -v curl &>/dev/null; then
    perl -e 'alarm shift @ARGV; exec @ARGV' 3 curl -s -o /dev/null --connect-timeout 1 --max-time 2 "http://localhost:${port}/" 2>/dev/null && return 0
  fi
  # 降级 nc：检测 TCP 端口开放
  if command -v nc &>/dev/null; then
    perl -e 'alarm shift @ARGV; exec @ARGV' 3 nc -z localhost "$port" 2>/dev/null && return 0
  fi
  # 降级 lsof
  if command -v lsof &>/dev/null; then
    perl -e 'alarm shift @ARGV; exec @ARGV' 3 bash -lc 'lsof -i :"$1" 2>/dev/null | grep -q LISTEN 2>/dev/null' _ "$port" && return 0
  fi
  return 1
}

# 等待 dev server 端口就绪（最多 60s）
_wait_dev_server() {
  local port="$1"
  local elapsed=0
  while [ $elapsed -lt 60 ]; do
    if _dev_server_running "$port"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# 确保 dev server 已启动，返回访问 URL
# 返回值（stdout）: http://localhost:{PORT}
# 返回码: 0=成功 1=失败
ensure_dev_server() {
  local feature_name="$1"
  local port
  echo "  [dev-server][debug] before _detect_dev_port" >&2
  port=$(_detect_dev_port)
  echo "  [dev-server][debug] after _detect_dev_port: ${port}" >&2
  local base_url="http://localhost:${port}"

  echo "  [dev-server][debug] before _dev_server_running check" >&2
  if _dev_server_running "$port"; then
    echo "  [dev-server] 已在端口 $port 运行" >&2
    notify "dev server 已在 $base_url 运行" "$feature_name"
    echo "$base_url"
    return 0
  fi

  echo "  [dev-server] 未检测到运行中的 dev server，尝试启动..." >&2
  local log_file="/tmp/devserver-${feature_name}.log"

  # 后台启动
  echo "  [dev-server][debug] before nohup npm run dev" >&2
  nohup npm --prefix "$PROJECT_ROOT" run dev \
    > "$log_file" 2>&1 &
  echo "  [dev-server][debug] after nohup npm run dev" >&2

  echo "  [dev-server] 等待端口 $port 就绪（最多 60s）..." >&2
  echo "  [dev-server][debug] before _wait_dev_server" >&2
  if _wait_dev_server "$port"; then
    echo "  [dev-server][debug] after _wait_dev_server success" >&2
    echo "  [dev-server] 启动成功: $base_url" >&2
    notify "dev server 已启动: $base_url\n日志: $log_file" "$feature_name"
    echo "$base_url"
    return 0
  else
    echo "  [dev-server] ❌ 启动超时（60s）" >&2
    agent_notify \
      "需求 '$feature_name' 的 dev server 启动失败，日志: $log_file" \
      "请手动启动 dev server 后执行 /resume $feature_name 继续" \
      "$feature_name"
    return 1
  fi
}
