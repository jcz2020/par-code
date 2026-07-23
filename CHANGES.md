# CHANGES

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
