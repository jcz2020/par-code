# lib/ — the `par_code` library

**Score 15** — 58 files (32 `.ml`, 25 `.mli`, `dune`), 10.1k LOC. Earned its file: the entire product core; every other directory consumes it.

Flat directory — no subdirs; the module set IS the architecture. All modules are top-level `Par_code_*` (`(wrapped false)` in `dune`).

## WHERE TO LOOK

| Task | Modules (LOC) |
|---|---|
| Runtime bootstrap: tools, agents, middleware, bash approval | `par_code_setup.ml` (680) |
| User/project skills: discovery, registration, body read | `par_code_skills.ml` (v0.9.0 W0/W1) |
| Skill distillation: /distill proposal + atomic write | `par_code_distill.ml` (v0.9.0 W2) |
| REPL loop, slash commands, goal-chain driver | `par_code_repl.ml` (880) + `par_code_repl_io.ml` (333) |
| Rendering: image algebra, ANSI backend, `render_*` | `par_code_ui.ml` (776) + `par_code_ui_markdown.ml` (320) |
| Config (38 fields) + wizard | `par_code_config.ml` (699) + `par_code_config_wizard.ml` (218) |
| Memory: Sqlite_memory proxy, FTS5/vec0, export | `par_code_memory.ml` (609) + `par_code_memory_tools.ml` (282) |
| Plan mode: six-section gate, synthesizer fallback | `par_code_plan_tools.ml` (574) |
| Long-session continuity | `par_code_checkpoint.ml` (449) |
| Goals: lifecycle / judge / chain / doom-loop / progress | `par_code_goal.ml` (134), `par_code_judge.ml` (128), `par_code_chain.ml` (300), `par_code_doom_loop.ml` (278), `par_code_progress.ml` (46) |
| Best-of-N: candidates + selector | `par_code_max_mode.ml` (168) + `par_code_selector.ml` (133) |
| Subagents / sessions / approvals / upgrade | `par_code_delegate.ml` (290), `par_code_session.ml` (210), `par_code_approvals.ml` (136), `par_code_upgrade.ml` (350) |
| Bounded parallel fan-out (v0.10.0) | `par_code_parallel.ml` (26) — `delegate_batch` 的底座 |

## CONVENTIONS

