# lib/ — the `par_code` library

**Score 15** — 56 files (31 `.ml`, 24 `.mli`, `dune`), 10.0k LOC. Earned its file: the entire product core; every other directory consumes it.

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
| Subagents / sessions / approvals / upgrade | `par_code_delegate.ml` (300), `par_code_session.ml` (210), `par_code_approvals.ml` (136), `par_code_upgrade.ml` (350) |
| Workflows on files (v0.10.0) | `par_code_flow.ml` (60) — `.par/flows/<id>.json` → `/flow` |

## CONVENTIONS

- 800-line file limit — extract when exceeded. `repl` (868) is the known violation; `repl_io` and `config_wizard` exist because of this rule.
- v0.9.0 W0/W1: user skills live at `./.par/skills/<id>/skill.md` (project first) and `~/.par/skills/`; only `trigger: manual` is registered; the REPL adds `/skills` and `/<id>`; the SDK does not consume `body_path`, so `Par_code_skills.read_body` injects the body via `~system_prompt_appendix`.
- v0.9.0 W2: `/distill` calls the tools-free `skill-distiller` agent for one JSON proposal; `par_code_distill` validates id/reserved/builtin/existing/description/body, shows it, writes via temp-file parse + rename, backs up to `.par/backups/skills/` on `--force`, then reloads; Build mode only. `--id <id>` pins the target id (overriding the model's pick) and is what makes `--force` reachable; the model call runs on `Runtime.invoke` with a REPL cancellation token (`?on_invoke` scopes it to the call), so Ctrl+C cancels instead of exiting.
- v0.9.0 W1 reload: PAR 0.12-beta has no skill unregister/replace on `Runtime` (`rt.skills` is private, `Skill_registry.t` abstract), so a rewritten skill keeps par-code fresh (listing / dispatch / body) while the SDK binding keeps old frontmatter until restart. `Par_code_skills.frontmatter_diff` makes `/skills reload` warn only on real drift and name the fields.
- v0.10.0 并发：`delegate_batch` 直接走 SDK 的 `Runtime.invoke_parallel`（`~parallel_limit:4 ~failure_policy:Continue_on_failure`），成功/失败两个列表各自保序，用 `merge_batch_results` 按 `spec.input` 双指针归并回输入序；**不要比较 spec 结构**——含 approval handler（函数字段），`(=)` 会抛。并行子任务必须只读（`delegate_batch` 只收 `explore`）。max-mode 仍走自己的 `Eio.Fiber.all`：它需要 usage，而 `invoke_parallel` 的 step 结果只回 text/tool_calls。
- v0.10.0 工作流：流程定义放 `.par/flows/<id>.json`（内容就是 `workflow_def` 的 yojson），`/flow run` 用 **同步** `submit_workflow` —— REPL 输入是 linenoise（Eio 之外的阻塞 C 调用），`submit_workflow_async` 叉出的 fiber 在提示符等待时不会被调度。格式由 `[@@deriving yojson]` 决定：step 是 `["Agent_call", {...}]`，空构造子如 `["Continue_on_failure"]`，`variables` 是 `[[name, value]]`。
- v0.10.0 崩溃恢复：REPL 与 `par ask` 的 invoke 都带 `~durable:true`；启动用 `list_orphaned_invokes` 提示孤儿行，`/resume [id|discard]` 走 `recover_invoke`；`Runtime` 没有删除入口，discard 通过 setup 暴露的 persistence service 调 `delete_invoke_checkpoint_fn`。语义至少一次：崩溃时在跑的那一轮重跑、已完成的工具批次不重跑；等审批挂起的运行不进孤儿列表。
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
