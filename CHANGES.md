# CHANGES

## v0.2.0-dev — Interactive coding agent (UNRELEASED)

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
