#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

test_cjk_chars_display() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "你好"
  sleep 0.5
  tmux_assert_contains '你好'
  tmux_kill
}

test_cjk_multiple_chars() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "你好世界"
  sleep 0.5
  tmux_assert_contains '你好世界'
  tmux_kill
}

test_ascii_backspace_after_cjk() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "你好X"
  sleep 0.5
  tmux_assert_contains '你好X'
  tmux send-keys -t "$SESSION_ID" BSpace
  sleep 0.5
  tmux_assert_contains '你好'
  tmux_assert_not_contains '你好X'
  tmux_kill
}

test_mixed_cjk_ascii() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "hello你好world"
  sleep 0.5
  tmux_assert_contains 'hello'
  tmux_assert_contains '你好'
  tmux_assert_contains 'world'
  tmux_kill
}

test_japanese_input() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "こんにちは"
  sleep 0.5
  tmux_assert_contains 'こんにちは'
  tmux_kill
}

test_korean_input() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "안녕하세요"
  sleep 0.5
  tmux_assert_contains '안녕하세요'
  tmux_kill
}

test_cjk_then_quit_clean() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux send-keys -t "$SESSION_ID" "你好"
  sleep 0.5
  tmux_assert_contains '你好'
  tmux send-keys -t "$SESSION_ID" C-c
  sleep 1
  if tmux has-session -t "$SESSION_ID" 2>/dev/null; then
    fail "session still alive after Ctrl+C"
  fi
  SESSION_ID=""
}

test_case "CJK chars display when typed"            test_cjk_chars_display
test_case "multiple CJK chars accumulate"            test_cjk_multiple_chars
test_case "ASCII backspace after CJK works"          test_ascii_backspace_after_cjk
test_case "mixed CJK + ASCII input"                  test_mixed_cjk_ascii
test_case "Japanese input (こんにちは)"               test_japanese_input
test_case "Korean input (안녕하세요)"                  test_korean_input
test_case "CJK then Ctrl+C exits cleanly"            test_cjk_then_quit_clean
run_tests "$@"
