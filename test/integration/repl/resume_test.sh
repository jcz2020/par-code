#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

# Regression: v0.7.2 — QA once saw --resume blank for 70s; pins banner+prompt ≤ 3s.
spawn_resume() {
  SESSION_ID="par-$$-$RANDOM"
  tmux kill-session -t "$SESSION_ID" 2>/dev/null || true
  tmux new-session -d -s "$SESSION_ID" -x 200 -y 50 \
    "env TERM=screen-256color HOME=$HOME PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1 $PAR_BIN --resume"
}

test_resume_banner_within_3s() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/help'
  tmux_wait_for '/quit' 5
  tmux send-keys -t "$SESSION_ID" C-d
  sleep 1
  if tmux has-session -t "$SESSION_ID" 2>/dev/null; then
    fail "session alive 1s after Ctrl+D"
  fi
  SESSION_ID=""
  spawn_resume
  local deadline=$((SECONDS + 3))
  local saw_banner=0 saw_prompt=0
  while (( SECONDS < deadline )); do
    local pane
    pane="$(tmux_capture)"
    echo "$pane" | grep -q 'type a message' && saw_banner=1
    echo "$pane" | grep -q 'par>' && saw_prompt=1
    (( saw_banner && saw_prompt )) && break
    sleep 0.2
  done
  (( saw_banner )) || fail "banner not visible within 3s of --resume"
  (( saw_prompt )) || fail "prompt not visible within 3s of --resume"
  tmux_kill
}

test_resume_session_turn_count() {
  setup_home; trap teardown_home EXIT
  tmux_spawn
  tmux_wait_for 'par>' 8
  tmux_send '/help'
  tmux_wait_for '/quit' 5
  tmux send-keys -t "$SESSION_ID" C-d
  sleep 1
  SESSION_ID=""
  spawn_resume
  tmux_wait_for 'par>' 8
  tmux_send '/session'
  tmux_wait_for 'Turns:' 5
  tmux_assert_contains 'Turns:'
  tmux_kill
}

test_case "--resume shows banner+prompt within 3s"   test_resume_banner_within_3s
test_case "--resume /session shows turn history"     test_resume_session_turn_count
run_tests "$@"
