# CHANGES

## v0.4.0 — Long-session continuity

> Checkpoint-writer subagent on a separate isolated Runtime, budgeted context
> injection, context reconstruction on resume, periodic mid-session memory
> extraction. Hour-long sessions never lose the thread.

### Added
- **Checkpoint-writer subagent**: a background LLM agent on a **separate,
  isolated Runtime** that snapshots session state every N turns (default 10)
  into structured entries (task, decisions, files, interfaces, open threads).
  The separate Runtime ensures checkpoint calls never clobber the user's
  conversation state.
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
  memory extraction via the isolated Runtime, so facts appear during long
  sessions without waiting for exit.
- **Config fields**: `checkpoint_enabled` (default true), `checkpoint_interval`
  (default 10), `context_budget_tokens` (default 100000).
- **Env overrides**: `PAR_NO_CHECKPOINT=1` disables checkpointing entirely.

### Changed
- **`par_code_repl.ml`**: `run` and `run_single_shot` gain `~ckpt_rt` parameter;
  turn counter, session_id capture, checkpoint hooks, and budget logic wired in.
- **`par_code_setup.ml`**: creates a second Runtime (`ckpt_rt`) with no-op
  persistence (prevents checkpoint saves from polluting the conversations table)
  and registers the checkpoint-writer agent on it.
- **`par_code_memory.ml`**: exposes `raw_db` accessor for checkpoint schema creation.
- **`par_code_config.ml`**: 3 new config fields across type/default/to_json/of_json/merge.

### New modules
- **`par_code_checkpoint.ml/mli`** (328/60 lines): checkpoint storage, serialization,
  JSON parsing, session brief rendering, `run_checkpoint`/`maybe_checkpoint`.
- **`par_code_context.ml/mli`** (99/23 lines): `token_estimate` (chars/4 heuristic),
  `compact` (replace old messages with summary, keep recent verbatim).

### Architecture
- **Separate Runtime isolation**: the checkpoint writer runs on its own
  `Runtime.create` instance with no-op persistence. This is architecturally
  correct (not a scope compromise): PAR SDK's `invoke_generate` clobbers
  `rt.current_conversation` and auto-saves, which would corrupt the user's
  session if run on the shared Runtime. The separate Runtime makes this race
  structurally impossible.

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
