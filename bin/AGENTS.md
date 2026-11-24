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
- `-v` is an accepted alias for `--version`: `main.ml` intercepts a lone `-v` in `let ()` BEFORE `Cmd.eval` (Cmdliner only wires `--version`), so it works without a config file and skips the startup update check. Keep that intercept ahead of the group parse; do not turn it into a term flag, since the default term calls `Par_code_config.require_config` first.

## ANTI-PATTERNS

- `is_chat_mode ()` 已删除（v0.15.8）：启动提示不再扫 `Sys.argv`。`startup_update_notice` 只读 `~/.par/.latest-cache.json`，**永远不要**在启动路径上调 `fetch_latest_tag`——它会把首帧阻塞 0.9–8.6 秒（移动网络实测）；缓存过期时用一个 `fork` 出来的子进程在后台刷新，下一次启动才能看到新 tag。升级提示现在由 `Par_code_repl.run ?update_notice` 写进 TUI 转写区（以前打到 stdout，被 notty 首帧抹掉）。
- A new flag needs an entry in `cli_args.ml` AND a term chain in `main.ml` — one without the other silently drops the flag.
- `par upgrade --purge` requires `--uninstall` plus an interactive TTY; otherwise error + exit 2. It must never delete `~/.par` silently.
- `PAR_NO_UPDATE_CHECK=1` disables the startup version check — set it in scripted/CI invocations.
