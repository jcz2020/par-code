# par-code

> An interactive coding agent built on the [PAR](https://github.com/jcz2020/par)
> SDK — and a real-world validation case for PAR itself.

`par-code` is a terminal coding assistant (Claude-Code-style) implemented in
OCaml on top of the **PAR (Programmable Agent Runtime)** SDK. It inherits PAR's
CLI conventions and drives the full PAR surface — ReAct loop, tool dispatch,
type-safe bash, MCP client, skills, workflows, streaming — to both ship a
useful agent and prove out the PAR SDK in anger.

**Status:** `v0.1.0-dev` — project skeleton. The `par-code` executable links
against the PAR SDK and exposes `--version` / `--help`. The interactive REPL
lands in `v0.2.0`.

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
| Custom tool registration | Code-specific tools (AST edits, semantic search) |
| MCP client (`Par.Mcp_client`) | Connect filesystem/git/GitHub MCP servers |
| Skills (`Par.Skill_registry`) | Package review/refactor/test behaviors |
| Workflows (`Par.Workflow_engine`) | lint → test → commit pipelines |
| Streaming (`invoke_stream`) | Real-time token + tool output |
| Long generation (`invoke_generate`) | PRDs, docs, large diffs |
| Persistence (`Par.Sqlite_persistence`) | Session history across runs |

## Install

par-code depends on the PAR SDK, which is **not yet on the public opam
repository**. Install it from source first:

```sh
# 1. PAR SDK (once)
opam pin add par https://github.com/jcz2020/par.git

# 2. par-code
git clone https://github.com/jcz2020/par-code.git
cd par-code
opam install . --deps-only --with-test
dune build
```

Run:

```sh
dune exec -- par-code --version
```

## Project layout

```
par-code/
├── bin/          # `par-code` executable + CLI args (mirrors PAR's bin/)
├── lib/          # `par_code` library facade (agent helpers land here)
├── test/         # Alcotest suite
└── dune-project  # par_code package, depends on par (>= 0.6.2)
```

## Roadmap

Each release ships **one** user-facing capability — a thin, demonstrable slice.
Version numbers stay minimal (no 1.0 until core parity is earned).

| Version | User-perceivable capability |
|---|---|
| **v0.1.0** ✅ | Project skeleton — links the PAR SDK; `par-code --version` works. |
| **v0.2.0** | Interactive coding agent — REPL, provider config, read/write/edit/grep/find/bash, streaming, session persistence. *"It reads and edits my code."* |
| **v0.3.0** | Project memory — `MEMORY.md` + FTS5 full-text search + memory/history tools. *"It remembers my project across sessions."* |
| **v0.4.0** | Long-session continuity — checkpoint-writer subagent, budgeted context injection, context reconstruction. *"Hours-long sessions never lose the thread."* |
| **v0.5.0** | Plan mode — read-only plan agent, build/plan switching, plan_enter/plan_exit. *"It plans before it touches code."* |
| **v0.6.0** | Subagent delegation — general/explore subagents, actor tool, task tree. *"It spawns helpers to explore and work in parallel."* |
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
