# CHANGES

## v0.7.0 — Goal-driven autonomy

> **Status**: In development. Core feature implemented (judge-supervised mode);
> full autonomous chaining deferred to v0.7.1.

### Added — Goal-driven autonomy

- **`/goal <description>` command** — sets an objective for the agent. The agent
  works toward the goal with an independent judge model evaluating progress.
  Use `/goal` (no args) to see status, `/goal clear` to abort.
- **Independent judge model** — a second LLM with fresh context evaluates
  whether the goal is truly met, preventing the agent from self-deceiving.
  Zero-config: uses the main model in a separate agent context by default.
  Configure via `judge_model`, `judge_provider`, `judge_api_key`,
  `judge_api_base` for a separate model.
- **`goal_done` agent tool** — the agent signals completion via this tool,
  triggering immediate judge verification.
- **Doom-loop detection** — hash-based tool-call repetition detector (threshold
  3, configurable via `doom_loop_threshold`). Escalation: nudge → force judge →
  abort.
- **Goal state persistence** — active goal saved to `.par/goals/current.json`,
  survives crashes.
- **`--goal` CLI flag** — start the REPL with a pre-set goal.

### Added — Config fields (8 new)

- `judge_enabled` (bool, default true)
- `judge_model` (string option, default inherit main model)
- `judge_provider`, `judge_api_key`, `judge_api_base` (string option, default inherit)
- `goal_verify_command` (string option, deterministic check before judge)
- `goal_max_steps` (int, default 50)
- `doom_loop_threshold` (int, default 3)

### Changed — PAR SDK consumption

- Bumped PAR SDK dependency from `>= 0.8.3` to `>= 0.8.6`.
- Consumed PAR v0.8.6 streaming error fix: non-2xx streaming responses now
  surface real error categories (rate_limited, auth failure, etc.) instead of
  silent empty responses. Empty-text fallback now shows finish_reason.

### Changed — Config

- `Par_code_config.save` now uses atomic write (temp-file + rename) to prevent
  readers from seeing partially-truncated files.

### Known Limitations

- Judge-supervised mode evaluates after each user-triggered turn (every 3 steps
  or when `goal_done` is called). Full autonomous chaining (invokes without
  user input) is deferred to v0.7.1.
- Doom-loop detection is mechanical (hash-based) only — no filesystem-mutation
  tracking or semantic similarity (v0.8.0 candidates).

## v0.6.2 — UTF-8 REPL input (linenoise)

> **Status**: Shipped. Patch release — fixes CJK input garbling + Ctrl+C
> regressions surfaced by the linenoise migration. linenoise's bundled C
> confirmed to build cleanly in AlmaLinux 8 Docker + macOS release CI.

### Fixed

