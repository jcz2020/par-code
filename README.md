# par-code: an open-source AI coding agent for the terminal

**An open-source AI coding agent that lives in your terminal.**
Full-screen TUI · persistent project memory · plan and goal modes · MCP · OCaml

[![Release](https://img.shields.io/github/v/release/jcz2020/par-code?display_name=tag&sort=semver)](https://github.com/jcz2020/par-code/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![CI](https://github.com/jcz2020/par-code/actions/workflows/ci.yml/badge.svg)](https://github.com/jcz2020/par-code/actions/workflows/ci.yml)
[![Platforms](https://img.shields.io/badge/platforms-linux%20%7C%20macos-lightgrey)](#platform-support)

`par-code` is a terminal coding agent: you describe a change in plain language,
and it reads your repository, edits files, runs commands, and verifies the
result without leaving the shell. It is written in OCaml on top of the PAR
agent SDK, ships as a single self-contained binary, and keeps its working
memory in a local SQLite database instead of a hosted service.

It is built for people who already live in a terminal and want an agent that
behaves like a careful colleague: it plans before editing, asks before running
destructive commands, snapshots the workspace so changes can be undone, and
never needs a browser, an IDE plugin, or a background daemon.

---

## Quick start

```sh
# 1. Install (Linux x86_64/arm64, macOS arm64 — no OCaml toolchain needed)
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash

# 2. Point it at a chat-completions-compatible endpoint (interactive wizard)
par config

# 3. Start working
cd ~/your-project && par
```

Or ask a single question without the interface:

```sh
par ask "Why does the release workflow pin actions to commit SHAs?"
```

## Why use it

- **It is a terminal application, not a chat wrapper.** Transcript, status bar,
  streaming markdown, scrollback, mouse wheel, bracketed paste, in-frame
  approval prompts, and resize handling are all part of one full-screen UI.
- **It remembers your project.** Conventions, gotchas, and decisions are stored
  per repository and recalled in later sessions — no re-explaining the layout
  every morning.
- **It asks before it breaks things.** A permission ruleset decides which
  commands run, and whole-workspace snapshots make `/undo` possible.
- **Long sessions keep the thread.** Checkpoints summarize hours of work, and a
  crammed context window is compacted rather than silently truncated.
- **You can watch it work.** Every tool call, diff, and command result is
  rendered in the transcript as it happens, not after the fact.

## Features

### A real terminal interface

`par` opens a full-screen frame: the transcript scrolls, the status bar shows
`model · mode · tokens · context fill · git branch`, and the input line supports
multi-line editing, word-wise motion (`Ctrl/Alt+←/→`, `Alt+Backspace`),
command completion, and history that survives restarts (`~/.par/history`).

Approvals for shell commands and plan submissions appear as in-frame modals, so
the interface never jumps to a second screen. `Ctrl+C` clears the line; pressed
twice it exits. When stdin is not a terminal (`echo "…" | par`), the same binary
answers once and prints plain text.

### Code editing that verifies itself

The agent reads, writes, edits, and patch-applies files, searches with
grep/find, and runs commands through a type-safe bash tool (argv, no shell
injection). It is instructed to check its work with your project's own build and
test commands before claiming success.

### Project memory (local, searchable)

Memory lives in SQLite under `~/.par/par.db` with FTS5 full-text search and
optional vector search, scoped per project (keyed on the git root). A compact
index is injected into the system prompt each turn; the agent can call
`recall_memory` / `remember_memory` itself, and on exit it extracts what it
learned. You stay in control:

```sh
par memory list
par memory search "authentication"
par memory search-history "why did we switch to sqlite"
par memory export -o MEMORY.md     # readable, commit-friendly snapshot
par memory prune --older-than 90 --dry-run
```

Memory kinds: `preference`, `convention`, `insight`, `gotcha`, `task_map`.

### Long-session continuity

A checkpoint writer runs in the background and records decisions, files
touched, and open threads. When the conversation approaches
`context_budget_tokens`, older turns are replaced by the latest checkpoint
summary instead of being cut off mid-sentence. `/checkpoints` lists them,
`/checkpoint` forces one, and `/resume` continues a run that a crash
interrupted.

### Plan mode

`/plan` switches to a read-only planner: it can read files, search, and inspect
git state, but cannot write. The result is a saved plan file you can review;
`/build` returns to full tool access. Plans are managed with
`par plan list|show|prune`.

### Goal mode

`/goal <description>` (or `par --goal`) starts an autonomous chain: after each
turn a separate judge model decides whether the goal is actually met. Doom-loop
detection, progress checks, and an error-streak guard stop runs that are going
nowhere, and `Ctrl+C` pauses mid-invoke without losing the conversation.

### Best-of-N reasoning

`/max 3` answers the same request along several strategy angles with read-only
candidates, then a selector picks one and routes it to a single-writer
execution. `/max off` returns to the normal single-pass loop.

### Delegation and workflows

A `delegate` tool spawns an `explore` (read-only) or `general` subagent for
work that can run in parallel. File-defined workflows live in
`.par/flows/<id>.json` and run with `/flow run <id> <spec…>`; a built-in
seven-stage `compose-seven` flow (plan → execute → review → tdd → debug →
verify → merge) is included.

### Custom skills

Repeated workflows become skills: `./.par/skills/<id>/skill.md` in a project or
`~/.par/skills/<id>/skill.md` for all projects. Only `trigger: manual` skills are
registered as `/<id>`. `/distill` turns a session into a proposed skill, shows
it for confirmation, and writes it atomically. Remote skill sources can be
pulled from URLs on startup.

### MCP servers

Connect Model Context Protocol servers over stdio or HTTP; their tools become
available to the agent, and `/mcp reload` picks up changed commands, URLs, new
servers, and removed ones without restarting the session.

### Permissions and undo

Two rule files — `~/.par/permissions.json` and `./.par/permissions.json` — hold
ordered `allow` / `ask` / `deny` rules matched against tool names and command or
path substrings; the first match wins, and user-level rules are read before
project ones. Bash approval has three modes (`ask`, `auto_project`, `always`).
Whole-workspace snapshots live under `.par/snapshot.git`, so `/undo [n]` and
`/snapshots` can roll back a bad edit.

### Sessions

Conversations persist locally. `par session list|show|fork` works from the
shell, `/sessions` picks one from inside the interface, and partial IDs are
enough to resume.

## Install

### One line (recommended)

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
```

Installs to `~/.par/bin/par` and offers to add it to `PATH`. Custom prefix or
pinned version:

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash -s -- --prefix /opt/par
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash -s -- --version v0.15.1
```

`par upgrade` checks for and installs newer releases; `par upgrade --check`
only reports. Release archives ship a `checksums.txt`.

### Platform support

| Platform | Status | Notes |
|---|---|---|
| Linux x86_64 (glibc >= 2.28) | ✅ Pre-built binary | Debian 11+, Ubuntu 20.04+, RHEL/Alma 8+, Fedora |
| Linux arm64 (aarch64) | ✅ Pre-built binary | Raspberry Pi 4/5, AWS Graviton |
| macOS arm64 (Apple Silicon) | ✅ Pre-built binary | Native |
| macOS x86_64 (Intel) | ✅ Source compile | Installer and `par upgrade` compile from source |
| Windows x86_64 | ❌ Not yet | Blocked upstream on process support |
| Alpine / musl | ❌ Not yet | Static musl build is a stretch goal |

Binaries bundle SQLite (FTS5, vector extension) and GMP, so they run without
system SQLite or OCaml/opam installed.

### From source

```sh
opam install par --deps-only --with-test   # PAR SDK, pinned to a release tag
git clone https://github.com/jcz2020/par-code && cd par-code
dune build && dune runtest
dune exec -- par
```

## Configuration

The wizard (`par config`) writes `~/.par/config.json`. `par config show` prints
every field with the API key masked, and `par config set <field> <value>` edits
one. Typical fields:

| Field | Meaning |
|---|---|
| `provider` | Chat-completions-compatible endpoint (or messages-style) |
| `api_base`, `api_key`, `model` | Endpoint, credential, default model |
| `max_tokens`, `top_p`, `temperature` | Generation limits |
| `context_window_tokens` | Model context window (default 128000) |
| `context_budget_tokens` | When older turns collapse into a checkpoint |
| `bash_approval` | `ask` / `auto_project` / `always` |
| `max_candidates` | Default Best-of-N width |
| `auto_extract`, `checkpoint_*` | Memory extraction and checkpoint cadence |
| `skill_sources` | URLs to pull remote skills from |

Project state lives next to the code: `.par/` holds permissions, snapshots,
flows, and project skills. Global state lives in `~/.par/`.

## Command reference

Inside the interface:

| Command | What it does |
|---|---|
| `/help` | Command list and key bindings |
| `/model` | Switch model for the session (saved to config) |
| `/sessions`, `/session` | Pick a saved session · show current session info |
| `/plan`, `/build` | Read-only planning mode · full tool access |
| `/goal`, `/max` | Autonomous goal with judge · Best-of-N width |
| `/checkpoints`, `/checkpoint` | List · force a session checkpoint |
| `/resume` | Continue an interrupted run (`discard` to drop) |
| `/undo [n]`, `/snapshots` | Roll the workspace back · list snapshots |
| `/skills`, `/distill` | List user skills · turn a workflow into one |
| `/flow run\|status\|cancel\|resume` | Run file-defined workflows |
| `/mcp`, `/mcp reload` | List MCP servers and tools · reload them |
| `/cost`, `/health` | Token usage · runtime health |
| `/reset`, `/quit` | Reset conversation · exit |

From the shell: `par`, `par ask "…"`, `par config …`, `par memory …`,
`par plan …`, `par session …`, `par upgrade …`.

## How it works

```
bin/main.ml        Cmdliner entry point (subcommands + flags)
   │
   ▼
lib/par_code_setup  build the runtime: tools, agents, middleware, approvals
   │
   ▼
PAR SDK ReAct loop  model ⇄ tools, streaming, persistence
   │
   ▼
~/.par/par.db       conversations, checkpoints, memory (SQLite WAL, FTS5)
```

`par-code` registers its tools, subagents, and middleware on one PAR runtime
per process; every auxiliary model call (checkpointing, memory extraction,
distillation, judging, candidate selection) runs on that same runtime with
saving disabled. [`docs/DECISIONS.md`](docs/DECISIONS.md) records why each
design choice was made, and [`CHANGES.md`](CHANGES.md) lists what shipped in
each release.

## FAQ

**Is par-code free?** The client is open source under Apache-2.0. You bring your
own model endpoint, so you pay only that provider.

**Which models can I use?** Any chat-completions-compatible endpoint (a
messages-style API is supported too). The model is a config field and can be
switched mid-session with `/model`.

**Does it send my code anywhere?** Code is sent to the model endpoint you
configure, and to nothing else. Memory, sessions, checkpoints, and snapshots are
stored locally in SQLite and `.par/`.

**Does it work without a network?** No — it needs your model endpoint. Everything
around it (history, memory search, snapshots) is local.

**Can it edit files and run commands on its own?** It can, and that is why the
permission ruleset, approval modes, and workspace snapshots exist. `deny` rules
win over everything, delete-class commands always prompt, and `/undo` restores a
snapshot.

**How is it different from other terminal agents?** It is one process with no
daemon or plugin layer, its state is a local SQLite file you can inspect, long
sessions are compacted through explicit checkpoints, and the whole thing is
built on a small OCaml agent runtime rather than a JavaScript or Python stack.

**Does it support Chinese and other non-ASCII text?** Yes — input editing,
markdown rendering, and truncation are all UTF-8 and display-width aware.

**Why OCaml?** Startup does not wait on an interpreter or a package loader, the
binary is self-contained, and the agent loop's types are checked at compile
time.

## Roadmap

Each release ships one user-facing capability. Shipped so far: interactive
agent, one-line install, project memory with hybrid search, checkpoint-based
continuity, plan mode, subagents, goal mode with a judge, Best-of-N reasoning,
custom skills, workflows, MCP, permissions with snapshots, and the full-screen
terminal UI. Next milestone is v1.0.0: core-parity stabilisation.

[`CHANGES.md`](CHANGES.md) is the authoritative release log;
[`docs/DECISIONS.md`](docs/DECISIONS.md) records the reasoning behind each
design change.

## 中文速览

`par-code` 是一个开源的终端 AI 编码助手：在命令行里用自然语言描述需求，它会读代码、
改文件、跑命令并自己验证结果。全屏终端界面、按项目保存的长期记忆、计划模式、目标模式、
MCP 支持，整个程序是一个自包含的二进制（macOS/Linux，无需安装 OCaml）。

```sh
curl -fsSL https://github.com/jcz2020/par-code/releases/latest/download/install.sh | bash
par config   # 配置一个 chat-completions 兼容的模型端点
par          # 进入界面
```

## Contributing

Issues and pull requests are welcome. `make dev-deps` installs dependencies,
`dune build` and `dune runtest` are the gates CI runs, and
`bash test/integration/run.sh` runs the end-to-end harness on Linux. Each
subdirectory carries an `AGENTS.md` describing its conventions.

## License

Apache-2.0. See [LICENSE](LICENSE).
