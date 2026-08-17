# par-code Strategy

> **Last updated**: 2026-08-07 (post-v0.6.2)
> **Status**: Active
> **Owner**: PAR-Code Contributors
>
> This document captures par-code's product positioning, target users, value
> proposition, and release strategy as a **snapshot of current strategy**.
> Individual strategic decisions (with their before/after/rationale) live in
> `docs/DECISIONS.md`. When strategy changes, update this file **and** append
> a decision record to `DECISIONS.md`.

---

## 1. Product Positioning (One-liner)

**par-code is an interactive terminal coding agent built on the PAR
(Programmable Agent Runtime) SDK in OCaml.** It ships as a CLI (`par`) that
reads, writes, edits, searches code, runs type-safe bash, and orchestrates
multi-step coding tasks through PAR's ReAct engine.

par-code is **not** a generic assistant, **not** a GUI product, and
**not** a standalone runtime — it consumes the PAR SDK as an OCaml library
and adds a coding-agent surface on top.

## 2. Dual Role (the defining strategic choice)

par-code serves two roles simultaneously. This duality is the project's
defining strategic choice and every roadmap/scope decision must serve both:

| Role | What it means | Success looks like |
|---|---|---|
| **A. User tool** | A terminal coding assistant that developers install and use daily. | Real users run `par` to do real coding work; the REPL is responsive, tools work, sessions persist. |
| **B. PAR validation case** | Every feature in par-code exercises one or more PAR SDK capabilities. Every gap/friction/bug found feeds back into PAR. | PAR SDK reaches maturity through par-code's dogfooding; PAR ships capabilities knowing they survive a real coding agent's workload. |

**Implication**: par-code is structurally coupled to PAR. Decoupling is a
non-goal. When par-code finds a PAR limitation, the **first** response is to
fix PAR, not to work around it in par-code.

## 3. Target Users

### Primary
**OCaml-ecosystem developers who want a native, controllable, deeply
customizable coding agent.** They value:
- Native performance (no Node/Python runtime tax)
- Type safety end-to-end (OCaml → PAR → user tools)
- Source-level inspectability (the agent is OCaml they can read)
- CLI conventions that match their existing OCaml tooling (dune, cmdliner)

### Secondary
**Potential PAR SDK adopters.** They look at par-code as the reference
application of PAR — "if PAR can power this, it can power my agent too."
par-code's feature coverage is PAR's capability showcase.

