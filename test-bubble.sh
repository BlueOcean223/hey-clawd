#!/bin/bash
set -euo pipefail

# 权限气泡端到端测试脚本。
# 默认跑一组最常见的场景，也支持按子命令拆开验证。

DEFAULT_PORT=23333
RUNTIME_FILE="${HOME}/.clawd/runtime.json"
CASE="${1:-all}"

resolve_port() {
  if [[ -n "${CLAWD_PORT:-}" ]]; then
    printf '%s\n' "${CLAWD_PORT}"
    return
  fi

  if [[ -f "${RUNTIME_FILE}" ]]; then
    local runtime_port
    runtime_port="$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${RUNTIME_FILE}" | head -n 1)"
    if [[ -n "${runtime_port}" ]]; then
      printf '%s\n' "${runtime_port}"
      return
    fi
  fi

  printf '%s\n' "${DEFAULT_PORT}"
}

PORT="$(resolve_port)"
BASE_URL="http://127.0.0.1:${PORT}"

request_json() {
  local payload="$1"
  curl --silent --show-error --fail \
    -X POST "${BASE_URL}/permission" \
    -H "Content-Type: application/json" \
    -d "${payload}"
}

single_case() {
  echo "single: send one permission request and click Allow or Deny in the bubble"
  request_json '{
    "tool_name": "Bash",
    "tool_input": {"command": "rm -rf /"},
    "session_id": "test-single",
    "permission_suggestions": [
      {"type": "addRules", "destination": "localSettings", "behavior": "allow", "rules": []}
    ]
  }'
  echo
}

stack_case() {
  echo "stack: send two permission requests; newest bubble should stay at the bottom"

  (
    request_json '{
      "tool_name": "Bash",
      "tool_input": {"command": "rm -rf /"},
      "session_id": "test-stack-1",
      "permission_suggestions": [
        {"type": "addRules", "destination": "localSettings", "behavior": "allow", "rules": []}
      ]
    }'
  ) &
  local first_pid=$!

  sleep 1

  (
    request_json '{
      "tool_name": "Write",
      "tool_input": {"file_path": "/etc/hosts", "content": "..."},
      "session_id": "test-stack-2"
    }'
  ) &
  local second_pid=$!

  wait "${first_pid}"
  wait "${second_pid}"
  echo
}

passthrough_case() {
  echo "passthrough: TaskCreate should auto-allow without showing a bubble"
  request_json '{
    "tool_name": "TaskCreate",
    "tool_input": {"title": "background worker"},
    "session_id": "test-passthrough"
  }'
  echo
}

disconnect_case() {
  echo "disconnect: curl exits early; matching bubble should disappear on its own"
  curl --silent --show-error \
    --max-time 1 \
    -X POST "${BASE_URL}/permission" \
    -H "Content-Type: application/json" \
    -d '{
      "tool_name": "Bash",
      "tool_input": {"command": "sleep 30"},
      "session_id": "test-disconnect"
    }' || true
  echo
}

dnd_case() {
  echo "dnd: enable Do Not Disturb from the tray first, then run this case"
  request_json '{
    "tool_name": "Bash",
    "tool_input": {"command": "touch /tmp/dnd-test"},
    "session_id": "test-dnd"
  }'
  echo
}

usage() {
  cat <<'EOF'
Usage: ./test-bubble.sh [all|single|stack|passthrough|disconnect|dnd]

all          run stack, passthrough, and disconnect in sequence
single       one permission request for Allow/Deny or suggestion-button checks
stack        two pending requests for bubble stacking and hotkey checks
passthrough  TaskCreate auto-allow check
disconnect   client disconnect cleanup check
dnd          send one request while DND is enabled and expect deny
EOF
}

case "${CASE}" in
  all)
    stack_case
    passthrough_case
    disconnect_case
    ;;
  single)
    single_case
    ;;
  stack)
    stack_case
    ;;
  passthrough)
    passthrough_case
    ;;
  disconnect)
    disconnect_case
    ;;
  dnd)
    dnd_case
    ;;
  *)
    usage
    exit 1
    ;;
esac
