# Decisions

## [2026-07-19] v0.4.1: async checkpoint via Eio.Fiber.fork (Oracle SAFE WITH CAVEATS)

**变更前**: v0.4.0 shipped checkpoint-writer + extractor as synchronous
`invoke_generate` calls inside the user's REPL turn. Every N turns (default
10) the user waited 2–5 s while the checkpoint LLM call completed before
the `par>` prompt returned. The v0.4.0 plan had flagged async as a target
but the ckpt_rt workaround (later eliminated) consumed the design surface;
the synchronous-at-turn-boundary path shipped.

**变更后**: `Par_code_checkpoint.run_checkpoint` now dispatches its
`invoke_generate ~save:false ~update_current:false` call via
`Eio.Fiber.fork ~sw:(Par.Runtime.cancellation_root rt)`. The user turn
returns immediately; the LLM call, JSON parse, store, and downstream
`run_extraction` all run in the background fiber. An `in_flight : bool ref`
in the REPL state throttles concurrent dispatches and is reset on every
fiber exit path (Ok/Error/exn) via `Fun.protect`. v0.4.0's
`~save:false ~update_current:false` isolation is preserved unchanged.

**原因**: synchronous checkpoint at every N turns was the most concrete
user-visible flaw in v0.4.0. PAR SDK 0.7.7 already ships `Eio.Fiber.fork`
and `Runtime.cancellation_root`; the v0.4.0 ckpt_rt elimination
([2026-07-18]) cleared the architectural surface needed to consume them
directly. Oracle review (2026-07-19) of every shared-state mutation in
`invoke_generate` (`runtime.ml:859-947`) returned **SAFE WITH CAVEATS**
under `~save:false ~update_current:false` for par-code's single-REPL
workload. The 9 engineering caveats are baked into the implementation.

**影响范围**: `lib/par_code_checkpoint.ml` (run_checkpoint / maybe_checkpoint
signatures gain `in_flight:bool ref`; new `format_checkpoints` and
`truncate_to_last_n` helpers also added in this version),
`lib/par_code_checkpoint.mli` (signature updates + new exposed vals),
`lib/par_code_extractor.ml` (local copy of last-N truncation helper),
`lib/par_code_repl.ml` (new `in_flight_checkpoint` ref in run state;
`/checkpoint` and `/checkpoints` command paths updated; periodic
`maybe_checkpoint` call site updated), `test/test_par_code_checkpoint.ml`
(5 new tests covering Pillar B truncation + Pillar C formatting),
`CHANGES.md` (v0.4.1 section), `docs/STRATEGY.md` (§8 + §9 updated),
`docs/DECISIONS.md` (this entry + 3 PAR SDK feedback items below).

**回退方式**: Revert to synchronous `invoke_generate` (drop the
`Eio.Fiber.fork` wrapper, drop `in_flight` plumbing). All other v0.4.1
changes (Pillar B truncation, Pillar C format_checkpoints, Pillar D
no-op confirmation) are pure additions and can stay.

**已知限制**:
1. Checkpoint/extraction LLM calls no longer appear in `rt.metrics` —
   the fiber's `ctx.metrics_accumulator` is discarded (no `merge_into`).
   Acceptable for v0.4.1; tracked for v0.5.0+ if metrics visibility
   becomes important.
2. `rt.last_llm_call_at` / `rt.last_llm_call_status` may briefly reflect
   the checkpoint call instead of the user's call (lost-update race on
   `runtime.ml:435-436, 442-443`). Diagnostic only; health snapshot
   tolerates stale reads.
3. Async return-immediately behavior verified by manual smoke rather than
   unit test. Mocking `invoke_generate` would require invasive functor
   refactor; deferred.
4. `compute_active_skill_effects` (`runtime.ml:886`) reads
   `rt.user_activated_skills` live (not snapshotted, unlike `invoke`
   at `runtime.ml:742`). Dormant race today — par-code never mutates
   this field after setup — but a future contributor adding mid-session
   skill toggling would activate it. Code comment in `run_checkpoint`
   flags this.

### Oracle evidence summary (full table in `.sisyphus/plans/v0.4.1.md`)

| Shared field | Touch under `~save:false ~update_current:false` | Race | Verdict |
|---|---|---|---|
| `rt.session_id` (`runtime.ml:861-867`) | Write only if None | None — REPL sets at first turn | SAFE |
| `Event_bus.current_session_id` (`event_bus.ml:141-142`) | Unconditional write, no mutex | Theoretical, always same value | SAFE |
| `rt.last_llm_call_{at,status}` (`runtime.ml:435-436,442-443`) | Write (record_llm_*) | Lost-update | SAFE (diagnostic) |
| `rt.metrics` (`metrics.ml:2-7`) | incr_llm via fiber-local ctx | None — invoke_generate never merges | SAFE |
| `rt.current_conversation` (`runtime.ml:938,944`) | Never read; write gated | None | SAFE |
| `rt.user_activated_skills` (`runtime.ml:886`) | Read live (not snapshot) | Dormant in par-code | SAFE |
| `rt.services.llm` | Concurrent HTTP | Stateless providers | SAFE |
| `save_conversation` (`runtime.ml:939-940`) | All paths gated | None | SAFE |

### 9 engineering caveats baked into implementation

1. `try ... with exn` inside fork body — `invoke_generate` handles LLM errors
   but PAR SDK or Eio can raise unexpected exceptions.
2. `~sw:(Par.Runtime.cancellation_root rt)` — not a fresh switch.
3. Snapshot `transcript` and `conv` by value before `Eio.Fiber.fork`.
4. `in_flight : bool ref` throttle; reset via `Fun.protect ~finally`.
5. Do NOT `Promise.await` the fiber handle — fire-and-forget.
6. All three REPL exit paths (SIGINT/EOF/`/quit`) let `rt.cancellation_root`
   teardown propagate cancellation via PAR SDK's normal close path.
7. Accept `rt.metrics` under-count (documented in CHANGES).
8. Accept `last_llm_call_*` flapping (documented in CHANGES).
9. Code comment flags the `user_activated_skills` live read.

### Type-mismatch note (why `Eio.Fiber.fork` instead of `Invoke_context.fork_invoke`)

`Invoke_context.fork_invoke` (`invoke_context.mli:96-100`) is typed for
closures returning `(invoke_result, error_category * conversation) result`,
but `Runtime.invoke_generate` returns `(generate_result, error_category *
conversation) result`. These are distinct types in `types.mli`. The
proposed `fork_invoke`-based sketch in the original v0.4.1 plan would not
have compiled. Using `Eio.Fiber.fork` directly (which is what `fork_invoke`
calls underneath, minus the type-restricted handle wrapping) is the
architecturally correct path. PAR SDK feedback item #3 tracks this gap.

## [2026-07-19] PAR SDK Feedback: 3 items surfaced by v0.4.1 async work

Per global AGENTS.md §1 and the par-code par-sdk-feedback skill, three
PAR SDK gaps surfaced during v0.4.1 implementation. Tracked here for
upstream action; none blocks v0.4.1.

1. **`Event_bus.set_session_id` writes without mutex** (`event_bus.ml:141-142`).
   `publish` reads under `Eio.Mutex.use_ro` (`event_bus.ml:56`), but the
   setter is bare assignment. In par-code's call pattern the value is
   always identical (read from already-set `rt.session_id`), so no
   observable race today. Future PAR SDK consumers that vary session_id
   per fiber would hit this. **Severity**: low (workaround: caller-side
   discipline).

2. **`rt.last_llm_call_at` / `rt.last_llm_call_status` are plain mutable**
   (`runtime.ml:435-436, 442-443`). Lost-update race under concurrent
   fibers. **Severity**: low (diagnostic only; readers at
   `runtime.ml:1776-1777` health snapshot and `par_capi.ml:1132-1136`
   FFI tolerate stale reads).

3. **`Runtime.invoke_async` lacks `?save` / `?update_current`** (re-affirmed
   from v0.4.0 feedback). The closure signature of
   `Invoke_context.fork_invoke` (`invoke_context.mli:96-100`) is typed
   for `invoke_result`, not `generate_result`. Both gaps force consumers
   needing async + isolation to bypass PAR SDK's async primitives and
   call `Eio.Fiber.fork` directly. **Severity**: medium (architectural
   paper-cut; encourages consumers to invent their own async patterns).

## [2026-07-18] Architecture: eliminate ckpt_rt, use PAR SDK 0.7.7 save/isolation controls

**变更前**：v0.4.0 used a separate checkpoint Runtime (`ckpt_rt`) with no-op persistence to isolate checkpoint/extractor `invoke_generate` calls from the user's Runtime. This was a ~50-line workaround for PAR SDK's lack of save/isolation controls.

**变更后**：PAR SDK v0.7.7 shipped `?save:bool` and `?update_current:bool` on `invoke_generate`, and `?conversation:` on `save_conversation`. par-code now runs checkpoint/extractor on the user's Runtime with `~save:false ~update_current:false`. The separate Runtime, no-op persistence, and second LLM service are eliminated. Exit paths use `save_conversation ?conversation:!conv` to save the authoritative ref directly.

**原因**：The ckpt_rt was a workaround for a PAR SDK limitation. With the limitation fixed at root (PAR SDK 0.7.7), the workaround is unnecessary overhead — a second Runtime, second LLM connection, and duplicate agent registrations. Removing it simplifies the architecture and reduces resource consumption.