- **CJK (Chinese/Japanese/Korean) backspace garbled the REPL prompt**: the
  kernel tty line discipline erases wide characters one byte/column at a
  time even with `IUTF8` set, so typing Chinese and pressing backspace left
  "ghost" characters on screen and eventually scrambled the display. This is
  cross-platform (Linux + macOS), not a macOS-only issue. par-code now uses
  [linenoise](https://github.com/ocaml-community/ocaml-linenoise) for input
  editing (raw mode, UTF-8/wcwidth-aware backspace). One backspace deletes one
  codepoint cleanly, no residue.
- **Ctrl+C during REPL input crashed** (`uncaught exception Stdlib.Sys.Break`):
  linenoise raises `Sys.Break` on Ctrl+C (not `None`); the REPL loop now
  catches it and routes to the same clean save + "Bye!" exit as EOF.
- **Ctrl+C during config wizard / upgrade-confirm crashed** (same `Sys.Break`,
  18 prompt sites via `read_line`). The catch must live in `read_line` — not
  at main's top level — because Cmdliner's `Cmd.eval` swallows uncaught term
  exceptions first. Mapping to `None` was rejected (would make the wizard
  continue + save with defaults). Fix: `read_line` catches `Sys.Break` →
  `exit 130` (SIGINT convention): wizard aborts without saving, upgrade
  confirm aborts without deleting.
- **Slash-command output (`/help`, `/session`, `/cost`) was swallowed after
  the linenoise migration**: linenoise writes the prompt directly to fd 1,
  bypassing OCaml's stdout buffer, so output rendered via `render` (which
  doesn't flush) — e.g. `render_help` — stayed buffered and never appeared.
  Fix: `flush stdout` before each `LNoise.linenoise` call (REPL loop +
  `read_line`). Caught by the tmux integration tests (3 failures), which now
  pass.

### Changed

- **New dependency: `linenoise` (ocaml-linenoise)**. Self-contained — bundled C
  source compiled via dune, no system library. Release Docker/macOS builds need
  no extra system packages beyond the opam dep (confirmed in v0.6.2 CI). Adds
  in-REPL line editing with up-arrow history (persisted at `~/.par/history`,
  capped at ~100 entries).
- **REPL prompt is now plain text** `(build) par> ` (was green-bold). linenoise
  sizes the prompt cursor with `strlen`, so ANSI escape codes would misposition
  it. The colored `render_prompt` is retained for tests/non-linenoise contexts.
- `Par_code_ui.read_line` (config wizard + upgrade prompts) migrated to
  linenoise too — all interactive line-input sites now UTF-8-aware. The
  `/dev/tty` bash y/n confirmation stays on `input_line` (ASCII-only, different
  channel).

## v0.6.1 — Install/upgrade fixes

> **Status**: Shipped. Patch release — no new features, fixes two dead-ends a
> macOS Intel user hit in install + upgrade.

### Fixed

- **install.sh stale-binary `Permission denied`**: the installer copied the
  built binary with a bare `cp` (no `-f`, no pre-clean). A stale
  `~/.par/bin/par` owned by another user (e.g. root, from a prior `sudo` run,
  or the `sudo curl … | bash` footgun where sudo applies only to curl, not
  bash) made `cp` fail with an unactionable "Permission denied". New
  `ensure_target_writable` guard runs before every binary write (both pre-built
  and source paths) and exits early with the exact fix:
  `sudo rm -f ~/.par/bin/par`. Source path also switched to `rm -f` + `cp -f`.
- **`par upgrade` dead-ended on no-prebuilt platforms**: `detect_platform`
  returned a hard `Error ("Unsupported platform: darwin/x86_64")` with no path
  forward, while `install.sh` treats the same platform as "compile from
  source". `perform_upgrade_core` now branches on `detect_platform`: `Error`
  fetches the matching release's `install.sh` and execs it with `--from-source`,
  streaming build progress to the terminal (5-20 min first build). Install and
  upgrade now agree on every platform; `detect_platform`'s `Error` flipped from
  user-facing hard failure to an internal source-fallback signal.
- **Temp-file hygiene in source-fallback**: the installer script was written to
  a pid-based name in `/tmp` via `open_out` (no `O_EXCL`) — a classic tmpfile
  symlink-race vector on shared multi-user systems. Switched to
  `Filename.temp_file` (random name + `O_CREAT|O_EXCL`). No behavioural change.

### Changed

- README Install section collapsed: removed a duplicated Linux x86_64 block and
  four identical `curl | bash` callouts; one command + one line now, pointing
  at the Platform support table for the per-platform matrix.

## v0.6.0 — Subagent delegation

> **Status**: Shipped.

The main agent can now delegate tasks to subagents via the `delegate` tool.

### Added

- **`delegate` tool**: spawn focused subagents for investigation or implementation.
  - `explore` type: read-only investigation (read/grep/find/ls/git/memory tools),
    max 15 iterations
  - `general` type: full capability (read/write/edit/bash/memory/git tools),
    max 25 iterations
  - Synchronous: main agent blocks while subagent runs, result returned as tool
    output
  - Isolated: `~save:false ~update_current:false` — subagent conversation never
    pollutes parent
  - Depth limit = 1: subagents cannot themselves delegate
  - Rendering: subagent tool events (including bash) shown with `[explore]`/
    `[general]` prefix; result preview truncated at 500 chars
  - Safety: cancellation token propagated; 300s timeout; bash confirmation hook
    inherited (runtime-global)

### Fixed

- **Plan mode completely non-functional** (critical): `find_last_assistant_text`
  returned the wrong assistant message due to recursive short-circuit logic.
  Every `/build` saved an empty plan file (1 byte `\n`). Plan content now
  correctly extracted from the last assistant message with non-empty text.
- **Plan not injected into build mode**: plan appendix previously referenced
  `read_file` (non-existent tool name — P0 #1 regression) and only gave a file
  path, not content. Now reads plan file and injects full content into the
  build agent's system prompt on the first build-mode turn.
- **Ctrl+C extraction crash**: SIGINT handler called `Runtime.invoke_generate`
  (extraction) with inconsistent Eio scheduler state, raising
  `Effect.Unhandled(Eio__core__Cancel.Get_context)`. Extraction now skipped on
  Ctrl+C; use `/quit` for clean extraction.

### Changed

- Main agent's default system prompt now includes `## Delegation` section with
  guidance on when to use `explore` vs `general` subagents.
- Integration test harness added: 68 tmux-based E2E tests covering CLI
  subcommands, REPL slash commands, and the v0.5.4 audit bug class.
- install.sh source compile fallback: auto-installs opam + OCaml on platforms
  without pre-built binaries (e.g., macOS Intel).

### Tests

271 unit tests + 68 integration tests. PAR SDK 0.8.3.

---

## v0.5.6 — Audit Wave 2–3 + UX polish

> **Status**: Shipped.

Resolves the remaining audit findings (P1 #5, #7; P2 #11–14) and completes
Wave 2 items now unblocked by PAR SDK 0.8.3 (`stream_options.include_usage`,
`Runtime.save_conversation ?scope`, `Think_tag_strip` middleware).

### Fixed

- **`par config set` limited to 1 field** (P1 #5): `update_field` only
  handled `default_mode`. Extended to all 20 settable config fields with
  type-aware parsing (string / optional string / float / int / bool /
  enum) and validation bounds (max_iterations > 0, checkpoint_interval
  >= 1, context_budget_tokens >= 1000). `system_prompt` excluded
  (multiline — set via wizard).
- **`install.sh` exits 0 on failure** (P1 #7): added `set -e` (was
  `set -u` only). Audited all commands; added `|| true` to 8
  intentional non-zero exit paths (grep pipelines, optional checksum
  fetches, trap cleanup). `set -o pipefail` intentionally omitted
  (POSIX-incompatible + breaks legitimate grep no-match returns).
- **Legacy NULL-scope conversations invisible** (P2 #14): ~40 existing
  conversations had `scope = ''` from before the v0.5.5 write-side fix.
  Added automatic migration in `par_code_session.list_sessions` —
  backfills from `checkpoints.project_id`. Idempotent.
- **`<think>` tag leak in checkpoints and plan files** (P1 #6):
  the middleware (v0.5.5) strips `<think>` from final LLM responses,
  but `parse_checkpoint_response` and `persist_plan_file` needed
  targeted strips for subagent responses with `~save:false`. Both now
  call `Par.Json_extract.strip_think_tags` before JSON extraction /
  file write.
- **`<think>` tag leak in streaming REPL output** (P1 #6):
  the middleware fires `on_after_llm` only (final response) — streaming
  chunks showed `<think>` live. Added a streaming state machine in
  `par_code_ui.strip_think_streaming` that buffers chunks, strips
  complete `<think>...</think>` blocks, detects unclosed opening tags,
  and holds back partial tag prefixes at chunk boundaries.

### Added

- **Source compilation fallback** in `install.sh`: when no pre-built binary
  exists for the user's platform (e.g., macOS Intel x86_64), the installer
  automatically detects this and compiles from source — installs opam +
  OCaml 5.x if missing, pins PAR SDK, builds par-code, installs binary.
  `--from-source` flag forces source compilation even when a pre-built
  binary is available. Supports macOS (Homebrew) and Linux (apt/dnf/pacman/apk).
- **`par memory prune --dry-run`** (P2 #11): preview the count of
  memories that would be pruned without deleting. Uses SELECT COUNT(*)
  with the same WHERE clause as `prune_stale`.
- **`par memory show/forget` prefix resolution** (P2 #12): both
  commands now resolve short UUID prefixes to full IDs, mirroring
  `par session show <prefix>`. Ambiguous prefix → error; unique prefix
  → resolved; no match → error.
- **`/session` output alignment** (P2 #13): Messages line merged into
  `render_session_info` vcat block with `%-10s` label padding. All 4
  lines (Agent/Session/Turns/Messages) now align consistently.
- **`/cost` token counts** (P1 #4): zero code change — PAR SDK 0.8.3
  now sends `stream_options.include_usage`, so token data flows to the
  existing `add_usage` accumulator. `/cost` now shows non-zero prompt /
  output / total tokens.

### Known Limitations

- **Legacy sessions without checkpoints**: the scope migration backfills
  from `checkpoints.project_id`. Sessions from before v0.4.0 (or short
  sessions where the checkpoint cycle never fired) have no checkpoint and
  remain with empty scope — they won't appear in `par session list` for
  any project. Use `par --resume <full-id>` if the session ID is known.
  The migration uses the latest checkpoint's project_id when multiple
  exist (deterministic).

### Tests

269 tests (up from 218), all passing. New coverage: config set (35),
memory prune dry-run + prefix (5), checkpoint think-strip (1),
session migration (2), UI streaming think-strip (8).

---

## v0.5.5 — Hotfix (audit findings)

> **Status**: Shipped.

Resolves 3 P0 release-blocker regressions and 3 P1 critical UX defects
identified in the [2026-08-05 comprehensive audit](docs/DECISIONS.md). Wave 1
fixes par-code internals; Wave 2 consumes PAR SDK 0.8.3 fixes (Runtime
`?scope` plumbing, `stream_options.include_usage`, `reasoning_content` +
`Think_tag_strip` middleware).

### Fixed

- **Plan Mode tool filter** (P0 #1): planner agent's tool allowlist used
  wrong names (`read_file`/`find_files`/`list_directory`) instead of the
  PAR SDK's actual tool names (`read`/`find`/`ls`). Planner could only
  `grep` — could not read files or list directories. README "What the
  planner can do" section updated to match.
- **Session scope write** (P0 #2): all 6 `Runtime.save_conversation`
  callsites in `par_code_repl.ml` (REPL + single-shot) now pass
  `~scope:(resolve_project_id ())`. Previously the write side never set
  scope, so `par session list` / `par -r` / `par --continue <prefix>`
  returned empty despite conversations existing in the DB. Also extends
  `par_code_session.list_sessions` to JOIN events with conversations
  (PAR SDK's `load_sessions` filters by `events.scope`, which is still
  unpopulated in our pipeline; retirement plan in
  `lib/par_code_session.ml:28`).
- **Startup version notice always fires** (P0 #3): GitHub `tag_name`
  returns `"v0.5.5"` (with `v` prefix) but `Par_code_version.version`
  returns `"0.5.5"` (no prefix). The string comparison was always
  unequal. Added `strip_v_prefix` helper in `bin/main.ml` and applied at
  both callsites (startup notice + `par upgrade --check` exit code).
- **REPL prompt invisible until first response** (P1 #8):
  `par_code_ui.render_prompt` didn't flush stdout. On a line-buffered
  pty the prompt stayed buffered until the next `\n` was written, so
  users saw a blank line where `(build) par>` should be. Added
  `flush backend.out` at the end of `render_prompt`.
- **`<think>` tag contamination of conversation history** (P1 #6):
  Reasoning models that embed chain-of-thought inline in `text` (rather
  than via the new `reasoning_content` field added in PAR SDK 0.8.3)
  polluted plan files and checkpoints. Registered `think_tag_strip`
  middleware at all 4 `Runtime.make_agent` callsites. The middleware
  strips `<think>...</think>` and `<reasoning>...</reasoning>` from
  `llm_response.text` via `Par.Json_extract.strip_think_tags` before
  the message enters conversation history. Plan files and checkpoint
  fields are now clean.
- **PAR SDK minimum version bumped** (par `(>= 0.8.1)` → `(>= 0.8.3)`):
  required for `Runtime.save_conversation ?scope`, streaming usage, and
  `reasoning_content`/`Reasoning_delta` types.

### Added

- **`Reasoning_delta` chunk handling** in `par_code_ui.render_llm_chunk`:
  the new streaming chunk variant (introduced by PAR SDK 0.8.3 for
  reasoning-model chain-of-thought deltas) is now explicitly handled —
  hidden from user-visible output. Future work: optional collapsible
  display.
- **`reasoning_content` field propagation** across all `Types.message`
  record construction sites in `lib/` and `test/` (5 sites) for PAR SDK
  0.8.3 API compatibility.

### Known Limitations

- **Streaming display still leaks `<think>` for some models**: the
  middleware runs `on_after_llm` (after streaming completes), so live
  chunks still hit the user's terminal. Conversation history is clean
  (verified), but the live REPL display still shows CoT for models that
  inline `<think>` in `Text_delta` chunks (e.g., some OpenAI-compatible
  reasoning models). Fix requires a streaming-aware buffer-and-strip
  state machine in `par_code_ui.flush_markdown`. Deferred to a future
  release.
- **Legacy conversations (pre-v0.5.5) remain invisible** in
  `par session list`. They have `scope = ''` from before the write-side
  fix. Future migration: backfill `scope` from `checkpoints.project_id`,
  or treat empty scope as "show in all projects" with a UI marker.
- **`par_code_session.list_sessions` uses a custom SQL JOIN** instead
  of `Sqlite_persistence.load_sessions`. The PAR SDK function filters
  by `events.scope`, which our pipeline does not populate. When PAR SDK
  plumbs scope through the event bus, this can revert to the simpler
  SDK call. (Retirement plan documented inline at `lib/par_code_session.ml:28`.)

### Process change

Audit also surfaced that 218/218 unit tests passed but encoded the same
wrong assumptions as the implementations (e.g., `test_par_code_setup.ml`
asserted the same wrong tool names that `par_code_setup.ml` filtered on).
Future releases need an integration-test harness (tmux/expect-based) that
asserts on observed behavior of advertised features. Tracked in
`.sisyphus/plans/v0.5.5.md` Wave 4.

## v0.5.4 — Session management

> **Status**: Shipped.

Browse, inspect, fork, and resume saved sessions — session resume is finally
practical without copy-pasting full UUIDs.

### Added
- **`par session list`**: Table of sessions for the current project — ID
  prefix, auto-generated title (first user message), last activity, event
  count. Bare `par session` defaults to list.
- **`par session show <id>`**: Display session details. Accepts full UUID or
  unique prefix.
- **`par session fork <id>`**: Copy a session's conversation to a new session
  ID. Original session is untouched. Forked session can be resumed with
  `par --continue <new-id>`.
- **`--continue` partial ID matching**: `par --continue abc12345` now resolves
  to the full UUID if the prefix is unique. No more copy-pasting 36-char UUIDs.
- **Session scope filtering**: `par session list` only shows sessions for the
  current project (via `resolve_project_id`).
- **New module**: `lib/par_code_session.ml/mli` — session listing, loading,
  partial ID resolution, title extraction, fork.
- **Tests**: 7 new session tests (format_age + resolve_id).

### Changed
- `is_chat_mode` in `main.ml` recognizes `"session"` subcommand.
- `load_initial_conv` in `par_code_repl.ml` uses `Par_code_session.resolve_id`
  for prefix matching before loading.

## v0.5.3 — REPL rendering fixes

> **Status**: Shipped.

Fixes three issues found through real-world MiniMax provider testing.

### Fixed
- **Tool indicator triple-rendering**: Removed redundant `tool_call_hook` that
  printed `  [tool_name]` alongside the streaming `Tool_call_start` indicator
  and the event `Tool_completed` indicator. Now only two indicators per tool
  call (start + complete).
- **Bash confirmation stdin contention**: Bash confirmation prompts now read
  from `/dev/tty` instead of `stdin`, preventing them from swallowing user
  input intended for the REPL loop. Previously, if the user typed during a
  long-running bash command, those keystrokes were consumed by the bash
  confirmation instead of reaching the REPL.
- **Silent empty responses**: When streaming delivers no text AND `resp.text`
  is empty/None, a diagnostic warning is now printed instead of silently
  showing nothing.

## v0.5.2 — Streaming fallback fix (critical)

> **Status**: Shipped.

Fixes a critical bug where `par` produced no output when the LLM provider's
streaming didn't deliver parseable chunks (common with some OpenAI-compatible
providers). The REPL relied entirely on the streaming callback to display
responses — if streaming failed silently, the response text was discarded.

### Fixed
- **REPL + `par ask`**: After invoke returns Ok, if no text was streamed
  (streaming callback received zero `Text_delta` chunks), the response text
  from `resp.text` is now printed as a fallback. This ensures the user always
  sees the LLM response even when streaming is broken.
- Both `run` (REPL loop) and `run_single_shot` (`par ask`) paths fixed.

## v0.5.1 — Plan CLI + Git Tools

> **Status**: Shipped. 211 tests passing across 12 suites.

Collects deferred items from v0.5.0 §17: plan file management CLI and
read-only git tools for the planner agent.

### Added
- **`par plan list`**: List saved plan files from `.par/plans/` with
  filename, size, and parsed creation timestamp. `--limit`/`-n` flag
  controls max results (default 50). `par plan` (bare) defaults to list.
- **`par plan show <file>`**: Display a saved plan file. Auto-appends
  `.md` if omitted.
- **`par plan prune --older-than <days>`**: Delete plan files older than
  N days (default 30). Parses timestamp from filename (not mtime).
- **`git_status` tool**: Read-only tool for the planner agent. Returns
  current branch and working tree file statuses as structured JSON.
  Uses `Eio.Process` to spawn `git status --porcelain=v1 -b`.
- **`git_log` tool**: Read-only tool for the planner agent. Returns
  recent commit history (hash, message, date) as structured JSON.
  Accepts optional `count` parameter (default 10). Uses `Eio.Process`.
- **`lib/par_code_git_tools.ml` + `.mli`**: New module for git tool
  bindings. `tools ~process_mgr` returns `git_status` and `git_log`
  `Types.tool_binding` list.
- **`lib/par_code_plan_tools.mli`**: New public API file exporting
  `plan_entry` type, `list_plans`, `show_plan`, `prune_plans`,
  `parse_plan_timestamp`.
- **Tests**: 13 new plan tools tests (parse/list/show/prune) + 10 new
  git tools tests (status/log parsing + dotted branch regression). All use temp dirs for isolation.

### Changed
- Planner agent's tool subset now includes `git_status` and `git_log`
  (up from 6 to 8 read-only tools).
- Planner system prompt updated to mention git tools.
- `is_chat_mode` in `main.ml` recognizes `"plan"` subcommand.

## v0.5.0 — Plan Mode

> **Status**: Shipped. 187 tests passing across 11 suites.

A read-only planning mode that runs before code changes. The agent
investigates the codebase and produces a structured markdown plan before
touching any files.

### Added
- **`lib/par_code_mode.ml`**: Mode state module (`type mode = Plan | Build`),
  `switch`, `agent_id_for`, `label`. Single source of truth for current mode.
  Includes `save_current_mode_to_disk` / `load_mode_from_disk` for
  `--resume` mode persistence via `.par/last_session_mode.txt`.
- **`lib/par_code_plan_tools.ml`**: Two LLM-callable tools (`plan_enter`,
  `plan_exit`) for agent-initiated mode switching. `persist_plan_file`
  function extracts the planner's last assistant message and writes it to
  `.par/plans/<ISO8601>.md`.
- **Planner agent**: Registered alongside the main `"par"` agent with a
  read-only tool subset (`read_file`, `grep`, `find_files`, `list_directory`,
  `recall_memory`, `search_history`, `plan_exit`). Distinct system prompt
  guides structured markdown plan output (Goal/Approach/Files/Risks/Steps).
- **`/plan` and `/build` slash commands**: User-driven mode switching.
  `/build` persists the plan file and injects the path into the next
  build-mode turn's system prompt appendix.
- **`plan_exit` auto-persist**: When the agent calls `plan_exit` during a
  ReAct invoke, the REPL detects the Plan→Build transition post-invoke and
  automatically persists the plan file (no need for manual `/build`).
- **`default_mode` config field**: Defaults to `build` (backward compat);
  configurable via wizard or `par config set default_mode plan`. Read at
  REPL startup to initialize the session mode.
- **`--resume` mode restoration**: `par --resume` restores the mode from
  the previous session via `.par/last_session_mode.txt`. New sessions
  (without `--resume`) always start at `default_mode`.
- **REPL prompt mode indicator**: Renders `(plan) par> ` or `(build) par> `.

### Changed
- `Runtime.invoke` in the REPL now uses
  `Par_code_mode.agent_id_for !current` instead of hardcoded `"par"`,
  enabling mode-driven agent dispatch.
- `par_code_ui.render_prompt` now requires a `~mode` parameter.
- Plan-file appendix combines with memory appendix in
  `?system_prompt_appendix` on the first build turn after `/build`.
- `par config set <field> <value>` subcommand added (was wizard-only).

### Architecture
- **Two-agent design**: The planner is a separate registered PAR SDK agent
  with its own tool list. Per-agent tool isolation is the SDK's intended
  primitive, so the LLM never sees write tool schemas in Plan Mode.
- **Module-level mutable ref** (`Par_code_mode.current`): documented
  limitation. Assumes single-runtime-per-process. Acceptable for v0.5.0.
- **File-based plan persistence**: `.par/plans/<timestamp>.md` archive
  format. No DB schema changes. Plans survive sessions, are
  version-controllable.
- **D4 scope compromise**: Plan output is free-form markdown guided by
  system prompt (no `submit_plan` tool). Retirement plan: v0.6.0 evaluates
  whether subagent coordination needs structured plan fields.

### Build Fixes
- **ARM64 Linux**: Dockerfile pins `uring 2.7.0` before pinning PAR SDK.
  Root cause: opam solver picks `eio.1.4` (latest) which requires
  `uring >= 2.15.0`; `uring.2.15.0` builds vendored liburing that fails to
  link on ARM64 AlmaLinux 8. Pinning `uring 2.7.0` cascades the solver to
  `eio.1.3` (which constrains `uring < 2.14.0`). `uring.2.7.0` links
  against system liburing and works on both x86_64 and ARM64.
- **ARM64 Linux**: Added `kernel-headers` + `liburing-devel` to Dockerfile
  dnf install list.

## v0.4.5 — UI abstraction layer + streaming markdown

> A foundational rendering API (`Ui.*`) that decouples business code from
> terminal output. All 175 `printf` sites migrated to structured `Ui.render_*`
> calls. Streaming markdown state machine renders LLM output with ANSI colors
> as it arrives. Discarded PAR SDK signals (tool_call chunks, usage_update,
> bash events) now rendered. Designed for future TUI backend migration
> (v0.14.0 Mosaic/Matrix) without business code changes.

### Added
- **`lib/par_code_ui.ml`** (511 lines): UI abstraction layer with composable
  styled images, ANSI color generation (16/256/RGB), backend with TTY/NO_COLOR
  detection, 13 high-level render functions (`render_error`, `render_warning`,
  `render_llm_chunk`, `render_tool_event`, `render_cost`, `render_table`, etc.)
- **`lib/par_code_ui_markdown.ml`** (318 lines): streaming markdown-to-ANSI
  renderer. Line-based state machine handles headings, code blocks, bold,
  italic, inline code, links. Round-trip property: chunked input produces
  identical output to whole input.
- **Signal restoration**: `stream_print_chunk` now handles all 5
  `llm_response_chunk` variants (was: only Text_delta, rest discarded).
  `make_tool_event_callback` now handles Tool_progress, Bash_invoked,
  Bash_completed (was: discarded via `_ -> ()`).
- **73 new tests**: 36 UI tests (composition laws, dimensions, style, layout,
  backend) + 37 markdown tests (basic rendering, code blocks, partial chunks,
  round-trip property, edge cases, lists, headings).

### Changed
- **175 printf sites migrated**: all `Printf.printf`/`Printf.eprintf` in lib/
  and bin/ replaced with `Ui.render_*` calls. Zero `Printf.printf` remaining
  in production code.
- **Config wizard**: `input_line stdin` → `Ui.read_line` (flushes stdout first;
  future TUI backends can replace with modal input).
- **Memory recall** (from v0.4.3): usage fields workaround continues to work
  through new UI layer.

### Architecture
- **Composable image type**: `Ui.image` is an immutable styled text rectangle.
  Composition operators `<|>` (horizontal) and `<->` (vertical) mirror Notty's
  and Matrix's Image APIs. Future TUI backend swap requires zero business code
  changes — only the `render` function's internals change.
- **Backend abstraction**: `Ui.backend` holds terminal state (size, color
  support, markdown parser state). Auto-detects TTY via `Unix.isatty`,
  respects `NO_COLOR` env var (https://no-color.org) and `TERM=dumb`.
- **Zero new dependencies**: pure ANSI escape codes (no external color lib),
  hand-rolled markdown parser (no regex lib), in-house image type.
- **Future TUI path**: spike confirmed Mosaic/Matrix (Invariant HQ, 2025-2026)
  has Eio-native TUI with x-agent streaming example. `Ui.image` maps 1:1 to
  both Notty's `I.image` and Matrix's `Image.t`.

### Known Limitations
- Streaming markdown parser handles single-line constructs only (no multi-line
  bold). This is a deliberate simplification — each line is parsed independently.
- No syntax highlighting in code blocks (deferred to v0.5.0+ — needs cmarkit AST).
- No `cmarkit` dependency in v0.4.5 (in-house SM only; final-render AST deferred).
- `Ui.render_table` is basic fixed-width columns (no wrapping).

### Hotfixes (post-release, same tag)
- **RNG initialization** (`fix(upgrade): initialize Mirage_crypto_rng at startup`):
  `par upgrade` crashed with "The default generator is not yet initialized"
  because `Mirage_crypto_rng_unix.use_default ()` was only called in
  `setup_runtime` (REPL/ask path), not in the upgrade path which does HTTPS
  directly. Fixed by moving the call to program startup in `bin/main.ml`,
  covering all code paths. Also silently fixed `maybe_check_version ()`
  (startup version check) which was swallowing the same error.
- **HTTP redirect following** (`fix(upgrade): follow HTTP 301/302/303/307/308 redirects`):
  `par upgrade` failed with "HTTP 302" because `http_get` only accepted
  HTTP 200. GitHub release downloads return 302 redirect to
  `objects.githubusercontent.com`. Fixed by adding redirect-following logic
  (up to 5 hops) to `http_get`. Pre-existing latent bug, exposed after the
  RNG fix allowed the code to reach the HTTP request.

### Upgrade urgency
**Medium.** All changes are additive (new module) or output-mechanism swaps
(printf → Ui). No breaking API changes. Users get colored output + structured
tool cards + markdown rendering. Existing scripts that parse par-code output
may see ANSI escape codes if stdout is a TTY.

## v0.4.3 — UX quick patch: cost visibility, config inspection, memory fix

> Four targeted improvements addressing daily-friction points found during
> v0.4.2 post-release review. No new signature capability (that's v0.5.0's
> plan mode); this release closes known UX gaps and a silent memory-quality
> bug.

### Added
- **`/cost` slash command**: per-session token accumulator visible at any
  time. Prints prompt/completion/total tokens, LLM call count, current
  context size via `Par_code_context.token_estimate`, and operational
  metrics from `Runtime.metrics_snapshot` (LLM requests, tool invocations,
  tasks). Notes that async checkpoint/extraction calls are excluded (their
  fiber's `metrics_accumulator` is discarded per v0.4.1 design). The
  accumulator is a pure `cost_state` ref updated only on `Runtime.invoke`
  Ok branches; Error branches do not accumulate.
- **`par config show` subcommand**: prints current configuration with
  `api_key` masked (showing only first 4 + last 4 chars, or first/last
  char for short keys ≤ 8 chars). All 19 fields rendered; `system_prompt`
  shows `<default>` / `<custom>` rather than the (potentially sensitive)
  content. Backward-compatible: bare `par config` still launches the
  wizard via Cmdliner's `~default:term_config_set`. The new `set`
  subcommand exposes the wizard explicitly.
- **6 new config wizard prompts**: `max_tokens`, `top_p`, `auto_extract`,
  `checkpoint_enabled`, `checkpoint_interval`, `context_budget_tokens`.
  Previously these fields were hardcoded to defaults at wizard exit time;
  users had to hand-edit `~/.par/config.json` to change them.

### Fixed
- **Memory `recall` was silently dropping usage stats**: when `recall_memory`
  searched via PAR SDK `Sqlite_memory.search`, the returned `Memory_object.t`
  lacked `last_used_at` and `usage_count` fields (PAR SDK type limitation).
  par-code's own `row_to_memory` (used by `list` / `render_index` /
  `export_markdown`) reads these correctly via raw SQL, but `recall` went
  through the PAR SDK path → `memory_of_object` conversion → fields
  hardcoded to `None` / `0`. Now `recall` does a supplementary
  parameterized SQL query (`fetch_usage_stats`) to fetch the real values
  and patches the converted records via immutable update. Adversarial
  test with `'; DROP TABLE memory_entries; --` as a memory ID passes —
  parameterized bindings are injection-safe. This unblocks usage-count
  visibility for the LLM (recall tool now shows accurate stats) and
  closes a quality-of-life gap for usage-based pruning diagnostics.

### Removed
- **Dead code: `Par_code_memory.bump_usage`**: 11-line function defined
  but never called from any production path. PAR SDK's
  `Sqlite_memory.search_fts` already calls its own internal `bump_usage`
  for every search result (PAR SDK `sqlite_memory.ml:363, 379`), so
  par-code's copy was redundant. Removal is safe — search behavior
  unchanged, all 15 memory tests pass. Public signature `.mli` updated;
  no external consumers per grep.

### Known Limitations
- `/cost` token totals exclude async checkpoint/extraction LLM calls
  (their fiber's `metrics_accumulator` is discarded — see v0.4.1 decision
  `[2026-07-19] v0.4.1: async checkpoint via Eio.Fiber.fork`). Affects
  ~5-10% undercounting in long sessions. Acceptable; the primary value
  is the call count + context size visibility.
- T5 fix is a par-code-side workaround for a PAR SDK limitation
  (`Memory_object.t` lacks usage fields). Filed as PAR SDK feedback for
  upstream addition.

### Architecture
- **Token accumulator pattern**: `cost_state` is an immutable record
  (`{ llm_calls; prompt_tokens; completion_tokens; total_tokens }`);
  `add_usage : cost_state -> Types.usage_stats -> cost_state` is a pure
  function. The REPL holds `cost : cost_state ref`; only `Runtime.invoke`
  Ok branches mutate it. The accumulator type is exported in
  `Par_code_repl` for testability.
- **PAR SDK feedback filed (1 item, not blocking v0.4.3)**:
  `Memory_object.t` lacks `last_used_at : float option` and
  `usage_count : int` fields even though (a) the DB schema has the
  columns, (b) PAR SDK's `row_to_memory` reads them but discards
  (underscore-prefixed), (c) `Sqlite_memory.search_fts` internally
  bumps them via private `bump_usage`. Severity: medium (architectural
  paper-cut; downstream consumers must do supplementary SQL fetch to
  surface usage stats from SDK search results).

### Upgrade urgency
**Low.** All changes are additive (new command, new subcommand, new
wizard prompts) or quality-of-life fixes (memory recall correctness).
No breaking changes; no API removals (only dead code removal). Users
on v0.4.2 do not need to upgrade urgently, but the `/cost` visibility
and `par config show` are daily-use improvements worth getting.

---

## v0.4.2 — Critical fix: multi-turn conversation context (PAR SDK 0.7.8)

> The PAR SDK 0.7.8 bug that silently dropped assistant responses from the
> conversation history has been fixed upstream. par-code v0.4.2 rebuilds
> against the fixed PAR SDK; multi-turn coding sessions now correctly
> preserve assistant context across turns. Checkpoint-writer / extractor
> also see the full dialogue (was seeing only the user side).

### Fixed
- **Multi-turn conversation coherence (critical)**: in v0.4.0 and v0.4.1,
  the conversation returned by `Runtime.invoke` contained only `System` +
  `User` messages — `Assistant` responses were silently dropped. This meant:
  - On each subsequent turn, the LLM could not see its own prior responses,
    degrading coherence in long coding sessions.
  - The checkpoint-writer and memory extractor saw only the user side of the
    dialogue, producing low-quality checkpoints.
  Root cause was in PAR SDK's ReAct engine (`engine.ml:1024-1029`): the
  `Stop`/`Content_filter` terminal branch omitted the `add_assistant_message`
  call that all other terminal branches made. PAR SDK 0.7.8 fixes this with
  a single egress wrap at the loop boundary (Oracle-audited, 4 redundant
  inline appends removed, loop invariant formalized).

### Upgrade urgency
**High for any user running v0.4.0 or v0.4.1.** Run `par upgrade` to get
v0.4.2. Multi-turn coherence is fundamental to coding agent quality; users
on v0.4.0/v0.4.1 have been silently affected.

### No other changes
This is a binary-only rebuild. par-code source itself has no logic changes
beyond the version bump and documentation sync. The fix lives entirely in
the PAR SDK dependency that ships bundled in the binary.

---

## v0.4.1 — Async checkpoints + UX polish

> Four targeted improvements that finish v0.4.0's unfinished business. The
> REPL no longer freezes during checkpoints; long-session transcripts feed
> the checkpoint-writer their latest content; `/checkpoints` shows decisions,
> files, and open threads per entry.

### Added
- **Async checkpoint + extraction (Pillar A)**: `Par_code_checkpoint.run_checkpoint`
  now dispatches its LLM call via `Eio.Fiber.fork ~sw:(Runtime.cancellation_root rt)`
  instead of calling `invoke_generate` synchronously. The 2–5 s checkpoint
  LLM call now runs in a background fiber; the user turn returns immediately.
  Preserves v0.4.0's `~save:false ~update_current:false` isolation. An
  `in_flight` ref throttles concurrent checkpoint dispatches and is reset on
  every fiber exit path (Ok/Error/exception) via `Fun.protect`. See
  DECISIONS.md [2026-07-19] for the Oracle fiber-safety verdict and 9
  engineering caveats.
- **`Par_code_checkpoint.format_checkpoints`**: new public function that
  renders a checkpoint list as multi-line text for the `/checkpoints` REPL
  command (Pillar C). Each entry shows an index, turn number, task headline,
  plus optional `decisions:`, `files:`, and `open:` sections indented
  underneath; empty sections are omitted.

### Changed
- **Transcript truncation switched from first-N to last-N (Pillar B)**:
  `Par_code_checkpoint.serialize_for_checkpoint` and
  `Par_code_extractor.serialize_transcript` now keep the **last** 8000 chars
  of a long transcript instead of the first. Long sessions need the latest
  content for the checkpoint-writer / extractor to capture current state —
  the opening greeting adds nothing.
- **`/checkpoints` REPL command**: now uses `format_checkpoints` (Pillar C)
  to render richer output. Previous single-line `[i] Turn N: task` replaced
  with multi-line entries showing decisions, files, and open threads.

### Confirmed no-op
- **`/checkpoint` extraction chaining (Pillar D)**: investigation during
  plan review (Momus, 2026-07-19) confirmed that `par_code_checkpoint.ml:341`
  already chains `Par_code_extractor.run_extraction` after a successful
  `store_checkpoint`. Both periodic and manual checkpoints route through
  `run_checkpoint`, so both already trigger extraction. No code change
  needed; documented as a confirmed no-op for traceability.

### Architecture
- **Fiber model**: checkpoint/extraction now run as background Eio fibers
  under `rt.cancellation_root`. REPL shutdown propagates cancellation to
  in-flight fibers via PAR SDK's existing switch teardown. No new switch
  lifecycle to manage at the par-code level.
- **PAR SDK Feedback filed (3 items, not blocking v0.4.1)**:
  1. `Event_bus.set_session_id` writes without mutex (`event_bus.ml:141-142`);
     `publish` reads under `use_ro` (`event_bus.ml:56`). In par-code's call
     pattern the value is always identical, so no observable race today.
  2. `rt.last_llm_call_at` / `rt.last_llm_call_status` are plain mutable
     (`runtime.ml:435-436`, `442-443`); lost-update race under concurrent
     fibers. Diagnostic only; health snapshot tolerates stale reads.
  3. `Runtime.invoke_async` lacks `?save` / `?update_current` (re-affirmed).
     This is why par-code uses `Eio.Fiber.fork` directly instead of
     `Invoke_context.fork_invoke` (which is typed for `invoke_result`, not
     `generate_result`).

### Known Limitations
- Checkpoint/extraction LLM calls no longer appear in `rt.metrics`. The
  fiber's `ctx.metrics_accumulator` is allocated fresh and discarded
  (`invoke_generate` doesn't call `Metrics.merge_into`). Acceptable for
  v0.4.1 — these are background bookkeeping calls.
- `rt.last_llm_call_at` / `rt.last_llm_call_status` may briefly reflect the
  checkpoint call instead of the user's call (lost-update race, see PAR SDK
  feedback #2). Health snapshot unaffected in practice.
- Async return-immediately behavior is verified by manual smoke rather than
  unit test. Mocking `invoke_generate` would require an invasive functor
  refactor; deferred to v0.5.0+ if metrics visibility becomes important.
- **PRE-EXISTING (inherited from v0.4.0, not introduced by v0.4.1; FIXED
  in v0.4.2)**: the `conversation` field returned by `Runtime.invoke`
  contained only `System` + `User` messages — `Assistant` responses were
  not included in `conv.messages`. Checkpoint-writer / extractor therefore
  saw only the user side of the dialogue, which limited checkpoint quality.
  Root cause was a missing `add_assistant_message` call in PAR SDK's
  ReAct engine; fixed upstream in PAR SDK 0.7.8 (single egress wrap) and
  consumed by par-code v0.4.2.

### Tests
- 4 new tests in `test_par_code_checkpoint.ml`:
  - `serialize.truncation_keeps_last` — verifies last-N truncation
  - `format.empty_list`, `format.single_minimal`, `format.multi_field_entry`,
    `format.omits_empty_sections` — verify `format_checkpoints` output shape
- All 44 tests (5 + 25 + 14) pass on a clean build.

---

## v0.4.0 — Long-session continuity

> Checkpoint-writer subagent with save/isolation controls, budgeted context
> injection, context reconstruction on resume, periodic mid-session memory
> extraction. Hour-long sessions never lose the thread.

### Added
- **Checkpoint-writer subagent**: a background LLM agent that snapshots session
  state every N turns (default 10) into structured entries (task, decisions,
  files, interfaces, open threads). Uses `invoke_generate rt ~save:false
  ~update_current:false` — checkpoint and extraction calls never clobber the
  user's conversation state or trigger unwanted saves.
- **`checkpoints` table**: new SQLite table for storing checkpoint entries,
  linked by session_id and project_id. FTS5 index created for future search
  capabilities.
- **`/checkpoint` command**: force an immediate checkpoint regardless of turn count.
- **`/checkpoints` command**: list checkpoints for the current session.
- **Context reconstruction on resume**: when `--resume`/`--continue`, the most
  recent checkpoints are rendered into a compact session brief and injected
  as `system_prompt_appendix` on the first turn.
- **Budgeted context injection**: before each `invoke`, if the conversation
  exceeds `context_budget_tokens` (default 100000), older messages are replaced
  with a checkpoint summary while the last 8 messages are kept verbatim.
- **Periodic mid-session memory extraction**: the checkpoint cycle also triggers
  memory extraction via save/isolation controls, so facts appear during long
  sessions without waiting for exit.
- **Config fields**: `checkpoint_enabled` (default true), `checkpoint_interval`
  (default 10), `context_budget_tokens` (default 100000).
- **Env overrides**: `PAR_NO_CHECKPOINT=1` disables checkpointing entirely.

### Changed
- **`par_code_repl.ml`**: turn counter, checkpoint hooks, slash-commands, resume
  brief, budgeted inject.
- **`par_code_setup.ml`**: registers checkpoint-writer agent; bash auto-approve
  for safe commands; tool description overrides.
- **`par_code_memory.ml`**: exposes `raw_db` accessor for checkpoint schema creation.
- **`par_code_config.ml`**: 3 new config fields across type/default/to_json/of_json/merge.

### New modules
- **`par_code_checkpoint.ml/mli`** (328/60 lines): checkpoint storage, serialization,
  JSON parsing, session brief rendering, `run_checkpoint`/`maybe_checkpoint`.
- **`par_code_context.ml/mli`** (99/23 lines): `token_estimate` (chars/4 heuristic),
  `compact` (replace old messages with summary, keep recent verbatim).

### Architecture
- **PAR SDK 0.7.7 save/isolation controls**: checkpoint writer and extractor use
  `invoke_generate ~save:false ~update_current:false` to run safely on the
  user's Runtime without clobbering conversation state or triggering unwanted
  saves. Exit paths use `save_conversation ?conversation:!conv` to save the
  authoritative conversation ref directly.

### PAR SDK Feedback (filed, not applied)
1. `invoke_generate`'s auto-save is inconsistent with `invoke` (which doesn't
   auto-save). Recommend `?persist:bool` parameter.
2. `rt.current_conversation` is unprotected shared mutable state — unsafe for
   concurrent invoke on the same Runtime.
3. `save_conversation` cannot target a specific conversation — recommend
   `?conv` parameter or exposing `rt.services.persistence`.

### Known Limitations
- Token estimation uses chars/4 heuristic (±20% accuracy, compacts conservatively).
- Checkpoint calls are synchronous (~2-5s every N turns). True background fiber
  execution is a future enhancement.
- No incremental/delta checkpoints — each checkpoint is a full snapshot.

## v0.3.3 — PAR SDK 0.7.3 + hybrid memory search

> Memory storage layer delegated to PAR SDK 0.7.3's `Sqlite_memory` module.
> Schema upgraded with auto-migration from v0.3.0–v0.3.2. Memory IDs are now
> UUID strings instead of integers.

### Changed
- **Memory storage migrated to PAR SDK `Sqlite_memory`**: `Par_code_memory` now
  delegates CRUD to `Sqlite_memory.add/search/delete`, gaining FTS5 + vec0 +
  RRF hybrid search infrastructure (from PAR SDK 0.7.3). par-code-specific
  features (`render_index` kind-grouping, `export_markdown`, `prune_stale`,
  `search_history` via `conversations_fts`) are kept as raw SQL wrappers.
- **Memory IDs changed from `int` to UUID strings**: `par memory show`,
  `par memory forget`, and the `remember_memory` tool now use UUID-based IDs
  (e.g. `b7dfb79f-...`) instead of sequential integers.
- **Auto-migration from v0.3.0–v0.3.2 schema**: on first `open_db`, if old
  schema is detected (`kind` column exists), data is read, old tables dropped,
  new schema created via `Sqlite_memory`, and data re-inserted preserving
  timestamps and usage stats.
- **PAR SDK dependency constraint**: added `par.memory` library dependency.

### Added (from earlier unreleased commits)
- **PAR SDK 0.7.3 consumption**: removed Auto-skill workaround; memory index
  now injected per-turn via `?system_prompt_appendix`.
- **Ctrl-C saves session**: SIGINT handler saves conversation + runs memory
  extraction before exiting.
- **Config fallback**: missing `system_prompt` in config.json falls back to
  default instead of silently becoming empty.

### Added
- **Embedding API configuration**: `par config` now supports separate embedding
  settings (`embedding_base_url`, `embedding_model`, `embedding_dimension`).
  Users can use a different provider for embeddings than for chat (e.g.,
  chat via one provider, embeddings via another). Defaults to chat provider config.
- **Hybrid search infrastructure**: `Sqlite_memory` with vec0 + RRF is wired
  via embedding service. When embeddings are available, `recall` uses hybrid
  search (FTS5 + vector). Falls back to FTS5-only when unsupported.

### Known Limitations
- vec0 extension may not be available on all platforms; degrades gracefully
  to FTS5-only when absent.

## v0.3.2 — Linux arm64 pre-built binary support

> Linux ARM64 devices (Raspberry Pi 4/5, AWS Graviton, other aarch64 Linux)
> now supported with one-line installer — no more compiling from source.

### Added
- **Linux arm64 pre-built binary**: new `build-linux-arm64` CI job on
  `ubuntu-24.04-arm` native ARM runner. Same AlmaLinux 8 Docker build base,
  same FTS5-enabled sqlite3 amalgamation. Output: `par-v<ver>-linux-arm64.tar.gz`.
- **install.sh arm64 detection**: `aarch64`/`arm64` → `linux-arm64` platform.
- **`par upgrade` arm64 support**: self-update recognizes `linux-arm64`.

### Changed
- **Dockerfile architecture-aware**: opam binary download and tarball naming
  use `uname -m` instead of hardcoded `x86_64`. Same Dockerfile builds both
  x86_64 and arm64.
- **release.yml**: `coordinate` job `needs` includes `build-linux-arm64`;
  Release assets list includes arm64 tarball + sha256.

## v0.3.1 — Auto-Extraction + History Search

> Session-end memory extraction and full-text search over past conversation
> transcripts. The agent now captures salient facts automatically when you quit,
> and you can search old sessions with `par memory search-history`.

### Added
- **Auto-extraction at session exit**: when the user quits the REPL, an
  extractor agent reads the session transcript and writes salient memories
  (quality-gated: "Will a future agent plausibly act better?"). Disable
  with PAR_NO_AUTO_EXTRACT=1 or auto_extract:false in config.
- **`search_history` agent tool**: FTS5 full-text search over past session
  transcripts. Returns snippets with highlighted match terms.
- **`par memory search-history <query>` CLI**: terminal-native history search.
- **`conversations_fts` FTS5 index**: virtual table indexing the conversations
  table for history search, with auto-backfill on DB open.
- **`lib/par_code_extractor.ml`**: new module — quality-gated extractor prompt,
  transcript serialization, JSON response parsing, deduplication via FTS5 recall.

### Changed
- **`lib/par_code_config.ml`**: added `auto_extract : bool` field (default: true).
- **`lib/par_code_setup.ml`**: registers "memory-extractor" agent (tools=[], pure
  generation) alongside the main "par" agent.
- **`lib/par_code_repl.ml`**: triggers extraction at both exit paths (Ctrl-D, /quit).
- **`lib/par_code_memory.ml`**: ensure_schema now creates conversations_fts + triggers
  + runs 'rebuild' backfill. New search_history function with snippet() highlighting.
- **`lib/par_code_memory_tools.ml`**: added search_history tool binding (3rd tool).

## v0.3.0 — Project Memory

> Cross-session project memory. par-code now remembers conventions, decisions,
> gotchas, and preferences from past sessions. Memories are SQLite-backed with
> FTS5 full-text search, auto-injected into the system prompt as a compact index,
> and searchable via the `recall_memory` agent tool.

### Added
- **Project memory layer** (`lib/par_code_memory.ml`): SQLite-backed memory
  entries with FTS5 virtual table + BM25 ranking, per-project scoping (git root),
  compact index rendering (≤200 lines), and full markdown export. Same `~/.par/par.db`
  file as sessions (PAR SDK 0.6.9+ exposes `Sqlite_persistence.raw_sqlite3_db`).
- **Agent tools**: `recall_memory` (FTS5 search) and `remember_memory` (save new
  memory). The remember tool includes a quality-gate prompt: "Only call this when
  a future agent will plausibly act better."
- **`par memory` subcommand group**: 7 leaf commands — `list`, `add`, `forget`,
  `show`, `export`, `prune`, `search`. CLI-native memory curation without entering
  the REPL.
- **Test module** (`test/test_par_code_memory.ml`): 8 test cases covering schema
  idempotency, FTS5 trigger correctness, recall limit, project isolation, usage
  tracking, prune semantics, and index line cap.

### Changed
- **Bundled sqlite3** now compiled from official amalgamation source with
  `-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1` (Linux Dockerfile + macOS build
  script). Previously used OS-package sqlite3 which may not include FTS5.
- **System prompt** now appends a per-project memory index on session start
  (compact, ≤200 lines / ~1K tokens). Index is empty for projects with no memories.
- **`lib/par_code_setup.ml`**: opens memory DB, injects index, registers memory
  tools, closes DB on shutdown. Memory is additive — degrades gracefully if DB
  unavailable.
- **PAR SDK upgraded** from 0.6.7 to 0.6.9 (adds `raw_sqlite3_db` accessor +
  `install_bash_tool ~fs` parameter). Bash tool fix: added `~fs:(Eio.Stdenv.fs env)`
  to match the new PAR API.

### Deferred
- **v0.2.2 (Windows native + code signing)**: deferred pending upstream
  `Eio.Process` Windows implementation. `Eio.Process` is currently
  `failwith "process operations not supported on Windows yet"` in the eio library,
  which blocks PAR SDK's MCP stdio transport and bash tool. Re-scope when eio
  upstream ships Windows process support.

## v0.2.1 — One-line install & self-update

> Distribution release. par-code now ships pre-built binaries for Linux (x86_64,
> glibc ≥ 2.28) and macOS (arm64). Users install with a single `curl | bash`
> command — no OCaml/opam prerequisite. The new `par upgrade` subcommand keeps
> installations current without a package manager.

### Added
- **One-line installer** (`scripts/install.sh`): POSIX sh installer for Linux +
  macOS. Idempotent rc-file updates with `# >>> par >>>` markers. Supports
  `--prefix <path>`, `--version <ver>`, `PAR_PREFIX`, `PAR_MIRROR`,
  `PAR_DISABLE_UPDATE_CHECK` env vars. Bundled C libraries (libsqlite3, libgmp)
  — no system prerequisites.
- **`par upgrade` subcommand** with flags `--check`, `--to <ver>`, `--uninstall`,
  `--purge`. Atomic self-replace via `rename(2)` over running binary + post-swap
  smoke test (3s timeout) + automatic rollback. Cache at
  `~/.par/.latest-cache.json` with 24h TTL + ETag conditional GET.
- **Startup version-check notice** (purely additive): single stderr line when a
  newer version exists, gated by `PAR_NO_UPDATE_CHECK=1`, never blocks, never
  crashes on network failure, fires only in default chat mode (not for
  `par config`, `par ask`, `par --version`, etc.).
- **Pre-built Linux binary** (AlmaLinux 8 build base, glibc ≥ 2.28
  baseline). Bundles `libsqlite3.so.0` + `libgmp.so.10` with `$ORIGIN` RPATH via
  patchelf. AlmaLinux 8's stock gcc 8.5 satisfies OCaml 5.x's C11 atomics
  requirement; no SCL/devtoolset needed.
- **Pre-built macOS arm64 binary**. Bundles `libsqlite3.0.dylib` +
  `libgmp.10.dylib` with `@loader_path` RPATH via `install_name_tool`.
- **Generated version module** (`lib/par_code_version.ml`): emitted at build
  time by a dune `(rule ...)` stanza from `dune-project`'s `(version ...)`
  field via `%{version:par_code}`. Replaces hand-written version constants in
  `lib/par_code.ml` (deleted). CI release builds on a clean tag checkout
  produce a binary whose `Par_code_version.version` matches the tag.
- **Self-update HTTP via eio** (`lib/par_code_upgrade.ml`): uses
  `Cohttp_eio.Client.call` for GET requests (Par.Http_client.do_request is
  POST-only). TLS config reuses `Par.Http_client.tls_config` lazy. SHA256
  verification via `Digestif.SHA256`. No shell-out to curl.
- **CI release pipeline** (`.github/workflows/release.yml`): tag-triggered on
  `v[0-9]+.[0-9]+.[0-9]+` (excludes pre-release tags). Three jobs: build-linux
  (docker build via AlmaLinux 8 Dockerfile), build-macos (macos-15 runner),
  coordinate (concatenate checksums, upload install.sh, create GitHub Release
  via pinned `softprops/action-gh-release@<sha>`). Workflow-dispatch with
  version input for manual re-runs.

### Changed
- `lib/dune` libraries: added `cohttp-eio`, `tls-eio`, `digestif` (all
  transitively available via par SDK; made explicit for manifest correctness
  and to survive removal of transitive deps in future par versions).
- `dune-project` `(depends ...)`: added the same three packages so
  `par_code.opam` reflects them as direct dependencies.
- `bin/main.ml`: `Cmd.group` extended with `par upgrade` subcommand. Version
  info now references `Par_code_version.version_info` (was
  `Par_code.version_info`).
- `test/test_par_code.ml`: version assertions updated to reference
  `Par_code_version.version` / `Par_code_version.version_info`.
- `lib/par_code.ml`: deleted (was 4 lines of hand-written version constants;
  replaced by generated module).
- `.gitignore`: added `lib/par_code_version.ml` (generated file, never
  committed).

## v0.2.0-dev — Interactive coding agent (shipped as part of v0.2.1)

> First working release. par-code is now a functional terminal coding agent
> with REPL, single-shot ask, provider configuration, PAR builtin tools,
> streaming output, and session persistence/resume.

**Rename:** command `par-code` → `par`; config dir `~/.par-code/` → `~/.par/`.

### Added
- Renamed command from `par-code` to `par`; config dir from `~/.par-code/` to `~/.par/`.
- **REPL** (`par`): interactive loop with token streaming to stdout via
  `on_chunk` callback. Coding system prompt (not a generic assistant).
- **Single-shot mode** (`par ask "<question>"`): run one query and exit.
- **Config wizard** (`par config`): interactive setup for provider, model,
  API key. Config stored at `~/.par/config.json`.
- **Session resume** (`par -r` most recent, `par -c <id>` specific).
  DB stored at `~/.par/par.db`.
- **All 20 PAR builtin tools** plus bash via type-safe `install_bash_tool`.
- **Four providers**: openai, anthropic, ollama, custom (use `+name` prefix).
- **CLI flags**: `--provider`, `--api-key`, `--model`, `--session-id`,
  `--resume`, `--continue`.
- **Architecture**: scheme C — par-code's own internal bootstrap layer in
  `lib/` (Par_code_setup, Par_code_config, Par_code_repl). `par_cli` is an
  executable package and cannot be linked. Retirement condition: migrate to
  PAR's bootstrap library if PAR ever exposes one.

### Changed
- Library facade (`lib/`) now includes `Par_code_setup`, `Par_code_config`,
  and `Par_code_repl` modules.
- `par_code.opam` depends on `par` (>= 0.6.2).

## v0.1.0-dev — Project skeleton (UNRELEASED)

> Initial public scaffolding. No agent logic yet — par-code links against the
> PAR SDK and exposes a `par` executable with `--version`/`--help`. The
> interactive coding REPL lands in v0.2.0.

### Added
- dune project (`par_code` package) depending on `par` (>= 0.6.2), cmdliner,
  eio, yojson, with generated `par_code.opam`.
- `par` executable (`bin/`) with cmdliner `--version`/`--help`, CLI arg
  definitions mirroring PAR's CLI for drop-in flag compatibility.
- `par_code` library facade (`lib/`) with `version`.
- Alcotest harness (`test/`).
- Apache-2.0 license, README, CHANGES, CONTRIBUTING, Makefile, editorconfig,
  gitignore, GitHub Actions CI.

### Planning
- Roadmap defined (v0.2.0 → v1.0.0): one user-perceivable capability per
  release. See README "Roadmap" and docs/DECISIONS.md.
