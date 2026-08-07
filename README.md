# par-code

> An interactive coding agent built on the [PAR](https://github.com/jcz2020/par)
> SDK — and a real-world validation case for PAR itself.

`par-code` is a terminal coding assistant (terminal-native, REPL-first) implemented in
OCaml on top of the **PAR (Programmable Agent Runtime)** SDK. It inherits PAR's
CLI conventions and drives the **core** PAR surface — ReAct loop, tool dispatch,
type-safe bash, skills, streaming, persistence — to both ship a useful agent and
prove out the PAR SDK in anger. (MCP client and Workflow engine are PAR SDK
primitives par-code does not yet wire — see roadmap items v0.10.0 / v0.11.0.)

**Status:** `v0.6.2` — UTF-8 REPL input (linenoise): CJK backspace no longer
garbles, plus Ctrl+C-crash fixes. Pre-built binaries with a one-line installer
(`curl | bash`) for Linux x86_64/arm64 + macOS arm64, plus `par upgrade`
self-update. No OCaml or opam needed for end users.

---

## Why par-code?

1. **A coding agent, built on PAR.** Read/write/edit code, run type-safe bash,
   search the codebase, and orchestrate multi-step coding tasks through PAR's
   ReAct engine and workflow system.
2. **A validation case for PAR.** Every feature in par-code exercises a PAR SDK
   capability. Gaps, friction, and bugs found here feed directly back into PAR.
3. **Inherits PAR's CLI.** `par-code` mirrors PAR's flags (`--provider`,
   `--api-key`, `--model`, …) for drop-in compatibility, and follows the same
   dune / cmdliner conventions.

## PAR SDK capabilities par-code targets

| PAR feature | How par-code uses it |
|---|---|
| ReAct engine (`Par.Runtime.invoke`) | Core coding-agent loop |
| Built-in tools (`Par.Builtin_tools`) | read/write/edit, grep, find, ls |
| Type-safe bash (`Par.Bash_safe_command`) | Run commands without shell injection |
| Custom tool registration | Code-specific tools (memory, plan, git) |
| Skills (`Par.Skill_registry`) | Builtin skills registered: code-reviewer, summarizer, translator, rag-assistant |
| Streaming (`invoke_stream`) | Real-time token + tool output |
| Long generation (`invoke_generate`) | PRDs, docs, large diffs (also: checkpoint-writer + memory-extractor subagents) |
| Persistence (`Par.Sqlite_persistence`) | Session history across runs |
| MCP client (`Par.Mcp_client`) | _Persistence wired; client init deferred — roadmap v0.11.0_ |
| Workflows (`Par.Workflow_engine`) | _State persistence registered; engine not yet invoked — roadmap v0.10.0_ |

## Install

### One-line install (Linux + macOS)

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
```

Pre-built binary on Linux x64/arm64 + macOS arm64; source compile on macOS Intel. Installs to `~/.par/bin/par` and offers to add it to PATH. Full matrix: [Platform support](#platform-support).

**Custom install prefix or version:**

```sh
# Custom install location
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash -s -- --prefix /opt/par

# Pin to a specific version
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash -s -- --version v0.2.1
```

**Environment variables:**

| Variable | Default | Purpose |
|---|---|---|
| `PAR_PREFIX` | `$HOME/.par` | Install directory override |
| `PAR_MIRROR` | `github.com` | Mirror host (for CN/enterprise users with restricted GitHub access) |
| `PAR_NO_UPDATE_CHECK` | unset | Set to `1` to disable the startup version check entirely |
| `PAR_DISABLE_UPDATE_CHECK` | unset | Set to `1` when invoking `install.sh` from `par upgrade` |

### Source compilation (fallback)

On platforms without a pre-built binary (e.g., macOS Intel), the installer
automatically falls back to compiling from source. You can also force it:

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash -s -- --from-source
```

This installs opam + OCaml 5.x (if missing), pins the PAR SDK, builds par-code,
and installs the binary to `~/.par/bin/par`. Takes 5-20 minutes depending on
whether the OCaml compiler needs to be compiled. Requires:

- **macOS**: Homebrew + Xcode Command Line Tools (`xcode-select --install`)
- **Linux**: C compiler + make + git (the installer installs opam + dev libraries via apt/dnf/pacman/apk)

### Self-update

Once installed, `par upgrade` keeps you current without a package manager:

```sh
par upgrade                 # upgrade to latest release
par upgrade --check         # print current vs latest, exit 0 if up-to-date
par upgrade --to v0.2.5     # pin to a specific version (downgrades too)
par upgrade --uninstall     # remove par binary (preserves ~/.par/config.json + par.db)
par upgrade --uninstall --purge  # remove ALL of ~/.par/ (interactive prompt)
```

A purely-additive startup check prints one stderr line when a newer version
exists (gated by `PAR_NO_UPDATE_CHECK=1`).

On platforms without a pre-built binary (e.g. macOS Intel), `par upgrade`
automatically recompiles from source via the installer — it streams build
progress to the terminal and takes 5-20 minutes on a first-time build. This
keeps install and upgrade consistent: whatever the installer can do, upgrade
can redo.

### Platform support

| Platform | Status | Notes |
|---|---|---|
| Linux x86_64 (glibc >= 2.28) | ✅ Pre-built binary | Covers AlmaLinux 8+, Debian 11+, Ubuntu 20.04+, RHEL 8+, Fedora |
| Linux arm64 (aarch64) | ✅ Pre-built binary (v0.3.2+) | Raspberry Pi 4/5, AWS Graviton, other ARM Linux |
| macOS arm64 (Apple Silicon) | ✅ Pre-built binary | Native |
| macOS x86_64 (Intel) | ✅ Source compile | No pre-built binary; installer and `par upgrade` auto-detect and compile from source (requires Homebrew + Xcode CLT; 5-20 min build) |
| Windows x86_64 | ❌ Deferred | v0.2.2 deferred (upstream `Eio.Process` Windows blocker); re-scope when eio ships Windows process support |
| Alpine Linux (musl) | ❌ Not yet | Static musl binary is a stretch goal |

### Integrity model

v0.2.1 downloads are protected by HTTPS + GitHub infrastructure + SHA256
checksum. This catches **transport corruption** (truncated downloads, bit rot)
but does **not** defend against a determined network attacker (the checksum
file ships in the same release as the binary; a MITM who can swap one can swap
both). Real adversarial integrity (signed checksums via cosign/sigstore, signed
Windows binaries) lands in v0.2.2 alongside Windows support.

macOS binaries are not code-signed in v0.2.1 — this is architecturally correct
for a CLI installed via `curl | bash` (it never passes through the OS gatekeeper,
which only intercepts `.app` bundles and browser-downloaded files with quarantine
attribute). The installer strips `com.apple.quarantine` xattr for the
browser-download edge case.

### Developer install (from source)

For contributors who want to build par-code from source (requires OCaml 5.x + opam):

```sh
# 1. PAR SDK (once)
opam pin add par https://github.com/jcz2020/par.git

# 2. par-code
git clone https://github.com/jcz2020/par-code.git
cd par-code
opam install . --deps-only --with-test
dune build

# Run
dune exec -- par --version
```

## Project layout

```
par-code/
├── bin/          # `par` executable + CLI args
├── lib/          # `par_code` library facade
├── scripts/      # install.sh, build-macos.sh, docker/, checksums.sh
├── test/         # Alcotest suite
└── dune-project
```

## Quickstart

```sh
# 1. Configure a provider (interactive wizard)
par config

# 2. Start the REPL
par

# Or ask a single question
par ask "What does this project do?"
```

## Project Memory

par-code remembers your project across sessions. Memories are stored per-project
(keyed on git root) in SQLite with FTS5 full-text search.

### Memory commands

```sh
par memory add --kind convention --summary "uses conventional commits" --content "..."
par memory list
par memory search "authentication"
par memory search-history "why did we switch to sqlite"
par memory show <id>
par memory export -o MEMORY.md
par memory forget <id>
par memory prune --older-than 90
par memory prune --older-than 90 --dry-run  # preview without deleting
```

### How the agent uses memory

On session start, a compact index of your project's memories is injected into
the agent's system prompt. The agent can call `recall_memory(query)` to search
memories via FTS5, and `remember_memory(kind, content, summary)` to save new
facts it discovers during your session.

On REPL exit, the agent automatically extracts salient facts from the session
and saves them as memories. Disable with `PAR_NO_AUTO_EXTRACT=1`.

Memory kinds: `preference`, `convention`, `insight`, `gotcha`, `task_map`.

### MEMORY.md export

`par memory export` generates a human-readable markdown file you can commit to
your repo. This is a read-only export — the database is the source of truth.

## Long-session Continuity

par-code v0.4.0 introduces long-session continuity features that keep hour-long
coding sessions productive without losing context.

### Session checkpoints

Every N turns (default 10, configurable), a checkpoint-writer subagent snapshots
the session state into a structured entry:

- **What you're working on** (task description)
- **Key decisions made** (architectural choices, approach)
- **Files touched** (read, written, or edited paths)
- **Interfaces added/modified** (function/type signatures)
- **Open threads** (TODOs, unresolved questions)

Checkpoints run with `~save:false ~update_current:false` — checkpoint and
extraction LLM calls never interfere with your conversation state.

```sh
/checkpoint      # Force an immediate checkpoint
/checkpoints     # List checkpoints for the current session
```

Disable with `PAR_NO_CHECKPOINT=1` or `checkpoint_enabled: false` in config.

### Context reconstruction on resume

When resuming a session (`par --resume` or `par --continue <id>`), the most
recent checkpoints are rendered into a compact session brief and injected into
the agent's context. The agent picks up exactly where it left off — knowing
what was done, what was decided, and what remains open.

### Budgeted context injection

When the conversation approaches the model's context window limit, older
messages are automatically replaced with a checkpoint summary while the most
recent messages are kept verbatim. A notice is printed:

```
[context compacted at turn 42 — ~130k → ~45k tokens]
```

Configure the budget via `context_budget_tokens` in config (default: 100000).

### Periodic memory extraction

In addition to the session-end extraction (v0.3.1), memories are now extracted
mid-session at each checkpoint cycle. Facts discovered during a long session
appear in the memory index without waiting for the session to end.

## Plan Mode

par-code v0.5.0 introduces Plan Mode, a read-only planning mode that runs
before code changes. In Plan Mode, the agent investigates your codebase and
produces a structured plan before touching any files.

### Switching modes

```
/plan         Switch to plan mode (read-only)
/build        Switch to build mode (full tool access; saves current plan)
```

The REPL prompt shows the current mode: `(plan) par> ` or `(build) par> `.

### What the planner can do

In Plan Mode, the agent has access only to read-only tools: `read`,
`grep`, `find`, `ls`, `recall_memory`, `search_history`,
`git_status`, `git_log`. Write, edit, and bash are not available, so the LLM
never sees their schemas.

The planner produces a markdown plan with sections: Goal, Approach, Files to
Touch, Risks, Open Questions, Steps.

### Plan persistence

When switching from Plan to Build (`/build`), the planner's last output is
saved to `.par/plans/<ISO8601-timestamp>.md`. On the next build-mode turn,
the agent is told the plan file path so it can read it before implementing.

### Managing plans

```sh
par plan              # list saved plans (same as `par plan list`)
par plan list         # list saved plans with size and creation date
par plan show <file>  # display a saved plan (auto-appends .md if omitted)
par plan prune        # delete plans older than 30 days
par plan prune --older-than 7  # delete plans older than 7 days
```

### Agent-invocable switching

The agent can also switch modes itself by calling the `plan_enter` or
`plan_exit` tools, useful for smooth handoffs ("Plan ready, switching to
build").

### Default mode

The default mode is `build` (backward-compatible with v0.4.x). Configure via
`par config` wizard or `par config set default_mode plan`.

## Roadmap

Each release ships **one** user-facing capability — a thin, demonstrable slice.
Version numbers stay minimal (no 1.0 until core parity is earned).

| Version | User-perceivable capability |
|---|---|
| **v0.1.0** ✅ | Project skeleton — links the PAR SDK; `par --version` works. |
| **v0.2.0** ✅ | Interactive coding agent — REPL, provider config, read/write/edit/grep/find/bash, streaming, session persistence. *"It reads and edits my code."* |
| **v0.2.1** ✅ | One-line install & self-update (Linux + macOS) — `curl … \| bash`, no OCaml/opam required; pre-built binaries bundle sqlite3 + libgmp for true portability (glibc ≥ 2.28); `par upgrade` keeps it current. *"Install in one line. Updates itself."* |
| **v0.2.2** | Deferred (upstream `Eio.Process` Windows blocker — `Eio.Process` unimplemented on Windows; re-scope when eio ships Windows process support) |
| **v0.3.0** ✅ | Project memory — SQLite-backed memory with FTS5 full-text search + recall/remember agent tools + `par memory` CLI. *"It remembers my project across sessions."* |
| **v0.3.1** ✅ | Auto-extraction + history search — session-end memory extraction + FTS5 search over past conversations. *"It remembers without being asked, and recalls what it wrote."* |
| **v0.3.2** ✅ | Linux arm64 pre-built binary — Raspberry Pi / AWS Graviton / other aarch64 Linux supported with one-line installer. *"Install on ARM without compiling."* |
| **v0.3.3** ✅ | PAR SDK 0.7.3 + hybrid memory search — memory storage migrated to PAR SDK `Sqlite_memory`; FTS5 + vector + RRF hybrid search via configurable embedding service; per-turn memory injection. *"Memory search understands meaning, not just keywords."* |
| **v0.4.0** ✅ | Long-session continuity — checkpoint-writer subagent, budgeted context injection, context reconstruction on resume, periodic mid-session memory extraction. *"Hours-long sessions never lose the thread."* |
| **v0.4.1** ✅ | Async checkpoints + UX polish — periodic checkpoint/extraction now run as background Eio fibers (no REPL freeze); transcript truncation switched from first-N to last-N; `/checkpoints` shows decisions, files, and open threads per entry. Manual `/checkpoint` stays synchronous for verification. *"Checkpoints no longer freeze the REPL."* |
| **v0.4.2** ✅ | Critical fix — multi-turn conversations now correctly preserve assistant responses in `conversation.history`. PAR SDK 0.7.8 engine bug (silently dropped the terminal assistant message) was affecting v0.4.0 and v0.4.1; this release rebuilds against the fixed PAR SDK. *"The agent remembers what it just said."* |
| **v0.4.3** ✅ | UX quick patch — `/cost` slash command (per-session token accumulator + operational metrics); `par config show` subcommand (prints all 19 fields with masked api_key); config wizard now prompts for 6 previously-hidden options (max_tokens, top_p, auto_extract, checkpoint_*, context_budget_tokens); memory `recall` no longer drops `usage_count`/`last_used_at` fields. Dead `bump_usage` removed. *"Daily-friction fixes — see what your session costs, inspect config without entering the wizard."* |
| **v0.4.5** ✅ | UI abstraction layer — `Ui.*` rendering API with composable styled images; streaming markdown state machine; all 175 printf sites migrated; PAR SDK signals (tool_call chunks, usage_update, bash events) now rendered; 73 new tests. Zero new dependencies. *"Output that's structured, colored, and markdown-aware — and ready for a future TUI swap."* |
| **v0.5.0** ✅ | Plan mode — read-only planner agent + `/plan` `/build` mode switching + plan file persistence + `plan_enter`/`plan_exit` agent tools. *"It plans before it touches code."* |
| **v0.5.1** ✅ | Plan CLI + git tools — `par plan list/show/prune` commands + `git_status`/`git_log` read-only tools for the planner agent. *"Manage saved plans; planner sees git state."* |
| **v0.5.2** ✅ | Streaming fallback — print `resp.text` when provider streaming delivers no chunks. *"No more silent empty responses."* |
| **v0.5.3** ✅ | REPL rendering fixes — tool indicator de-duplication + `/dev/tty` bash confirmation + empty response diagnostics. *"Cleaner tool output; bash no longer swallows your input."* |
| **v0.5.4** ✅ | Session management — `par session list/show/fork` + partial ID resume + Ctrl+C clean exit. *"Browse, fork, and resume sessions without copy-pasting UUIDs."* |
| **v0.5.5** ✅ | Hotfix — Plan Mode tool-filter name fix + startup version-notice fix + REPL prompt flush + `<think>` tag middleware + session scope write-side fix. *"Audit findings resolved; advertised features actually work."* |
| **v0.5.6** ✅ | Audit Wave 2–3 + UX polish — `par config set` all 20 fields + install.sh source compile fallback + `par memory prune --dry-run` + memory prefix resolution + `/session` alignment + legacy scope migration + streaming `<think>` strip + checkpoint/plan `<think>` strips + `/cost` token counts (PAR SDK 0.8.3). *"Every advertised feature works end-to-end; daily-friction UX polished."* |
| **v0.6.0** ✅ | Subagent delegation — `delegate` tool with `explore` (read-only) and `general` (full capability) subagents. Synchronous, isolated, depth-limited. Plus plan mode fix (find_last_assistant_text bug). *"It spawns helpers to explore and work in parallel."* |
| **v0.6.1** ✅ | Install/upgrade fixes — stale-binary permission guard in install.sh + `par upgrade` source-fallback parity (no-prebuilt platforms now self-update via source recompile) + `Filename.temp_file` hygiene. *"Intel Mac upgrade no longer dead-ends."* |
| **v0.6.2** ✅ | UTF-8 REPL input (linenoise) — CJK backspace no longer garbles (raw-mode wcwidth-aware editing) + Ctrl+C-crash fixes (REPL + config wizard) + slash-command stdout-flush fix. New bundled-C `linenoise` dep. *"Type and edit Chinese cleanly."* |
| **v0.7.0** | Goal-driven autonomy — `/goal` + independent judge model + doom-loop detection. *"It won't declare done until the goal is truly met."* |
| **v0.8.0** | Best-of-N reasoning — max-mode (parallel candidates + judge selection). *"It tries several approaches and picks the best."* |
| **v0.9.0** | Self-improvement — `/dream` + `/distill` + custom slash commands. *"It turns my repeated workflows into reusable skills."* |
| **v0.10.0** | Compose mode — spec-driven orchestration with plan/execute/review/tdd/debug/verify/merge skills. *"Give a spec, it designs, codes, reviews, and tests end-to-end."* |
| **v0.11.0** | Ecosystem connections — MCP OAuth + hot-reload + multi-source skills (remote URLs, `.claude`/`.agents`/…). *"Connect any MCP server; pull skills from URLs."* |
| **v0.12.0** | Code intelligence — LSP integration (diagnostics, go-to-def, references, call hierarchy) + lsp tool. *"It navigates code like an IDE."* |
| **v0.13.0** | Safe & reversible — permission ruleset (allow/ask/deny + persisted approvals) + filesystem snapshot/undo. *"It asks before destructive ops; changes can be undone."* |
| **v0.14.0** | Polished terminal app — rich TUI (streaming render, inline permission prompts, i18n). *"A real terminal application."* |
| **v1.0.0** | **Core-parity milestone** — v0.2–v0.14 capabilities complete and stabilized. |

Post-1.0 (extended, on demand): voice input/control, plugin system, codesearch,
notebook editing, apply_patch, LSP rename.

## License

Apache-2.0. See [LICENSE](LICENSE).
