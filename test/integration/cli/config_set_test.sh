#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

# Columns: field value expected_regex_in_config_show
declare -a FIELDS=(
  "provider anthropic anthropic"
  "api_key sk-test-1234 sk-t"
  "model claude-3-haiku claude-3-haiku"
  "persistence memory memory"
  "api_base https://api.test.com https://api.test.com"
  "db_uri /tmp/test.db /tmp/test.db"
  "embedding_base_url https://embed.test.com https://embed.test.com"
  "embedding_model text-embed-001 text-embed-001"
  "temperature 0.5 0\\.50"
  "event_retention_days 60 60\\.0"
  "top_p 0.9 0\\.9000"
  "max_iterations 25 25"
  "embedding_dimension 512 512"
  "checkpoint_interval 5 5"
  "context_budget_tokens 50000 50000"
  "max_tokens 2048 2048"
  "parallel_tool_execution true parallel_tool_execution.*true"
  "auto_extract false auto_extract.*false"
  "checkpoint_enabled true checkpoint_enabled.*true"
  "default_mode plan plan"
  "bash_approval auto_project auto_project"
)

test_all_21_fields_set_and_show() {
  setup_home; trap teardown_home EXIT
  for entry in "${FIELDS[@]}"; do
    local field value pattern
    read -r field value pattern <<< "$entry"
    par_cli config set "$field" "$value" >/dev/null 2>&1 || fail "config set $field $value exited non-zero"
    par_cli config show 2>&1 | assert_contains "$pattern" || fail "config show missing $field=$value (pattern: $pattern)"
  done
}

test_set_provider() {
  setup_home; trap teardown_home EXIT
  par_cli config set provider anthropic 2>&1
  par_cli config show 2>&1 | assert_contains 'anthropic'
}

test_set_api_key() {
  setup_home; trap teardown_home EXIT
  par_cli config set api_key sk-test-1234 2>&1
  par_cli config show 2>&1 | assert_contains 'sk-t'
}

test_set_api_base() {
  setup_home; trap teardown_home EXIT
  par_cli config set api_base https://api.test.com 2>&1
  par_cli config show 2>&1 | assert_contains 'api.test.com'
}

test_set_model() {
  setup_home; trap teardown_home EXIT
  par_cli config set model claude-3-haiku 2>&1
  par_cli config show 2>&1 | assert_contains 'claude-3-haiku'
}

test_set_persistence() {
  setup_home; trap teardown_home EXIT
  par_cli config set persistence memory 2>&1
  par_cli config show 2>&1 | assert_contains 'memory'
}

test_set_db_uri() {
  setup_home; trap teardown_home EXIT
  par_cli config set db_uri /tmp/test.db 2>&1
  par_cli config show 2>&1 | assert_contains '/tmp/test.db'
}

test_set_embedding_base_url() {
  setup_home; trap teardown_home EXIT
  par_cli config set embedding_base_url https://embed.test.com 2>&1
  par_cli config show 2>&1 | assert_contains 'embed.test.com'
}

test_set_embedding_model() {
  setup_home; trap teardown_home EXIT
  par_cli config set embedding_model text-embed-001 2>&1
  par_cli config show 2>&1 | assert_contains 'text-embed-001'
}

test_set_temperature() {
  setup_home; trap teardown_home EXIT
  par_cli config set temperature 0.5 2>&1
  par_cli config show 2>&1 | assert_contains '0\.50'
}

test_set_event_retention_days() {
  setup_home; trap teardown_home EXIT
  par_cli config set event_retention_days 60 2>&1
  par_cli config show 2>&1 | assert_contains '60\.0'
}

test_set_top_p() {
  setup_home; trap teardown_home EXIT
  par_cli config set top_p 0.9 2>&1
  par_cli config show 2>&1 | assert_contains '0\.9000'
}

test_set_max_iterations() {
  setup_home; trap teardown_home EXIT
  par_cli config set max_iterations 25 2>&1
  par_cli config show 2>&1 | assert_contains '25'
}

test_set_max_tokens() {
  setup_home; trap teardown_home EXIT
  par_cli config set max_tokens 2048 2>&1
  par_cli config show 2>&1 | assert_contains '2048'
}

test_set_embedding_dimension() {
  setup_home; trap teardown_home EXIT
  par_cli config set embedding_dimension 512 2>&1
  par_cli config show 2>&1 | assert_contains '512'
}

test_set_checkpoint_interval() {
  setup_home; trap teardown_home EXIT
  par_cli config set checkpoint_interval 5 2>&1
  par_cli config show 2>&1 | assert_contains '5'
}

test_set_context_budget_tokens() {
  setup_home; trap teardown_home EXIT
  par_cli config set context_budget_tokens 50000 2>&1
  par_cli config show 2>&1 | assert_contains '50000'
}

test_set_parallel_tool_execution() {
  setup_home; trap teardown_home EXIT
  par_cli config set parallel_tool_execution true 2>&1
  par_cli config show 2>&1 | assert_contains 'true'
}

test_set_auto_extract() {
  setup_home; trap teardown_home EXIT
  par_cli config set auto_extract false 2>&1
  par_cli config show 2>&1 | assert_contains 'false'
}

