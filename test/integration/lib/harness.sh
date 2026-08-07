#!/usr/bin/env bash
# Core harness primitives for par-code integration tests.
# Provides: isolation, one-shot CLI exec, tmux REPL control, assertions.

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ── Isolation ──────────────────────────────────────────────────────────

TEST_HOME=""
SESSION_ID=""

setup_home() {
  TEST_HOME="$(mktemp -d -t par-test-home.XXXXXX 2>/dev/null || mktemp -d)"
  export HOME="$TEST_HOME"
  export PAR_NO_UPDATE_CHECK=1
  export PAR_NO_AUTO_EXTRACT=1
  export PAR_NO_CHECKPOINT=1
  write_dummy_config
}

teardown_home() {
  [ -n "$SESSION_ID" ] && tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  [ -n "$TEST_HOME" ] && rm -rf "$TEST_HOME" 2>/dev/null || true
}

# ── One-shot CLI exec (no tmux) ────────────────────────────────────────

par_cli() {
  "$PAR_BIN" "$@"
}

# ── tmux REPL primitives ───────────────────────────────────────────────

tmux_spawn() {
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed" >&2; exit 0; }
  SESSION_ID="par-$$-$RANDOM"
  tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  tmux new-session -d -s "$SESSION_ID" -x 200 -y 50 \
    "env TERM=screen-256color HOME=$HOME PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1 $PAR_BIN"
}

tmux_wait_for() {
  local pattern="$1" timeout="${2:-$PROMPT_TIMEOUT}"
  local deadline=$((SECONDS + timeout))
  until tmux capture-pane -t "$SESSION_ID" -p 2>/dev/null | grep -qE "$pattern"; do
    if (( SECONDS >= deadline )); then
      echo "FAIL: timeout waiting for: $pattern" >&2
      tmux capture-pane -t "$SESSION_ID" -p >&2 2>/dev/null || true
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

tmux_send() {
  tmux send-keys -t "$SESSION_ID" "$1" Enter
}

tmux_capture() {
  tmux capture-pane -t "$SESSION_ID" -p 2>/dev/null
}

tmux_kill() {
  [ -n "$SESSION_ID" ] && tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  SESSION_ID=""
}

# ── Assertions ─────────────────────────────────────────────────────────

assert_contains() {
  local pattern="$1"
  local input
  input="$(cat)"
  if ! echo "$input" | grep -qiE "$pattern"; then
    fail "expected pattern not found: $pattern"
  fi
}

assert_not_contains() {
  local pattern="$1"
  local input
  input="$(cat)"
  if echo "$input" | grep -qiE "$pattern"; then
    fail "unexpected pattern found: $pattern"
  fi
}

assert_exit_zero() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "expected exit 0, got $rc"
  fi
}

tmux_assert_contains() {
  local pattern="$1"
  if ! tmux_capture | grep -qiE "$pattern"; then
    echo "FAIL: expected in pane: $pattern" >&2
    tmux_capture >&2
    fail "pattern not found in tmux pane: $pattern"
  fi
}

tmux_assert_not_contains() {
  local pattern="$1"
  if tmux_capture | grep -qiE "$pattern"; then
    echo "FAIL: unexpected in pane: $pattern" >&2
    tmux_capture >&2
    fail "unexpected pattern in tmux pane: $pattern"
  fi
}

# ── Pass/Fail ──────────────────────────────────────────────────────────

_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  : # individual test functions call exit 0 on success
}

# ── Test registration & runner ─────────────────────────────────────────

declare -a _TEST_NAMES=()
declare -a _TEST_FUNCS=()

test_case() {
  _TEST_NAMES+=("$1")
  _TEST_FUNCS+=("$2")
}

run_tests() {
  local filter="${1:-}"
  local total=0 passed=0 failed=0
  for i in "${!_TEST_NAMES[@]}"; do
    local name="${_TEST_NAMES[$i]}"
    local func="${_TEST_FUNCS[$i]}"
    if [ -n "$filter" ] && ! echo "$name" | grep -qE "$filter"; then
      continue
    fi
    total=$((total + 1))
    printf "  %-50s " "$name"
    if ( "$func" ) 2>&1; then
      echo "PASS"
      passed=$((passed + 1))
    else
      echo "FAIL"
      failed=$((failed + 1))
    fi
  done
  echo ""
  echo "Results: $passed passed, $failed failed, $total total"
  [ "$failed" -eq 0 ]
}
