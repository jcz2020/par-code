# Integration Tests

tmux-based end-to-end tests for par-code's public CLI surface.

## Quick start

```sh
cd /root/dev/PAR-CODE
eval $(opam env) && dune build
bash test/integration/run.sh
```

## What it tests

| File | Surface | Bug caught |
|------|---------|------------|
| `cli/version_config_test.sh` | `par --version`, `par config show` | — |
| `cli/config_set_test.sh` | `par config set` all 20 fields | P1 #5: "Unknown config field" |
| `cli/memory_test.sh` | `par memory` CRUD + search + prune | v0.5.6 prune --dry-run regression |
| `cli/plan_test.sh` | `par plan` list/show/prune | — |
| `cli/session_test.sh` | `par session` list/show/fork | P0 #2: empty session list |
| `repl/basics_test.sh` | `/help` `/session` `/cost` `/quit` | — |
| `repl/modes_test.sh` | `/plan` `/build` prompt switch | P0 #1: plan mode surface |
| `repl/startup_test.sh` | PAR_NO_UPDATE_CHECK silence | P0 #3: version notice always fires |

## Architecture

- **CLI tests**: plain `$PAR_BIN <args>` exec + stdout grep. No tmux. ~50ms each.
- **REPL tests**: tmux spawn (200x50, TERM=screen-256color) + send-keys + capture-pane. Real tty.
- **Isolation**: each test gets a fresh temp HOME with dummy config + `PAR_NO_UPDATE_CHECK=1`.
- **No LLM needed**: all tests exercise non-LLM code paths (CLI subcommands + slash commands).

## Harness API

See `lib/harness.sh` for the full API. Key functions:
- `setup_home` / `teardown_home` — isolation
- `par_cli <args>` — one-shot exec
- `tmux_spawn` / `tmux_send` / `tmux_wait_for` / `tmux_assert_contains` — REPL control
- `assert_contains` / `assert_not_contains` — stdout assertions
- `test_case` / `run_tests` — registration + runner

## CI

GitHub Actions runs `bash test/integration/run.sh` after `dune runtest`. Requires tmux
(`apt-get install tmux` on Linux, pre-installed on macOS).