**影响范围**：`lib/par_code_checkpoint.ml` (run_checkpoint/maybe_checkpoint use rt instead of ckpt_rt), `lib/par_code_extractor.ml` (invoke_generate gains ~save:false ~update_current:false), `lib/par_code_setup.ml` (removed ckpt_rt creation + agent registrations), `lib/par_code_repl.ml` (removed ~ckpt_rt parameter), `bin/main.ml` (simplified callbacks).

**回退方式**：Revert to ckpt_rt architecture. The checkpoint module still accepts `~rt` which can be either the user's or a separate Runtime.

**已知限制**：`invoke_generate` with `~save:false ~update_current:false` still mutates `rt.session_id` (if None), `event_bus`, and metrics. In par-code's single-threaded REPL, these are benign (session_id is already set, metrics inflation is negligible). Not full fiber-safe isolation — reduced shared-state dependency, not eliminated.

## [2026-07-16] v0.4.0 shipped — Long-session continuity

**变更前**：v0.3.3 shipped (hybrid memory search). v0.4.0 was unimplemented. Long sessions relied on the full conversation being passed to each invoke, eventually exceeding the model's context window with no recovery mechanism.

**变更后**：v0.4.0 shipped. Version bumped to 0.4.0 in dune-project + par_code.opam + test assertion. Tag v0.4.0 pushed; Release workflow built Linux x64/arm64 + macOS arm64 binaries successfully (all 4 jobs green); GitHub Release published. README/CHANGES/STRATEGY synced.

**原因**：v0.4.0 delivers the signature capability "hours-long sessions never lose the thread" via four pillars: (1) checkpoint-writer subagent on a separate isolated Runtime, (2) budgeted context injection (chars/4 heuristic compaction), (3) context reconstruction on resume, (4) periodic mid-session memory extraction. The separate Runtime architecture was Oracle-reviewed and confirmed as architecturally correct (R1/R3). Live testing verified all features end-to-end with real LLM calls, finding and fixing 7 bugs (think-tag JSON parsing, infinite loop, exception guard gaps, missing extractor registration on ckpt_rt, false compaction notices).

**影响范围**：2 commits — feat(v0.4.0) (14 files, +1120 lines) + release bump (7 files). New modules: par_code_checkpoint.ml/mli (351/60 lines), par_code_context.ml/mli (99/23 lines). New tests: 20 checkpoint tests. Users: `curl install.sh | bash` now installs v0.4.0; existing users get offered the upgrade.

**回退方式**：Git tag and GitHub Release are permanent. Code state can be reverted via `git revert`. Memory schema is backward-compatible (checkpoints table is additive).

**已知限制**：(1) Token estimation uses chars/4 heuristic (±20% accuracy). (2) Checkpoint calls are synchronous (~2-5s every N turns). (3) Checkpoint content quality depends on model capability (weaker models may return trivial/empty checkpoints). (4) PAR SDK feedback filed (3 items: invoke_generate auto-save inconsistency, current_conversation shared mutable, save_conversation lacks ?conv parameter).

## [2026-07-16] v0.4.0: separate checkpoint Runtime for isolation

**变更前**：par-code used a single `Runtime` instance for all LLM calls (main agent + memory extractor). The extractor ran synchronously at session exit, so no concurrency issue existed.

**变更后**：v0.4.0 adds a checkpoint-writer subagent that runs `invoke_generate` during the session (not just at exit). PAR SDK's `invoke_generate` clobbers `rt.current_conversation` (line 917) and auto-saves (line 918), which would corrupt the user's saved session if run on the shared Runtime. A **separate `Runtime` instance** (`ckpt_rt`) with no-op persistence is created at setup time. Checkpoint calls only affect `ckpt_rt`'s state. The user's `rt` is never touched.

**原因**：PAR SDK's `Runtime` has unprotected shared mutable state (`current_conversation`, `session_id`). Concurrent `invoke_generate` on the same runtime races — the last writer wins, potentially saving the checkpoint's conversation as the user's session. The separate Runtime eliminates this race class structurally rather than relying on cooperative-scheduling reasoning. Oracle confirmed this is the architecturally-correct choice (R1/R3).

**影响范围**：`lib/par_code_setup.ml` (creates `ckpt_rt`), `lib/par_code_repl.ml` (accepts `~ckpt_rt`), `bin/main.ml` (threads `ckpt_rt`). No PAR SDK changes.

**回退方式**：Remove `ckpt_rt`, pass `None` as the `~ckpt_rt` parameter. Checkpointing is disabled but all other functionality continues. The separate Runtime is a pure addition — no existing behavior changes when `ckpt_rt = None`.