test_set_checkpoint_enabled() {
  setup_home; trap teardown_home EXIT
  par_cli config set checkpoint_enabled true 2>&1
  par_cli config show 2>&1 | assert_contains 'true'
}

test_set_default_mode() {
  setup_home; trap teardown_home EXIT
  par_cli config set default_mode plan 2>&1
  par_cli config show 2>&1 | assert_contains 'plan'
}

test_set_bash_approval() {
  setup_home; trap teardown_home EXIT
  par_cli config set bash_approval auto_project 2>&1
  par_cli config show 2>&1 | assert_contains 'auto_project'
}

test_bash_approval_invalid_rejected() {
  setup_home; trap teardown_home EXIT
  local output rc=0
  output=$(par_cli config set bash_approval bogus 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bash_approval bogus should exit non-zero"
  echo "$output" | assert_contains 'Invalid bash_approval'
}

test_clear_top_p_with_none() {
  setup_home; trap teardown_home EXIT
  par_cli config set top_p 0.9 2>&1
  par_cli config show 2>&1 | assert_contains '0\.9000'
  par_cli config set top_p none 2>&1
  par_cli config show 2>&1 | assert_contains '<default>'
}

test_clear_max_tokens_with_none() {
  setup_home; trap teardown_home EXIT
  par_cli config set max_tokens 2048 2>&1
  par_cli config show 2>&1 | assert_contains '2048'
  par_cli config set max_tokens none 2>&1
  par_cli config show 2>&1 | assert_contains '<unlimited>'
}

test_clear_api_base_with_none() {
  setup_home; trap teardown_home EXIT
  par_cli config set api_base https://custom.api.com 2>&1
  par_cli config show 2>&1 | assert_contains 'custom.api.com'
  par_cli config set api_base none 2>&1
  par_cli config show 2>&1 | assert_contains '<default>'
}

test_system_prompt_rejected() {
  setup_home; trap teardown_home EXIT
  local output
  output=$(par_cli config set system_prompt "hello world" 2>&1) || true
  echo "$output" | assert_contains 'multiline|wizard'
}

test_unknown_field_lists_supported() {
  setup_home; trap teardown_home EXIT
  local output
  output=$(par_cli config set bogus_field value 2>&1) || true
  echo "$output" | assert_contains 'Unknown config field'
  echo "$output" | assert_contains 'Supported fields'
  echo "$output" | assert_contains 'provider'
  echo "$output" | assert_contains 'temperature'
  echo "$output" | assert_contains 'context_budget_tokens'
}

test_max_iterations_zero_rejected() {
  setup_home; trap teardown_home EXIT
  local output rc=0
  output=$(par_cli config set max_iterations 0 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "max_iterations 0 should exit non-zero"
  echo "$output" | assert_contains 'must be > 0'
}

test_checkpoint_interval_zero_rejected() {
  setup_home; trap teardown_home EXIT
  local output rc=0
  output=$(par_cli config set checkpoint_interval 0 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "checkpoint_interval 0 should exit non-zero"
  echo "$output" | assert_contains 'must be >= 1'
}

test_context_budget_tokens_500_rejected() {
  setup_home; trap teardown_home EXIT
  local output rc=0
  output=$(par_cli config set context_budget_tokens 500 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "context_budget_tokens 500 should exit non-zero"
  echo "$output" | assert_contains 'must be >= 1000'
}

test_case "all 21 fields set+show round-trip"  test_all_21_fields_set_and_show

test_case "set provider"                       test_set_provider
test_case "set api_key"                        test_set_api_key
test_case "set api_base"                       test_set_api_base
test_case "set model"                          test_set_model
test_case "set persistence"                    test_set_persistence
test_case "set db_uri"                         test_set_db_uri
test_case "set embedding_base_url"             test_set_embedding_base_url
test_case "set embedding_model"                test_set_embedding_model
test_case "set temperature"                    test_set_temperature
test_case "set event_retention_days"           test_set_event_retention_days
test_case "set top_p"                          test_set_top_p
test_case "set max_iterations"                 test_set_max_iterations
test_case "set max_tokens"                     test_set_max_tokens
test_case "set embedding_dimension"            test_set_embedding_dimension
test_case "set checkpoint_interval"            test_set_checkpoint_interval
test_case "set context_budget_tokens"          test_set_context_budget_tokens
test_case "set parallel_tool_execution"        test_set_parallel_tool_execution
test_case "set auto_extract"                   test_set_auto_extract
test_case "set checkpoint_enabled"             test_set_checkpoint_enabled
test_case "set default_mode"                   test_set_default_mode
test_case "set bash_approval"                  test_set_bash_approval
test_case "bash_approval invalid rejected"     test_bash_approval_invalid_rejected

test_case "clear top_p with none"              test_clear_top_p_with_none
test_case "clear max_tokens with none"         test_clear_max_tokens_with_none
test_case "clear api_base with none"           test_clear_api_base_with_none

test_case "system_prompt rejected"             test_system_prompt_rejected
test_case "unknown field lists supported"      test_unknown_field_lists_supported

test_case "max_iterations 0 rejected"          test_max_iterations_zero_rejected
test_case "checkpoint_interval 0 rejected"     test_checkpoint_interval_zero_rejected
test_case "context_budget_tokens 500 rejected" test_context_budget_tokens_500_rejected

run_tests "$@"
