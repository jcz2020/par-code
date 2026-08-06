#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

test_version_exits_zero() {
  setup_home; trap teardown_home EXIT
  par_cli --version >/dev/null 2>&1
}

test_version_format() {
  setup_home; trap teardown_home EXIT
  par_cli --version 2>&1 | assert_contains '[0-9]+\.[0-9]+\.[0-9]+'
}

test_config_show_no_config() {
  setup_home; trap teardown_home EXIT
  rm -f "$HOME/.par/config.json"
  par_cli config show 2>&1 | assert_contains 'no config'
}

test_config_show_with_config() {
  setup_home; trap teardown_home EXIT
  par_cli config show 2>&1 | assert_contains 'provider'
}

test_case "version exits zero"      test_version_exits_zero
test_case "version format"          test_version_format
test_case "config show no config"   test_config_show_no_config
test_case "config show with config" test_config_show_with_config
run_tests "$@"