**已知限制**：Creates a second LLM provider connection (minor resource overhead). The long-term clean fix is a PAR SDK `?persist:bool` parameter on `invoke_generate` (tracked as PAR feedback #1). When PAR ships that, the separate Runtime can be collapsed back to one with the flag.

## [2026-07-16] v0.4.0: Context Ledger pattern for checkpoint storage

**变更前**：No checkpoint mechanism existed. Long sessions relied on the full conversation being passed to each `invoke`, eventually exceeding the model's context window.

**变更后**：Checkpoint entries are structured JSON records (task, decisions, files_changed, interfaces, open_threads) stored in a `checkpoints` SQLite table with FTS5 index. Each entry is ~300 tokens. On resume, the most recent entries are rendered into a compact session brief injected as `system_prompt_appendix`.

**原因**：Research into production coding-agent continuity patterns identified "Context Ledger" (structured entries at semantic boundaries + retrievable pointers) as the highest-leverage approach. Unlike prose summarization (lossy, compounds errors across cycles), structured entries are compact and lossless — each entry captures what matters without degrading through repeated summarization.

**影响范围**：`lib/par_code_checkpoint.ml` (new, 328 lines), `test/test_par_code_checkpoint.ml` (new, 15 tests), `lib/par_code_memory.ml` (+raw_db accessor).

**回退方式**：Delete the `checkpoints` table and checkpoint module. The `checkpoints_fts` virtual table and triggers are safe to drop. No data dependency exists on checkpoint entries — they are pure additions to the session state.

**已知限制**：Each checkpoint is a full snapshot (no delta/incremental). FTS5 search is keyword-based (no semantic search yet). Delta checkpoints and embedding-based retrieval are deferred to v0.5.0+.

## [2026-07-16] v0.4.0: Budgeted context injection (chars/4 heuristic)

**变更前**：The full conversation was passed to every `invoke` call. No token budget checking. Long sessions would eventually hit the model's context window limit, causing truncated or failed calls.

**变更后**：Before each `invoke`, `Par_code_context.token_estimate` computes a rough token count (total chars / 4). If over `context_budget_tokens` (default 100000), older messages are replaced with a single summary message (from the most recent checkpoint) while the last 8 messages are kept verbatim. A notice is printed to stderr.

**原因**：A real tokenizer (per-model token tables, BPE-style) would add an external dependency and per-model tables. The chars/4 heuristic is deliberately conservative (over-estimates → compacts early) and sufficient for a v0.4.0 MVP. The PAR SDK's internal `context_strategy = Summarize` handles within-turn trimming; this par-code-level budgeting controls what reaches PAR in the first place.

**影响范围**：`lib/par_code_context.ml` (new, 99 lines), `lib/par_code_repl.ml` (budget check before invoke).

**回退方式**：Set `context_budget_tokens` to a very large value (e.g., 999999) in config. Compaction never triggers.

**已知限制**：±20% accuracy (chars/4 heuristic). A real tokenizer can replace this in v0.5.0+ without API changes — the `token_estimate` function signature stays the same.

## [2026-07-16] v0.4.0: Periodic mid-session memory extraction

**变更前**：Memory extraction ran only at session exit (synchronous, blocking the user for 2-5 seconds). Facts discovered during a long session weren't available as memories until the session ended.

**变更后**：The checkpoint cycle (every N turns) also triggers memory extraction via the checkpoint Runtime (`ckpt_rt`). Facts appear in the memory index mid-session. Exit-time extraction remains as a safety net (synchronous, unchanged from v0.3.1).

**原因**：The `fork_invoke` deferred item from v0.3.3 (DECISIONS.md [2026-07-11]) is consumed: the separate checkpoint Runtime provides the isolation that `fork_invoke` was meant to enable. Mid-session extraction makes long sessions more productive — the agent can recall facts it discovered earlier in the same session.

**影响范围**：`lib/par_code_checkpoint.ml` (calls `run_extraction` after storing checkpoint), `lib/par_code_repl.ml` (checkpoint cycle triggers both checkpoint + extraction).

**回退方式**：Disable checkpointing via `PAR_NO_CHECKPOINT=1`. Exit-time extraction still runs (v0.3.1 behavior).

**已知限制**：Extraction runs synchronously on `ckpt_rt` (~2-5s every N turns). True background fiber execution is a future enhancement. The `ckpt_rt`'s `invoke_generate` auto-save is a no-op (by design), so extracted conversations don't pollute the DB.

## [2026-07-15] v0.3.3 shipped — PAR SDK 0.7.3 + hybrid memory search

**变更前**：v0.3.2 shipped (Linux arm64). v0.3.3 unreleased with 6 commits on main: PAR SDK 0.7.3 consumption (per-turn memory injection, skill-workaround removed), `Sqlite_memory` storage migration (memory IDs int → UUID, schema auto-migrated from v0.3.0–v0.3.2), embedding API configuration (independent embedding provider), hybrid search infrastructure (FTS5 + vec0 + RRF), UX fixes (Ctrl-C saves session, config fallback), and doc sync.

**变更后**：v0.3.3 shipped. Version bumped to 0.3.3 in `dune-project`, `par_code.opam`, and `test/test_par_code.ml`. Tag `v0.3.3` pushed; Release workflow built Linux x64 + Linux arm64 + macOS arm64 binaries successfully (all 4 jobs green); GitHub Release published. README/CHANGES/STRATEGY synced to shipped state.

**原因**：The 6 unreleased commits formed a closed architectural-cleanup loop (consume PAR SDK 0.7.3 + standardize memory storage on PAR SDK `Sqlite_memory`). Holding them unshipped would defer the hybrid-search infrastructure value and inflate v0.4.0 into a large release. Shipping now clears the deck for v0.4.0 (long-session continuity: checkpoint-writer + `fork_invoke` background extraction).

**影响范围**：Release commit (`dune-project`, `par_code.opam`, `test/test_par_code.ml`) + doc-sync commit (`README.md`, `CHANGES.md`, `docs/STRATEGY.md`, `docs/DECISIONS.md`). No code changes in either commit. Users: `curl install.sh | bash` now installs v0.3.3; existing users get offered the upgrade via the startup version check.

**回退方式**：Git tag and GitHub Release are permanent (users may have already installed v0.3.3). Code state can be reverted via `git revert <release-sha>`. **Memory schema migration is NOT reversible** — v0.3.3's `Sqlite_memory` migration drops old tables after reading; users upgrading from v0.3.0–v0.3.2 should have exported memories first (`par memory export > backup.md`). See [2026-07-11] migration decision for details.

**已知限制**：(1) CI workflow's `ubuntu-24.04-arm` job failed during release due to a transient GitHub ARM-runner network issue (`ports.ubuntu.com` unreachable — IPv6 "Network is unreachable", IPv4 timeout); re-run separately. The Release workflow (Docker-based, AlmaLinux 8) was unaffected and produced correct arm64 artifacts. (2) vec0 extension availability varies by platform; degrades gracefully to FTS5-only when absent.

## [2026-07-11] v0.3.3: migrate memory storage to PAR SDK Sqlite_memory

**变更前**：par-code used a custom `Par_code_memory` module with its own schema (`id INTEGER PK`, `kind TEXT`, `citations TEXT`, `project_id TEXT`) and FTS5 keyword search only.

**变更后**：Storage layer delegated to PAR SDK 0.7.3 `Sqlite_memory`. Memory CRUD uses `Sqlite_memory.add/search/delete`; par-code-specific features (kind-grouped `render_index`, `export_markdown`, `prune_stale`, `search_history` via `conversations_fts`) kept as raw SQL wrappers. Memory IDs changed from `int` to UUID strings (`ext_id`). Old v0.3.0–v0.3.2 schema auto-migrated on first `open_db` (detects `kind` column, reads data, drops old tables, re-inserts preserving timestamps and usage stats).

**原因**：PAR SDK 0.7.3 shipped `Sqlite_memory` with FTS5 + vec0 vector search + RRF hybrid search (need #4). Migration enables future semantic search capabilities. par-code's custom schema is replaced by PAR SDK's standard schema (`ext_id`, `scope`, `metadata`, `categories`), reducing maintenance burden.

**影响范围**：`lib/par_code_memory.ml` (full rewrite), `lib/par_code_memory.mli` (id: int→string), `lib/par_code_memory_tools.ml` (id serialization), `lib/par_code_extractor.ml` (dedup type), `bin/main.ml` (CLI format strings), `bin/cli_args.ml` (id arg: int→string), `lib/dune` (+par.memory dependency), `test/test_par_code_memory.ml` (adapted for new types).

**回退方式**：Revert to old `Par_code_memory` module. The migration drops old tables after reading, so old data is lost without backup. Users upgrading to v0.3.3 should export memories first (`par memory export > backup.md`) if they want a safety net.

**已知限制**：vec0 扩展在极少数环境下可能不可用（自动降级为 FTS5 关键词搜索）。Embedding API 可通过 `par config` 单独配置（`embedding_base_url`、`embedding_model`、`embedding_dimension`），支持聊天和 embedding 使用不同 provider。

## [2026-07-11] Deferred: fork_invoke for background extraction (target v0.4.0)

**变更前**：Memory extraction runs synchronously at session exit, blocking the user for 2-5 seconds while the extractor agent runs one LLM call. No extraction happens during the session.

**变更后**（计划）：Use PAR SDK 0.7.3 `fork_invoke` to run extraction in a background fiber. User exits immediately; extraction completes asynchronously. Additionally, periodic mid-session extraction (every N turns) becomes possible.

**原因**：PAR SDK 0.7.3 shipped `fork_invoke` + `invoke_async` + fiber-local `invoke_context` (need #3). par-code's current synchronous-at-exit approach was a workaround for PAR SDK's lack of safe concurrent invoke.

**归属**：v0.4.0（长会话连续性）。fork_invoke 是 v0.4.0 checkpoint-writer subagent 的实现基础——后台提取只是顺手做的事，主线是"长时间会话不掉链子"。不单独版本化。

**已知限制**：PAR SDK `rt.current_conversation` 仍是共享可变状态，两个并发 invoke 会 race。使用时必须显式传 `?conversation`，且只在用户侧 invoke 上调 `save_conversation`，后台 invoke 不碰 `current_conversation`。

**回退方式**：维持现状（同步退出时提取），不影响功能。

## [2026-07-11] Deferred: migrate to PAR SDK Sqlite_memory for vector/hybrid search (独立基建版本)

> **Consumed [2026-07-11]**: Migration completed in v0.3.3. See [2026-07-11] v0.3.3 decision above. Embedding wiring deferred.

**变更前**：par-code 使用自建的 `Par_code_memory` 模块，仅支持 FTS5 关键词搜索。记忆检索依赖词面匹配——用户问"认证"搜不到写着"auth"的记忆。

**变更后**（计划）：迁移存储层到 PAR SDK 0.7.3 的 `Sqlite_memory`，获得 vec0 向量搜索 + RRF 混合搜索能力。记忆检索从关键词匹配升级为语义搜索。

**原因**：PAR SDK 0.7.3 shipped `Par.Memory` module (`Sqlite_memory`) with FTS5 + vec0 + RRF (need #4)。par-code 的 `Par_code_memory` 已验证模式可行，上游化是 STRATEGY.md §2 双角色职责。

**归属**：独立基建版本（v0.3.3 或 v0.4.0 与 v0.5.0 之间）。不绑定特定功能版本——它是存储层升级，用户面感知是"搜记忆更准了"。

**迁移要点**：
- `kind` (Preference/Convention/...) → `categories: ["preference"]`
- `project_id` → `scope: project_id`
- `citations` → `metadata: [("citations", `List [...])]`
- 保留 par-code 专有功能作为 wrapper：`render_index`（kind-grouped）、`export_markdown`、`prune_stale`、`search_history`（conversations_fts，PAR SDK 的 builtin 版本更弱）
- 需写 `Memory_service.memory_service` → `Types.memory_service` 类型适配器

**回退方式**：维持现状（FTS5 关键词搜索），不影响功能。

## [2026-07-11] Consume PAR SDK 0.7.3: remove skill workaround + adopt per-turn memory injection

**变更前**：PAR SDK 0.6.9 had two gaps: (1) Auto-trigger skills silently replaced the agent system prompt via `system_prompt_override`; par-code worked around this by downgrading Auto→Manual before registration. (2) `Runtime.make_agent` took `system_prompt` once at registration; par-code baked the memory index into the system prompt at session start (static for the entire session).

**变更后**：(1) Workaround removed — PAR SDK 0.7.3 strips `system_prompt_override = None` for Auto-trigger skills in `compute_active_skill_effects` (commit 344bef7). Builtin skills now register as-is. (2) Memory index is injected per-turn via `?system_prompt_appendix` parameter on `Runtime.invoke` — fresh on every turn, reflecting mid-session memory additions immediately.

**原因**：PAR SDK 0.7.3 shipped all four needs par-code raised (#1 Auto-skill fix, #2 per-turn system prompt, #3 fork_invoke, #4 Par.Memory). This change consumes #1 and #2 — the highest-value, lowest-risk improvements. #3 (background extraction) and #4 (Sqlite_memory migration) deferred to future versions.

**影响范围**：`dune-project` (par >= 0.7.3), `lib/par_code_setup.ml` (remove workaround + simplify system_prompt + pass mem_db to callback), `lib/par_code_repl.ml` (build_memory_appendix + ?system_prompt_appendix on invoke), `bin/main.ml` (pass mem_db through callback), `lib/par_code_setup.ml` make_persistence_service (forward ?scope parameter added in 0.7.3).

**回退方式**：Revert to PAR SDK 0.6.9 constraint, restore Auto→Manual workaround, restore static memory baking. But this loses per-turn memory freshness and requires maintaining the workaround.

**已知限制**：Memory index rendering runs once per turn (fast indexed query, <1ms). `fork_invoke` (#3) and `Sqlite_memory` migration (#4) not yet consumed — tracked for v0.4.0+.

## [2026-07-09] Auto-trigger skills downgraded to Manual (system_prompt_override fix)

> **Superseded [2026-07-11]**: PAR SDK 0.7.3 strips system_prompt_override for Auto skills. Workaround removed. See [2026-07-11] decision above.

**变更前**：par-code registered all PAR SDK builtin skills as-is. The `summarizer` and `rag-assistant` skills have `trigger=Auto` + `system_prompt_override=Some(Stable_prompt ...)`, causing them to activate on every turn and replace the agent's system prompt entirely via `apply_skill_effect_to_config` (PAR SDK `runtime.ml:406`).

**变更后**：Skills with `trigger=Auto` are downgraded to `trigger=Manual` before registration. The skills remain available for explicit activation but no longer auto-activate and clobber the system prompt.

**原因**：A user test session with a third-party LLM provider revealed the model responding as "expert summarizer" instead of the coding agent identity. Root cause: the summarizer skill's `Stable_prompt` override completely replaced par-code's `"You are par, an interactive coding assistant..."` system prompt on every turn. The model literally received the skill's override text as its system prompt.

**影响范围**：`lib/par_code_setup.ml` (skill registration — `List.map` downgrade before `register_skill`).

**回退方式**：Remove the `List.map` filter; register `Builtin_skills.builtin_skills` directly.

**已知限制**：`summarizer` and `rag-assistant` now require explicit user activation (Manual trigger). PAR SDK should fix the root cause: `trigger=Auto` skills should not carry `system_prompt_override`. Tracked as PAR SDK feedback item.

## [2026-07-09] SIGINT handler saves conversation before exit

**变更前**：Ctrl-C (SIGINT) killed the process immediately with no cleanup. Conversations from interrupted sessions were never persisted, making them invisible to `search_history`.

**变更后**：A `Sys.set_signal Sys.sigint` handler in the REPL calls `save_conversation` + `maybe_extract` before `exit 130`.

**原因**：User test session showed `search_history` returning 0 results after the previous session was terminated with Ctrl-C. The REPL had handlers for Ctrl-D (EOF) and `/quit` but none for SIGINT — the process died before `save_conversation` could run.

**影响范围**：`lib/par_code_repl.ml` (signal handler in `run`).

**回退方式**：Remove the `Sys.set_signal` call.

**已知限制**：If SIGINT arrives mid-stream during an LLM response, the conversation is saved in a potentially incomplete state. Acceptable — partial history is better than no history.

## [2026-07-09] system_prompt falls back to default when missing from config

**变更前**：`of_json`'s `get_s` returned `""` for missing string fields with no fallback. If `system_prompt` was absent from `config.json`, it silently became empty — unlike `temperature`/`max_iterations` which had explicit defaults.

**变更后**：`system_prompt` falls back to `default.system_prompt` when the field is empty or absent.

**原因**：Inconsistency with other config fields that had defaults. An empty `system_prompt` would cause `Runtime.make_agent` validation failure (`runtime.ml:115`) with a confusing error message.

**影响范围**：`lib/par_code_config.ml` (`of_json` function).

**回退方式**：Revert to `get_s "system_prompt"` without fallback.

**已知限制**：Only `system_prompt` has the fallback. Other string fields (`provider`, `api_key`, `model`, `persistence`) still return `""` for missing fields — correct behavior, as these must be explicitly set.

## [2026-07-06] v0.3.2: Linux arm64 pre-built binary via native ARM runner

**变更前**：Pre-built binaries only for Linux x86_64 and macOS arm64. ARM Linux users (Raspberry Pi, AWS Graviton) had to compile from source (~20-30 min on Pi).

**变更后**：Added `build-linux-arm64` CI job on GitHub's `ubuntu-24.04-arm` native ARM runner. Same AlmaLinux 8 Docker build base, same FTS5 sqlite3 amalgamation. install.sh and `par upgrade` recognize `aarch64`/`arm64`.

**原因**：User reported Raspberry Pi compilation pain. GitHub opened free ARM runners for public repos (2025). Same Dockerfile works for both architectures (architecture-aware opam download + tarball naming via `uname -m`). No cross-compilation complexity.

**影响范围**：release.yml (new job), Dockerfile (architecture-aware), install.sh (arm64 detection), par_code_upgrade.ml (arm64 platform), README platform table.

**回退方式**：Remove `build-linux-arm64` job from release.yml. ARM users fall back to source compilation.

**已知限制**：Alpine Linux (musl) still unsupported — static musl binary is a separate stretch goal.

## [2026-07-06] Auto-extraction at session exit (not background)

**变更前**：No auto-extraction. Memories only written via explicit `remember_memory` tool or `par memory add` CLI.

**变更后**：After REPL session exit, an extractor agent reads the transcript and writes salient memories.

**原因**：PAR SDK cannot safely run parallel/background agents (shared mutable state `current_conversation` corrupts on reentrant `invoke`). Synchronous extraction at exit avoids all concurrency issues. Cost: one LLM call (~2-5s) at exit, acceptable.

**影响范围**：lib/par_code_extractor.ml (NEW), lib/par_code_repl.ml (exit trigger), lib/par_code_setup.ml (extractor agent registration).

**回退方式**：Set PAR_NO_AUTO_EXTRACT=1 or auto_extract:false. Background extraction deferred to v0.3.2+ pending PAR SDK invoke_async support.

**已知限制**：Extraction runs once per session (at exit), not per-turn. No background extraction during active session.

## [2026-07-06] History search via FTS5 on raw messages_json

**变更前**：No way to search past session transcripts. Users had to manually resume individual sessions.

**变更后**：FTS5 virtual table `conversations_fts` indexes the `messages_json` column of the existing `conversations` table. `search_history` agent tool + `par memory search-history` CLI provide FTS5 BM25 search with snippet highlighting.

**原因**：FTS5 is already available (bundled sqlite3 with v0.3.0). Indexing raw JSON is pragmatic — JSON syntax noise dilutes BM25 ranking slightly, but `snippet()` extracts relevant fragments. A flattened text column would improve quality but needs a PAR SDK schema change (conversations table is created by Sqlite_persistence).

**影响范围**：lib/par_code_memory.ml (conversations_fts schema + search_history), lib/par_code_memory_tools.ml (search_history tool), bin/main.ml (CLI command).

**回退方式**：N/A (additive feature).

**已知限制**：History search is global, not project-scoped (conversations table lacks project_id column). FTS5 over JSON has minor quality degradation vs flattened text.

## [2026-07-06] v0.2.2 deferred; v0.3.0 prioritized

**变更前**：Roadmap had v0.2.2 (Windows native + code signing) as the next release after v0.2.1.

**变更后**：v0.2.2 deferred. v0.3.0 (project memory) is now the active development target.

**原因**：Research revealed the PAR SDK dependency stack cannot build on Windows today — `Eio.Process` (needed by PAR's MCP stdio transport and bash tool) is unimplemented on Windows (`failwith "process operations not supported on Windows yet"`). Shipping a Windows binary that crashes on first process spawn would be a scope compromise disguised as architecture (R1 violation). Code signing alone (without Windows) was too thin to justify a release.

**影响范围**：README roadmap table, STRATEGY.md §8 Roadmap Posture, release pipeline (no Windows CI job added).

**回退方式**：When eio upstream ships `Eio.Process` for Windows, re-scope v0.2.2 with Windows native + signing.

**已知限制**：Windows users must use WSL in the meantime.

## [2026-07-06] v0.3.0 memory architecture: SQLite+FTS5 over filesystem

**变更前**：No memory layer existed. Public reference projects in the same category use filesystem-based memory (markdown files + LLM-as-retriever).

**变更后**：SQLite-backed memory with FTS5 virtual table + BM25 ranking, per-project scoping. DB is source of truth; `MEMORY.md` is auto-generated export only.

**原因**：par-code is SQLite-native (par.db already exists, sqlite3-ocaml is a hard dep, pre-built binary bundles libsqlite3). FTS5 gives transactional writes + search for free. Filesystem-based memory would require parsing markdown back to structured data and loses transactional guarantees. Diverges from public reference projects' filesystem choice, which was driven by their runtime constraints, not a principled DB aversion.

**影响范围**：New module `lib/par_code_memory.ml`, new tools (`recall_memory`, `remember_memory`), new CLI subcommand group (`par memory`).

**回退方式**：N/A (new feature, no prior state to revert to).

**已知限制**：FTS5 unicode61 tokenizer is suboptimal for CJK (Chinese/Japanese/Korean) text — treats codepoints as individual tokens. Acceptable for v0.3.0 (most memories are English or mixed); revisit in v0.3.1+ if CJK recall quality is poor.

## [2026-07-06] v0.3.0 memory storage: shared par.db via PAR SDK accessor

**变更前**：PAR SDK's `Sqlite_persistence.t` was opaque — no way for downstream apps to add tables.

**变更后**：PAR SDK 0.6.9 adds `val raw_sqlite3_db : t -> Sqlite3.db` (1-line accessor). par-code opens a second connection to the same `~/.par/par.db` with WAL mode for memory tables.

**原因**：Per STRATEGY.md §2 dual-role mandate, when par-code finds a PAR limitation, the first response is to fix PAR. The accessor is read-only and trivially correct. Opening a separate `memory.db` was the fallback (Path C) if PAR didn't ship the accessor.

**影响范围**：PAR SDK 0.6.9 (new `raw_sqlite3_db` in `sqlite_persistence.mli`); par-code `lib/par_code_memory.ml` (opens same DB file, WAL mode).

**回退方式**：If the accessor causes issues, switch to separate `~/.par/memory.db` (Path C). Migration: copy memory tables to new DB, point `open_db` at the new path.

**已知限制**：Two connections to the same SQLite file requires WAL mode (enabled by `open_db`). If PAR SDK later switches away from SQLite, memory tables need migration.

## [2026-07-06] MEMORY.md as auto-generated export, not source of truth

**变更前**：Public reference projects treat their memory file (various naming conventions) as the source of truth — agent reads and writes it directly.

**变更后**：par-code's DB is the source of truth. `par memory export` generates a read-only `MEMORY.md` for human consumption / git commit. par-code never reads `MEMORY.md` back.

**原因**：DB-first gives transactional writes, FTS5 search, usage tracking, and per-project scoping for free. Filesystem-first would require parsing markdown back to structured data, which is fragile and loses these guarantees.

**影响范围**：`par memory export` command, README "Project Memory" section (documents the export-only contract).

**回退方式**：N/A (design decision, not a regression).

**已知限制**：If a user edits the exported `MEMORY.md` by hand, those edits are lost on the next export. Documented in the export command output.

## [2026-07-02] Founding: par-code as a PAR-SDK coding agent

**变更前**：—（新项目）

**变更后**：初始化 `par-code` —— 基于 PAR (Programmable Agent Runtime) SDK 的
交互式编码 Agent，同时作为 PAR 项目的实战验证案例。

**原因**：
- 充分利用 PAR SDK 的全部能力（ReAct、工具分发、类型安全 bash、MCP、skills、
  workflow、流式），从 coding 视角验证 PAR 成熟度。
- 继承 PAR 的 CLI 约定（cmdliner、bin/ 布局），保持 flag 兼容。

**关键决策**（经与用户确认）：
1. **集成路径**：OCaml 原生 SDK（`opam pin add par`），而非 Python binding 或包装 CLI
   二进制 —— 真正继承 PAR 的 OCaml CLI 代码，验证面最广。
2. **Agent 形态**：交互式编码助手（类主流编码 agent 终端 REPL）。
3. **MVP 范围**：v0.1.0 仅项目骨架 + README，不含 agent 逻辑。
4. **许可**：Apache-2.0（含专利授权，区别于 PAR 的 MIT）。
5. **仓库名**：`jcz2020/par-code`（公开）。

**影响范围**：整个仓库（dune 工程、bin/、lib/、test/、文档、CI）。

**回退方式**：删除仓库 / `git reset --hard`（初始 commit 前）。

**已知限制**：
- PAR 尚未发布到公开 opam 仓库，需 `opam pin add par https://github.com/jcz2020/par.git`。
- GitHub Actions（`.github/workflows/ci.yml`）已推送（gh token 已补 `workflow` scope）。

## [2026-07-02] Architecture: scheme-C bootstrap layer

**变更前**：par-code 依赖 PAR 的 `par_cli` 可执行包提供 bootstrap 能力
（配置解析、CLI 参数、启动流程）。

**变更后**：par-code 在 `lib/` 中实现自己的内部 bootstrap 层（Par_code_setup,
Par_code_config, Par_code_repl），不依赖 `par_cli`。

**原因**：`par_cli` 是可执行包（executable package），OCaml 的 dune 构建系统
不允许库链接可执行包。要使用 `par_cli` 的 bootstrap 能力，必须 fork 或重写，
而非直接依赖。因此选择自建轻量 bootstrap 层，通过 PAR SDK 的库接口（而非 CLI
接口）驱动 agent 循环。

**影响范围**：
- `lib/`：新增 Par_code_setup、Par_code_config、Par_code_repl 三个模块。
- `bin/`：仅负责命令行参数解析和调用 lib/ 层。
- 构建：`par_code` 库不再尝试链接 `par_cli`。
- 用户体验：配置路径 `~/.par/config.json`。

**回退方式**：若 PAR 未来暴露 bootstrap 库（library），可将三个模块迁移至
该库的 wrapper，现有 API 不受影响。

**已知限制**：
- 与 PAR 的 CLI flag 定义存在重复维护成本（PAR 升级 CLI 时需同步检查）。
- 配置路径与 PAR 分离，用户需分别管理两套配置。

## Roadmap（2026-07-02 经源码核查后确认）

> 先对 PAR 与对齐目标做了双侧源码逐条核查（PAR 9 大能力全部真实；目标 9 个招牌
> 特性全部实打实实现、非 stub；PAR 在记忆/上下文整块为零覆盖）。据此重定路线图。

每版交付**一个**用户可感知的核心功能（垂直薄片，做完即可演示）；版本号最小递增，
核心能力对齐前不升 1.0。

- **v0.1.0** ✅ 项目骨架（链接 PAR SDK，`par --version` 可用）。
- **v0.2.0** 能用：交互编码 agent（REPL + provider 配置 + read/write/edit/grep/find/bash + 流式 + 会话持久）。
- **v0.3.0** 记得住：项目记忆（MEMORY.md + FTS5 全文检索 + memory/history 工具）。
- **v0.4.0** 长程不断线：checkpoint-writer 子 agent + 预算式上下文注入 + 上下文重建（最硬一役，PAR 零覆盖块）。
- **v0.5.0** 先想后做：plan 模式（只读）+ build/plan 切换 + plan_enter/plan_exit。
- **v0.6.0** 会分身：general/explore 子 agent + actor 工具 + 任务树。
- **v0.7.0** 干到底：/goal + 独立 judge 模型 + doom_loop 检测。
- **v0.8.0** 择优：max-mode（N 路并行候选 + judge 选取）。
- **v0.9.0** 会自学：/dream + /distill + 自定义 slash 命令系统。
- **v0.10.0** 全流程编排：compose 模式 + 内置 plan/execute/review/tdd/debug/verify/merge skill。
- **v0.11.0** 连万物：MCP OAuth + 热重载 + 多源 skill（远程 URL/.claude/.agents 等）。
- **v0.12.0** 懂代码：LSP 集成（诊断/跳定义/引用/调用层级）+ lsp 工具。
- **v0.13.0** 安全可控：权限规则集（allow/ask/deny + 持久批准）+ 文件快照/undo。
- **v0.14.0** 好用好看：富 TUI（流式渲染 + 内联权限提示 + i18n）。
- **v1.0.0** 核心能力对齐里程碑（v0.2–v0.14 齐备 + 稳定化）。
- **1.x** 扩展轨（按需）：语音输入/控制、插件系统、codesearch、notebook_edit、apply_patch、LSP rename。

**排序原则**：先能用再出彩（0.2 地基）；招牌优先且难度爬坡（0.3–0.4 直接上记忆/长程
零覆盖块；0.5–0.8 自主性爬坡；0.9–0.10 自进化+编排）；安全/UX 收口（0.13–0.14 兜底 1.0）。

## [2026-07-02] 路线插入 v0.2.1：一键安装 + 自更新

> ⚠️ **范围已修订** — 本条的签名策略、Windows 处理、target 数量已被下一条
> `[2026-07-02] v0.2.1 范围修订` 更新（v0.2.1 改为 Linux+macOS only，Windows
> 整体推 v0.2.2，bundle C 库，CentOS 7 build base）。以下原文保留作历史审计；
> **实施时以下一条为准**。

**变更前**：v0.2.0 之后直接进 v0.3.0（项目记忆）。用户安装 par-code 必须先装
OCaml + opam，再 `opam pin add par`（源码编译 PAR SDK），再装 par-code。这是当前
最大的上手门槛。

**变更后**：在 v0.2.0 ✅ 与 v0.3.0 之间插入 **v0.2.1**——一键安装与自更新版本。
三大支柱：

1. **预编译二进制分发**（GitHub Releases，覆盖 linux-x64 / linux-x64-musl /
   darwin-arm64 / darwin-x64 / windows-x64 五个 target）。用户**无需**安装
   OCaml/opam/PAR 源码。opam 源码 pin 路径降级为"开发者路径"，仍保留。
2. **一键安装脚本**：`scripts/install.sh`（POSIX sh，Linux+macOS）和
   `scripts/install.ps1`（PowerShell 5.1+，Windows）。检测平台 → 下载对应包 →
   SHA256 校验 → 解压到 `~/.par/bin/` → 提示 PATH。
3. **内置 `par upgrade` 子命令**：自更新，不依赖系统包管理器。`--check` /
   `--to <ver>` / `--uninstall`。启动时后台版本检查（24h 缓存 + ETag，
   `PAR_NO_UPDATE_CHECK=1` 可关）。

**原因**：
- 当前安装链路（装 OCaml → 装 opam → pin PAR 源码 → 装 par-code）是用户上手最大
  阻力。业界公开参考实现（同类编码 agent CLI）**无一**强制用户装编译器工具链；
  全部走预编译二进制 + 安装脚本。par-code 必须对齐这一基线，否则 v0.3.0+ 的能力
  再强也没有用户量基础。
- "以后哪怕迭代再多次也能用"——CI 在 tag 推送时自动产出三平台二进制 + 校验文件 +
  版本清单，零人工介入；`par upgrade` 让用户不依赖任何包管理器即可升级。
- 插入 v0.2.1（而非把它塞进 v0.3.0）的原因：v0.3.0（项目记忆）已经是一个完整
  能力，再叠加分发系统会让 v0.3.0 范围过大；分发是独立垂直薄片，值得独占一个版本。

**签名策略（R1/R2 标注）**：

| 平台 | v0.2.1 决策 | 性质 | R1/R2 标注 |
|---|---|---|---|
| macOS | **不签名** | 架构正确 | **R1 = 架构正确**：CLI 经 `curl\|bash` 装到 `~/.par/bin/`，不经过 Gatekeeper（Gatekeeper 只拦 `.app` bundle 和带 quarantine 属性的浏览器下载）。业界公开参考项目的 macOS CLI 同样不签名，理由相同。**不是妥协，是判断**。可能永远不签（除非未来出 Desktop GUI）。 |
| Windows | **v0.2.1 不签，v0.2.2 签** | 范围妥协 | **R1 = 范围妥协**：未签名 Windows 二进制会触发 Defender 误报和 SmartScreen 警告（参考项目 issue 已实证），是真实 UX 问题。v0.2.1 不签**仅因为**云代码签名服务账户审核需 1-3 个工作日，会阻塞 v0.2.1 发布节奏。**R2 退役条件**：v0.2.2 发布签名版 Windows 二进制时，README 的"SmartScreen 绕过指南"同步删除，未签名状态正式退役。 |
| Linux | N/A | — | 无签名概念。 |

**R3（一次做对 vs 分两步）评估**：理想态是 v0.2.1 直接签 Windows。分两步合法，因
满足 R3 分步条件中的 (b) 依赖未完成的上游（签名账户审核）+ (c) 需未知技术验证
（云签名服务集成）+ (d) 用户明确指示。第 1 步（v0.2.1）已为第 2 步铺路：README
明确警告 + 本决策记录 + 退役条件齐备。

**R4 自问**：抛开开发周期，只看用户长远体验，v0.2.1 不签 Windows 还成立吗？答：
不签是**短期阵痛**（用户读一段绕过指南），换来的是 v0.2.1 能立即发布 + Windows
原生构建 spike 也能在 v0.2.1 周期内验证。若强行等签名账户下来再发，会让 Linux/
macOS 用户也陪等。分两步是主动提议，不是被动妥协。

**影响范围**：
- 路线图：README 路线表插入 v0.2.1 行；v0.3.0 及之后所有版本号顺延（实质上不变，
  仅 v0.2.x 段多一个版本）。
- 新增目录：`scripts/`（install.sh / install.ps1）。
- 新增 CI：`.github/workflows/release.yml`；`.github/workflows/ci.yml` 矩阵加
  `windows-2022`。
- 新增 lib 模块：`lib/par_code_upgrade.ml` + `.mli`。
- 改动：`bin/cli_args.ml` + `bin/main.ml`（加 `par upgrade` 子命令）。
- 文档：README 安装章节重写；CHANGES.md 在发布时加 v0.2.1-dev 段。
- 不影响：v0.2.0 现有功能（REPL/config/ask/persistence）冻结不动；`par_code.opam`
  作为开发者路径保留。

**回退方式**：
- 整个 v0.2.1 范围可逆：删除 `scripts/`、`release.yml`、`par_code_upgrade.ml`，
  还原 README/DECISIONS/CHANGES，路线表回到 v0.2.0 → v0.3.0 直连。
- Windows 原生构建若 spike 失败：Windows 在 v0.2.1 降级为 WSL 安装路径（install.ps1
  检测/安装 WSL 后跑 Linux 二进制），原生 Windows 推到 v0.2.2。spike 结果记录在
  本文件追加段落。

**已知限制**：
- **Windows 原生构建未验证**：OCaml + `eio` + `sqlite3` + `mirage-crypto-rng` 在
  `windows-2022` runner 上能否干净编译是 v0.2.1 启动时的第一个 spike 任务。
- **二进制大小未知**：静态/动态链接 PAR + sqlite3 + crypto 后的体积待首次 release
  实测。若 >50MB，v0.2.2 立项瘦身任务。
- **未签名 Windows 体验差**：v0.2.1 用户首次运行会看到 SmartScreen 警告，README
  需明确指引绕过（"More info" → "Run anyway"）。
- **arm64 Linux / arm64 Windows / baseline 变体不在 v0.2.1**：v0.2.1 只覆盖 4 个
  高流量 target（含 musl），arm 系列推到 v0.2.3+。
- **GitHub API 速率限制**：匿名 60 次/小时。`par upgrade --check` 必须用 ETag 条件
  请求（304 不计数）+ 24h 本地缓存。
- **首页安装 URL 待定**：install 脚本的 canonical URL（是 github.io / 自定义域 /
  GitHub Releases raw）在 v0.2.1 实施期决定。

**详细实施计划**：`.sisyphus/plans/v0.2.1.md`。

## [2026-07-02] v0.2.1 范围修订：Linux + macOS only，Windows 整体推 v0.2.2

**变更前**：v0.2.1 立项范围是"Linux + macOS + Windows 三平台一键安装 + 自更新"。Windows v0.2.1
不签名、签名推 v0.2.2；macOS 不签名（架构正确）；分发产物 5 个 target（linux-x64 / linux-x64-musl /
darwin-arm64 / darwin-x64 / windows-x64）。原 plan 在 `.sisyphus/plans/v0.2.1.md`（commit
`acbc469`）。

**变更后**：基于两份独立评审（plan 严苛性评审 + 架构评审）发现 4 个 BLOCKER 级工程根因，**v0.2.1
范围收缩**：

1. **平台收缩**：v0.2.1 只发 **Linux (x86_64, glibc ≥ 2.17) + macOS (arm64)** 两个 target。
   Windows（含签名）整体推到 **v0.2.2**。darwin-x64（Intel Mac）由"arm64 binary 走 Rosetta"覆盖；
   native x64 推到 v0.2.2 决策（universal lipo vs 永久 Rosetta-only）。linux-x64-musl 推到 v0.2.3
   且要求 musl-**static**（动态 musl 只在 Alpine 能跑，几乎零价值，已从范围移除）。

2. **C 库打包**（新增 IN）：v0.2.1 **bundle** `libsqlite3.so.0` + `libgmp.so.10`（Linux）/对应
   `.dylib`（macOS）到 tarball/zip，与 `par` 同目录，RPATH 设 `$ORIGIN`（Linux）/
   `@loader_path`（macOS）。**这一步同时是 v0.3.0 FTS5 的硬前置**（FTS5 是 sqlite3 编译期扩展；
   若 v0.2.1 走 system sqlite，v0.3.0 必须强制用户换 FTS5-enabled libsqlite3——跨发行版不可行）。
   典型"一次做对"原则（R3）应用：现在 bundle = v0.3.0 只重编 bundled sqlite，不是分发革命。

3. **Linux 构建 base 改为 CentOS 7**（glibc 2.17，manylinux 标准）：用 `container: centos:7`
   在 GitHub Actions 里跑。Ubuntu 22.04（glibc 2.35）构建的产物在 Ubuntu 20.04 / Debian 11 /
   RHEL 8 上跑不起来——评审指出原 plan 的 verification #1 只测 ubuntu:22.04 = 自测自。

4. **`par upgrade` 加 post-swap smoke test + rollback**：原 plan 直接 atomic replace，新版本
   启动 crash 无回滚。修订后：replace 后 fork 子进程跑 `par --version`（3s 超时），exit≠0 则
   reverse-swap 回 `.old` 并报错。代价 ~20 行代码，救命的鲁棒性。

5. **新增 `lib/par_code_version.ml` 生成模块**：解决"`par upgrade --check` 怎么知道当前版本"
   的实现空白。dune 规则从 `dune-project` 的 `(version)` 字段生成 `let version = "..."`。

6. **完整性模型显式化**：v0.2.1 完整性 = HTTPS + checksum（**仅防传输损坏，不防 MITM**）。
   真正的对抗完整性（签名）随 v0.2.2 Windows 一起。README + 本文件明确措辞，避免用户误以为
   checksum 是安全保证。

7. **CI cache 策略明确**：三层 cache（`setup-ocaml` 内置 + dune `_build` + PAR source pin）
   把首次 release 从 ~30min 压到 ≤15min。

8. **启动版本检查是"purely additive"**：与 v0.2.0 "frozen" Non-Goal 修订——加一条 stderr 行、
   不阻塞、`PAR_NO_UPDATE_CHECK=1` 可关。v0.2.0 REPL/config/ask 行为不变。

**原因**（评审关键发现摘要）：
- **Windows 承诺与 fallback 矛盾**：原 plan 的 "Windows spike 失败 → WSL fallback" 是伪清晰——
  WSL 不是 Windows-native（装机率 <5%），等于 silently 砍 Windows 但 README 还写"Works on
  Windows"。诚实做法是显式声明 "v0.2.1 = Linux+macOS only"，Windows 整体推 v0.2.2。
- **Linux glibc 兼容性是 silent breakage**：ubuntu-22.04 build 在企业主流发行版（Ubuntu 20.04
  LTS、Debian 11、RHEL 8）上启动失败。必须用 CentOS 7（glibc 2.17）做 build base 才能覆盖
  "几乎所有 Linux"。
- **C 库不 bundle = 二进制跑不起来**：`libsqlite3.so.0` + `libgmp.so.10` 在 minimal 容器 / 企业
  Server 上不存在。bundle 是 standard practice（Haskell Stack / Rust sqlite3 crate / esy-packed
  都这么做）。
- **darwin-x64 构建机制未定**：GitHub 已退役 Intel runner（`macos-13` 退出倒计时），`macos-15`
  是 M1。产 x64 native 需双 build + lipo，复杂度不值得（Intel Mac 已 EOL，Rosetta 兼容 arm64）。
- **musl-dynamic 几乎零价值**：原 plan 的 musl tarball 描述为"动态链接 musl"——只在 Alpine 能
  跑，而 Alpine 用户 `apk add` 装依赖本就能用 glibc 版。真 musl 价值在 static linking，推到 v0.2.3。

**R3（一次做对 vs 分两步）评估**：
- Windows：理想态是 v0.2.1 直接三平台。分两步合法（R3 b/c/d 全满足：Windows 原生构建未验证、
  签名基础设施账户审核延迟、用户明确指示）。第 1 步（v0.2.1 Linux+macOS）已为第 2 步（v0.2.2
  Windows）铺路：release.yml 预留 Windows job slot、CI Docker 化方便后续加 Windows 容器、bundle
  策略对 Windows DLL 同样适用。
- darwin-x64：分两步合法（Rosetta 是合理桥接，非"以后再说"）。
- sqlite3 bundle：**不分两步**——R3 直接一次做对。v0.3.0 FTS5 是真实 landmine。
- musl-static：分两步合法（v0.2.3 独立任务，v0.2.1 不阻塞）。

**R4 自问**：抛开周期，只看用户长远体验，v0.2.1 砍 Windows 还成立吗？答：成立。Windows 半
承诺（unsigned + Defender 误报 + SmartScreen 拦截）比"v0.2.1 不发 Windows，README 明确说 v0.2.2
带签名一起"用户体验更差。砍掉换诚实，且把签名基础设施 + Windows 原生构建验证（spike）放
到 v0.2.2 周期里专心做。

**影响范围**：
- README 路线表：v0.2.1 描述改为"Linux + macOS"；新增 v0.2.2 行（Windows native + 签名 +
  darwin-x64）。
- `.sisyphus/plans/v0.2.1.md`：整体重写（279 行 → ~350 行）。新增：bundle C 库、CentOS 7
  Docker build、post-swap smoke test、Version.ml 生成、4-wave dependency graph（移除原 spike
  节点）、可执行 verification 21 条（含 disclosure grep 命令 + e2e upgrade 脚本 spec）、
  CI cache 策略。
- 不影响：v0.2.0 现有功能冻结不变（除 purely additive 启动 hook）。
- v0.2.2 范围扩大：原仅"Windows 签名"，现 + "Windows 原生二进制 + install.ps1 + darwin-x64"。
  v0.2.2 立项时第一动作仍是"Windows 原生构建 spike"。

**回退方式**：
- 本决策本身可逆：还原 README v0.2.1 行 + 删除本 DECISIONS 段，回到 commit `acbc469` 状态。
- v0.2.1 实施过程中若 CentOS 7 上 OCaml 5.2 编译失败（gcc 4.8 太老）：fallback 到 Debian
  `bullseye`（glibc 2.31，gcc 10）。在 Wave 1 决策，记录在本文件追加段。

**已知限制**：
- **Intel Mac 用户**：v0.2.1 不发 native x64 二进制，靠 Rosetta 跑 arm64。性能损失 ~20-40%，
  对 CLI 可接受。native x64 在 v0.2.2 决策。
- **Alpine Linux 用户**：v0.2.1 不支持（glibc-only）。v0.2.3 跟随 musl-static 一起。
- **Windows 用户**：v0.2.1 不支持。v0.2.2 跟随签名一起（unsigned Windows 用户体验灾难，
  必须签）。
- **v0.2.1 完整性仅 HTTPS**：checksum 防传输损坏，不防 MITM。企业 / 高安全场景等 v0.2.2
  签名。
- **CentOS 7 OCaml 5.2 编译未验证**：gcc 4.8.5 可能太老。Wave 1 第一动作验证，失败则 fallback
  Debian bullseye。
- **bundle 后二进制 + 库体积**：估计 15-25MB。可接受，瘦身是后续可选项。

**评审证据**：
- Plan 严苛性评审（Momus）：11 BLOCKER + 12 FLAG + 15 NIT，总评 CONDITIONAL PASS。
- 架构评审（Oracle）：4 BLOCKER（glibc 兼容、darwin-x64 runner、C 库打包、Windows spike 语义）
  + 9 实现级 RISK + 4 可持续性 RISK，总评"不进实施，否则回炉"。
- 本修订解决全部 4 个架构 BLOCKER + 全部 plan BLOCKER 的根因。

**详细实施计划**：`.sisyphus/plans/v0.2.1.md`（已重写，反映本范围修订）。

## [2026-07-03] Linux bundle base: CentOS 7 + devtoolset-11

**变更前**：v0.2.1 计划假设 `centos:7` Docker base + 系统 gcc 4.8.5 即可编译 OCaml 5.x，glibc 2.17 baseline。

**变更后**：发现 OCaml 5.x 的 configure.ac 硬性拒绝 gcc < 4.9（exit code 69），原因：OCaml 5.x 运行时依赖 C11 `_Atomic` 与 `<stdatomic.h>`，gcc 4.8 不支持 C11。解决方案：在 `centos:7` 上安装 Software Collections（SCL）的 `devtoolset-11-gcc` + `devtoolset-11-gcc-c++`，构建命令用 `scl enable devtoolset-11 bash -c '...'` 包装获得 gcc 11。**glibc baseline 不变**（仍为 2.17，由 base image 决定），仅升级编译器。

**原因**：
- OCaml 5.x configure step 在 gcc 4.8.x 上直接 fail，不可绕过。
- CentOS 7 的 gcc 4.8.5 是系统默认，无法通过简单 yum upgrade 升级。
- SCL（Software Collections）是 Red Hat 官方支持的并行工具链方案，与 manylinux2014 wheel 构建使用的方法相同。
- 替代方案比较：(A) `debian:bullseye`（glibc 2.31，丢失 CentOS 7/Debian 10/Ubuntu 18.04 用户）;(C) `almalinux:8`（glibc 2.28，丢失 CentOS 7 用户）。Option B 是唯一保留原 plan "覆盖几乎所有 Linux" 承诺的方案。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`：base image 不变（仍 `FROM centos:7`），增加 EPEL + SCL 安装步骤，所有 build 命令在 `scl enable devtoolset-11` 子 shell 内执行。
- `release.yml`（待 Wave 3 编写）：build-linux job 引用此 Dockerfile，无需特殊改动。
- README（待 Wave 4 编写）：Linux 系统需求仍为 glibc ≥ 2.17，不变。
- `docs/STRATEGY.md` §Release Strategy：Linux baseline 仍为 glibc 2.17，不变。

**回退方式**：
- 若 SCL 在某些 CentOS 7 衍生镜像（Oracle Linux 7、Amazon Linux 2）上不可用：fallback 到 Option A `debian:bullseye`，README 改写 Linux 需求为 glibc ≥ 2.31，损失约 5-10% Linux 用户（CentOS 7/Debian 10/Ubuntu 18.04）。
- 若 devtoolset-11 不稳定：降级到 devtoolset-9（gcc 9，仍满足 C11 要求）。

**已知限制**：
- CentOS 7 已于 2024-06-30 EOL，`yum` 默认 repo 失效，需 sed 改道 `vault.centos.org`。
- `bubblewrap`（opam 沙箱依赖）在 CentOS 7 + Docker 组合下不稳，故构建用 `opam init --disable-sandboxing` 绕过。
- SCL 安装会增加 Docker 构建时间约 1-2 分钟（首次），通过 CI cache 缓解。
- 此方案仅解决"编译"问题；运行时不需要 SCL（最终用户的机器无需安装 devtoolset）。

## [2026-07-03] par_code_upgrade.ml HTTP client: Cohttp_eio.Client.call (GET via Par.Http_client TLS)

**变更前**：v0.2.1 plan §Pillar 3 设想 `par_code_upgrade.ml` 使用 `Par.Http_client.do_request` 发 HTTP 请求。

**变更后**：发现 `Par.Http_client.do_request` **硬编码 POST method**（http_client.ml:317，POST 是 `Cohttp_eio.Client.call` 的固定参数）。GET 请求（GitHub Releases API 的 `/releases/latest`、二进制资产下载）需要直接使用 `Cohttp_eio.Client.call ~sw ~headers client \`GET uri`。TLS 配置仍复用 PAR 的 `Par.Http_client.tls_config`（lazy_t）与 `tls_host_of_string`；构造 cohttp-eio client 时传入本地 `tls_wrapper` 复用 PAR 的 TLS 上下文。

**原因**：
- `Par.Http_client.do_request` 的签名 + 实现都是 POST-only，GET 路径不可达。
- 改 PAR SDK 暴露 GET 是 PAR 上游的决策（v0.6.6+ 候选项），par-code 不应为此阻塞。
- `cohttp-eio` 是 PAR 的既有 transitive 依赖（PAR 的 http_client.ml 已经使用），par-code 链接 par 时已经间接拉入 cohttp-eio 的代码；显式声明它为 par-code 的 direct 依赖只是把"既成事实"写进 manifest。

**影响范围**：
- `lib/dune`：`libraries` 字段增加 `cohttp-eio`、`tls-eio`、`digestif`（digestif 用于 SHA256 校验，与 HTTP 无关但同期加入）。
- `dune-project` 的 `(package ... (depends ...))`：必须增加 `cohttp-eio`、`tls-eio`、`digestif`（W4-T4 配套修改），以保持 `par_code.opam` 元数据完整。
- `lib/par_code_upgrade.ml`：`tls_wrapper` + `make_client` + `http_get` 三个本地 helper 直接使用 `Cohttp_eio.Client.call` + `Par.Http_client.tls_config`。
- 用户安装路径：`opam install par-code` 会显式安装这三个包（之前作为 par 的 transitive deps 也会安装，差异仅在 manifest 元数据）。
- 退役条件：当 PAR SDK v0.6.6+ 暴露 GET-able HTTP 接口时，把 `par_code_upgrade.ml` 改回使用 `Par.Http_client.do_request`，并把 `cohttp-eio`、`tls-eio` 从 par-code 的 direct deps 移除（恢复为 transitive）。

**回退方式**：
- 完全可逆：删除 `lib/dune` 中的 3 个 libraries 条目，删除 `dune-project` depends 中的对应条目，删除 `par_code_upgrade.ml` 中的 `tls_wrapper`/`make_client`/`http_get` helper。回到没有 upgrade 模块的状态。

**已知限制**：
- 显式 direct dep 会触发 opam solver 在 par-code 单独安装时（无 par）尝试拉 cohttp-eio，但 cohttp-eio 在 opam repo 一直存在，不会引入安装失败。
- 如果 PAR SDK 未来 rename 或 restructure 其 Http_client 模块，par-code 的 `tls_wrapper` 需要同步调整。这是 par-code 与 PAR 的既有耦合（不是新引入的）。

## [2026-07-03] Bundle libsqlite3 + libgmp next to `par` binary (R3 "do it right once")

**变更前**：v0.2.0 阶段，par-code 假设用户机器上有 `libsqlite3.so.0` 和 `libgmp.so.10`（通过 opam 系统依赖声明）。

**变更后**：v0.2.1 预编译二进制分发将 `libsqlite3.so.0`（Linux）/ `libsqlite3.0.dylib`（macOS）和 `libgmp.so.10` / `libgmp.10.dylib` 与 `par` 二进制放在同一目录，通过 RPATH `$ORIGIN`（Linux）/ `@loader_path`（macOS）让二进制优先找到 bundled 版本。

**原因**：
- 预编译二进制分发的基本要求是"用户机器什么都不用预装"。`libsqlite3` 和 `libgmp` 在 minimal 容器（Alpine、distroless）、企业 Server（RHEL 8 minimal）上均不存在；不 bundle = 二进制启动失败。
- **R3 "一次做对"原则的直接应用**：v0.3.0 计划引入 FTS5 全文检索，FTS5 是 sqlite3 的**编译期**扩展（`-DSQLITE_ENABLE_FTS5`）。如果 v0.2.1 用 system sqlite，v0.3.0 必须强制用户切换到 FTS5-enabled libsqlite3——这在跨发行版场景不可行。bundle 之后，v0.3.0 只是重编 bundled sqlite3，不是分发革命。
- 同类项（`libgmp`）：mirage-crypto-rng 间接依赖 libgmp，同理需要 bundle。
- 业界同类预编译 CLI 项目均采用 bundle 策略，已是标准做法。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`（W2-T2）：构建后将 `libsqlite3.so.0` + `libgmp.so.10` 复制到 `/out/`，`patchelf --set-rpath '$ORIGIN'` 设置 RPATH。
- `scripts/build-macos.sh`（W2-T3）：构建后将 `libsqlite3.0.dylib` + `libgmp.10.dylib` 复制到 staging 目录，`install_name_tool -add_rpath @loader_path par` + `-id @rpath/<name>` + `-change <abspath> @rpath/<name>`。
- `scripts/install.sh`（W1-T1）：解压 tarball/zip 到 `$PREFIX/bin/`，二进制与 dylib 同目录；RPATH/$ORIGIN 让运行时自动找到 bundled libs。
- 二进制大小：约 15-25 MB（含 libs）。可接受，瘦身是后续可选项。
- 退役条件：永远不会退役（bundle 是终态）。如未来切换到 static linking（musl），bundle .so 阶段会被 static .a 替代。

**回退方式**：
- Linux：删除 Dockerfile 中 `cp /usr/lib64/libsqlite3.so.0 /out/` 和 `cp /usr/lib64/libgmp.so.10 /out/` 两行 + `patchelf --set-rpath` 行。回到 system-lib 链接（但二进制将在 minimal 容器上启动失败）。
- macOS：删除 build-macos.sh 中的 `install_name_tool` 调用。

**已知限制**：
- bundle 的 .so 是 CentOS 7 构建的版本（glibc 2.17 baseline）。若用户机器 glibc < 2.17 仍会失败——但 glibc < 2.17 的 Linux 已绝迹。
- bundled sqlite3 不带 FTS5（v0.2.1 暂不需要）。v0.3.0 重编时切到 FTS5-enabled sqlite3 amalgamation 源码。
- macOS 上 `install_name_tool` 操作要求二进制未签名——v0.2.1 不签名（架构正确），符合。

## [2026-07-03] v0.2.1 integrity model: HTTPS + SHA256 checksum (transport corruption only)

**变更前**：v0.2.0 没有二进制分发，integrity 由 opam 系统保证（opam 本身有签名链路）。

**变更后**：v0.2.1 预编译二进制通过 GitHub Releases 分发，integrity = HTTPS + GitHub 基础设施 + SHA256 checksum 文件。**显式声明：仅防传输损坏，不防对抗性 MITM**。checksums.txt 与二进制一同发布在 release 中——一个能替换二进制的 MITM 也能替换 checksums.txt。

**原因**：
- HTTPS + GitHub 基础设施已覆盖绝大多数真实威胁模型（用户 ISP 注入广告、CDN cache poisoning、传输 bit rot）。
- SHA256 checksum 检测传输损坏（bit flip、truncated download）。
- 真正的对抗性 integrity（cosign/sigstore 签名 checksums、Authenticode 签名 Windows 二进制）需代码签名基础设施，与 v0.2.2 Windows 签名一并上线。
- 提前半步（仅签名 checksums.txt 但不签名二进制）的边际价值低——攻击者替换二进制 + 替换 checksums.txt 是单一动作。

**影响范围**：
- `scripts/install.sh`（W1-T1）：`verify_sha256` 函数下载 `<asset>.sha256` 与二进制一同校验。注释明确说明 "transport corruption detection only, NOT adversarial integrity"。
- `lib/par_code_upgrade.ml`（W1-T3）：`perform_upgrade` 调用 `verify_sha256 ~expected:hash archive` 校验下载内容。
- `README.md`（W4-T1）：install 章节明确措辞 "v0.2.1 integrity = HTTPS + transport-corruption check; adversarial integrity (signed checksums) lands in v0.2.2 with signing"。
- 退役条件：v0.2.2 上线签名 checksums.txt + Authenticode 签名 Windows 二进制时，本条目退役（措辞更新为"已签名"）。

**回退方式**：
- 移除 `verify_sha256` 调用 → 回到无校验（不可取，仅作回退路径描述）。
- 增加签名验证（cosign verify）——这是 v0.2.2 的工作，不在 v0.2.1 范围。

**已知限制**：
- 企业 / 高安全场景用户应等 v0.2.2 签名版本，或在 v0.2.1 自行 GPG-verify 下载内容。
- checksums.txt 与二进制同 release——MITM 攻击者可同时替换。GitHub Releases 的 HTTPS 是唯一防线。
- 没有 key rotation 机制——签名基础设施落地时（v0.2.2）再设计。

## [2026-07-03] Linux bundle base 从 CentOS 7 + devtoolset-11 切换到 AlmaLinux 8

> ⚠️ **取代上一条** `[2026-07-03] Linux bundle base: CentOS 7 + devtoolset-11`。以下为实际发布采用的决策。

**变更前**：v0.2.1 计划使用 `centos:7` + SCL `devtoolset-11`（gcc 11 via Software Collections），glibc 2.17 baseline。

**变更后**：改用 `almalinux:8`（stock gcc 8.5，glibc 2.28 baseline）。不再需要 SCL / devtoolset。

**原因**：
- CentOS 7 于 2024-06-30 EOL，`mirrorlist.centos.org` DNS 已下线。
- `vault.centos.org` 的 SCL 仓库路径不稳定——在 5 轮 CI 迭代中均无法可靠拉取 devtoolset-11。
- AlmaLinux 8 是 CentOS 8 的社区后继，stock gcc 8.5 已满足 OCaml 5.x 的 C11 atomics 要求（gcc ≥ 4.9），无需 SCL。
- glibc 从 2.17 升到 2.28：失去 CentOS 7 / Debian 10 / Ubuntu 18.04 用户（均已 EOL）。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`：`FROM almalinux:8`，`dnf install gcc`（不再需要 `scl enable devtoolset-11`）。
- README / CHANGES.md：Linux 需求从 glibc ≥ 2.17 改为 glibc ≥ 2.28。
- `release.yml`：step name 从 "CentOS 7" 改为 "AlmaLinux 8"。

**回退方式**：还原 Dockerfile 为 `FROM centos:7` + SCL 方案（但 CentOS 7 vault 不稳定，不推荐）。

**已知限制**：
- CentOS 7 / Debian 10 / Ubuntu 18.04 用户无法使用预编译二进制（均已 EOL）。
- 如未来需要覆盖 glibc < 2.28 的发行版，需引入 musl-static 构建（v0.2.3 计划）。



