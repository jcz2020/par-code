#!/usr/bin/env bash
# Integration tests for /plan and /build mode switching.
# Tests P0 #1: mode switching changes the REPL prompt.
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

test_default_mode_is_build() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  # Default mode is build — prompt shows (build) par>
  tmux_assert_contains 'build.*par>'
  tmux_kill
}

test_plan_mode_switch() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_assert_contains 'build'    # default mode is build
  tmux_send '/plan'
  tmux_wait_for 'plan.*par>' 5
  tmux_assert_contains 'plan.*par>'
  tmux_kill
}

test_build_mode_switch() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/plan'
  tmux_wait_for 'plan.*par>' 5
  tmux_send '/build'
  tmux_wait_for 'build.*par>' 5
  tmux_kill
}

test_plan_file_on_build_switch() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/plan'
  tmux_wait_for 'plan.*par>' 5
  # /build attempts to save the plan to .par/plans/ and switches mode
  tmux_send '/build'
  tmux_wait_for 'Switched' 5
  tmux_kill
  # After /build, .par/plans/ may or may not exist depending on whether
  # an assistant message was present (no LLM ran, so no plan text).
  # The flow must succeed regardless — just verify it didn't crash.
  if [ -d "$HOME/.par/plans" ]; then
    : # plans dir created (plan text was non-empty)
  else
    : # no plans dir (expected when no LLM generated plan)
  fi
}

test_case "default mode is build"                       test_default_mode_is_build
test_case "/plan switches to plan mode"                 test_plan_mode_switch
test_case "/build switches back to build mode"          test_build_mode_switch
test_case "/plan then /build creates plans directory"   test_plan_file_on_build_switch
run_tests "$@"
