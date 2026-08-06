#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

_get_added_id() {
  local out="$1"
  echo "$out" | grep -oE 'Added memory #[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | sed 's/Added memory #//'
}

test_memory_list_empty() {
  setup_home; trap teardown_home EXIT
  par_cli memory list 2>&1 | assert_contains 'no memories'
  par_cli memory list >/dev/null 2>&1
}

test_memory_add() {
  setup_home; trap teardown_home EXIT
  par_cli memory add \
    --kind convention \
    --summary "test summary" \
    --content "test content" 2>&1 | assert_contains 'Added memory'
}

test_memory_list_after_add() {
  setup_home; trap teardown_home EXIT
  par_cli memory add \
    --kind convention \
    --summary "test summary" \
    --content "test content" >/dev/null 2>&1
  par_cli memory list 2>&1 | assert_contains 'test summary'
}

test_memory_show_full_id() {
  setup_home; trap teardown_home EXIT
  local out
  out="$(par_cli memory add --kind convention --summary "test summary" --content "test content" 2>&1)"
  local full_id
  full_id="$(_get_added_id "$out")"
  [ -n "$full_id" ] || fail "could not extract full ID from: $out"
  par_cli memory show "$full_id" 2>&1 | assert_contains 'test content'
}

test_memory_show_prefix() {
  setup_home; trap teardown_home EXIT
  local out
  out="$(par_cli memory add --kind convention --summary "test summary" --content "test content" 2>&1)"
  local full_id
  full_id="$(_get_added_id "$out")"
  [ -n "$full_id" ] || fail "could not extract full ID from: $out"
  local prefix="${full_id:0:8}"
  par_cli memory show "$prefix" 2>&1 | assert_contains 'test content'
}

test_memory_search() {
  setup_home; trap teardown_home EXIT
  par_cli memory add \
    --kind convention \
    --summary "test summary" \
    --content "test content" >/dev/null 2>&1
  par_cli memory search "test" 2>&1 | assert_contains 'test summary'
}

test_memory_prune_dry_run() {
  setup_home; trap teardown_home EXIT
  par_cli memory add \
    --kind convention \
    --summary "test summary" \
    --content "test content" >/dev/null 2>&1
  par_cli memory prune --dry-run --older-than 9999 2>&1 | assert_contains 'Would prune 0'
}

test_memory_forget() {
  setup_home; trap teardown_home EXIT
  local out
  out="$(par_cli memory add --kind convention --summary "test summary" --content "test content" 2>&1)"
  local full_id
  full_id="$(_get_added_id "$out")"
  [ -n "$full_id" ] || fail "could not extract full ID from: $out"
  par_cli memory forget "$full_id" 2>&1 | assert_contains 'Forgot memory'
}

test_memory_list_after_forget() {
  setup_home; trap teardown_home EXIT
  local out
  out="$(par_cli memory add --kind convention --summary "test summary" --content "test content" 2>&1)"
  local full_id
  full_id="$(_get_added_id "$out")"
  [ -n "$full_id" ] || fail "could not extract full ID from: $out"
  par_cli memory forget "$full_id" >/dev/null 2>&1
  par_cli memory list 2>&1 | assert_contains 'no memories'
}

test_memory_show_bad_prefix() {
  setup_home; trap teardown_home EXIT
  local out rc=0
  out="$(par_cli memory show zzzz 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected non-zero exit for bad prefix"
  echo "$out" | assert_contains 'No memory matches'
}

test_case "memory list empty"         test_memory_list_empty
test_case "memory add"                test_memory_add
test_case "memory list after add"     test_memory_list_after_add
test_case "memory show full ID"       test_memory_show_full_id
test_case "memory show prefix"        test_memory_show_prefix
test_case "memory search FTS5"        test_memory_search
test_case "memory prune dry-run"      test_memory_prune_dry_run
test_case "memory forget"             test_memory_forget
test_case "memory list after forget"  test_memory_list_after_forget
test_case "memory show bad prefix"    test_memory_show_bad_prefix
run_tests "$@"
