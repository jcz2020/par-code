#!/usr/bin/env bash
# Integration tests for max mode (v0.8.0): /max command surface and the
# all-candidates-fail fallback, exercised against a dead endpoint
# (http://127.0.0.1:9) so no real LLM is needed.
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

write_dead_endpoint_config() {
  mkdir -p "$HOME/.par"
  cat > "$HOME/.par/config.json" <<'JSON'
{"provider":"openai","api_key":"test-key-fake-not-real","model":"gpt-4o","api_base":"http://127.0.0.1:9"}
JSON
}

tmux_spawn_max() {
  local n="$1"
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed" >&2; exit 0; }
  SESSION_ID="par-$$-$RANDOM"
  tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  tmux new-session -d -s "$SESSION_ID" -x 200 -y 50 \
    "env TERM=screen-256color HOME=$HOME PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1 $PAR_BIN --max $n"
}

test_max_status_defaults_off() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  tmux_spawn
  tmux_wait_for "par>" 60
  tmux_send "/max"
  tmux_wait_for "max mode: off" 10
  tmux_assert_contains "3 candidates"
  tmux_kill
}

test_max_rejects_out_of_range() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  tmux_spawn
  tmux_wait_for "par>" 60
  tmux_send "/max 9"
  tmux_wait_for "between 2 and 5" 10
  tmux_assert_not_contains "Max mode on: 9"
  tmux_kill
}

test_max_all_candidates_fail_falls_back() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  tmux_spawn_max 3
  tmux_wait_for "max mode" 60
  tmux_assert_contains "3 candidates per turn"
  tmux_send "hello there"
  tmux_wait_for "3 candidates running" 30
  tmux_wait_for "all candidates failed" 60
  tmux_kill
}

test_max_skipped_in_goal_chain() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  rm -f "$PROJECT_ROOT/.par/goals/current.json"
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed" >&2; exit 0; }
  SESSION_ID="par-$$-$RANDOM"
  tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  tmux new-session -d -s "$SESSION_ID" -x 200 -y 50 \
    "env TERM=screen-256color HOME=$HOME PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1 $PAR_BIN --max 3 --goal 'write hello.txt'"
  tmux_wait_for "skipped during the goal chain" 60
  tmux_assert_not_contains "candidates running"
  tmux_kill
  rm -f "$PROJECT_ROOT/.par/goals/current.json"
}

test_case "/max status defaults to off"            test_max_status_defaults_off
test_case "/max rejects out-of-range candidate N"  test_max_rejects_out_of_range
test_case "all candidates fail falls back"          test_max_all_candidates_fail_falls_back
test_case "goal chain skips max mode"              test_max_skipped_in_goal_chain
run_tests "$@"
