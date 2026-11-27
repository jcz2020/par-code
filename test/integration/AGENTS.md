# test/integration/ — bash/tmux e2e harness

**Score 9** — 19 files (13 `*_test.sh`, `run.sh`, `README.md`, 3 shared files), 3 subdirs, ~1.7k LOC. Earned its file: distinct domain (bespoke harness sharing zero code with the Alcotest suite).

`run.sh` (34 LOC) cds to the project root, discovers `cli/*_test.sh` + `repl/*_test.sh` via `find | sort`, runs each with `bash`, prints `Files: N passed, M failed`, exits non-zero on any failure. No LLM and no external network: CLI tests exec the built binary; REPL tests point the dummy config at the dead endpoint `http://127.0.0.1:9`. The one exception is a loopback-only fault-injection server (`lib/silent_provider.py`), which binds `127.0.0.1:0`, writes its port to argv[1], sends SSE headers, then goes silent forever (the Esc-cancels-stalled-turn test).

## WHERE TO LOOK

| Task | Path |
|---|---|
| Discovery + runner | `run.sh` |
| Shared env | `lib/config.sh` (25) — `PAR_BIN` (default `_build/default/bin/main.exe`, rebased onto the project root), `PROMPT_TIMEOUT=8`, `POLL_INTERVAL=0.1`, `CLI_TIMEOUT=10`, `write_dummy_config` |
| Shared API | `lib/harness.sh` (172) — `setup_home teardown_home par_cli tmux_spawn tmux_wait_for tmux_send tmux_capture assert_contains assert_not_contains assert_exit_zero fail pass test_case run_tests` |
| CLI subcommand e2e (no tmux) | `cli/` — `config_set_test.sh` (286 LOC, bulk round-trip + one case per field), `memory`, `plan`, `session`, `version_config` |
| REPL e2e (tmux) | `repl/` — `basics`, `cjk_input`, `goal_chain`, `max_mode`, `modes`, `resume`, `silent_provider`, `startup` |
| Fault injection | `lib/silent_provider.py` — std-lib only, port file handshake, never writes a byte |

## CONVENTIONS

- Every `*_test.sh`: `#!/usr/bin/env bash` + `set -euo pipefail` + source `../lib/config.sh` then `../lib/harness.sh`. The two sourced libs DELIBERATELY omit `set -euo pipefail` (they are sourced, not executed).
- Every test function's first line: `setup_home; trap teardown_home EXIT`. `setup_home` makes a fresh `mktemp -d` HOME, exports `PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1`, writes a dummy `~/.par/config.json` (key literally `test-key-fake-not-real`).
- REPL tests need a real tty: `tmux new-session -d -x 200 -y 50`, `TERM=screen-256color`. Missing tmux → print `SKIP:` and exit 0 (skip = pass).
- `assert_contains` reads stdin into a TEMP FILE instead of `echo | grep -q` — nested pipes intermittently truncated child output (the old config_set flake).
- `test_case "<name>" <func>` appends to parallel name/func arrays; `run_tests "$@"` runs only names matching argv[1] as an ERE (`bash cli/memory_test.sh prune`). Each case runs in a subshell.
- `PAR_BIN=/usr/local/bin/par bash run.sh` tests an installed binary instead of `_build`.
- Empty discovery is a soft-pass: `run.sh` prints "No integration test files found." and exits 0.
- Integration tests need `dune build` first (they exec the binary directly); tmux is optional for REPL files.

## ANTI-PATTERNS

- NEVER `sleep` as a readiness signal — use `tmux_wait_for <pattern> [timeout]`. Actual offenders: `repl/cjk_input_test.sh` (10 raw sleeps), `basics_test.sh` (4), `resume_test.sh` (3); treat them as the suite's flake risk and do not add more.
- NEVER `echo | grep -q` in assertions — use the temp-file `assert_contains`.
- NEVER point a test at a live provider — dead endpoint, dummy config, or the loopback fault-injection server only.
- NEVER run a REPL test without `setup_home` + trap (leaks a temp HOME and a tmux session).
- plan/session tests `cd` into a temp project (with `git init`) — never the repo's real `.par/`.
- `setup_home` exports `PAR_NO_UPDATE_CHECK=1 PAR_NO_AUTO_EXTRACT=1 PAR_NO_CHECKPOINT=1`; a test that skips `setup_home` will hit the real `~/.par`.
