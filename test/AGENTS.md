# test/ — Alcotest unit suite

**Score 12** — 37 files (35 `test_*.ml` + `dune` + this file), ~8.3k LOC OCaml, 595 `Alcotest.test_case`. Earned its file: distinct domain (unit-harness conventions); the `integration/` subtree has its own AGENTS.md.

One executable per lib module: `test_par_code_<feature>.ml` mirrors `lib/par_code_<feature>.ml`, plus cross-cutting suites (`test_par_code.ml`, `_payload_dump`, `_repl_plan_mode`, `_ui_prompt`). 595 cases total, ~987 `Alcotest.(check …)` calls. Tests link the whole `par_code` library, so every lib module is importable.

## WHERE TO LOOK

| Task | File |
|---|---|
| Release bump: hardcoded version assertion | `test_par_code.ml:2` — expected string `0.15.8`; the check NAME still says `0.15.7`, so bump both on release |
| v0.8.2 P2 regressions | `test_par_code_doom_loop.ml` (action-streak exemptions), `test_par_code_ui.ml` (table/tool-boundary), `test_par_code_repl.ml` (metric helpers), `test_par_code_session.ml` (migration stderr) |
| Skill discovery (v0.9.0 W0/W1) | `test_par_code_skills.ml` — temp dirs, frontmatter parse, project-over-user precedence, body read |
| Skill distillation (v0.9.0 W2) | `test_par_code_distill.ml` — proposal parse, id/size validation, atomic write + force backup |
| Largest suites | `test_par_code_config.ml` (724 LOC, 72 cases), `test_par_code_plan_tools.ml` (580, 40), `test_par_code_ui.ml` (537, 54) |
| Slowest (real SQLite + FTS5/vec0 in temp dirs) | `test_par_code_memory.ml` (500), `test_par_code_checkpoint.ml` (455) |
| Mock runtime (no LLM) | `test_par_code_setup.ml` — `Eio_mock.Backend.run`, `:memory:` persistence, consumes the production `Par_code_setup.planner_tool_names` |
| TUI / input regressions | `test_par_code_screen.ml` (CJK wrap, scroll, split mouse tail never becomes typed text), `_selection.ml` (span algebra), `_ui_prompt.ml` |
| Newer plumbing suites | `_edit_preview.ml` (diff/approval body), `_tool_summary.ml`, `_flow.ml`, `_permissions.ml`, `_payload_dump.ml` (uncreatable dump dir must never raise) |

## CONVENTIONS

- `test/dune` lists all 35 executables in ONE explicit `(tests (names …))` stanza — a new file requires editing `dune`; nothing is auto-discovered. Libraries are fixed to `par_code alcotest eio.mock eio_main`.
- No `.mli`, no shared helper module: the temp-dir idiom is copy-pasted per file (`Filename.temp_file` → `Sys.remove` → `Unix.mkdir` → body wrapped in `Fun.protect ~finally:(fun () -> Sys.chdir old)`).
- `Sys.chdir` into a temp dir IS the isolation mechanism for workspace-scoped code (`.par/`, `.par/plans/`, `.par/approvals.json`).
- Suite labels are inconsistent by design (`par_code_*` majority, but also `par`, `payload`, `par_memory`, `par_checkpoint`, `par_git_tools`, `par_plan_tools`, `par_session`, `par_setup`, `par_screen`, `par_selection`, `par_progress`, `par_tool_summary`, `par_edit_preview`, `par_payload_dump`) — do not rename piecemeal.
- Assertion style: fully-qualified `Alcotest.(check …)` everywhere except `test_par_code_approvals.ml`, which uses bare `test_case`.
- `test_par_code_approvals.ml` and `test_par_code_session.ml` are cwd-sensitive (`Par.Workspace.of_cwd`, `git rev-parse`) — run from the project root.
- No LLM, no network: failure paths use the dead endpoint `http://127.0.0.1:9`; CLI/e2e coverage lives in `integration/` (`bash test/integration/run.sh`, needs `dune build` first).
- `test_par_code_payload_dump.ml` points `HOME` at a regular file on purpose; `test_par_code_screen.ml` encodes CJK widths and mouse-tail splitting.
- UI exact-output tests use a temp-file backend (`with_backend_output`, `NO_COLOR=1`) and assert the flattened string; no tty.

## ANTI-PATTERNS

- Never delete or weaken a failing assertion to go green — one failing case fails the exe and therefore `dune runtest`.
- Never mutate the repo's real `.par/` state — always the temp-dir chdir first.
- Forgetting the version-assertion bump on release breaks `dune runtest` — label AND expected value live in `test_par_code.ml:2` and must match `dune-project`.
- A new suite file without its name in `test/dune` never runs (no warning).
