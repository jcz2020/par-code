#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/config.sh"
source "$(dirname "$0")/../lib/harness.sh"

if [[ "$PAR_BIN" != /* ]]; then
  PAR_BIN="$PROJECT_ROOT/$PAR_BIN"
fi

# Helper: set up an isolated project dir with a git repo.
# Plan commands resolve .par/plans/ from the current directory, so we must
# cd into a directory that has the plans folder.
setup_project() {
  setup_home; trap teardown_home EXIT
  mkdir -p "$TEST_HOME/project"
  cd "$TEST_HOME/project"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  touch .gitkeep && git add . && git commit -q -m "init"
}

# ── Test 1: plan list with no plans ─────────────────────────────────────

test_plan_list_empty() {
  setup_project
  mkdir -p .par/plans
  par_cli plan list 2>&1 | assert_contains 'no plans'
}

# ── Test 2: plan list shows a created plan ──────────────────────────────

test_plan_list_shows_plan() {
  setup_project
  mkdir -p .par/plans
  echo "# My Plan" > .par/plans/test-plan.md
  par_cli plan list 2>&1 | assert_contains 'test-plan'
}

# ── Test 3: plan show displays plan content ─────────────────────────────

test_plan_show_content() {
  setup_project
  mkdir -p .par/plans
  echo "# Test Plan" > .par/plans/test-plan.md
  par_cli plan show test-plan 2>&1 | assert_contains 'Test Plan'
}

# ── Test 4: plan show works with .md extension ──────────────────────────

test_plan_show_with_md_extension() {
  setup_project
  mkdir -p .par/plans
  echo "# Another Plan" > .par/plans/another-plan.md
  par_cli plan show another-plan.md 2>&1 | assert_contains 'Another Plan'
}

# ── Test 5: plan show nonexistent exits non-zero ────────────────────────

test_plan_show_nonexistent() {
  setup_project
  mkdir -p .par/plans
  if par_cli plan show nonexistent >/dev/null 2>&1; then
    fail "expected non-zero exit for nonexistent plan"
  fi
}

# ── Test 6: plan prune removes old files ────────────────────────────────

test_plan_prune_removes_old() {
  setup_project
  mkdir -p .par/plans
  # Old plan (timestamp far in the past — well beyond the 30-day default)
  echo "# Old Plan" > .par/plans/2020-01-01T00-00-00Z.md
  # Recent plan (now)
  local recent_ts
  recent_ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  echo "# Recent Plan" > ".par/plans/${recent_ts}.md"

  par_cli plan prune 2>&1 | assert_contains 'pruned'

  # Old file should be deleted
  if [ -f .par/plans/2020-01-01T00-00-00Z.md ]; then
    fail "old plan file should have been pruned"
  fi
  # Recent file should remain
  if [ ! -f ".par/plans/${recent_ts}.md" ]; then
    fail "recent plan file should not have been pruned"
  fi
}

# ── Test 7: plan prune with no old files says nothing to prune ──────────

test_plan_prune_nothing_to_prune() {
  setup_project
  mkdir -p .par/plans
  # Only a recent plan
  local recent_ts
  recent_ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  echo "# Recent Plan" > ".par/plans/${recent_ts}.md"

  par_cli plan prune 2>&1 | assert_contains 'no plans to prune'
}

# ── Register & run ──────────────────────────────────────────────────────

test_case "plan list empty"                 test_plan_list_empty
test_case "plan list shows plan"            test_plan_list_shows_plan
test_case "plan show content"               test_plan_show_content
test_case "plan show with .md extension"    test_plan_show_with_md_extension
test_case "plan show nonexistent"           test_plan_show_nonexistent
test_case "plan prune removes old"          test_plan_prune_removes_old
test_case "plan prune nothing to prune"     test_plan_prune_nothing_to_prune
run_tests "$@"
