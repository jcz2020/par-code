# par-code

> An interactive coding agent built on the [PAR](https://github.com/jcz2020/par)
> SDK — and a real-world validation case for PAR itself.

`par-code` is a terminal coding assistant (terminal-native, REPL-first) implemented in
OCaml on top of the **PAR (Programmable Agent Runtime)** SDK. It inherits PAR's
CLI conventions and drives the full PAR surface — ReAct loop, tool dispatch,
type-safe bash, MCP client, skills, workflows, streaming — to both ship a
useful agent and prove out the PAR SDK in anger.

**Status:** `v0.2.1` — distribution release. pre-built binaries with a
one-line installer (`curl | bash`) for Linux + macOS, plus `par upgrade`
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
| Custom tool registration | Code-specific tools (AST edits, semantic search) |
| MCP client (`Par.Mcp_client`) | Connect filesystem/git/GitHub MCP servers |
| Skills (`Par.Skill_registry`) | Package review/refactor/test behaviors |
| Workflows (`Par.Workflow_engine`) | lint → test → commit pipelines |
| Streaming (`invoke_stream`) | Real-time token + tool output |
| Long generation (`invoke_generate`) | PRDs, docs, large diffs |
| Persistence (`Par.Sqlite_persistence`) | Session history across runs |

## Install

### One-line installer (Linux + macOS)

**Linux** (x86_64, glibc >= 2.28 — covers AlmaLinux 8+, Debian 11+, Ubuntu 20.04+, RHEL 8+, Fedora, Arch, etc.):

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
```

**macOS** (arm64 Apple Silicon; Intel Mac runs via Rosetta 2):

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
```

This downloads a pre-built `par` binary with `libsqlite3` + `libgmp` bundled
alongside it (no system prerequisites). The binary lands at `~/.par/bin/par`.
The installer offers to add `~/.par/bin` to your shell's PATH.

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

### Platform support

| Platform | v0.2.1 status | Notes |
|---|---|---|
| Linux x86_64 (glibc >= 2.28) | ✅ Pre-built binary | Covers AlmaLinux 8+, Debian 11+, Ubuntu 20.04+, RHEL 8+, Fedora |
| macOS arm64 (Apple Silicon) | ✅ Pre-built binary | Native |
| macOS x86_64 (Intel) | ✅ Via Rosetta 2 | Same arm64 binary; ~20-40% performance penalty (acceptable for CLI) |
| Windows x86_64 | ❌ Not in v0.2.1 | Native binary + code signing ship together in v0.2.2 |
| Alpine Linux (musl) | ❌ Not in v0.2.1 | Static musl binary is a v0.2.3 stretch goal |

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

## Roadmap

Each release ships **one** user-facing capability — a thin, demonstrable slice.
Version numbers stay minimal (no 1.0 until core parity is earned).

| Version | User-perceivable capability |
|---|---|
| **v0.1.0** ✅ | Project skeleton — links the PAR SDK; `par --version` works. |
| **v0.2.0** ✅ | Interactive coding agent — REPL, provider config, read/write/edit/grep/find/bash, streaming, session persistence. *"It reads and edits my code."* |
| **v0.2.1** ✅ | One-line install & self-update (Linux + macOS) — `curl … \| bash`, no OCaml/opam required; pre-built binaries bundle sqlite3 + libgmp for true portability (glibc ≥ 2.28); `par upgrade` keeps it current. *"Install in one line. Updates itself."* |
| **v0.2.2** | Windows native + code signing — `irm … \| iex` installer, signed Windows binary via cloud signing service; darwin-x64 (universal binary or Rosetta-only formalized). *"It runs on Windows too."* |
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
