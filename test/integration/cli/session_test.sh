#!/usr/bin/env bash
# Integration tests for `par session list` and `par session show`.
#
# P0 #2 regression: `par session list` returned empty because conversation
# scope was never written. The fix (v0.5.5) threads ~scope through all
# save_conversation calls. The migration (v0.5.6) backfills empty-scope rows.
#
# These tests seed the DB directly with sqlite3 since no LLM is available.
# Tables are created by running `par session list` once (triggers Sqlite_persistence.init_schema).

set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

# The scope used by par session list = resolve_project_id()
# = git rev-parse --show-toplevel (falls back to cwd if not in a git repo)
SCOPE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Fixed session UUID (36 chars) for deterministic tests
SID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
SID_SHORT="${SID:0:8}"   # a1b2c3d4

DB=""

# Bootstrap the PAR DB schema by running par session list once.
# Sets $DB to the DB path for subsequent sqlite3 calls.
_ensure_db() {
  par_cli session list >/dev/null 2>&1 || true
  DB="$HOME/.par/par.db"
  [ -f "$DB" ] || fail "DB not created at $DB"
}

# Seed a conversation + event pair.
# Args: session_id [scope]
#   scope defaults to $SCOPE; pass "" for empty scope (legacy migration test).
_seed_session() {
  local sid="$1"
  local scope="${2-$SCOPE}"
  local now
  now="$(date +%s)"
  # conversations table: session_id, messages_json, metadata_json, updated_at, turn_count, scope
  sqlite3 "$DB" "INSERT OR IGNORE INTO conversations \
    (session_id, messages_json, metadata_json, updated_at, turn_count, scope) \
    VALUES ('$sid', '[]', '{}', $now, 0, '$scope')"
  # events table: id, task_id, payload, timestamp, idempotency_key, session_id
  sqlite3 "$DB" "INSERT OR IGNORE INTO events \
    (id, task_id, payload, timestamp, idempotency_key, session_id) \
    VALUES ('evt-$sid', 'task-$sid', '{}', $now, 'idem-$sid', '$sid')"
}

# Seed a checkpoint row (for legacy migration test).
# Args: session_id project_id
_seed_checkpoint() {
  local sid="$1"
  local project_id="$2"
  local now
  now="$(date +%s)"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS checkpoints (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL, project_id TEXT NOT NULL,
    turn_number INTEGER NOT NULL, checkpoint_json TEXT NOT NULL, created_at REAL NOT NULL)"
  sqlite3 "$DB" "INSERT OR IGNORE INTO checkpoints \
    (id, session_id, project_id, turn_number, checkpoint_json, created_at) \
    VALUES ('ckpt-$sid', '$sid', '$project_id', 1, '{\"task\":\"test\"}', $now)"
}

# ── Test 1: empty DB ───────────────────────────────────────────────────
test_session_list_empty() {
  setup_home; trap teardown_home EXIT
  par_cli session list 2>&1 | assert_contains 'no sessions'
}

# ── Test 2: P0 #2 regression — scope-filtered listing ──────────────────
test_session_list_with_scope() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  _seed_session "$SID"
  par_cli session list 2>&1 | assert_contains "$SID_SHORT"
}

# ── Test 3: wrong scope → hidden ───────────────────────────────────────
test_session_list_wrong_scope_hidden() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  _seed_session "$SID" "/some/other/project"
  par_cli session list 2>&1 | assert_not_contains "$SID_SHORT"
}

# ── Test 4: session show by full ID ────────────────────────────────────
test_session_show_full_id() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  _seed_session "$SID"
  par_cli session show "$SID" 2>&1 | assert_contains "$SID"
}

# ── Test 5: session show by prefix ─────────────────────────────────────
test_session_show_prefix() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  _seed_session "$SID"
  par_cli session show "$SID_SHORT" 2>&1 | assert_contains "$SID"
}

# ── Test 6: session show with bad ID → non-zero exit ──────────────────
test_session_show_bad_id() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  local rc=0
  par_cli session show zzzz 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected non-zero exit for bad session ID"
}

# ── Test 7: legacy migration — empty scope + checkpoint backfill ───────
test_session_list_legacy_migration() {
  setup_home; trap teardown_home EXIT
  _ensure_db
  # Seed with empty scope (pre-v0.5.5 state)
  _seed_session "$SID" ""
  # Seed a checkpoint with the correct project_id
  _seed_checkpoint "$SID" "$SCOPE"
  # par session list triggers migrate_legacy_scopes → backfills scope from checkpoint
  par_cli session list 2>&1 | assert_contains "$SID_SHORT"
}

# ── Registration ────────────────────────────────────────────────────────
test_case "session list: empty DB"                       test_session_list_empty
test_case "session list: scope-filtered (P0 #2)"         test_session_list_with_scope
test_case "session list: wrong scope hidden"             test_session_list_wrong_scope_hidden
test_case "session show: full ID"                        test_session_show_full_id
test_case "session show: prefix resolution"              test_session_show_prefix
test_case "session show: bad ID exits non-zero"          test_session_show_bad_id
test_case "session list: legacy scope migration"         test_session_list_legacy_migration
run_tests "$@"
