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

- **v0.1.0** — Project skeleton + README (this release).
- **v0.2.0** — Interactive REPL: config wizard, multi-turn chat, built-in file
  tools, type-safe bash, streaming output, SQLite persistence.
- **v0.3.0** — Custom code tools (AST-aware edits, semantic search) and skill
  packaging (review / refactor / test behaviors).
- **v0.4.0** — MCP client integration (filesystem, git, GitHub) and multi-step
  workflows (lint → test → commit).

## License

Apache-2.0. See [LICENSE](LICENSE).
