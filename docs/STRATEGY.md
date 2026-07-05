# par-code Strategy

> **Last updated**: 2026-07-03
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
   supports OpenAI, Anthropic, Ollama, and custom (`+name`) — no provider
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
- **v0.2.1 ✅ shipped** — one-line install + self-update (Linux + macOS);
  Windows + signing deferred to v0.2.2
- v0.3.0+ — project memory, long-session continuity, plan mode, subagents,
  autonomy, reasoning, self-improvement, compose mode, ecosystem, code
  intelligence, safety, polish → v1.0

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
