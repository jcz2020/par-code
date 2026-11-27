# lib/ — the `par_code` library

**Score 15** — 71 files (42 `.ml`, 27 `.mli`, `dune`), ~17k LOC. Earned its file: the entire product core; every other directory consumes it.

Flat directory — no subdirs; the module set IS the architecture. All modules are top-level `Par_code_*` (`(wrapped false)` in `dune`). Adding a module = one file; `lib/dune` is a single library stanza.

## WHERE TO LOOK

| Task | Modules (LOC) |
|---|---|
| Runtime bootstrap: tools, agents, middleware, bash approval | `par_code_setup.ml` (960) |
| Skills: discovery, remote sync, body injection, `/distill` proposal + atomic write | `par_code_skills.ml` (350) + `par_code_distill.ml` (374) |
| REPL loop, slash commands, goal/chain driver, resume, cancellation, save gating | `par_code_repl.ml` (1842) + `par_code_repl_io.ml` (301) |
| Full-screen Notty TUI: frame, status, input editing, modal, scrollback, mouse | `par_code_screen.ml` (2291) — sole terminal owner |
| Rendering: image algebra, ANSI backend, tables/cost, streaming markdown | `par_code_ui.ml` (1123) + `par_code_ui_markdown.ml` (349) |
| Config (38 fields, embedded main-agent prompt) + wizard | `par_code_config.ml` (805) + `par_code_config_wizard.ml` (226) |
| Memory: SQLite/FTS5/vec0, export, prune + tool bindings | `par_code_memory.ml` (625) + `par_code_memory_tools.ml` (282) |
| Plan mode: six-section gate, synthesizer fallback, plan files | `par_code_plan_tools.ml` (574) |
| Long-session continuity: periodic/manual checkpoint + memory extraction | `par_code_checkpoint.ml` (449) + `par_code_extractor.ml` (258) |
| Goals: lifecycle / judge / chain / doom-loop / progress | `par_code_goal.ml` (134), `par_code_judge.ml` (128), `par_code_chain.ml` (300), `par_code_doom_loop.ml` (311), `par_code_progress.ml` (46) |
| Best-of-N: candidates + selector | `par_code_max_mode.ml` (168) + `par_code_selector.ml` (133) |
| Model sandbox: approvals, permission rules, edit preview, line diff | `par_code_approvals.ml`, `par_code_permissions.ml` (145), `par_code_edit_preview.ml` (153), `par_code_diff.ml` (127) |
| Tool plumbing: result capping/hygiene, one-line summaries, `!cmd` passthrough | `par_code_payload.ml` (348), `par_code_tool_summary.ml` (284), `par_code_shell.ml` |
| Sessions / subagents / upgrade / snapshot / git | `par_code_session.ml` (210), `par_code_delegate.ml` (340), `par_code_upgrade.ml` (487), `par_code_snapshot.ml`, `par_code_git_tools.ml` (218) |
| Workflows on files (v0.10.0) | `par_code_flow.ml` (185) — `.par/flows/<id>.json` → `/flow` |

## CONVENTIONS

