#!/usr/bin/env bash
# Integration tests for autonomous goal chaining (v0.7.3 W8).
# Uses a dead endpoint (http://127.0.0.1:9) — connection refused instantly,
# no real LLM needed. Exercises: chain start, llm_error_x2 block + prompt
# return, goal file on disk, kill-switch single-turn.
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

# ── Config helpers (dead endpoint = instant connection refused) ─────────

write_dead_endpoint_config() {
  mkdir -p "$HOME/.par"
  cat > "$HOME/.par/config.json" <<'JSON'
{"provider":"openai","api_key":"test-key-fake-not-real","model":"gpt-4o","api_base":"http://127.0.0.1:9","goal_auto_chain":true}
JSON
}

write_no_chain_config() {
  mkdir -p "$HOME/.par"
  cat > "$HOME/.par/config.json" <<'JSON'
{"provider":"openai","api_key":"test-key-fake-not-real","model":"gpt-4o","api_base":"http://127.0.0.1:9","goal_auto_chain":false}
JSON
}

# ── Spawn helper (tmux_spawn doesn't accept CLI args) ──────────────────

tmux_spawn_goal() {
  local goal="$1"
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed" >&2; exit 0; }
  SESSION_ID="par-$$-$RANDOM"
  tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  tmux new-session -d -s "$SESSION_ID" -x 200 -y 50 \
    "env TERM=screen-256color HOME=$HOME PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1 $PAR_BIN --goal '$goal'"
}

# ── Goal file cleanup (goal_file_path is CWD-relative, CWD = project root) ─

clean_goal_file() {
  rm -f "$PROJECT_ROOT/.par/goals/current.json"
}

# ── Test 1: --goal auto-starts the chain ──────────────────────────────

test_goal_auto_starts_chain() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  clean_goal_file
  tmux_spawn_goal "write hello.txt"
  # W7 renders goal-set notice + chain-start text before the first turn
  tmux_wait_for "Goal set" 60
  tmux_assert_contains "Starting autonomous chain"
  tmux_kill
  clean_goal_file
}

# ── Test 2: two error turns → llm_error_x2 block → prompt returns ────

test_goal_blocked_llm_error_x2() {
  setup_home; trap teardown_home EXIT
  write_dead_endpoint_config
  clean_goal_file
  tmux_spawn_goal "write hello.txt"
  # Chain runs 2 error turns; second turn hits the streak guard
  # Rendered text: "[goal blocked — LLM errors x2; ...]" (spaces, not underscores)
  tmux_wait_for "LLM errors x2" 60
  # Chain stopped → prompt returns
  tmux_wait_for "par>" 10
  tmux_assert_contains "par>"
  tmux_kill
  # Verify goal file exists on disk with Blocked status
  test -f "$PROJECT_ROOT/.par/goals/current.json" \
    || fail ".par/goals/current.json not found after llm_error_x2 block"
  cat "$PROJECT_ROOT/.par/goals/current.json" \
    | assert_contains "blocked: llm_error_x2"
  clean_goal_file
}

# ── Test 3: auto_chain=false → one error turn then prompt ─────────────

test_goal_auto_chain_false_single_turn() {
  setup_home; trap teardown_home EXIT
  write_no_chain_config
  clean_goal_file
  tmux_spawn_goal "write hello.txt"
  # Goal-set + chain-start still render (W7 renders before the first turn)
  tmux_wait_for "Goal set" 60
  tmux_assert_contains "Starting autonomous chain"
  # One error turn → Chain_stop (auto_chain=false) → prompt returns
  tmux_wait_for "par>" 30
  tmux_assert_contains "par>"
  # Streak 1 < 2 → llm_error_x2 must NOT appear
  tmux_assert_not_contains "llm_error_x2"
  tmux_kill
  clean_goal_file
}

# ── Test 4: Ctrl+C at prompt exits ────────────────────────────────────
# NOTE: basics_test.sh test_ctrl_c_at_prompt_exits_cleanly already covers
# Ctrl+C at prompt exit (guards W5 SIGINT rewrite regression).
# Skipping to avoid duplication — the goal-chain binary's prompt path is
# identical (loop() → LNoise.linenoise → exception Sys.Break → exit_normally).

test_case "goal auto-starts chain"                  test_goal_auto_starts_chain
test_case "goal blocked llm_error_x2"              test_goal_blocked_llm_error_x2
test_case "goal auto_chain=false single turn"      test_goal_auto_chain_false_single_turn
run_tests "$@"
