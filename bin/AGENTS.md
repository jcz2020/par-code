# bin/ — the `par` executable

**Score 9** — 3 files, 908 LOC. Earned its file: distinct domain (Cmdliner CLI wiring), the repo's only OCaml entry point.

## WHERE TO LOOK

| Task | File |
|---|---|
| Subcommand groups, dispatch, exit codes | `main.ml` (698) — ~30 `cmd_*` fns, 7 Cmdliner groups |
| Flag definitions | `cli_args.ml` (210) — 29 args; `main.ml` is the single consumer |
| Build stanza | `dune` — `(executable (name main) (public_name par) (modules main cli_args))` |

Subcommand tree: `par` (REPL, default), `ask`, `config show|set`, `upgrade`, `memory list|add/forget/show/export/prune/search/search-history`, `plan list/show/prune`, `session list/show/fork`.

## CONVENTIONS

- One arg per top-level `let` in `cli_args.ml`, each with a LOCAL `let open Cmdliner in` (no file-level open); `main.ml` instead opens `Cmdliner` + `Par` at the top.
- Wiring style: `Term.const f $ arg` chains; subcommands `Cmd.v info term`; groups `Cmd.group ~default:…`.
- Exit codes are manual `exit 1` / `exit 2` inside handlers, not Cmdliner's.
- No `.mli` — both modules are private to the executable; nothing may import them (verified: zero external references).
- `main.ml` consumes 10 `Par_code_*` modules — the widest coupling surface in the repo.
- Chat-mode flags (`--provider`, `--model`, `-c/--continue`, `-r/--resume`, `--goal`, `--max`, …) merge over `~/.par/config.json` via `Par_code_config.merge` before `Par_code_setup.setup_runtime`.
- `par` with no subcommand → `Par_code_repl.run`; `par ask "…"` → `run_single_shot`.
- Version string comes from `Par_code_version.version_info` (dune-generated; see lib/AGENTS.md).

## ANTI-PATTERNS

- `is_chat_mode ()` in `main.ml` scans `Sys.argv` for the literals `config|ask|upgrade|memory|plan|session`. A new subcommand WITHOUT updating this list makes the startup update-check fire incorrectly.
- A new flag needs an entry in `cli_args.ml` AND a term chain in `main.ml` — one without the other silently drops the flag.
- `par upgrade --purge` requires `--uninstall` plus an interactive TTY; otherwise error + exit 2. It must never delete `~/.par` silently.
- `PAR_NO_UPDATE_CHECK=1` disables the startup version check — set it in scripted/CI invocations.
