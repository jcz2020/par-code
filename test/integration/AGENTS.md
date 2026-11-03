# test/integration/ — bash/tmux e2e harness

**Score 12** — 16 files (15 bash + README), 4 subdirs. Earned its file: distinct domain (bespoke harness sharing zero code with the Alcotest suite).

`run.sh` (34 LOC) cds to the project root, discovers `cli/*_test.sh` + `repl/*_test.sh` via `find | sort`, runs each with `bash`, prints a per-file tally, exits non-zero on any failure. No LLM, no network: CLI tests exec the built binary; REPL tests point the dummy config at the dead endpoint `http://127.0.0.1:9`.

## WHERE TO LOOK

| Task | Path |
|---|---|
| Discovery + runner | `run.sh` |
| Shared env | `lib/config.sh` — `PAR_BIN` (default `_build/default/bin/main.exe`), `PROMPT_TIMEOUT=8`, `POLL_INTERVAL=0.1`, `CLI_TIMEOUT=10`, `write_dummy_config` |
| Shared API | `lib/harness.sh` (172) — `setup_home teardown_home par_cli tmux_spawn tmux_wait_for tmux_send tmux_capture assert_contains assert_not_contains assert_exit_zero fail pass test_case run_tests` |
| CLI subcommand e2e (no tmux) | `cli/` — `config_set_test.sh` (286 LOC, one case per config field), `memory`, `plan`, `session`, `version_config` |
| REPL e2e (tmux) | `repl/` — `basics`, `cjk_input`, `goal_chain`, `max_mode`, `modes`, `resume`, `startup` |

## CONVENTIONS

- Every `*_test.sh`: `#!/usr/bin/env bash` + `set -euo pipefail` + source `../lib/config.sh` then `../lib/harness.sh`. The two sourced libs DELIBERATELY omit `set -euo pipefail` (they are sourced, not executed).
- Every test function's first line: `setup_home; trap teardown_home EXIT`. `setup_home` makes a fresh `mktemp -d` HOME, exports `PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1`, writes a dummy `~/.par/config.json` (key literally `test-key-fake-not-real`).
- REPL tests need a real tty: `tmux new-session -d -x 200 -y 50`, `TERM=screen-256color`. Missing tmux → print `SKIP:` and exit 0 (skip = pass).
- `assert_contains` reads stdin into a TEMP FILE instead of `echo | grep -q` — nested pipes intermittently truncated child output (the old config_set flake).
- `run_tests "$@"` forwards argv: the first arg is a name-regex filter (`bash cli/memory_test.sh prune`).
- `PAR_BIN=/usr/local/bin/par bash run.sh` tests an installed binary instead of `_build`.
- Empty discovery is a soft-pass: `run.sh` prints "No integration test files found." and exits 0.

## ANTI-PATTERNS

- NEVER `sleep` as a readiness signal — use `tmux_wait_for <pattern> [timeout]`. Known offender: `repl/cjk_input_test.sh` (10 raw sleeps) is the main flake risk in the suite.
- NEVER `echo | grep -q` in assertions — use the temp-file `assert_contains`.
- NEVER point a test at a live provider — dead endpoint or dummy config only.
- NEVER run a REPL test without `setup_home` + trap (leaks a temp HOME and a tmux session).
- plan/session tests `cd` into a temp project (with `git init`) — never the repo's real `.par/`.