- 800-line file limit — extract when exceeded. `repl` (868) is the known violation; `repl_io` and `config_wizard` exist because of this rule.
- v0.9.0 W0/W1: user skills live at `./.par/skills/<id>/skill.md` (project first) and `~/.par/skills/`; only `trigger: manual` is registered; the REPL adds `/skills` and `/<id>`; the SDK does not consume `body_path`, so `Par_code_skills.read_body` injects the body via `~system_prompt_appendix`.
- v0.9.0 W2: `/distill` calls the tools-free `skill-distiller` agent for one JSON proposal; `par_code_distill` validates id/reserved/builtin/existing/description/body, shows it, writes via temp-file parse + rename, backs up to `.par/backups/skills/` on `--force`, then reloads; Build mode only. `--id <id>` pins the target id (overriding the model's pick) and is what makes `--force` reachable; the model call runs on `Runtime.invoke` with a REPL cancellation token (`?on_invoke` scopes it to the call), so Ctrl+C cancels instead of exiting.
- v0.9.0 W1 reload: PAR 0.12-beta has no skill unregister/replace on `Runtime` (`rt.skills` is private, `Skill_registry.t` abstract), so a rewritten skill keeps par-code fresh (listing / dispatch / body) while the SDK binding keeps old frontmatter until restart. `Par_code_skills.frontmatter_diff` makes `/skills reload` warn only on real drift and name the fields.
- v0.10.0 并发：所有扇出走 `Par_code_parallel.map ?parallel_limit`（底层 `Eio.Fiber.List.map ~max_fibers`，默认 4，钳制 1..16），逐项把异常收成 `Error`，`Eio.Cancel.Cancelled` 必须原样上抛；**不要用 `Runtime.invoke_parallel`**——它的 `Agent_call` 步骤只回 text/tool_calls，丢了 conversation 与 usage。并行子任务必须只读（`delegate_batch` 只收 `explore`），写并行要等 per-child worktree。
- v0.10.0 SDK 0.16：`message` 不再有 `reasoning_content`——推理在 `content_blocks` 的 `Reasoning_block` / `Redacted_reasoning_block` 里，`llm_response.reasoning` 是有序列表；`handler_result` 多了 `Success_content`（工具可回图像等富内容）；`persistence_service` 的 durable-invoke checkpoint / lease 六个钩子必须实现，否则 record 构造不过；`Http_client.tls_host_of_string` 已移除，自己用 `Domain_name.host` 构造 SNI。
- v0.8.2 工具行边界：`Par_code_ui_markdown.has_pending` + `push "\n"` 在渲染工具/状态行前刷出半行（保留 code-block context）；`Tool_call_start` 独占一行；表格/help/cost/session 用无内嵌换行的 image，`render_line` 补一个行尾换行。
- v0.8.2 `/cost`：事件回调对 `Tool_invoked` 调 `Runtime.record_tool_invocation`（每次调用一次，bash 不重复计）；max-mode 候选各自记录，胜者事件重放走不带 `~rt` 的回调；`tools_visible` 由主 agent 去重工具数计算；SDK 0.12-beta 的 `events_*` / budget 计数器不展示。
- 手动 `/checkpoint` 传 `~extract:false`；周期 `maybe_checkpoint` 仍提取记忆（v0.8.2+）。
- doom-loop action-streak 排除 bash 与编辑类工具（各有 bash_retry / edit_repeat）；其余非 info 工具仍计数（v0.8.2+）。
- Pure-core extraction for testability: decision logic lives in side-effect-free modules (`progress`, `chain`, `doom_loop`, `json_extract`, `plan_tools.gate_response`).
- Errors are polymorphic variants RETURNED across module boundaries, never raised: ``[> `Db_error of string]``, ``[> `Plan_error of string]``, upgrade's ``[> `Http of string | `Offline]``.
- Atomic writes for ALL persisted state: temp file + `Sys.rename` (config, approvals, goal, doom-loop incidents). This fixed a ~10% config-save flake.
- Every auxiliary LLM agent (checkpoint/extractor/distiller/judge/selector/synthesizer/delegate/candidate) runs on the user's Runtime with `~save:false ~update_current:false` — no second runtime.
- Every agent registration carries `~context_window_override` (default 128000) + `~context_strategy:None` — never rely on the SDK's 8k silent truncation.
- Memory index is injected per turn via `Runtime.invoke ~system_prompt_appendix`, never baked into agent system prompts.
- `think_tag_strip` middleware is a LOCAL ~17-line construct in `par_code_setup.ml` (SDK ships it but does not re-export it via the `Par` facade). Retire when `Par.Think_tag_strip.create ()` appears.
- Prompts are inline `{| … |}` literals in the owning module — no asset files.
- Module-level mutable refs hold global state (`mode.current`, `goal.current`, `plan_tools.last_submitted_plan`); the single-runtime-per-process assumption is documented in the `.mli`s.
- Transcripts fed to sub-agents keep the LAST 8000 chars; doom-loop keeps first 800 + last 800 of a command.

## ANTI-PATTERNS

- NEVER git write ops from agent code. `git_tools` exposes only `git status --porcelain=v1 -b` and `git log --format=%H|%s|%ai` — that is the planner's whole allowlist.
- Parallel agents (explore subagent, max-mode candidates) share ONE read-only tool list by construction — no candidate races another on the workspace.
- NEVER assume `skill_descriptor.body_path` is injected by the SDK — 0.12-beta has no runtime consumer; read it in `Par_code_skills` and pass it as a system-prompt appendix.
- Approval classification fails CLOSED: `..` or `:` in a path, or any unmapped error → `Unknown` → human prompt; delete-class commands (`rm/mv/dd/shred/truncate`) are always `External_path`.
- Do NOT await the checkpoint fiber — fire-and-forget (`par_code_checkpoint.ml:428`).
- NEVER render a tool/status line while markdown has a pending half-line — route through `render_event_line` / `flush_pending_line` first.
- NEVER call `Runtime.record_tool_invocation` from the max-mode winner replay callback — replay is render/doom only, or `/cost` double-counts.
- Config key `doom_loop_threshold` is DEPRECATED → `doom_bash_retries` / `doom_edit_matches` / `doom_action_streak`.
- `lib/par_code_version.ml` is GENERATED by the `dune` rule from `dune-project (version …)` — gitignored, never hand-edit.
- Embedded agent prompt (`par_code_config.ml:65,79,82`): NEVER amend git config, NEVER commit unless the user explicitly asks, never bypass safety checks, never retry failing commands in a loop.
