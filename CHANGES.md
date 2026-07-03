# CHANGES

## v0.2.1-dev — One-line install & self-update (UNRELEASED)

> Distribution release. par-code now ships pre-built binaries for Linux (x86_64,
> glibc ≥ 2.17) and macOS (arm64). Users install with a single `curl | bash`
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
- **Pre-built Linux binary** (CentOS 7 + devtoolset-11 build base, glibc ≥ 2.17
  baseline). Bundles `libsqlite3.so.0` + `libgmp.so.10` with `$ORIGIN` RPATH via
  patchelf. devtoolset-11 is required because OCaml 5.x's configure hard-rejects
  gcc < 4.9; CentOS 7's stock gcc 4.8.5 fails.
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
  (docker build via CentOS 7 Dockerfile), build-macos (macos-15 runner),
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
