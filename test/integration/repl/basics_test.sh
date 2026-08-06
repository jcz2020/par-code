#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

test_startup_banner() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_assert_contains 'par'
  tmux_assert_contains 'type a message|/help'
  tmux_kill
}

test_help_command() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/help'
  tmux_wait_for '/quit' 5
  tmux_assert_contains '/cost'
  tmux_assert_contains '/plan'
  tmux_assert_contains '/session'
  tmux_kill
}

test_session_command() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/session'
  tmux_wait_for 'Messages:' 5
  tmux_assert_contains 'Agent:'
  tmux_assert_contains 'Session:'
  tmux_assert_contains 'Turns:'
  tmux_assert_contains 'Messages:'
  tmux_kill
}

test_cost_command() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/cost'
  tmux_wait_for 'LLM calls|tokens|Token' 5
  tmux_assert_contains 'LLM calls|tokens|Token'
  tmux_kill
}

test_quit_command() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/quit'
  local deadline=$((SECONDS + 8))
  while tmux has-session -t "$SESSION_ID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      fail "tmux session still alive 8s after /quit"
    fi
    sleep 0.2
  done
  SESSION_ID=""
}

test_case "startup banner"            test_startup_banner
test_case "/help lists commands"      test_help_command
test_case "/session shows info"       test_session_command
test_case "/cost shows token usage"   test_cost_command
test_case "/quit exits cleanly"       test_quit_command
run_tests "$@"