- 800-line file limit — extract when exceeded. Over the line today: `screen` (2291), `repl` (1842), `ui` (1123), `setup` (960), `config` (805). `repl_io`/`config_wizard` exist because of this rule; split off pure cores, not new coupling.
- v0.9.0 W0/W1: user skills live at `./.par/skills/<id>/skill.md` (project first) and `~/.par/skills/`; only `trigger: manual` is registered; the REPL adds `/skills` and `/<id>`; the SDK does not consume `body_path`, so `Par_code_skills.read_body` injects the body via `~system_prompt_appendix`.
- v0.9.0 W2: `/distill` calls the tools-free `skill-distiller` agent for one JSON proposal; `par_code_distill` validates id/reserved/builtin/existing/description/body, shows it, writes via temp-file parse + rename, backs up to `.par/backups/skills/` on `--force`, then reloads; Build mode only. `--id <id>` pins the target id (overriding the model's pick) and is what makes `--force` reachable; the model call runs on `Runtime.invoke` with a REPL cancellation token (`?on_invoke` scopes it to the call), so Ctrl+C cancels instead of exiting.
- v0.11.0 远程 skill：`skill_sources` 里的 URL 在启动与 `/skills reload` 下载到 `~/.par/skills-remote/<id>/skill.md`，再作为 `Remote` 来源扫描；优先级 project > user > remote，远程永远不覆盖本地同名 id。远程内容按不可信输入处理：只收 markdown，id 必须匹配 `[a-z0-9-]` 且不撞保留命令/内置 skill，单文件 256 KiB 上限，失败保留旧缓存。Eio 的 brand 参数放不进模块级 ref，按 SDK 的做法用 `Obj.repr` 存、`Obj.obj` 取。
- v0.9.0 W1 reload（**0.17.1 起完整**）：`/skills reload` 在 frontmatter 漂移时调 `Runtime.replace_skill`，绑定即时生效；`frontmatter_diff` 用来区分“没变”与“变了”。MCP 侧 `/mcp reload` 走 `Runtime.reload_mcp_servers` + `Runtime.mcp_tool_bindings` + `update_agent_tools`：改 URL/命令、**新增/移除服务器都不必重启**，但只更新“本来就有 MCP 工具”的 agent（`explore` 保持只读）加主 agent `par`。HTTP MCP 现在符合规范（0.17.1 补了 `"jsonrpc":"2.0"`），已对官方 Python `mcp` 服务器验证通过。
- v0.14 TUI（v0.14.2 起是唯一的交互界面）：
  - `Par_code_screen` 用 notty 画整帧（转写区 + 状态栏 + 输入行），`pump` 用 `Unix.select` 带 50ms 超时——按键即时唤醒，空闲时每 50ms 一次唤醒而不是自旋。
  - **任何进入帧的字符串都要过 `sanitize_text`**：notty 的 `I.string` 遇到控制字符直接 raise（模型输出必带 `\n`，曾把界面打崩）；行要按 `\n` 拆开，宽度按显示列算（`I.hsnap`）。
  - 审批/确认优先走 `Par_code_ui.set_modal_hook`（帧内模态）；未装 hook 时回退 /dev/tty，并由 `set_suspend_hooks` 先释放终端。
  - 非 TTY（管道 / 重定向 / CI）走单次问答：stdin 即问题、输出纯文本（等价 `par ask`），stdin 为空才报错；`config set ui` 与 `ui` 字段已移除，`linenoise` 依赖已删除，`Par_code_ui.read_line` 只用于 CLI 向导的 stdin 问答。
- v0.15.7 结果与取消：宿主注册工具与 MCP 工具都过 `Par_code_payload.cap_handler_result`（`tool_output_chars` 默认 32K，超出写 `.par/tool-results/` + 路径）；PAR 0.18 起 `runtime_config.max_tool_result_chars` 也在 engine 层封顶，bash 的重建 handler 由它覆盖（bash 无落盘）。MCP 启动时 `wrap_mcp_bindings` + `update_agent_tools` 挂主 agent，重名工具跳过以免顶掉内置 handler。取消交给 SDK 原生 socket shutdown；`/flow run` 无 token，仍用宿主 `with_interrupt`。弹窗里 Esc 只拒绝当前步，Ctrl-C 才取消整轮（状态栏如实显示）。
- v0.13.0 W1 权限规则：`~/.par/permissions.json` + `./.par/permissions.json` 的 `rules`，按顺序**第一条命中生效**；`tool` 可为 `*`，`match` 是 bash 命令 / 文件工具路径的大小写不敏感子串。`deny` 走 tool_call_hook 对所有工具生效，`allow`/`ask` 对 bash 在审批决策里生效。用户级规则先读，项目级后读（运维 deny 压过仓库 allow）。Yojson 的 `member` 对非对象会抛，取字段一律防御式（工具入参可能是 null）。
- v0.10.0 并发：`delegate_batch` 直接走 SDK 的 `Runtime.invoke_parallel`（`~parallel_limit:4 ~failure_policy:Continue_on_failure`），成功/失败两个列表各自保序，用 `merge_batch_results` 按 `spec.input` 双指针归并回输入序；**不要比较 spec 结构**——含 approval handler（函数字段），`(=)` 会抛。并行子任务必须只读（`delegate_batch` 只收 `explore`）。max-mode 仍走自己的 `Eio.Fiber.all`：它需要 usage，而 `invoke_parallel` 的 step 结果只回 text/tool_calls。
- v0.10.0 工作流：流程定义放 `.par/flows/<id>.json`（内容就是 `workflow_def` 的 yojson），`/flow run` 用 **同步** `submit_workflow`（输入循环在同一个线程里跑，`submit_workflow_async` 的 fiber 在等输入时不会被调度），并起一个后台 fiber 每 5 秒打 `[flow] still running (Ns)`；定义里出现 `planner`/`par`/`general` 这类可能停下的 agent 时先警告 —— **但审批提示仍会送到终端，用户看得到也能回答**，不要把它当成挂死。格式由 `[@@deriving yojson]` 决定：step 是 `["Agent_call", {...}]`，空构造子如 `["Continue_on_failure"]`，`variables` 是 `[[name, value]]`。
- v0.10.0 崩溃恢复：REPL 与 `par ask` 的 invoke 都带 `~durable:true`；启动用 `list_orphaned_invokes` 提示孤儿行，`/resume [id|discard]` 走 `recover_invoke`；`Runtime` 没有删除入口，discard 通过 setup 暴露的 persistence service 调 `delete_invoke_checkpoint_fn`。语义至少一次：崩溃时在跑的那一轮重跑、已完成的工具批次不重跑；等审批挂起的运行不进孤儿列表。
- v0.10.0 SDK 0.16：`message` 不再有 `reasoning_content`——推理在 `content_blocks` 的 `Reasoning_block` / `Redacted_reasoning_block` 里，`llm_response.reasoning` 是有序列表；`handler_result` 多了 `Success_content`（工具可回图像等富内容）；`persistence_service` 的 durable-invoke checkpoint / lease 六个钩子必须实现，否则 record 构造不过；`Http_client.tls_host_of_string` 已移除，自己用 `Domain_name.host` 构造 SNI。
- v0.8.2 工具行边界：`Par_code_ui_markdown.has_pending` + `push "\n"` 在渲染工具/状态行前刷出半行（保留 code-block context）；`Tool_call_start` 独占一行；表格/help/cost/session 用无内嵌换行的 image，`render_line` 补一个行尾换行。
- v0.8.2 `/cost`：事件回调对 `Tool_invoked` 调 `Runtime.record_tool_invocation`（每次调用一次，bash 不重复计）；max-mode 候选各自记录，胜者事件重放走不带 `~rt` 的回调；`tools_visible` 由主 agent 去重工具数计算；SDK 0.12-beta 的 `events_*` / budget 计数器不展示。
- 手动 `/checkpoint` 传 `~extract:false`；周期 `maybe_checkpoint` 仍提取记忆（v0.8.2+）。
- doom-loop action-streak 排除 bash 与编辑类工具（各有 bash_retry / edit_repeat）；其余非 info 工具仍计数（v0.8.2+）。
- Pure-core extraction for testability: decision logic lives in side-effect-free modules (`progress`, `chain`, `doom_loop`, `json_extract`, `plan_tools.gate_response`).
- 启动提示（v0.15.8）：启动路径**只读缓存**（`Par_code_upgrade.cached_update_notice`），过期由 `bin/main.ml` fork 的脱离子进程刷新；`fetch_latest_tag` 的 timeout 参数至今无效，任何同步调用都会把首帧拖住。提示由 `Par_code_repl.run ?update_notice` 写进 TUI 转写区，不要再打到 stdout（会被 notty 首帧覆盖）。
- 启动/退出热路径（v0.15.9）：`create_conversations_fts` 只在建表时 `rebuild`，之后靠 `conv_ai/ad/au` 触发器；REPL 退出只在 `conv` 自上次保存后被替换过时 `save_conversation`（每轮已保存），且不再同步提取记忆——`auto_extract` / `PAR_NO_AUTO_EXTRACT` 已接到周期 `maybe_checkpoint ?extract`。回合进行中的 `/exit` / `/quit` 等同“取消 + 退出”，其它输入仍排队。新增「每次启动全量扫描/重建」或「退出时调 LLM」的写法都会在大会话上放大成秒级。
- 升级可观测（v0.15.8）：`par_code_upgrade` 每个阶段向 **stderr** 打一行带 flush 的 `[info]`（current / checking / download 大小 + 每 2 MB 进度 / checksum / extract / install），stdout 只留最终结果；进度钩子是 `http_get` 的可选 `on_start` / `on_chunk`。`decide_upgrade` 是纯函数：同版本与“本地比发行版新”都返回 `Up_to_date` 不下载，只有显式 `--to` 才允许降级；`perform_upgrade` 返回 `` [`Upgraded of string | `Up_to_date of string] ``，安装（rename/smoke）失败单列 `` `Rename_failed `` 而不是混进下载错误。
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
- Do NOT await the checkpoint fiber — fire-and-forget (`Eio.Fiber.fork` on the cancellation root, `in_flight` throttle released via `Fun.protect`).
- NEVER render a tool/status line while markdown has a pending half-line — route through `render_event_line` / `flush_pending_line` first.
- NEVER call `Runtime.record_tool_invocation` from the max-mode winner replay callback — replay is render/doom only, or `/cost` double-counts.
- Config key `doom_loop_threshold` is DEPRECATED → `doom_bash_retries` / `doom_edit_matches` / `doom_action_streak`.
- `lib/par_code_version.ml` is GENERATED by the `dune` rule from `dune-project (version …)` — gitignored, never hand-edit.
- Embedded agent prompt (`par_code_config.ml`): NEVER amend git config, NEVER commit unless the user explicitly asks, never bypass safety checks, never retry failing commands in a loop.
- `Par_code_screen` owns the terminal: everything else appends images to the transcript. First frame / exit path stays free of network rescans, full rebuilds and LLM calls (`/exit` mid-turn = cancel + exit).
