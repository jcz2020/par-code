#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

# v0.15.7: Esc must stop a turn whose provider accepted the request and then
# went silent. A local loopback server provides the silence; no external
# network is involved.
TEST_PROVIDER_PID=""
trap 'kill "${TEST_PROVIDER_PID:-}" 2>/dev/null || true; teardown_home' EXIT

test_escape_cancels_silent_provider() {
  command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed" >&2; exit 0; }
  setup_home; trap teardown_home EXIT
  local port_file="$HOME/provider.port"
  python3 "$PROJECT_ROOT/test/integration/lib/silent_provider.py" "$port_file" &
  TEST_PROVIDER_PID=$!
  trap 'kill "${TEST_PROVIDER_PID:-}" 2>/dev/null || true; teardown_home' EXIT

  local deadline=$((SECONDS + 10))
  while [ ! -s "$port_file" ]; do
    if (( SECONDS >= deadline )); then
      fail "silent provider did not start"
    fi
    sleep 0.1
  done
  local port
  port="$(cat "$port_file")"

  python3 - "$HOME/.par/config.json" "$port" <<'PY'
import json, sys
path, port = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg.update({
    "api_base": "http://127.0.0.1:%s/v1" % port,
    "model": "silent-test",
    "checkpoint_enabled": False,
    "auto_extract": False,
    "judge_enabled": False,
    "snapshot_enabled": False,
    "mcp_servers": [],
})
json.dump(cfg, open(path, "w"))
PY

  tmux_spawn
  tmux_wait_for '›' 8
  tmux send-keys -t "$SESSION_ID" -l 'hello silent provider'
  tmux send-keys -t "$SESSION_ID" Enter
  tmux_wait_for 'esc interrupt' 15

  local started=$SECONDS
  tmux send-keys -t "$SESSION_ID" Escape
  tmux_wait_for 'cancelled by user' 8
  local elapsed=$((SECONDS - started))
  if (( elapsed > 5 )); then
    fail "Esc took ${elapsed}s to cancel a silent provider (expected <= 5s)"
  fi
  tmux_wait_for 'Ask anything' 5
}

test_escape_cancels_silent_provider
