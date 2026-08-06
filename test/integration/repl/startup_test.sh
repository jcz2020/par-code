#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

test_no_update_notice() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_assert_not_contains 'is available'
  tmux_assert_not_contains "par upgrade"
  tmux_kill
}

test_banner_present() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_assert_contains 'par'
  tmux_kill
}

test_case "no update notice with PAR_NO_UPDATE_CHECK"  test_no_update_notice
test_case "banner present on startup"                   test_banner_present
run_tests "$@"
