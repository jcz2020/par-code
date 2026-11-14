# test/ — Alcotest unit suite

**Score 8** — 44 files, 7.4k LOC (28 Alcotest exe + `test/dune`, plus the `integration/` subtree, which has its own AGENTS.md). Earned its file: distinct domain (unit-harness conventions).

One executable per lib module: `test_par_code_<feature>.ml` mirrors `lib/par_code_<feature>.ml`, plus `test_par_code.ml` (cross-cutting: version, config paths, agent id, JSON round-trip), `test_par_code_payload_dump.ml`, `test_par_code_repl_plan_mode.ml`, `test_par_code_ui_prompt.ml`. ~473 cases.

## WHERE TO LOOK

| Task | File |
|---|---|
| Release bump: hardcoded version assertion | `test_par_code.ml:2` — asserts `Par_code_version.version = "0.8.2"` |
| v0.8.2 P2 regressions | `test_par_code_doom_loop.ml` (action-streak exemptions), `test_par_code_ui.ml` (table/tool-boundary), `test_par_code_repl.ml` (metric helpers), `test_par_code_session.ml` (migration stderr) |
| Skill discovery (v0.9.0 W0/W1) | `test_par_code_skills.ml` — temp dirs, frontmatter parse, project-over-user precedence, body read |
| Skill distillation (v0.9.0 W2) | `test_par_code_distill.ml` — proposal parse, id/size validation, atomic write + force backup |
| Largest suites | `test_par_code_config.ml` (699 LOC, 92 checks), `test_par_code_plan_tools.ml` (579) |
| Slowest (real SQLite + FTS5/vec0 in temp dirs) | `test_par_code_memory.ml` (500), `test_par_code_checkpoint.ml` (455) |
| Mock runtime (no LLM) | `test_par_code_setup.ml` — `Eio_mock.Backend.run`, `:memory:` persistence, consumes the production `Par_code_setup.planner_tool_names` |

## CONVENTIONS

- `test/dune` lists all 28 executables in ONE explicit `(tests (names …))` stanza — a new file requires editing `dune`; nothing is auto-discovered.
- No `.mli`, no shared helper module: the temp-dir idiom is copy-pasted per file (`Filename.temp_file` → `Sys.remove` → `Unix.mkdir` → body wrapped in `Fun.protect ~finally:(fun () -> Sys.chdir old)`).
- `Sys.chdir` into a temp dir IS the isolation mechanism for workspace-scoped code (`.par/`, `.par/plans/`, `.par/approvals.json`).
- Suite names are inconsistent (`par_code_<mod>` mostly, but also `par`, `Approvals`, `par_memory`, `payload`…) — do not rename piecemeal.
- Assertion style: fully-qualified `Alcotest.(check …)` in 24 files; `test_par_code_approvals.ml` alone uses bare `test_case`.
- `test_par_code_approvals.ml` and `test_par_code_session.ml` are cwd-sensitive (`Par.Workspace.of_cwd`, `git rev-parse`) — run from the project root.
- No LLM, no network: failure paths use the dead endpoint `http://127.0.0.1:9` (instant connection refused).
- UI exact-output tests use a temp-file backend (`with_backend_output`, `NO_COLOR=1`) and assert the flattened string; no tty.

## ANTI-PATTERNS

- Never delete or weaken a failing assertion to go green — `fail` exits 1 and `run_tests` propagates non-zero.
- Never mutate the repo's real `.par/` state — always the temp-dir chdir first.
- Forgetting the version-assertion bump on release breaks `dune runtest`.