### Explicitly NOT target users (non-goals)
- Users who want a GUI / IDE plugin (par-code is a terminal tool)
- Users who want a closed-source / hosted product (Apache-2.0 forever)
- Users who need cross-language portability of the agent itself (par-code is
  OCaml-native; if you want Python, use PAR's Python bindings directly)

## 4. Value Proposition

| # | Value | Why it matters |
|---|---|---|
| 1 | **Native OCaml on PAR** | Inherits PAR's CLI conventions (cmdliner, dune, bin/ layout) for drop-in compatibility with existing OCaml tooling. Real type-safety across the agent boundary. |
| 2 | **Coding-first, not generic** | Default system prompt and tools are tuned for code work — read/write/edit/grep/find/bash — not for chit-chat. |
| 3 | **One capability per release** | Each version ships exactly one user-perceivable capability. Thin, demonstrable vertical slices. No 1.0 until core parity is earned. |
| 4 | **Dual-purpose by design** | Using par-code makes PAR better. Users who adopt par-code accelerate the underlying runtime for the whole ecosystem. |

## 5. Release Strategy

### Versioning
- **Semantic Versioning**, pre-1.0 (`0.x.y`).
- **No 1.0 until core-parity milestone** (v0.2 through v0.14 capabilities
  complete and stabilized — see README roadmap).
- **No automatic version bumps.** Any MAJOR/MINOR/PATCH bump requires
  explicit user instruction. Pure tooling/docs/CI changes do not bump
  (only refresh beta-date).

### Per-release shape
Each release ships **one** user-perceivable capability — a thin, demonstrable
vertical slice. Version numbers stay minimal. Examples:
- v0.2.0: interactive REPL ("it reads and edits my code")
- v0.2.1: one-line install + self-update on Linux + macOS
- v0.3.0: project memory across sessions

### Distribution channel evolution

| Phase | User path | Developer path |
|---|---|---|
| **v0.1.0 – v0.2.0** | (none — source only) | `opam pin add par` + `opam install . --deps-only` + `dune build` |
| **v0.2.1+** | `curl install.sh \| bash` (Linux + macOS, pre-built binary bundling sqlite3 + libgmp) | same as above (opam source-pin demoted to "Developer install") |
| **v0.2.2+** | + `irm install.ps1 \| iex` (Windows native, signed binary) | unchanged |
| **v0.2.3+ (stretch)** | + Homebrew tap / Scoop bucket / winget manifest | unchanged |

### Signing & integrity evolution

| Phase | macOS CLI | Windows CLI | Linux |
|---|---|---|---|
| **v0.2.1** | Unsigned (architecturally correct — CLI installed via `curl\|bash` doesn't pass through Gatekeeper) | Not shipped (Windows deferred to v0.2.2) | N/A |
| **v0.2.2+** | Unsigned (likely permanently — revisit only if a Desktop GUI ever ships) | Cloud code-signing service (e.g. Azure Trusted Signing class) | N/A |
| **Integrity model v0.2.1** | HTTPS + SHA256 checksum (transport-corruption detection only — **not** adversarial-integrity guarantee) | — | same |
| **Integrity model v0.2.2+** | + signed checksums (cosign/sigstore class) | + Authenticode signatures | — |

### Stability grading
- **Production-ready**: not yet (pre-1.0)
- **Public beta**: v0.2.x — usable for real work, but CLI/API still settling
- **Internal alpha**: v0.1.x (project skeleton only)
- **Audit findings resolved**: v0.5.5 + v0.5.6 cleared all 3 P0 + 7 P1 from
  the v0.5.4 audit. 68 tmux-based integration tests now guard against the
  "tests encode wrong assumptions" failure mode. v0.6.0 found a new P0
  (plan mode non-functional — `find_last_assistant_text` recursive bug)
  via tmux walkthrough, validating the integration test investment.

## 6. Strategic Non-Goals

These are explicitly **out of scope** for par-code for the foreseeable future.
Revisit only with a new STRATEGY.md revision + DECISIONS.md entry:

1. **No GUI / Desktop app.** par-code is a terminal tool. (A future Desktop
   shell is not impossible but is not on any current roadmap.)
2. **No closed-source / commercial edition.** Apache-2.0 in perpetuity.
3. **No decoupling from PAR SDK.** par-code's reason for existing is to
   validate PAR. Decoupling would erase the project's strategic value.
4. **No 1.0 speedrun.** Core-parity milestone (v0.2–v0.14 capabilities
   complete + stabilized) is the only legitimate path to 1.0.
5. **No multi-language agent runtime.** The agent itself is OCaml. Users who
   want Python/Go/Rust agents should consume PAR directly in that language.
6. **No proprietary vendor lock-in at the protocol layer.** Provider config
   supports major cloud providers, local inference engines, and custom (`+name`) — no provider
   gets a privileged integration.

## 7. Disclosure Rule (commit-time constraint)

Per global project rules, **no committed artifact in this repo may name
identifiable external projects, companies, or organizations**. This applies
to commit messages, README, CHANGES.md, DECISIONS.md, this STRATEGY.md,
code comments, dune/CI config, and any pushed issue/PR text.

When referencing external projects (reference implementations, alignment
targets, competitors), use generic phrasing:
- ✅ "public reference project", "mainstream coding-agent CLI",
  "cloud code-signing service"
- ❌ specific project/product/company names

Internal chat / session transcripts / uncommitted local notes are exempt.
**When in doubt, generalize.** Historical violations are cleaned in独立
sweep commits (`docs: sanitize … identifiers`), never folded into
feature/bug commits.

## 8. Roadmap Posture

The detailed version-by-version roadmap lives in `README.md` (user-facing
table) and is operationalized per-version in `.sisyphus/plans/v<ver>.md`
(implementation plans, local-only).

**Current posture** (as of this snapshot):
- v0.1.0 ✅ shipped (skeleton)
- v0.2.0 ✅ shipped (interactive coding agent)
- **v0.2.1 ✅ shipped** — one-line install + self-update (Linux x86_64 + macOS arm64)
- v0.2.2 — deferred (upstream `Eio.Process` Windows blocker; re-scope when eio
  ships Windows process support)
- **v0.3.0 ✅ shipped** — project memory: FTS5 + recall/remember tools
  + `par memory` CLI
- **v0.3.1 ✅ shipped** — auto-extraction at session exit + history search
  (FTS5 over conversations table)
- **v0.3.2 ✅ shipped** — Linux arm64 pre-built binary (Raspberry Pi / Graviton)
- **v0.3.3 ✅ shipped** — PAR SDK 0.7.3 consumption + memory storage migrated to
  `Sqlite_memory` (FTS5 + vec0 + RRF hybrid search) + configurable embedding
  service + per-turn memory injection
- **v0.4.0 ✅ shipped** — long-session continuity: checkpoint-writer
  subagent with save/isolation controls + Context Ledger storage + budgeted
  context injection + context reconstruction on resume + periodic mid-session
  extraction
- **v0.4.1 ✅ shipped** — async checkpoints via `Eio.Fiber.fork` (Oracle
  SAFE WITH CAVEATS) + last-N transcript truncation + richer `/checkpoints`
  listing. Finishes v0.4.0's unfinished business. Pillar D confirmed no-op
  via code-path audit.
- **v0.4.2 ✅ shipped** — critical fix: PAR SDK 0.7.8 engine.ml bug that
  silently dropped assistant responses from `conversation.messages`. Binary
  rebuild only; no par-code source changes. Multi-turn coherence + checkpoint
  quality restored.
- **v0.4.3 ✅ shipped** — UX quick patch (no new signature capability;
  v0.5.0 plan mode still next). Four daily-friction fixes: `/cost` REPL
  command with per-session token accumulator, `par config show` subcommand,
  config wizard prompts for 6 previously-hidden options, memory `recall`
  supplementary SQL fetch to recover `usage_count`/`last_used_at` dropped by
  PAR SDK `Memory_object.t` type limitation. Dead `bump_usage` removed.
- **v0.4.5 ✅ shipped** — UI abstraction layer. `Ui.*` module with composable
  styled images, streaming markdown state machine, 13 high-level render
  functions. All 175 printf migrated. PAR SDK signals restored. 73 new tests.
  Zero new deps. Future TUI backend (v0.14.0 Mosaic/Matrix) path confirmed.
- **v0.5.0 ✅ shipped** — Plan Mode: read-only planner agent,
  `/plan` `/build` mode switching, plan file persistence, `plan_enter`/
  `plan_exit` agent tools. 187 tests passing.
- **v0.5.1 ✅ shipped** — Plan CLI + git tools: `par plan list/show/prune`
  subcommands + `git_status`/`git_log` read-only tools for the planner.
  Fliegel-Van Flandern timestamp parser. 211 tests passing.
- **v0.5.2 ✅ shipped** — Streaming fallback: print `resp.text` when provider
  streaming delivers no chunks. Fixes silent empty responses.
- **v0.5.3 ✅ shipped** — REPL rendering fixes: tool indicator de-duplication,
  `/dev/tty` bash confirmation (fixes stdin contention), empty response
  diagnostics. Ctrl+C clean exit.
- **v0.5.4 ✅ shipped** — Session management: `par session list/show/fork` CLI
  commands + partial ID resume + project-scoped listing. 7 new tests.
- **v0.5.4 audit (2026-08-05)** ⚠️ — First comprehensive end-to-end audit
  found 3 P0 release-blocker regressions in v0.5.4's marquee features
  (Plan Mode tool-filter names wrong, session `scope` never written,
  startup version notice always fires) + 7 P1 critical UX defects. 218/218
  unit tests passed but encoded the same wrong assumptions as the
  implementations. 4 of the 10 findings require PAR SDK upstream fixes
  (see [2026-08-05] PAR SDK Feedback entry). v0.5.5 hotfix planned in
  two waves; Wave 1 (par-code-only) ships immediately, Wave 2 gated on
  PAR SDK. **Process change**: future releases require integration-test
  harness (tmux/expect) for advertised features.
- **v0.5.5 ✅ shipped** — Hotfix: 3 P0 + 3 P1 audit findings fixed
  (planner tool filter, session scope write, version compare, prompt flush,
  think_tag_strip middleware, PAR SDK 0.8.3 bump). Release took 3 CI
  attempts (opam exit 31 on macOS + ARM64).
- **v0.5.6 ✅ shipped** — Audit Wave 2–3: `par config set` all 20 fields,
  install.sh `set -e` + source compile fallback, memory prune `--dry-run`,
  prefix resolution, legacy scope migration, streaming `<think>` strip,
  checkpoint/plan/extractor think-tag strips, `/cost` token counts (PAR SDK
  0.8.3). 271 tests. Also added 68 tmux-based integration tests.
- **v0.6.0 ✅ shipped** — Subagent delegation: `delegate` tool with `explore`
  (read-only) and `general` (full-capability) subagents. Synchronous, isolated,
  depth-limited. Also fixes critical plan mode bug (`find_last_assistant_text`
  returned wrong message — plan files were always empty). Plan content now
  injected directly into build agent's system prompt.
- **v0.6.1 ✅ shipped** — Install/upgrade fixes (patch, no new features):
  install.sh `ensure_target_writable` guard for stale root-owned binary (the
  `sudo curl | bash` footgun), `par upgrade` source-fallback parity (no-prebuilt
  platforms now self-update via source recompile instead of dead-ending),
  `Filename.temp_file` hygiene. Closes install/upgrade parity gap surfaced by a
  macOS Intel user.
- **v0.6.2 ✅ shipped** — UTF-8 REPL input: migrated line input to linenoise
  (raw mode, wcwidth-aware backspace) to fix CJK garbling that cooked-mode tty
  line discipline couldn't (no wcwidth in kernel; IUTF8 insufficient). New
  bundled-C opam dep (no system packages; confirmed builds in release CI).
  Plain-text prompt (linenoise strlen cursor math). Ctrl+C `Sys.Break` caught
  (REPL loop + read_line → exit 130). stdout flushed before linenoise (slash
  commands were swallowed). Three review rounds; two post-migration
  regressions (config-wizard Ctrl+C crash, slash-command output) caught and
  fixed before release.
- **v0.7.0 ✅ shipped** — Goal-driven autonomy: `/goal`
  command, independent judge model, doom-loop detection, `goal_done` agent
  tool, `--goal` CLI flag. Judge-supervised mode (evaluates after each turn;
  full autonomous chaining deferred). PAR SDK bumped 0.8.3 → 0.8.6.
  300 tests passing. 4 new modules, 29 new unit tests.
- **v0.7.1 ✅ shipped** — Hotfix. Two regressions from v0.7.0 plan-mode
  walkthrough: (a) planner `max_iterations` was capped at `min cfg.max_iterations 8`
  — exactly equal to the prescribed 7-tool workflow + 1 closing response, so
  any LLM "thinking" iteration burned the budget and the planner fell through
  to the empty-plan auto-save fallback; fixed by adding a dedicated
  `planner_max_iterations` config field (default 15) and switching
  `early_stopping_method` from `Force` to `Generate` so an exhausted budget
  still yields a synthesized best answer. (b) Three of four REPL exit paths
  (`/exit`, Ctrl+D, Ctrl+C at prompt) had inconsistent code — only `/exit`
  called `exit 0`, causing the loop to re-enter and memory extraction to run
  twice on exit; fixed by routing all three through a shared `exit_normally ()`
  helper. +3 unit tests, +2 integration tests.
- **v0.7.2 ✅ shipped** — Goal autonomy usability hardening. Two rounds of
  real-LLM testing (post-release QA + same-model dual-agent walkthrough
  against a reference harness) showed `/goal` fails end-to-end on real write
  tasks: invisible confirmation prompts (bash confirm + plan gate never
  render — no flush), reasoning-model blind periods, goal drift with zero
  guardrails, doom-loop Abort that lies. v0.7.2 = W0 invisible-wait fixes +
  W1 three-class bash approval with always-pattern persistence + W2 planner
  synthesis fallback + W3 doom-loop v2 (three signals, real abort, incidents)
  + W4 goal lifecycle (verbs, blocked status, disk flush, activation
  memory-only) + W5 no-progress & completion-claim detection + W6 resume
  regression test. Full spec: `docs/v0.7.2-ROADMAP.md`.
- **v0.7.3 ✅ shipped 2026-08-17** — Full autonomous goal chaining
  (`execute_turn` + `run_chain`, judge cadence unchanged), real
  in-invoke cancellation consuming PAR SDK 0.10.0 (doom Guard-cancel +
  Ctrl+C pause/force-escape), error-streak guard (`llm_error_x2`),
  `--goal` auto-start, `goal_auto_chain` kill switch. PAR SDK feedback:
  0.9.1/0.8.3/0.8.6 items retired; `Think_tag_strip` facade gap filed.
- v0.8.0+ — best-of-N reasoning, self-improvement, compose mode, ecosystem,
  code intelligence, safety, polish → v1.0

The roadmap order follows: **usable first (v0.2 foundation) → signature
capabilities on steepest difficulty curve (v0.3–v0.4 memory/long-context,
where PAR has zero coverage) → autonomy climb (v0.5–v0.8) → self-evolution
+ orchestration (v0.9–v0.10) → safety/UX closing (v0.13–v0.14) → v1.0
core-parity milestone.**

## 9. Strategic Decision Index

The full decision history (with before/after/rationale/retirement-condition
per global rules) lives in `docs/DECISIONS.md`. Strategic-level entries:

| Date | Decision | Status |
|---|---|---|
| 2026-07-02 | Founding: par-code as a PAR-SDK coding agent (integration path = OCaml native SDK; agent form = interactive coding REPL; MVP scope = v0.1.0 skeleton only; license = Apache-2.0; repo = `jcz2020/par-code` public) | Active |
| 2026-07-02 | Roadmap v0.2.0 → v1.0.0 defined (one user-perceivable capability per release; core parity before 1.0) | Active |
| 2026-07-02 | v0.2.1 scope inserted between v0.2.0 and v0.3.0 (distribution release) | Active (superseded in part by next row) |
| 2026-07-02 | v0.2.1 scope revised post-review: Linux + macOS only; Windows + signing → v0.2.2; bundle sqlite3/libgmp; CentOS 7 build base; Intel Mac via Rosetta; musl-static → v0.2.3 | Active (superseded by AlmaLinux 8 row) |
| 2026-07-03 | v0.2.1 shipped (one-line install + self-update, AlmaLinux 8 base, glibc ≥ 2.28) | Active |
| 2026-07-03 | Linux bundle base switched from CentOS 7 + devtoolset-11 to AlmaLinux 8 (CentOS 7 EOL + vault unstable) | Active |
| 2026-07-06 | v0.2.2 deferred; v0.3.0 prioritized (upstream `Eio.Process` Windows blocker) | Active |
| 2026-07-06 | v0.3.0 memory architecture: SQLite+FTS5 over filesystem (DB-first, MEMORY.md export-only) | Active |
| 2026-07-06 | v0.3.0 memory storage: shared par.db via PAR SDK 0.6.9 `raw_sqlite3_db` accessor | Active |
| 2026-07-06 | MEMORY.md as auto-generated export, not source of truth (DB is canonical) | Active |
| 2026-07-06 | Auto-extraction at session exit (synchronous, not background) to avoid PAR SDK reentrant invoke corruption | Active |
| 2026-07-06 | History search via FTS5 on raw messages_json (global, not project-scoped) | Active |
| 2026-07-11 | v0.3.3: memory storage migrated to PAR SDK 0.7.3 `Sqlite_memory` (FTS5 + vec0 + RRF); memory IDs int → UUID; auto-migration from v0.3.0–v0.3.2 schema | Active |
| 2026-07-11 | Deferred: `fork_invoke` for background extraction → v0.4.0 (long-session continuity) | Active |
| 2026-07-15 | v0.3.3 shipped — PAR SDK 0.7.3 + hybrid memory search (6 commits, closed architectural-cleanup loop) | Active |
| 2026-07-16 | v0.4.0: checkpoint/extractor isolation via PAR SDK 0.7.7 save/isolation controls (eliminates ckpt_rt workaround) | Active |
| 2026-07-16 | v0.4.0: Context Ledger pattern for checkpoint storage (structured entries, not prose) | Active |
| 2026-07-16 | v0.4.0: budgeted context injection via chars/4 heuristic (conservative compaction) | Active |
| 2026-07-16 | v0.4.0 shipped — Long-session continuity (checkpoint-writer + context budget + mid-session extraction) | Active |
| 2026-07-19 | v0.4.1: async checkpoint/extraction via Eio.Fiber.fork on rt.cancellation_root (Oracle SAFE WITH CAVEATS) | Active |
| 2026-07-19 | v0.4.1: PAR SDK feedback filed (3 items: Event_bus.set_session_id unlocked; last_llm_call_* non-atomic; invoke_async lacks ?save/?update_current — re-affirmed) | Active |
| 2026-07-19 | v0.4.1 shipped — Async checkpoints + UX polish (Pillar A async, B last-N truncation, C richer /checkpoints, D confirmed no-op) | Active |
| 2026-07-19 | v0.4.2 shipped — critical fix: PAR SDK 0.7.8 engine.ml bug silently dropped assistant messages from `conversation.messages`; multi-turn coherence + checkpoint quality restored via single-egress-wrap fix upstream | Active |
| 2026-07-20 | v0.4.3: per-session token accumulator for `/cost` REPL command (PAR SDK `Metrics.counters` only tracks operational counts, not tokens; par-code accumulates `Types.usage_stats` from each `Runtime.invoke` Ok branch) | Active |
| 2026-07-20 | v0.4.3: PAR SDK feedback filed — `Memory_object.t` lacks `last_used_at`/`usage_count` fields even though DB schema has the columns and `Sqlite_memory.search_fts` internally bumps them; par-code side workaround via supplementary parameterized SQL fetch in `recall` | Active |
| 2026-07-20 | v0.4.3 shipped — UX quick patch: `/cost` + `par config show` + 6 wizard prompts + memory recall usage-field fix + dead `bump_usage` removal (63 tests, Oracle-reviewed) | Active |
| 2026-07-21 | v0.4.5: UI abstraction layer — composable styled images, ANSI colors, backend with TTY detection; all 175 printf migrated; future TUI path to Mosaic/Matrix confirmed | Active |
| 2026-07-21 | v0.4.5: streaming markdown state machine — line-based incremental parser; round-trip property verified; zero OCaml reference impl existed | Active |
| 2026-07-28 | v0.5.0: ARM64 build fix — pin uring 2.7.0 in Dockerfile to cascade solver to eio.1.3 (eio.1.4 requires uring >= 2.15.0 which fails vendored liburing build on ARM64 AlmaLinux 8) | Active |
| 2026-07-28 | v0.5.0: plan_exit auto-persist — post-invoke mode-change detection persists plan when agent self-switches via plan_exit tool | Active |
| 2026-07-27 | v0.5.0: Plan Mode architecture — two registered agents (planner + par) with per-agent tool isolation; mode switch = swap agent_id in Runtime.invoke; file-based plan persistence; default Build mode | Active |
| 2026-07-27 | v0.5.0: PAR SDK feedback filed — first-class mode concept missing (currently par-code simulates via agent_id swap + module-level mutable ref). Priority: low. Re-evaluation trigger: if v0.6.0+ adds more modes. | Active |
| 2026-07-27 | v0.5.0: PAR SDK feedback filed — no plan/task primitive (plans stored as markdown files, not queryable). Priority: medium. Re-evaluation trigger: v0.6.0 subagent coordination needs structured plan handoff. | Active |
| 2026-07-29 | v0.5.1 shipped — Plan CLI (par plan list/show/prune) + git_status/git_log read-only tools for planner + Fliegel-Van Flandern timestamp parser. 211 tests passing. | Active |
| 2026-08-04 | v0.5.2–v0.5.4 shipped — streaming fallback (print resp.text on no-chunks), REPL rendering fixes (tool dedup + /dev/tty bash + empty-response diagnostics + Ctrl+C clean exit), session management (par session list/show/fork + partial ID resume + project-scoped listing) | Active — v0.5.4 has known regressions, see next row |
| 2026-08-05 | v0.5.4 comprehensive audit — 3 P0 (planner tool filter, session scope write, version compare) + 7 P1 findings; 218/218 unit tests passed but encoded wrong assumptions; v0.5.5 hotfix planned in two waves (Wave 1 par-code-only, Wave 2 gated on PAR SDK); process change: integration-test harness required for future releases | Active |
| 2026-08-05 | PAR SDK feedback filed — 3 gaps surfaced by audit: (1) Runtime.save_conversation lacks ?scope (blocks P0 #2), (2) openai_provider streaming lacks stream_options.include_usage (blocks /cost accuracy), (3) think_tag_strip middleware not default (blocks CoT-leaking model support). User will direct PAR SDK team before v0.5.5 Wave 2 | Active |
| 2026-08-07 | v0.6.1 shipped — install/upgrade parity fix: install.sh stale-binary permission guard + `par upgrade` source-fallback on no-prebuilt platforms (macOS Intel self-update now works via source recompile) + `Filename.temp_file` hygiene. Surfaces install/upgrade consistency as an architectural property. | Active |
| 2026-08-07 | v0.6.2 shipped — linenoise migration for UTF-8/wide-char REPL input: cooked-mode tty line discipline has no wcwidth (IUTF8 insufficient), garbling CJK backspace cross-platform. Added bundled-C `linenoise` opam dep (no system packages; confirmed in release CI); migrated REPL loop + `read_line`; plain-text prompt (linenoise strlen cursor); Ctrl+C `Sys.Break` caught (REPL + read_line→exit 130); stdout flush before linenoise (slash-command output fix). "一次做对": proven library over hand-rolled raw-mode editor. | Active |

## 10. Revision Protocol

When strategy changes:
1. Update this file (`docs/STRATEGY.md`) in place — it's the snapshot.
2. Append a `[YYYY-MM-DD] <title>` entry to `docs/DECISIONS.md` with the
   6-field format (变更前 / 变更后 / 原因 / 影响范围 / 回退方式 / 已知限制).
3. Add the new decision to the **Strategic Decision Index** (§9) above.
4. If the change invalidates a prior strategic claim in this file, leave the
   prior claim's decision record in `DECISIONS.md` intact (audit trail) and
   add a supersession pointer at the top of the older record.

**Trigger thresholds for mandatory strategy-record update** (per global
AGENTS.md rule §"项目记忆强制记录规则"):
1. Strategic-level decisions — value positioning, target users, release strategy
2. API/interface-level changes — breaking type signatures, module add/remove
3. Architecture-level changes — new sub-library, deleted module, package restructure
4. Dependency-level changes — add/remove hard deps, version requirements
5. Scope-level changes — delete a major feature, toggle a core capability

---

*This document is the authoritative snapshot of par-code's strategy. For
questions about *why* a strategic decision was made, see
`docs/DECISIONS.md`. For *what* ships in each version, see `README.md`
roadmap. For *how* a specific version will be implemented, see
`.sisyphus/plans/v<ver>.md`.*
