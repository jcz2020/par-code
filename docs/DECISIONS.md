# Decisions

### Open PAR SDK feedback

- Mode concept → [2026-07-27] First-class mode concept
- Plan/task primitive → [2026-07-27] Plan/task primitive
- `set_session_id` mutex → [2026-07-19] 3 items surfaced by v0.4.1 async work
- `last_llm_call` atomicity → [2026-07-19] 3 items surfaced by v0.4.1 async work
- `invoke_async` `?save`/`?update_current` → [2026-07-19] 3 items surfaced by v0.4.1 async work
- `Think_tag_strip` facade → [2026-08-15] Think_tag_strip not re-exported via Par facade
- Nested-invoke depth-limiting — anticipated for v0.7.0+, still unfilled, no par-code pain yet

## [2026-08-15] PAR SDK Feedback: v0.7.2 trio — consumed by PAR SDK 0.10.0

**Tag**: PAR SDK Feedback

**变更前**: Three gaps filed during v0.7.2 (referenced in the v0.7.2 scope
decision): (1) write-tool absolute-path error lacked actionable guidance —
the agent saw a raw `Permission denied` or `No such file or directory` when
attempting to write outside the workspace, with no structured metadata or
remediation hint; (2) in-invoke cancellation API missing — there was no
first-class way to signal cancellation mid-turn from par-code's doom-loop
abort or user-initiated Ctrl+C pause; (3) workspace path-admission semantics
unconfirmed — par-code's `auto_project` classifier used argv+regex heuristics
to decide whether a bash command's paths stay inside the workspace, but the
PAR SDK had no canonical admission-check API to validate against.

**变更后**: All three gaps consumed by PAR SDK 0.10.0:
1. **Actionable tool errors**: PAR 0.10.0 ships instructive path-rejection
   messages with metadata codes (e.g. `METADATA:workspace_violation`) on
   write-tool attempts outside the workspace. Agent sees clear guidance
   instead of raw OS errors.
2. **First-class cancellation**: PAR 0.10.0 introduces `Types.cancel_reason`,
   a `Cancellation` module, and per-iteration/tool/chunk cancellation
   checkpoints. par-code v0.7.3 consumes this for doom-loop abort (Guard
   cancel) and Ctrl+C pause.
3. **Workspace path-admission**: PAR 0.10.0 exposes `Par.Workspace.admit` +
   `workspace_*` metadata codes. par-code's `auto_project` classifier already
   consumes `admit` for bash approval classification.

**原因**: v0.7.2 scope decision identified these as blockers for goal-mode
autonomous chaining. PAR SDK 0.10.0 shipped all three primitives, closing
every gap.

**影响范围**: lib/par_code_setup.ml (write-tool error surfacing),
lib/par_code_repl.ml (doom abort + Ctrl+C cancellation wiring),
lib/par_code_config.ml (bash approval auto_project classifier).

**回退方式**: N/A (upstream shipped; workarounds removed).

**已知限制**: none open.

## [2026-08-15] PAR SDK Feedback: Think_tag_strip not re-exported via Par facade

**Tag**: PAR SDK Feedback

**变更前**: par-code carries a local 23-line `think_tag_strip` middleware
(lib/par_code_setup.ml:18-40, 8 agent-registration sites) because PAR ships
`lib/middleware/think_tag_strip.ml` but omits it from the Par facade module
list (lib/par.ml).

**变更后**: filed as open feedback — trivial upstream ask: add
`module Think_tag_strip = Think_tag_strip` to the facade.

**原因**: single source of truth; par-code duplicates logic PAR already
maintains.

**影响范围**: PAR lib/par.ml only; retirement on par-code side = replace
local middleware with `Par.Think_tag_strip.create ()`.

**回退方式**: N/A (filing only).

**已知限制**: severity trivial; no par-code pain beyond duplication.

## [2026-08-15] v0.7.2 实现期决策：invoke_generate 拒绝带工具 agent → 专用 plan-synthesizer

**Tag**: PAR SDK 边界 / 架构

**变更前**: W2 计划让综合兜底复用 planner agent 调 `invoke_generate`。
**变更后**: 注册专用 `plan-synthesizer` agent（tools=[]、六节形状 system
prompt、max_iterations=1），综合调用指向它。
**原因**: 带上调试日志实测发现 PAR SDK `invoke_generate` 对带工具集的
agent 直接返回 `Invalid_input "... generate mode requires tool-free..."`。
planner 必须带只读工具集，二者不可兼得。extractor（无工具）从未踩过此坑。
**影响范围**: lib/par_code_plan_tools.ml（agent id）、lib/par_code_setup.ml
（注册，镜像 extractor 模板）。
**回退方式**: 若 SDK 未来放开限制，可切回 planner；专用 agent 无耦合。
**已知限制**: 多一个常驻 agent 注册（纯生成，无成本直到被调用）。

## [2026-08-15] v0.7.2 实现期决策：doom 回调经 on_doom_action hook 设 flag（而非回调内直接改 goal）

**Tag**: 架构 / 并发

**变更前**: 首版 W3 实现里回调只渲染消息——`doom_abort`/`doom_force_judge`
有消费端无生产端，升级阶梯形同虚设（orchestrator 实测发现）。
**变更后**: `make_tool_event_callback` 增加 `?on_doom_action` hook；
Abort/Force_judge 时经闭包设置 run 局部 flag（Abort 同时携带 msg ref 供
incident 落盘）；between-turns 拦截消费 flag 并落 goal 状态。
**原因**: 回调是模块级函数拿不到 run 的局部 ref；直接传 ref 列表会随
信号种类膨胀。单一 hook 让"检测"（模块级）与"后果"（run 局部）解耦，
测试时可注入 no-op。
**影响范围**: lib/par_code_repl.ml（callback 签名 + run 接线）。
**回退方式**: hook 有默认 no-op，可整体移除而不动检测器。
**已知限制**: 轮内（invoke 进行中）仍只能渲染消息，真正的状态落盘在
invoke 返回后（诚实文案已声明 "current turn will finish"）。

## [2026-08-15] v0.7.2 范围：autonomous goal chaining 推迟一版，改为 goal 可用性收尾

**Tag**: Roadmap / 范围级变更

**变更前**: STRATEGY.md roadmap 排定 v0.7.2 = 全自主 goal chaining（judge
验证通过后自动续 turn，无需用户输入）。

**变更后**: v0.7.2 = goal/plan 可用性收尾（`docs/v0.7.2-ROADMAP.md`，
W0–W7）；chaining 移至 v0.7.3，前置条件为 v0.7.2 验收全绿。

**原因**: 两轮真实 LLM 实测证明 goal mode 在真实写任务上完全不可用：
- v0.7.1 后代跑 QA（生产主力模型）：plan mode 落盘 117 字节客套话；
  goal mode 静默放弃；doom-loop Abort 只打印不中止
- 同模型双 agent 对照走查（同端点同模型、专用 fixture、双副本同任务）：
  三个隐形等待点（bash 确认与 plan 闸门渲染后不 flush 永不可见，后者还会
  吃掉用户下一句输入；推理模型思考期零输出）+ goal 漂移零防护（agent 修错
  任务后自报完成，护栏全程沉默）。对照 agent 三局全胜且全部胜在 harness
  层而非模型层
在单轮跑不通、用户看不到等待点的地基上叠加自动续轮会放大 judge 误判与
成本失控。机制根因均已锚定到 file:line（详见 ROADMAP §1.3）。

**影响范围**: 排期推迟一版；v0.7.2 工作量（W0–W7，10 个原子 commit）与
chaining 原估相当；产生 3 条 PAR SDK Feedback（write 工具错误文本出路
指引、invoke 内取消 API、Workspace 路径包含判定 API 语义确认）。

**回退方式**: v0.7.2 提前完成且 dogfood 良好 → v0.7.3 chaining 直接开工，
无结构性锁定；本决策无代码耦合，纯排期变更。

**已知限制**: `auto_project` 审批判定是 argv+正则近似而非语法解析级 AST
判定（对齐目标 harness 用后者；引入解析器的成本留待 v0.13.0 完整规则引擎
时评估）；轮内强制终止依赖 PAR SDK 反馈进度（当前降级为轮间拦截）；
思考计时行与跨会话记忆召回的最终验证依赖人工 dogfood。

## [2026-08-12] v0.7.1: Dedicated `planner_max_iterations` config + `Generate` early-stop

**Tag**: Architecture / Config

**变更前**: Planner agent's `max_iterations` was computed as
`min cfg.max_iterations 8` at registration (`lib/par_code_setup.ml:441`).
The planner's system prompt prescribes a 5-phase workflow that needs 7 tool
calls (5 investigation + `write_plan_file` + `plan_submit`) + 1 closing LLM
response = 8 iterations total. Budget exactly equal to demand left zero slack,
so any LLM "thinking" iteration, parallel-tool-call batching, retry, or
off-script behavior burned the cap mid-investigation. The engine's default
`early_stopping_method = Force` then returned `Error (Internal "Max iterations
exceeded")`, and the REPL's auto-save fallback printed
`"Plan auto-saved to ... (planner reached step limit)."` — saving whatever
partial text the planner had emitted (often just the preamble "let me
investigate"), not a real plan.

**变更后**:
1. Added dedicated `planner_max_iterations : int` config field (default **15**,
   ~2× the old cap). Follows the existing `max_iterations` lifecycle exactly:
   type, default, `to_json`, `of_json`, `merge`, `update_field`, wizard,
   `show`, valid-keys list. Configurable via `par config set planner_max_iterations N`
   and the interactive wizard. No CLI flag (matches `goal_max_steps`,
   `context_budget_tokens`, `checkpoint_interval` — all config-file only).
2. Planner agent's `early_stopping_method` switched from default `Force` to
   `Types.Generate`. When the iteration budget does exhaust, the PAR SDK
   engine now appends `"Based on the work done so far, provide your best
   final answer."` to the conversation and makes one more LLM call with the
   full investigation context, returning `Ok (resp, conv')` instead of
   `Error`. User gets a synthesized partial plan instead of nothing.

**原因**:
- Budget of 8 was a leftover from an early planner prototype; the prompt grew
  to 7 mandatory tool calls but the cap was never re-checked. Tight coupling
  to `cfg.max_iterations` (main agent budget) meant raising one raised both,
  which is wrong — main agent and planner have different workflow shapes.
- `Force` policy is appropriate for the main agent (errors should surface
  loudly) but wrong for the planner, whose entire purpose is to produce a
  plan. An error mid-investigation gives the user nothing; a synthesized
  best-effort answer at least captures what the planner learned.
- R3 "一次做对": rather than just bumping `8` to `15`, do the structural fix
  (dedicated field + Generate policy) so the same class of bug doesn't recur
  when the planner prompt evolves again.

**影响范围**:
- `lib/par_code_config.ml` — 9 touchpoints (type/default/json/wizard/set/show/keys)
- `lib/par_code_setup.ml:441–442` — agent registration
- `test/test_par_code_config.ml` — +1 unit test, +1 field in round-trip + unknown-field list
- `par_code.opam` — no dependency change
- **Public API**: adds one config field. Non-breaking — old configs without
  the field load fine via `get_i "planner_max_iterations" default.planner_max_iterations`
  fallback. No existing config behavior changes.
- **Migration**: users with `max_iterations = N < 15` who relied on the
  `min N 8` behavior will now see the planner get 15 (not 8). This is the
  intended fix; no migration action needed.

**回退方式**:
- Field removal: revert `par_code_config.ml` and `par_code_setup.ml` changes;
  the field is additive and unused elsewhere.
- Behavioral revert: change `par_code_setup.ml:442` back to
  `~early_stopping_method:Types.Force` (or remove the line entirely — `Force`
  is the default).
- Cap revert: change `par_code_setup.ml:441` back to
  `~max_iterations:(min cfg.Par_code_config.max_iterations 8)`.
- All three are independent and individually reversible.

**已知限制**:
- `Generate` policy's effectiveness depends on the LLM's ability to synthesize
  from the investigation trail. If the planner spent most iterations on tool
  calls and never produced substantial assistant text, the synthesized answer
  may be thin. Not manually verified end-to-end in this release (audit env
  lacked a working LLM provider); covered by type system + PAR SDK contract
  test (`test_engine_assistant_message.ml` test 9).
- `planner_max_iterations` has no CLI flag (`--planner-max-iterations`). This
  matches the convention for "internal" config fields (`goal_max_steps`,
  `context_budget_tokens`, `checkpoint_interval`). Add later if users ask.

## [2026-08-12] v0.7.1: Unified REPL exit path (`exit_normally`)

**Tag**: Bugfix / Architecture

**变更前**: Four exit paths in `lib/par_code_repl.ml` had inconsistent
post-conditions. Only `/exit`-`/quit` and the streaming-time SIGINT handler
called `exit 0`. The Ctrl+D (`None`) and Ctrl+C-at-prompt (`Sys.Break`)
arms returned unit from `loop ()` without terminating the process, leaving
the OCaml runtime in an ambiguous state that could re-prompt the user and
trigger a second memory-extraction pass. User-visible symptom: type Ctrl+D
at the prompt → `[extracting memories...]` → `Bye!` → fresh prompt →
`[extracting memories...]` again → user hits Ctrl+C → second `Bye!`.

**变更后**: Extracted a shared `exit_normally ()` helper inside `run` that
performs `save_conversation → maybe_extract → render_notice "\nBye!" → exit 0`.
Routed three of the four exit paths through it (`/exit`, `/quit`, Ctrl+D,
Ctrl+C at prompt). The streaming-time SIGINT handler stays separate — it
intentionally skips `maybe_extract` for a fast abort while the LLM is
mid-response.

**原因**:
- Three code paths doing nearly the same thing with subtly different
  post-conditions is the textbook setup for the bug that shipped. Centralize
  or repeat the mistake.
- Streaming-SIGINT stays separate because its requirements differ: when the
  user hits Ctrl+C mid-LLM-response, they want immediate termination, not a
  30-second extraction pass. Conflating the two would either slow the fast
  path or lose extraction on the normal path.

**影响范围**:
- `lib/par_code_repl.ml:218–223` (new `exit_normally` helper) + lines 237,
  240, 288 (three call sites). Streaming SIGINT handler at lines 214–217
  unchanged.
- `test/integration/repl/basics_test.sh` — +2 regression tests
  (`test_ctrl_d_exits_cleanly`, `test_ctrl_c_at_prompt_exits_cleanly`) using
  tmux to verify process death within 1s.

**回退方式**:
- Revert `lib/par_code_repl.ml` to pre-v0.7.1 state. The `exit_normally`
  helper is purely a refactoring extract; removing it just inlines the code
  back.

**已知限制**:
- Exact reproduction of the original double-extraction bug was not captured
  in tmux before the fix (the bug was intermittent and depended on signal
  delivery timing). The new regression tests verify the FIXED behavior
  (process exits within 1s of Ctrl+D / Ctrl+C); they don't retroactively
  prove the old bug existed. The user's transcript from the original report
  is the primary evidence.

## [2026-08-10] PAR SDK Feedback: parallel tool-call error loses tool_call_id

**Tag**: PAR SDK Feedback

> **Retired [2026-08-15]**: fixed in PAR SDK 0.9.1 (tool_call_id correlation, 5 bugs). Retirement trigger met — the plan auto-save fallback it mandated was already superseded by the v0.7.2 synthesis fallback (kept as a quality feature, not a workaround).

**变更前**: par-code v0.7.0 plan mode walkthrough with MiniMax-M3 found that
when the LLM makes parallel tool calls and some fail, the subsequent API
request returns 400 with `"invalid params, tool result's tool id
(call_xxx) not found (2013)"`. Root cause: PAR SDK's engine, when processing
multiple tool results from a single assistant message, sends a tool result
message whose `tool_call_id` doesn't match the LLM's original tool call IDs.
The mismatch is specific to error results (when `handler_result = Error`).

**变更后**: Filed as PAR SDK gap. par-code mitigations:
1. Planner `max_iterations` lowered to 8 (reduces parallel call chains)
2. Plan auto-save fallback: if planner reaches step limit without calling
   `plan_submit`, extract last assistant text and save as plan file
3. With affected providers (MiniMax), plan mode still produces empty plan
   files due to this bug — not fixable on par-code side

**原因**: Discovered during real LLM walkthrough (MiniMax-M3 via
`api.minimaxi.com/v1`). Error message is provider-specific:
`tool result's tool id(call_c3c9d58cabf149f7b1c4d0ff) not found (2013)`.

**影响范围**: All par-code features that trigger parallel tool calls where
some succeed and some fail. Not limited to plan mode.

**回退方式**: N/A (filing only — PAR SDK source change needed).

**已知限制**:
- **Severity**: HIGH — breaks plan mode with affected providers
- **Proposed upstream fix**: In `/root/dev/PAR/lib/core/engine.ml`, verify
  that every tool result message carries the exact `tool_call_id` from the
  corresponding assistant tool call, even when the handler returns `Error`.
  The error path may be generating synthetic IDs or dropping the original.
- **Retirement trigger**: When PAR SDK ships the fix, remove the plan
  auto-save fallback (it becomes unnecessary) and restore planner
  `max_iterations` to the user-configured value.

## [2026-08-09] v0.7.0 architecture — goal-driven autonomy design decisions

> Six architectural decisions for v0.7.0 "Goal-driven autonomy", all
> classified per the "一次做对" R1-R4 framework.

**变更前**: v0.7.0 was the next roadmap item. No design decisions recorded.

**变更后**: Six decisions made during implementation:

1. **Goal is orthogonal to Mode (R1 architecturally-correct)**: `Goal` is NOT
   a third variant of `Par_code_mode.t` (alongside Plan/Build). It's a separate
   `goal_state` ref. Plan/Build change which agent runs + which tools it has;
   Goal changes loop control (judge, continuation, doom-detection). Adding
   Goal to the mode type would be a disguised scope compromise (R4).

2. **Judge default = zero-config, main model in separate context (R1 + R3)**:
   `judge_enabled = true`, `judge_model = None` (inherits main model). Research
   ("progress mirage" arXiv:2607.25152): separate-context same-model drops
   false-acceptance from ~100% to ~44%; separate model is best. Zero-config is
   strictly better than nothing and upgrades cleanly. Alternative (require
   explicit config) blocks the headline feature behind setup — rejected.

3. **Judge-supervised mode, not full autonomous chaining (R2 scope compromise
   with retirement plan)**: v0.7.0 evaluates the goal after each
   user-triggered turn (every 3 steps or on `goal_done`). Full autonomous
   chaining (invokes without user input) deferred to v0.7.1. Rationale: the
   REPL loop restructuring for autonomous chaining is the highest-risk change
   (Slice 6 in the plan); judge-supervised mode delivers 80% of the value at
   20% of the risk. Retirement: v0.7.1 adds `goal_loop` recursion to chain
   invokes.

4. **Doom-loop detection = mechanical hash-based, threshold 3 (R1)**: Hash
   `(tool_name, args)`, detect N consecutive identical, escalate at 3→6→9.
   No filesystem-mutation tracking or semantic similarity (deferred to v0.8.0).
   Industry consensus (ForgeCode, LangSight, Vstorm): threshold 3 has zero
   reported false positives.

5. **Goal storage = flat JSON file, not SQLite (R1 + R3)**: Goal persists to
   `.par/goals/current.json`. Human-readable, no schema migration, matches
   Codex/goalkeeper pattern. The conversation history already lives in SQLite;
   the goal is a thin session-scoped pointer.

6. **PAR SDK bumped 0.8.3 → 0.8.6 (R3 one-shot)**: Consumes streaming error
   fix (C5 retirement). Low risk — zero API surface changes between 0.8.3 and
   0.8.6. Two workaround retirements: C1 (Memory_object usage fields, already
   retired in code, Superseded marker added) and C5 (streaming error
   propagation, consumed in this version).

**原因**: v0.7.0 is the first "autonomy" release. The architectural decisions
above determine how the agent self-regulates (judge), self-corrects
(doom-loop), and persists intent (goal state). Getting these right avoids
costly rework in v0.7.1+.

**影响范围**: 4 new modules (`par_code_doom_loop`, `par_code_goal`,
`par_code_judge`, `par_code_goal_tools`), 8 new config fields, `/goal`
slash command, `goal_done` agent tool, `--goal` CLI flag, PAR SDK dep bump.

**回退方式**: `/goal` command and goal features are additive — removing the
new modules + config fields + slash command reverts to v0.6.2 behavior. The
PAR SDK dep bump is a 1-line revert in `dune-project`.

**已知限制**:
- Judge-supervised mode (not full autonomous) — see decision 3 above.
- Doom-loop detection is mechanical only — see decision 4 above.
- Two PAR SDK gaps anticipated but not yet formally filed (doom-loop primitive,
  nested invoke depth-limiting) — will file if v0.7.1 implementation confirms.

## [2026-08-09] PAR SDK upgrade assessment — v0.8.3 → v0.8.6 (v0.7.0 prep)

> Pre-v0.7.0 investigation. Searched whether PAR SDK can support v0.7.0's
> three needs (independent judge model, nested subagent calls, doom-loop
> detection) without upstream changes, and whether any existing par-code
> workarounds are retirement-eligible against newer PAR versions.

**变更前**: par-code v0.6.2 pins `par {>= "0.8.3"}`. Local opam pin metadata
reads 0.8.3 even though `/root/dev/PAR` source `dune-project` is at 0.8.6
(the metadata lag is normal — opam caches the version at last install).
PAR SDK has shipped three patch releases since (0.8.4, 0.8.5, 0.8.6); their
contents and relevance to v0.7.0 had not been assessed.

**变更后**: Assessment complete. Findings:

**A. v0.8.4 / v0.8.5 / v0.8.6 contain zero API surface changes** — confirmed
by both `CHANGES.md` and per-tag `git log` (each version has exactly one
commit). 0.8.4 and 0.8.5 are test mock-path portability fixes (so opam-repo
CI users can run `dune runtest`). 0.8.6 is one production-relevant fix:
`Http_client.do_request_streaming` now raises `Http_status_error` for
non-2xx streaming responses instead of silently swallowing the error body.
The OpenAI/Anthropic providers' existing `map_http_status` handlers (dead
code in the production streaming path before 0.8.6) are now reachable.

**B. v0.7.0's three needs are all buildable from existing v0.8.3 primitives**
(no PAR SDK blocker):

| v0.7.0 need | PAR SDK primitive | Status |
|---|---|---|
| Independent judge model | `Runtime.register_llm_provider ~id` + `Runtime.make_agent ~model:{provider_id; ...}` + `Runtime.invoke_structured ~response_schema` | Fully composable. `skill_descriptor.expected_output` comment in `types.mli:341-346` shows PAR is design-aware of judge use-case. |
| Nested subagent calls | `handler_result.Handoff` (lateral transfer within ReAct loop) + `Runtime.invoke` from tool handler (already used by v0.6.0 `delegate`) | Safe — `invoke_context` is fiber-local via `Eio.Fiber.with_binding`; `?save:false ~update_current:false` isolates. Handoff ≠ true nesting but is sufficient for v0.7.0. |
| Doom-loop detection | `max_iterations` + `max_execution_time` + `early_stopping_method` + `context_compression_threshold` (all pre-existing) | **No PAR SDK primitive exists.** par-code must build tool-call dedup + progress heuristics at app level (as middleware or `register_tool_call_hook`). |

**C. Two existing workarounds are retirement-eligible**:

- **C1 (Memory_object usage fields)** — **fully retired in code, DECISIONS.md
  Superseded marker added today**. PAR v0.8.1 exposed `last_used_at` /
  `usage_count` on the public type; `lib/par_code_memory.ml:304-305` reads
  them directly. The v0.4.3 supplementary-SQL fetch is gone.
- **C5 (streaming error propagation)** — **Retired [2026-08-15] (consumed)**.
  Fallback string removed from `lib/` (grep-verified); `error_category` surfaced at
  all rendering sites.

**D. Two PAR SDK gaps anticipated for v0.7.0** (NOT yet filed as formal
feedback — per `par-sdk-feedback` skill, file when implementation actually
hits the gap, not before):

1. **Doom-loop detection primitive** (anticipated 🟡 WORKAROUND): no
   `tool_call_dedup` or no-progress hook on `agent_config`. par-code must
   implement at app level (~30-50 LOC for tool-call hash tracker +
   breaker). Will file formally when v0.7.0 doom-loop implementation
   confirms the gap is real.
2. **Nested invoke depth-limiting** (anticipated 🟡 WORKAROUND): no
   `?depth:int` parameter on `Runtime.invoke` and no `max_call_depth` on
   `agent_config`. par-code v0.6.0 `delegate` already does manual depth
   limiting; v0.7.0 judge-handoff will need the same. Will file formally
   if v0.7.0 implementation hits a depth-limiting wall that manual code
   cannot cleanly handle.

**原因**: Per STRATEGY.md §2 (Dual Role), par-code's first response to a
PAR limitation is to confirm whether PAR can already do it. This assessment
unblocks v0.7.0 planning: no PAR SDK changes are required to start, all
three needs compose from existing primitives, and the v0.8.6 streaming fix
is a bonus that improves error diagnostics when consumed.

**影响范围**:
- `docs/DECISIONS.md` (this entry + Superseded marker on the 2026-07-20
  Memory_object feedback entry)
- v0.7.0 prep tasks tracked (NOT executed in this assessment):
  - `opam upgrade par` in the `/root/dev/PAR` switch to refresh pin metadata 0.8.3 → 0.8.6
  - bump `par {>= "0.8.3"}` → `par {>= "0.8.6"}` in `dune-project` after pin refresh
  - consume PAR v0.8.6 streaming error fix in `par_code_repl.ml:407,469` (C5 retirement)
- Zero par-code source changes from this assessment alone.

**回退方式**: N/A (filing + supersede marker only). The Superseded marker
on the Memory_object entry reflects already-shipped code reality; reverting
the marker would not un-retire the workaround.

**已知限制**:
- Local opam pin metadata lag (0.8.3 vs source 0.8.6) means `dune build`
  currently links against whatever code is at `/root/dev/PAR` HEAD (which
  is post-v0.8.6 source). The version-string constraint in `dune-project`
  is the only formal declaration — bumping it requires the pin refresh.
- v0.7.0 anticipated gaps (doom-loop primitive, depth-limiting) are
  hypotheses based on reading PAR SDK surface area, not implementation
  experience. Either may turn out to be cleanly workaroundable (downgrade
  to 🟢) or genuinely blocking (upgrade to 🔴) once v0.7.0 work starts.

---

## [2026-08-07] linenoise migration for UTF-8/wide-char REPL input

> User reported Chinese (CJK) input couldn't be backspaced cleanly in the
> REPL — characters left "ghost" residue and the screen scrambled after a
> few backspaces. Reproduced on Linux (not macOS-only).

**变更前**: par-code read REPL input via stdlib `input_line stdin`, relying
entirely on the kernel tty line discipline (canonical/cooked mode) for line
editing. The line discipline erases wide characters (CJK = 2 terminal columns)
one byte/column at a time even with `IUTF8` set — it has no `wcwidth` table.
So backspace on Chinese left half-erased "ghost" characters that accumulated
into a scrambled screen. Cross-platform (Linux + macOS), because the root cause
is the kernel line-discipline, not par-code. Setting `IUTF8` was confirmed
insufficient (it was already set in the repro pty; wide-char display erase
still failed).

**变更后**: par-code now uses [linenoise][ln] (`ocaml-linenoise`, module
`LNoise`) for interactive line input. linenoise takes over the terminal in raw
mode during `readline` and does UTF-8/wcwidth-aware editing itself (one
backspace = one codepoint, correct column erase), then restores the terminal.
Migrated sites: the REPL main loop (`par_code_repl.ml`) and
`Par_code_ui.read_line` (config wizard + upgrade prompts = 11 sites). The
`/dev/tty` bash y/n confirmation stays on `input_line` (ASCII-only, different
channel). Up-arrow history is persisted at `~/.par/history`.

**原因**:
- cooked-mode CJK backspace is fundamentally broken (kernel has no display-
  width awareness); no termios flag fixes it. The only correct fix is to take
  over input editing.
- linenoise is the standard OCaml solution: battle-tested, BSD-licensed,
  self-contained bundled C (no system lib), adds history/completion for free.
  A hand-rolled raw-mode editor would be 300-500 lines with many correctness
  traps (terminal width/wrapping, signals, wide-char widths) — worse than the
  bug if done poorly. "一次做对": use the proven library.

**影响范围**:
- New opam dependency `linenoise (>= 1.3)` in `dune-project`; linked in
  `lib/dune`. Self-contained C, so release Docker (AlmaLinux 8) + macOS builds
  need NO extra system packages — only the opam dep flows through
  `opam install . --deps-only`.
- REPL prompt is now plain text (`(build) par> `) — linenoise sizes the
  prompt cursor with `strlen`, so ANSI color codes would misposition it. The
  colored `render_prompt` is retained (tests + non-linenoise contexts).
- Ctrl+C during input: linenoise raises `Sys.Break` (not `None`); the REPL
  loop catches it → clean save + "Bye!" exit. The streaming-time SIGINT
  handler is unchanged.
- `par ask` with piped stdin: unchanged — linenoise auto-detects non-tty and
  falls back to a plain `fgetc` loop.

**回退方式**: Revert the commits. `input_line stdin` path is still present in
git history. No on-disk format change (`~/.par/history` is a new optional file;
its absence is handled).

[ln]: https://github.com/ocaml-community/ocaml-linenoise

## [2026-08-07] install.sh + par upgrade: stale-binary permission fix + source-fallback parity

> Real user on macOS Intel hit two dead-ends in one session: install failed
> with a confusing `cp: Permission denied`, and `par upgrade` returned a bare
> "Unsupported platform: darwin/x86_64" with no path forward.

**变更前**：
- `install.sh` copied the built binary with a bare `cp` (no `-f`, no pre-clean).
  A stale `~/.par/bin/par` owned by another user (e.g. root, from a prior
  `sudo` run or the `sudo curl … | bash` footgun where sudo applies only to
  curl) made `cp` fail with an unactionable "Permission denied".
- `par_code_upgrade.ml`'s `detect_platform` returned a hard
  `Error (Download_failed "Unsupported platform: …")` for any platform without
  a pre-built binary (notably macOS Intel). But `install.sh` treats the same
  platform as "compile from source" (supported). So install said "yes" and
  upgrade said "no" — a user who installed from source could never self-update.

**变更后**：
- `install.sh`: new `ensure_target_writable` guard runs before every binary
  write (both the pre-built `install_binary` and the source `install_from_source`
  paths). On a non-writable stale binary it exits early with the exact fix:
  `sudo rm -f '~/.par/bin/par' && re-run`, plus a note that
  `sudo curl … | bash` does not elevate bash (use `curl … | sudo bash`). The
  source path also switched to `rm -f` + `cp -f` with the same actionable hint.
- `par_code_upgrade.ml`: `perform_upgrade_core` now branches on
  `detect_platform ()`. `Error` no longer dead-ends — it fetches the matching
  release's `install.sh` and execs it with `--from-source --prefix <current>
  --version <tag>`, streaming build progress to the user's stdout/stderr
  (5-20 min on first build). Install and upgrade now agree on every platform.

**原因**：
- Install/upgrade parity is an architectural property, not a nicety: a feature
  the installer advertises (source compile on Intel Mac) that `par upgrade`
  refuses to redo is a broken contract.
- The bare-`cp` failure was the #1 install failure mode for anyone who had
  ever touched `sudo`; the fix turns a mystifying shell error into a one-line
  remediation.

**影响范围**：
- `scripts/install.sh` (guard helper + two call sites).
- `lib/par_code_upgrade.ml` (`perform_upgrade_core` restructured; `detect_platform`
  and the public `perform_upgrade` signature unchanged — no `.mli` change).
- `README.md` (Self-update section + platform table now state upgrade works
  via source fallback on Intel Mac).

**回退方式**：
- Revert the two files. No on-disk format, schema, or config change — the
  behaviour change is purely in the install/upgrade code paths.
- Open enhancement (not taken now, per user's scope-B choice): ship a
  pre-built `darwin-x64` binary via a `macos-13` CI runner to eliminate the
  source-compile cost on Intel Mac entirely. This decision does not preclude
  that; it is complementary.

## [2026-08-07] User-reported runtime issues (v0.5.6, MiniMax-M3)

> Real user on macOS hitting two issues. Root cause diagnosed from
> terminal session output. Not audit findings — production feedback.

**变更前**: v0.5.6 shipped with all audit findings resolved. No
production usage data since release.

**变更后**: Two issues surfaced from a real user running `par` with
MiniMax-M3 via a third-party API endpoint:

**Issue A — Streaming provider silently swallows API errors (PAR SDK gap)**
- Symptom: every message returns `⚠ [no response text received — provider
  streaming may be broken]` with no diagnostic detail.
- Root cause: user set `max_tokens: 100000000` (100M). The API rejected
  the request (HTTP 400 or error embedded in SSE stream), but PAR SDK's
  `openai_provider` streaming path did not surface the error to the caller.
  The user saw "streaming may be broken" instead of the actual API rejection.
- Fix applied (user-side): `par config set max_tokens none` resolved
  the immediate issue. MiniMax-M3 then responded correctly.
- Upstream gap: PAR SDK's streaming error handling needs to propagate
  API error objects (HTTP 4xx/5xx and SSE error events) to the caller
  so par-code can display them. Currently these are silently dropped.
- Severity: MEDIUM — users with misconfigured providers see a confusing
  message with no actionable diagnostic.
- Recommended upstream fix: in `openai_provider.ml` streaming path,
  check for `error` field in SSE data chunks and HTTP status codes;
  return as `Error` on the stream or raise to the caller.

**Issue B — Ctrl+C during extraction crashes with unhandled Eio effect**
- Symptom: pressing Ctrl+C to exit while memory extraction is running
  produces `✗ [extraction failed: Stdlib.Effect.Unhandled(Eio__core__Cancel.Get_context)]`.
- Root cause: Ctrl+C triggers Eio fiber cancellation. The extraction
  subagent (running via `Runtime.invoke_generate ~save:false`) doesn't
  handle the `Eio.Cancel.Get_context` effect, causing an unhandled
  exception in the extraction code path.
- Workaround: use `/quit` instead of Ctrl+C — `/quit` saves state and
  exits cleanly without triggering Eio cancel.
- Severity: LOW — only affects Ctrl+C exit during the brief extraction
  window (session-end memory extraction). `/quit` works correctly.
- Fix direction: wrap extraction in `Eio.Cancel.try_with` or catch
  `Effect.Unhandled` in the extraction dispatch path. ~5 LOC.

**原因**: Production usage with a non-standard provider (MiniMax via
custom API base) exposed edge cases not covered by the v0.5.4 audit
(which used an OpenAI-compatible reasoning model). The max_tokens
validation in `par config set` (checks `> 0` but no upper bound) allowed
an absurdly large value that most APIs reject.

**影响范围**:
- Issue A: PAR SDK `openai_provider.ml` (streaming error path) + par-code
  error display. Affects all users with misconfigured providers.
- Issue B: `par_code_extractor.ml` / `par_code_repl.ml` (Ctrl+C handling).
  Affects users who Ctrl+C during extraction.

**回退方式**: N/A (diagnostic record, no code changes).

**已知限制**:
- `par config set max_tokens` accepts any positive integer. Consider
  adding an upper-bound warning (e.g., > 200000 is likely a mistake).
- Issue A cannot be fixed in par-code alone — requires PAR SDK streaming
  error propagation. File as PAR SDK feedback when prioritized.
- Issue B can be fixed in par-code (~5 LOC Eio cancel handling) but is
  low-priority given the `/quit` workaround.

---

## [2026-08-05] v0.5.6 scope — clear all audit findings + UX polish

**变更前**: v0.5.5 shipped Wave 1 fixes (P0 #1, #3; P1 #8, #9 partial #6)
but Wave 2 (P0 #2, P1 #4, P1 #6 streaming) was believed gated on PAR SDK
upstream changes. Wave 3 (P1 #5, #7) and P2 items (#11–14) were deferred
to v0.6.0+.

**变更后**: PAR SDK v0.8.3 shipped all 3 Wave 2 blockers
(`Runtime.save_conversation ?scope`, `stream_options.include_usage`,
`Think_tag_strip` middleware). v0.5.6 scope expanded to "全清" — clear
all remaining audit findings + add deferred UX improvements. 8 items
implemented across 14 files, +51 tests (218→269).

Key realizations during implementation:
- v0.5.5 had already shipped MORE than its plan stated: scope threading
  at all 6 `save_conversation` callsites, `Think_tag_strip` middleware at
  all 4 agents, and `Reasoning_delta` chunk handling. The DECISIONS.md
  audit entry was stale relative to the actual v0.5.5 codebase.
- v0.5.6 remaining work was smaller than estimated: T6 (scope migration)
  reduced to backfill-only, T8a (think strips) reduced to 2 targeted
  strips (~4 LOC) since middleware registration was already done.

**原因**: PAR SDK unblock removed the gate. Clearing all audit findings
in one release is architecturally cleaner than spreading them across
v0.6.0+ (R5 — "一次做对").

**影响范围**: lib/par_code_config.ml, lib/par_code_memory.{ml,mli},
lib/par_code_session.{ml,mli}, lib/par_code_ui.{ml,mli},
lib/par_code_repl.ml, lib/par_code_checkpoint.ml,
lib/par_code_plan_tools.ml, bin/cli_args.ml, bin/main.ml,
scripts/install.sh, +5 test files.

**回退方式**: Each fix is independently revertable via `git revert`.

**已知限制**:
- `/cost` token counts (P1 #4) verified at code level — PAR SDK sends
  `stream_options.include_usage`, existing `add_usage` reads it. Runtime
  smoke test with a real LLM deferred to release verification.
- Streaming `<think>` strip handles common cases (tag at start,
  across chunks, unclosed at flush) but not adversarial inputs
  (e.g., `<think>` nested inside a code block). Acceptable for v0.5.6.

---

## [2026-08-05] v0.5.4 comprehensive audit — 3 P0 + 7 P1 findings, v0.5.5 hotfix planned

> First full end-to-end audit since project inception. Driven via tmux
> against `par 0.5.4` (PAR SDK `v0.7.10-62-gb22e17a`) using a chain-of-thought-
> leaking OpenAI-compatible reasoning model. Full audit report:
> `.sisyphus/audits/2026-08-05-comprehensive-walkthrough.md` (local,
> gitignored). Fix soundness verified by deep code-path analysis (file:line
> evidence in report).

**变更前**：v0.5.4 shipped with three marquee features (session management,
clean Ctrl+C exit, partial-UUID resume). Unit tests pass 218/218. No
end-to-end integration testing had ever been performed; the project relied
on unit tests + manual smoke during release.

**变更后**：Comprehensive audit identified **3 release-blocker defects
(P0)** and **7 critical UX defects (P1)**. v0.5.5 hotfix planned in two
waves (see §Wave breakdown below). 4 of the P1s require PAR SDK upstream
fixes (see [2026-08-05] PAR SDK Feedback entry below). Findings and
fix strategies:

**P0 #1 — Plan Mode planner tool filter uses wrong names** (release blocker)
- Symptom: planner agent in Plan Mode can only `grep`; cannot `read`/`find`/`ls`.
- Root cause: `lib/par_code_setup.ml:326-330` filters on `"read_file"` /
  `"find_files"` / `"list_directory"` but PAR SDK exposes them as `read` /
  `find` / `ls` (`/root/dev/PAR/lib/tools/builtin_tools.ml:726,798,880`).
- README "What the planner can do" section repeats the wrong names.
- Fix: rename in filter + planner system prompt + README. ~7 LOC, 15 min.
- Architecturally correct (R1): pure bugfix, no scope compromise.

**P0 #2 — Session management non-functional end-to-end (scope never written)**
- Symptom: `par session list`, `par -r`, `par --continue <prefix>` all return
  empty despite 40 conversations in DB.
- Root cause: write side (`par_code_repl.ml:198,206,253,360,374,434`) calls
  `Runtime.save_conversation rt ?conversation:!conv ()` without `~scope`;
  read side (`par_code_session.ml:31`) filters by `scope`. All 40 DB rows
  have `scope = ''`. Regression introduced in commit `ba3692f` (only the
  read path was updated).
- PAR SDK gap: `Runtime.save_conversation` (`runtime.ml:687`) doesn't
  accept `~scope`, even though the underlying `Sqlite_persistence.save_conversation`
  (`sqlite_persistence.ml:693`) does. See PAR SDK Feedback entry below.
- Fix options:
  - (A) **Architecturally correct**: PAR SDK extends `Runtime.save_conversation`
    to forward `?scope`. ~3 LOC PAR SDK change. **PREFERRED — wait for upstream.**
  - (B) **Scope compromise (R2)**: par-code bypasses Runtime, calls
    `Sqlite_persistence.save_conversation ~scope` directly. Requires
    threading `Types.persistence_service` handle from `par_code_setup.ml`
    through to `par_code_repl.ml`'s `run`/`run_single_shot`. ~20 LOC.
    Retirement plan: revert to Runtime API once PAR SDK ships (R2 — has
    explicit retirement condition).
- Migration: ~40 existing conversations have `scope = ''`. Backfill from
  `checkpoints.project_id` (which IS populated) or treat empty-scope as
  "show in all projects" with `(no project)` marker.
- Fix effort: ~20 LOC (Option B) or ~3 LOC PAR SDK + 5 LOC par-code (Option A).

**P0 #3 — Startup version notice always fires**
- Symptom: every `par` launch (without `PAR_NO_UPDATE_CHECK=1`) prints
  `info: par v0.5.4 is available (current: 0.5.4). Run 'par upgrade'.`
  `par upgrade --check` always exits 1.
- Root cause: `bin/main.ml:654` `| Ok latest when latest <> cur ->`
  compares `"v0.5.4"` (GitHub `tag_name`, with `v`) to `"0.5.4"`
  (`Par_code_version.version`, no `v`). Always unequal. Same bug at
  `main.ml:175` (`par upgrade --check` exit code).
- Fix: strip leading `v` from `latest` before comparing. Helper ~5 LOC +
  2 call-site changes. ~10 min.
- Architecturally correct (R1): pure bugfix.

**P1 #4 — `/cost` token counts always zero** (PAR SDK blocker)
- Symptom: `/cost` shows correct LLM call count but always 0 prompt/output
  tokens.
- Root cause: PAR SDK `openai_provider.ml:259` streams with `"stream":true`
  but omits `stream_options: {"include_usage": true}`. OpenAI-compatible
  APIs only emit usage in the final chunk when explicitly requested.
- Re-tiered from P0 to P1: `/cost` still shows LLM call count and context
  size correctly — degraded, not completely non-functional.
- **PAR SDK fix required** (see Feedback entry). No feasible par-code
  workaround (would need duplicate non-streaming request — defeats
  streaming UI purpose).

**P1 #5 — `par config set` only supports 1 of 21 fields**
- Symptom: `par config set temperature 0.5` → `Unknown config field`.
- Root cause: `lib/par_code_config.ml:295-310` `update_field` hardcodes
  match on `"default_mode"` only.
- Fix effort: ~80-100 LOC (revised up from initial 50 estimate). Each
  field needs type coercion (int/float/bool/string/null) + validation.
  `system_prompt` skipped (multiline — set via wizard only).
- Architecturally correct (R1): consistency fix.

**P1 #6 — `<think>` tag leak corrupts 3 surfaces** (partially PAR SDK blocker)
- Symptom: chain-of-thought tags from reasoning models
  leak into (a) plan files (only `<think>` block persisted), (b) checkpoints
  (4/7 DB rows have empty fields), (c) REPL / `par ask` output.
- Root cause: par-code passes through raw assistant text. PAR SDK HAS a
  `Think_tag_strip` middleware (`/root/dev/PAR/lib/middleware/think_tag_strip.ml`)
  but par-code does NOT register it at any of the 4 `Runtime.make_agent`
  call sites (`par_code_setup.ml:280-286` etc., all default `~middleware:[]`).
  Additionally, `parse_checkpoint_response` (`par_code_checkpoint.ml:191`)
  calls `extract_json_object` without stripping `<think>` first — fragile
  when `<think>` contains JSON examples.
- Fix layers:
  - (a) Register `Think_tag_strip.create ()` middleware at all 4 agents
    (4 LOC) — fixes non-streaming responses.
  - (b) Strip `<think>` in `extract_json_object` (2 LOC) — fixes
    checkpoint parsing.
  - (c) Strip in `persist_plan_file` (2 LOC) — fixes plan file content.
  - (d) Streaming path: need buffer-and-strip in flush_markdown step
    (10-20 LOC state machine) — fixes REPL output.
- Note: existing checkpoint `ead94af2-...` has literal task text
  `"Add a test case verifying parse_checkpoint_response handles responses
  wrapped in think tags"` — team knew, never implemented.

**P1 #7 — `install.sh` exits 0 on failure**
- Symptom: `sh install.sh --version v999.999.999` (nonexistent) prints
  `[error] download failed` but exits 0.
- Root cause: `scripts/install.sh:14` has `set -u` but no `set -e` /
  `set -o pipefail`.
- Fix complexity: `set -e` alone is safe (most error paths already use
  `|| { error; exit 1; }`). `set -o pipefail` is dangerous — grep pipeline
  at line 144 returns non-zero when checksum file has no match. Need
  ~5-8 `|| true` annotations on intentionally-non-fatal commands.
- Architecturally correct (R1).

**P1 #8 — REPL prompt invisible until first response** (re-tiered from P0)
- Symptom: after banner, user sees blank line instead of `(build) par>`.
- Root cause: `lib/par_code_ui.ml:266-267` `render` doesn't flush stdout.
  `render_prompt` (line 468-473) calls `render`. stdout is line-buffered
  (tmux pty); won't flush until next `\n`.
- Fix: add `flush b.out` at end of `render_prompt`. 1 LOC, 2 min.
  (Note: do NOT add flush to `render` itself — `render_line` already
  flushes; double-flushing is harmless but the contract is "render is
  unflushed for batch operations".)
- Architecturally correct (R1).

**P1 #9 — README MCP/Workflows overstatement** (corrected from initial report)
- Initial claim: MCP, Skills, Workflows all unwired.
- **Correction**: Skills IS wired (`par_code_setup.ml:442-444` registers
  `Builtin_skills.builtin_skills`: code-reviewer, summarizer, translator,
  rag-assistant). Only MCP client and Workflows engine are unwired.
- Fix: README capabilities table — annotate MCP as "persistence wired;
  client init deferred — v0.11.0", Workflows as "state persistence
  registered; engine not yet invoked — v0.10.0". Remove Skills entry
  fix (correctly claimed).

**P1 #10 — DROPPED (false positive)**
- Initial claim: `par session show <prefix>` returns EXIT 0 on not-found.
- **Verification**: `bin/main.ml:570-587` correctly calls `exit 1` on all
  error paths (resolve_id error at line 574, load error at line 579,
  Ok None at line 587). Cmdliner exits 0 only on the success path.
- This finding is incorrect; no bug present.

**原因**：
1. Unit tests encoded the same wrong assumptions as the implementations
   they were meant to verify (e.g., `test_par_code_setup.ml` asserts
   the same wrong tool names that `par_code_setup.ml` filters on). The
   tests pass because both sides agree on the wrong contract.
2. No integration test harness drives the public CLI surface end-to-end.
   Per AGENTS.md global §"工程习惯与规矩" R3 ("一次做对"), the project
   needs an integration-test layer (tmux/expect) that asserts on
   observed behavior, not just internal state.
3. The v0.5.4 release notes advertised Session Management without an
   end-to-end smoke test of `par session list` returning non-empty.
   Per §"工程习惯与规矩" R3, advertised features must be smoke-tested
   before ship.

**影响范围**：
- P0 #1: `lib/par_code_setup.ml:326-330, 334-364` + `README.md:281-284`
- P0 #2: `lib/par_code_repl.ml` (6 call sites) + `lib/par_code_session.ml:28-43`
  + `lib/par_code_setup.ml` (thread persistence through) + PAR SDK `runtime.ml:687`
- P0 #3: `bin/main.ml:175, 654`
- P1 #4: PAR SDK `openai_provider.ml:259`
- P1 #5: `lib/par_code_config.ml:295-310`
- P1 #6: `lib/par_code_setup.ml` (4 agent sites) + `lib/par_code_checkpoint.ml:174-192`
  + `lib/par_code_plan_tools.ml:138-150` + `lib/par_code_ui.ml:301-307` (flush_markdown)
- P1 #7: `scripts/install.sh:14, 144`
- P1 #8: `lib/par_code_ui.ml:468-473`
- P1 #9: `README.md:8-10, 37-39`

**回退方式**：Audit itself is documentation-only; no code changes to
revert. Each fix ships as an atomic commit in v0.5.5 / v0.5.6 (per wave
breakdown below). Individual revert via `git revert <commit>`.

**已知限制**：
- 3 of the 10 findings (P0 #2, P1 #4, P1 #6 streaming) require PAR SDK
  upstream changes. User will direct PAR SDK team to confirm + fix before
  v0.5.5 Wave 2 begins (per user instruction 2026-08-05).
- Audit did not exercise: actual `par upgrade` self-replace runtime test
  (code-reviewed only — atomic_replace + smoke + rollback looks solid),
  context compaction at 100k+ tokens (cost-prohibitive), macOS/ARM
  cross-platform builds (hardware-bound). These remain as future audit work.
- Coverage matrix of feature → test existence not produced (future work).
- Audit was conducted against locally-built binary on PAR SDK
  `v0.7.10-62-gb22e17a`. Release artifact at github.com/jcz2020/par-code
  is built against PAR SDK `v0.8.2-3-ga377a70` — minor SDK version skew.
  Re-running P0/P1 verification against the release binary is recommended
  after v0.5.5 ships.

### Wave breakdown for fixes

**Wave 1 (par-code only, ships as v0.5.5 immediately)**:
- P0 #1 — Plan Mode tool filter fix (~7 LOC, 15 min)
- P0 #3 — Version comparison fix (~7 LOC, 10 min)
- P1 #8 — REPL prompt flush (1 LOC, 2 min)
- P1 #9 — README MCP/Workflows annotation (5 LOC docs, 10 min)

**Wave 2 (after PAR SDK fixes ship, v0.5.6 or v0.5.5延期)**:
- P0 #2 — Session scope write (3 LOC PAR SDK + 5 LOC par-code, OR
  20 LOC par-code bypass if PAR SDK can't ship promptly)
- P1 #4 — Token tracking via `stream_options.include_usage` (3 LOC PAR SDK)
- P1 #6 — `<think>` tag middleware registration (4 LOC par-code after
  PAR SDK exposes clean middleware constructor) + extract_json_object
  strip (2 LOC) + persist_plan_file strip (2 LOC) + streaming state
  machine (10-20 LOC)

**Wave 3 (par-code only, v0.6.0 bundle)**:
- P1 #5 — `par config set` extended to all 20 settable fields (~80-100 LOC)
- P1 #7 — install.sh `set -e` + audit of intentional non-zero exits (~5-8 LOC)

**Wave 4 (process improvement, ongoing)**:
- Integration test harness: tmux/expect-based E2E tests for each P0/P1 path
- Test coverage matrix: feature → test existence audit
- Per-release smoke checklist: every advertised feature gets an E2E test
  before ship

## [2026-08-05] PAR SDK Feedback: 3 gaps surfaced by v0.5.4 audit

**Tag**: PAR SDK Feedback

**变更前**：v0.5.4 audit identified three PAR SDK gaps that block par-code
fixes. Per AGENTS.md §1 (PAR SDK boundary), par-code cannot fix these
in-tree.

**变更后**：No PAR SDK change yet. User will direct PAR SDK team to
confirm + fix before v0.5.5 Wave 2 work begins (per user instruction
2026-08-05). par-code Wave 1 fixes (P0 #1, P0 #3, P1 #8, P1 #9) do NOT
depend on PAR SDK and can proceed immediately.

**原因**：Per AGENTS.md §1 and the par-code `par-sdk-feedback` skill,
gaps discovered during par-code development must be filed upstream with
file:line evidence, severity, and a workaround status. Per STRATEGY.md
§2 (Dual Role), the first response to a PAR limitation is to fix PAR,
not work around it in par-code.

**影响范围**：Upstream PAR SDK only (`/root/dev/PAR/`). Zero par-code
source changes from this entry alone.

**回退方式**：N/A (filing only).

**已知限制**：

1. **`Runtime.save_conversation` doesn't accept `?scope` parameter**
   (`/root/dev/PAR/lib/core/runtime.ml:687-694`). The function signature
   is `save_conversation rt ?(conversation : Types.conversation option) ()`
   but the underlying persistence service fn type at
   `/root/dev/PAR/lib/core/types.ml:1243` IS `save_conversation_fn :
   ?scope:string -> string -> conversation -> (...)`, and the sqlite
   implementation at `/root/dev/PAR/lib/persistence/sqlite_persistence.ml:693`
   correctly binds `?scope` to the `scope` column. The Runtime wrapper
   simply drops the parameter.
   - **Severity**: HIGH — blocks P0 #2 (session management non-functional).
   - **Recommended upstream fix**: Add `?scope:string` parameter to
     `Runtime.save_conversation`, forward to `save_conversation_fn`.
     ~3 LOC + signature update in `runtime.mli`.
   - **par-code workaround**: bypass Runtime.save_conversation in
     `par_code_repl.ml`, call `Sqlite_persistence.save_conversation ~scope`
     directly (pattern already used in `par_code_session.ml:120` for fork).
     Requires threading `Types.persistence_service` from setup through to
     repl. ~20 LOC. **Workaround is a scope compromise (R2)** with
     retirement plan: revert to Runtime API once upstream ships.

2. **`openai_provider` streaming omits `stream_options.include_usage`**
   > **Retired [2026-08-15]**: fixed in PAR SDK 0.8.3 (stream_options.include_usage + empty-choices usage propagation); /cost add_usage consumes streamed usage since v0.5.6.
   (`/root/dev/PAR/lib/providers/openai_provider.ml:259`). The provider
   adds `("stream", `Bool true)` to the request body but never adds
   `("stream_options", `Assoc [("include_usage", `Bool true)])`. Per
   the OpenAI-compatible streaming spec, the final chunk omits the
   `usage` field unless `include_usage: true` is explicitly requested.
   PAR SDK's
   usage-parsing code at `openai_provider.ml:372-374, 541-543` is correct
   — the data simply never arrives.
   - **Severity**: MEDIUM — degrades par-code `/cost` slash command
     (claim 14.1 broken: token counts always zero).
   - **Recommended upstream fix**: When `stream=true`, add
     `("stream_options", `Assoc [("include_usage", `Bool true)])` to
     the request body in `build_request_body`. ~3 LOC.
   - **par-code workaround**: NONE feasible. The REPL UI requires
     streaming for responsive output; a duplicate non-streaming request
     would double LLM cost + latency.

3. **`<think>` tag handling not exposed as default middleware**
   (`/root/dev/PAR/lib/middleware/think_tag_strip.ml` exists but is opt-in).
   Reasoning models (those that emit chain-of-thought inline such as
   `<think>...</think>` tagged variants) corrupt plan files, checkpoints,
   and REPL output. PAR SDK HAS the middleware but par-code (and
   likely other SDK consumers) doesn't know to register it. Result:
   CoT tags corrupt plan files, checkpoints, and REPL output.
   - **Severity**: MEDIUM — UI pollution across 3 surfaces.
   - **Recommended upstream fix** (one of):
     - (a) Make `Think_tag_strip` part of the default middleware stack
       when an OpenAI-compatible provider is detected. Most non-reasoning
       models don't emit `<think>` so the middleware is a no-op for them.
     - (b) Add a `Types.llm_response.reasoning : string option` field and
       have providers parse `<think>` into it, leaving `text` clean.
       Cleaner long-term but requires API change.
     - (c) Document the middleware prominently in PAR SDK quickstart so
       consumers know to register it.
   - **par-code workaround**: register middleware at all 4
     `Runtime.make_agent` sites in `par_code_setup.ml` (~4 LOC). Plus
     add explicit `<think>` strip in `par_code_checkpoint.ml:extract_json_object`
     and `par_code_plan_tools.persist_plan_file` (4 LOC). Plus streaming
     state machine (10-20 LOC). Total ~20-30 LOC.

**Re-evaluation trigger**: PAR SDK 0.9.0 release. **Would enable**: clean
P0 #2 fix (3 LOC instead of 20), accurate `/cost`, clean CoT model support
without per-call-site workarounds.

## [2026-08-04] v0.5.2–v0.5.4 shipped — Streaming fix + REPL polish + Session management

**变更前**：v0.5.1 shipped Plan CLI + git tools but had three critical UX issues:
(1) provider streaming failures caused silent empty responses, (2) tool
indicator triple-rendering + bash confirmation stdin contention made the REPL
messy, (3) session resume required copy-pasting 36-char UUIDs with no way to
list or browse past sessions.

**变更后**：Three patch releases shipped:
- v0.5.2: Streaming fallback — after invoke returns Ok, if no Text_delta was
  streamed, print `resp.text` as fallback. If `resp.text` is also empty, print
  a diagnostic warning instead of silently showing nothing.
- v0.5.3: Removed redundant `tool_call_hook` (triple→double indicator). Bash
  confirmation reads `/dev/tty` instead of `stdin` (fixes stdin contention
  where user input during long bash commands was swallowed). Ctrl+C exits
  cleanly (`Bye!` + exit 0) instead of crash-like (`Interrupted` + exit 130).
- v0.5.4: New `par session list/show/fork` CLI commands. Session listing shows
  ID prefix + auto-generated title (first user message) + last activity +
  event count. `--continue` accepts partial UUIDs (unique prefix resolution).
  Session fork copies conversation to new session ID. New module
  `lib/par_code_session.ml/mli`.

**原因**：These are quality-of-life fixes that make par-code practical for
daily use. The streaming fallback fixed a show-stopper bug (no response from
certain OpenAI-compatible providers when streaming delivered no chunks).
The REPL fixes addressed output readability. Session
management was the #1 UX gap vs competitor tools — users couldn't discover
or resume past sessions without external tools.

**影响范围**：
- v0.5.2: `lib/par_code_repl.ml` (streaming callback + fallback print)
- v0.5.3: `lib/par_code_setup.ml` (removed tool_call_hook + /dev/tty),
  `lib/par_code_repl.ml` (Ctrl+C clean exit), `lib/par_code_ui.ml` (event
  match arms)
- v0.5.4: `lib/par_code_session.ml/mli` (new), `bin/main.ml` (session CLI +
  is_chat_mode), `bin/cli_args.ml` (session args), `lib/par_code_repl.ml`
  (partial ID resolution in load_initial_conv)

**回退方式**：Each release is independent. Revert via `git revert <tag>`.
Session management is pure addition — removing it doesn't affect v0.5.0 Plan
Mode or v0.5.1 Plan CLI functionality.

**已知限制**：
1. Session titles are derived from the first user message (truncated to 50
   chars). No AI-generated titles or manual rename yet.
2. Partial ID resolution loads up to 200 sessions for prefix matching —
   adequate for now but could be slow with thousands of sessions.
3. Fork copies the full conversation but does NOT copy checkpoints or
   memory associations — the forked session starts fresh for checkpoint
   tracking.
4. `--resume` (most recent) still loads across all projects (no scope
   filter on the Runtime API). Only `par session list` and `--continue`
   are project-scoped.

## [2026-07-29] v0.5.1 shipped — Plan CLI + Git Tools

**变更前**：v0.5.0 shipped Plan Mode but deferred 4 items to §17: `par plan
list/show/prune` CLI subcommands and dedicated `git_status`/`git_log`
read-only tools for the planner agent. The planner had no way to inspect
git state (its tool filter excluded bash), and saved plans accumulated in
`.par/plans/` with no management interface.

**变更后**：v0.5.1 ships. Version bumped to 0.5.1 in dune-project +
par_code.opam + test assertion. Tag v0.5.1 pushed; Release workflow builds
Linux x64/arm64 + macOS arm64. Four items delivered:
1. `par plan list` (default for bare `par plan`) — lists `.par/plans/*.md`
   with filename, size, parsed creation timestamp (newest-first).
2. `par plan show <file>` — reads plan content, auto-appends `.md`.
3. `par plan prune --older-than <days>` — deletes old plans by filename
   timestamp (not mtime).
4. `git_status` + `git_log` — read-only tool bindings using `Eio.Process`
   with `tok.switch` for fiber safety. Planner filter updated from 6→8
   read-only tools.

New files: `lib/par_code_git_tools.ml/mli`, `lib/par_code_plan_tools.mli`.
Modified: `par_code_plan_tools.ml` (+list/show/prune/parse_plan_timestamp),
`par_code_setup.ml` (git tool registration + planner filter + prompt),
`bin/cli_args.ml` + `bin/main.ml` (plan subcommands + is_chat_mode).
Tests: 13 plan tools + 10 git tools = 23 new tests (211 total).

**原因**：Collects v0.5.0's deferred items into a focused patch release.
Plan CLI makes the accumulated `.par/plans/` directory manageable. Git
tools give the planner visibility into working-tree state and commit
history — essential for producing accurate plans. Both are small,
self-contained features that round out the Plan Mode UX.

**影响范围**：14 files (10 modified, 4 new). Zero PAR SDK changes.
Zero new dependencies (eio already in lib/dune). Users: `curl install.sh
| bash` now installs v0.5.1; existing v0.5.0 users get offered the
upgrade via startup version check.

**回退方式**：Git tag and GitHub Release are permanent. Code state can
be reverted via `git revert`. The plan CLI and git tools are pure
additions — removing them doesn't affect v0.5.0 Plan Mode functionality.

**已知限制**：
1. `git_log` count parameter not validated/clamped — negative values
   produce invalid git args, but git exits non-zero and the handler
   returns a clean error. Read-only, no security impact.
2. `show_plan` reads outside `.par/plans/` if given a path like
   `../../etc/passwd` — consistent with `cat` behavior for a local CLI
   (same-user, no privilege boundary). Defense-in-depth (basename-only)
   deferred.
3. `parse_plan_timestamp` uses Fliegel-Van Flandern algorithm — handles
   all Gregorian dates correctly. The earlier v0.5.1-dev JDN float
   formula had a +0.5 day offset bug, now fixed.

## [2026-07-28] v0.5.0 ARM64 build: pin uring 2.7.0 to avoid vendored liburing failure

**变更前**：Docker build for ARM64 AlmaLinux 8 pulled `eio.1.4` (latest from
opam), which requires `uring >= 2.15.0`. `uring.2.15.0` builds its own
vendored liburing from source, which fails to link on ARM64 AlmaLinux 8
(`collect2: ld returned 1 exit status`). x86_64 was unaffected (possibly
due to Docker layer cache from prior releases).

**变更后**：Dockerfile pins `uring 2.7.0` before pinning PAR SDK. This
cascades the opam solver to `eio.1.3` (which constrains
`uring < 2.14.0`). `uring.2.7.0` does not build vendored liburing — it
links against the system liburing installed via `liburing-devel`.

**原因**：ARM64 users (Raspberry Pi, AWS Graviton) need pre-built binaries.
Skipping ARM64 was considered (commit `5969d36`) but reversed after root
cause analysis. The pin is a par-code-side workaround — no PAR SDK change.

**影响范围**：`scripts/docker/linux-bundle.Dockerfile` only. Affects both
x86_64 and ARM64 Docker builds (x86_64 unaffected by the pin since it was
already using a compatible uring version via cache).

**回退方式**：Remove the `opam pin add uring 2.7.0 -y` line from the
Dockerfile. Upstream fix: when `eio.1.4+` / `uring.2.15.0+` ARM64
compilation is fixed upstream, the pin becomes unnecessary.

**已知限制**：Pins par-code's Docker builds to `eio.1.3` instead of latest.
When PAR SDK adds features that require `eio.1.4+`, the pin will need to be
revisited (either fix the ARM64 liburing build or find an alternative).

## [2026-07-28] v0.5.0 plan_exit auto-persist (post-invoke mode-change detection)

**变更前**：When the planner called `plan_exit` tool to self-switch from
Plan to Build, no plan file was persisted (the tool handler signature
`Yojson.t -> cancellation_token -> handler_result` lacks conversation
access). Only manual `/build` slash command persisted plans.

**变更后**：REPL checks after each `Runtime.invoke`: if mode transitioned
Plan→Build during the invoke (detected via `mode_before_invoke` capture),
automatically calls `persist_plan_file` from the returned conversation.

**原因**：Agent self-switching via `plan_exit` is the smooth UX path
("Plan ready, switching to build"). Losing the plan on this path was
broken UX.

**影响范围**：`lib/par_code_repl.ml` (14 lines added in the invoke
result handling section).

**回退方式**：Remove the post-invoke mode-change check block.

**已知限制**：If the invoke returns Error (no conversation update),
persistence is skipped. The plan content is still in the streamed output
but not saved to file.

## [2026-07-27] v0.5.0 Plan Mode Architecture

**变更前**: par-code had a single "par" agent that both investigated and
modified code. No mode separation; the agent could write/edit/bash at any
time.

**变更后**: Two registered agents, "par" (build, all tools) and "planner"
(read-only subset: read_file/grep/find_files/list_directory/recall_memory/
search_history/plan_exit). Mode switch = swap `~agent_id` in
`Runtime.invoke`. Conversation shared across both agents. Plan output
persisted to `.par/plans/<ISO8601>.md`. `plan_enter`/`plan_exit` tools let
the agent self-switch.

**原因**: Plan mode (research, plan, execute) is the v0.5.0 capability.
Per-agent tool isolation is PAR SDK's intended primitive, so the LLM only
sees tools registered on the current agent. Two-agent design also sets up
v0.6.0 subagent delegation.

**影响范围**: New files `lib/par_code_mode.ml/mli`, `lib/par_code_plan_tools.ml`.
Modified: `par_code_setup.ml` (planner registration + tool registration),
`par_code_repl.ml` (mode-aware dispatch + slash commands + appendix),
`par_code_ui.ml/mli` (render_prompt mode param), `par_code_config.ml`
(default_mode field), `bin/main.ml` (config set subcommand).

**回退方式**: Set `default_mode: build` in config (already default). The
plan mode code paths are dormant unless the user types `/plan` or the agent
calls `plan_enter`. Removing v0.5.0 = delete the new files + revert the
modified files.

**已知限制**:
1. Module-level mutable ref (`Par_code_mode.current`) — single-runtime
   assumption. Documented in `.mli`.
2. D4 scope compromise: plan output is free-form markdown (no `submit_plan`
   tool). Retirement plan: v0.6.0 evaluates structured plan fields.
3. Plan/Build conversation history is shared — planner sees past builder
   tool calls, builder sees past planner analysis. Integration tested but
   may require prompt engineering for edge cases.

## [2026-07-27] PAR SDK Feedback: First-class mode concept

**Tag**: PAR SDK Feedback

**变更前**: par-code v0.5.0 simulates "modes" (Plan/Build) by swapping
`~agent_id` in `Runtime.invoke` and maintaining a module-level mutable
ref `Par_code_mode.current`.

**变更后**: No PAR SDK change. par-code works around the gap.

**原因**: PAR SDK has no first-class `current_mode` field on Runtime or
invoke_context. The workaround is functional but adds par-code-side state
management that PAR SDK could own.

**影响范围**: par-code only. Future PAR SDK evolution.

**回退方式**: N/A (no PAR SDK change to revert).

**已知限制**:
- Priority: low (v0.5.0 ships without it)
- Re-evaluation trigger: if v0.6.0+ adds more modes (debug, review,
  refactor), the agent-swap pattern becomes unwieldy. At that point,
  request PAR SDK to add `mode : string` field on invoke_context or
  runtime.
- Would enable: mode-aware hooks (instead of agent-swap), mode-transition
  events, cross-session mode persistence in SDK.

## [2026-07-27] PAR SDK Feedback: Plan/task primitive

**Tag**: PAR SDK Feedback

**变更前**: par-code v0.5.0 stores plans as markdown files in
`.par/plans/<timestamp>.md`. No PAR SDK primitive for plan artifacts.

**变更后**: No PAR SDK change. Plans are app-level.

**原因**: PAR SDK has no "task" or "plan" artifact type. Plans are
conversation content + files.

**影响范围**: par-code only. Future PAR SDK evolution.

**回退方式**: N/A.

**已知限制**:
- Priority: medium (v0.6.0 will feel the gap)
- Re-evaluation trigger: v0.6.0 subagent coordination needs structured
  plan handoff between builder and delegated planner subagent. At that
  point, request PAR SDK to add a `Task` or `Plan` artifact type.
- Would enable: cross-agent plan sharing, plan status tracking
  (not-started / in-progress / complete), plan-based tool filtering.

## [2026-07-21] v0.4.5: UI abstraction layer — composable styled images

**变更前**: par-code used `Printf.printf`/`Printf.eprintf` directly throughout
lib/ and bin/ (175 call sites across 8 files). No structured rendering — LLM
streaming output was plain text, tool events were single-line `→ X ✓`,
markdown was unrendered. PAR SDK chunk variants (Tool_call_start,
Tool_call_delta, Usage_update) and event variants (Tool_progress,
Bash_invoked, Bash_completed) were silently discarded via `_ -> ()`.

**变更后**: New `lib/par_code_ui.ml` module provides a composable styled image
abstraction. Business code builds `Ui.image` values via primitives (`text`,
`textf`, composition operators `<|>`/`<->`, layout `hpad`/`vpad`/`hsnap`).
Backend abstraction renders images to terminal via ANSI escape codes.
13 high-level `render_*` functions handle common patterns (errors, warnings,
LLM chunks, tool events, tables, cost summaries). All 175 printf sites
migrated. All PAR SDK chunk/event variants now rendered.

**原因**: User feedback identified two concerns: (1) current output is visually
rough (no colors, no markdown rendering, no structured tool cards), (2)
continuing to add features on top of printf-based rendering would increase
future TUI refactor cost. The abstraction layer solves both: immediate visual
improvement via ANSI + structured layout, and future-proof API that maps 1:1
to Notty and Matrix/Mosaic TUI backends.

**影响范围**: 2 new modules (par_code_ui.ml/mli, par_code_ui_markdown.ml/mli),
7 modified files (all lib/ + bin/), 2 new test files (73 new tests).
Zero new external dependencies.

**回退方式**: Each file's printf→Ui migration is a pure output-mechanism swap.
Reverting to printf requires restoring the old code (the logic is unchanged,
only the output calls differ). The Ui module itself is a pure addition.

**已知限制**: Streaming markdown handles single-line constructs only. No syntax
highlighting. Basic table rendering (no wrapping). Future TUI backend (v0.14.0)
will add Mosaic/Matrix as an alternative render target.

## [2026-07-21] v0.4.5: streaming markdown state machine

**变更前**: LLM streaming output was rendered as plain text via
`Printf.printf "%s%!" text`. No markdown parsing — headings, bold, code
blocks, etc. appeared as literal markdown syntax in the terminal.

**变更后**: `lib/par_code_ui_markdown.ml` implements a streaming markdown
parser. Line-based state machine buffers incomplete lines, parses complete
lines for inline formatting (bold, italic, code, links), and handles block
constructs (headings, code fences, lists, quotes). Output is ANSI-styled text.
Round-trip property verified: feeding a document in arbitrary chunks produces
identical output to feeding it whole.

**原因**: Markdown rendering is the #1 visual improvement for LLM output.
Streaming (incremental) parsing is required because LLM output arrives token
by token, not as a complete document. No OCaml streaming markdown library
exists (omd is stale alpha, cmarkit is for complete documents). In-house
state machine based on streaming-markdown.js pattern.

**影响范围**: `lib/par_code_ui_markdown.ml` (318 lines) + `.mli` (41 lines),
`test/test_par_code_ui_markdown.ml` (37 tests including 3 round-trip property tests).

**回退方式**: Disable markdown rendering by routing Text_delta chunks directly
to `output_string` instead of through the markdown state machine. The module
is a pure addition.

**已知限制**: Single-line constructs only (no multi-line bold). Hand-rolled
parser (no regex lib) — handles common cases but may miss edge cases in
Complex CommonMark. Strikethrough deferred (terminal support varies).

## [2026-07-20] v0.4.3: per-session token accumulator for `/cost` command

**变更前**: par-code's REPL had no way to show token usage. PAR SDK's
`Metrics.counters` type tracks only operational counts (`llm_requests_total`,
`task_completed_total`, `task_failed_total`, `tool_invocations_total`,
`events_published_total`, `events_dropped_total`) — no token-level fields.
`Types.usage_stats` carries per-call token counts (`prompt_tokens`,
`completion_tokens`, `total_tokens`, etc.) returned in
`invoke_result.response.usage`, but nothing accumulated these across calls.

**变更后**: `lib/par_code_repl.ml` adds an immutable `cost_state` record
plus a mutable `cost_state ref` in the `run` function. After each
`Runtime.invoke` returns `Ok { Types.response; conversation }`, the
accumulator is updated: `cost := add_usage !cost resp.Types.usage`. Error
branches do NOT touch the accumulator. A new `/cost` slash command prints
the accumulator state, current context size (via
`Par_code_context.token_estimate !conv`), turn count, and the operational
metrics list from `Runtime.metrics_snapshot rt`.

**原因**: `/cost` was the top P0 user-pain item from the v0.4.2 post-release
review. Token usage visibility is foundational for users to understand
session cost and debug context-window exhaustion. PAR SDK's `Metrics` module
architecture (operational counts only) means token accumulation must live
in downstream consumers; par-code is the right place.

**影响范围**: `lib/par_code_repl.ml` (+72 lines: new `cost_state` type,
`empty_cost`, `add_usage`, `format_cost_output` helpers, `cost` ref,
`/cost` slash command, `/help` update, Ok-branch accumulator update),
`test/test_par_code_repl.ml` (NEW: 7 tests covering cost_state operations
and format_cost_output formatting).

**回退方式**: Remove the `cost` ref, `add_usage` call in Ok branch, `/cost`
slash command case, and `/help` line. The accumulator is a pure addition
with no side effects on existing code paths.

**已知限制**: Async checkpoint/extraction LLM calls (v0.4.1 Eio.Fiber.fork
dispatch) bypass the accumulator — their fiber's metrics are discarded.
`/cost` output explicitly notes this exclusion. Affects ~5-10% undercounting
in long sessions. Acceptable for v0.4.3; tracked for v0.5.0+ if metrics
visibility becomes important (would require PAR SDK enhancement to merge
fiber metrics back into `rt.metrics`).

## [2026-07-20] v0.4.3: memory `recall` usage-field workaround (PAR SDK limitation)

**变更前**: `Par_code_memory.recall` delegated to
`Sqlite_memory.search` (PAR SDK), which returns
`Memory_object.memory_object list`. That type lacks `last_used_at` and
`usage_count` fields entirely. par-code's `memory_of_object` conversion
hardcoded these to `None` / `0`. Result: the `recall_memory` LLM tool
showed stale usage stats even though the DB columns were being maintained
correctly by PAR SDK's internal `Sqlite_memory.search_fts` bump_usage.

**变更后**: `Par_code_memory.recall` now runs a supplementary parameterized
SQL query (`fetch_usage_stats`) after `Sqlite_memory.search` returns. The
query binds all returned memory IDs via `Sqlite3.bind` (never string
interpolation — injection-safe), reads `(last_used_at, usage_count)` from
the `memory_entries` table, and the converted `memory` records are patched
via immutable record update before return. Empty result list short-circuits
to avoid generating invalid `IN ()` SQL. Exceptions in the supplementary
query are caught and degrade gracefully to returning unpatched memories
(consistent with par-code's existing `with _ -> ()` style for raw SQL).

**原因**: PAR SDK's `Memory_object.t` (`lib/memory/memory_object.mli:1-11`)
was designed without usage-tracking fields. The DB schema has the columns
(`sqlite_memory.ml:81-82`), the SDK's `row_to_memory` reads them but
discards (underscore-prefixed at `sqlite_memory.ml:208-212`), and
`search_fts` internally bumps them via private `bump_usage`
(`sqlite_memory.ml:327, 363, 379, 399, 417, 482`). The data is in the DB
and being maintained — it just isn't surfaced through the SDK's public
type. Per AGENTS.md §1 (PAR SDK boundary), the workaround belongs on the
par-code side, with PAR SDK feedback filed for the upstream fix.

**影响范围**: `lib/par_code_memory.ml` (+30 lines: `fetch_usage_stats`
helper + `recall` modification), `test/test_par_code_memory.ml` (+2 new
tests: `recall_usage.returns_usage_fields` and
`recall_usage.safe_with_metachar_ids` — adversarial SQL injection test).

**回退方式**: Revert `recall` to direct `List.map memory_of_object results`.
The supplementary query is a pure addition.

**已知限制**: One extra SQL query per `recall` call (negligible — indexed
by `ext_id`, returns ≤ `limit` rows). The underlying PAR SDK limitation
remains: `Memory_object.t` still lacks the fields, so any future code path
that uses `Sqlite_memory.search` directly (without going through par-code's
`recall`) will still drop them. PAR SDK feedback filed separately
([2026-07-20] PAR SDK Feedback entry below).

## [2026-07-20] PAR SDK Feedback: Memory_object.t lacks usage-tracking fields

> **Superseded [2026-08-09]**: PAR SDK v0.8.1 shipped `last_used_at` and
> `usage_count` as public fields on `Memory_object.memory_object` (CHANGES.md
> v0.8.1 §"Memory service": "exposed on public type — were internal-only,
> maintained by `bump_usage`, affected `list_all` ordering"). par-code
> consumes them directly at `lib/par_code_memory.ml:304-305`
> (`memory_of_object` conversion reads `obj.Memory_object.last_used_at` and
> `obj.Memory_object.usage_count`). The v0.4.3 supplementary-SQL workaround
> in `Par_code_memory.recall` is fully removed; no `fetch_usage` or
> `supplementary` references remain. The raw-SQL paths in `row_to_memory`
> (line 311+) are unrelated bulk-listing queries, not the recall workaround.
> Retirement recorded as part of the v0.7.0 PAR SDK upgrade assessment.

Per global AGENTS.md §1 and the par-code par-sdk-feedback skill, one PAR
SDK gap surfaced during v0.4.3 implementation. Tracked here for upstream
action; does not block v0.4.3 (worked around in par-code).

1. **`Memory_object.memory_object` lacks `last_used_at` / `usage_count`
   fields** (`lib/memory/memory_object.mli:1-11`). The DB schema has both
   columns (`sqlite_memory.ml:81-82`); the SDK's `row_to_memory` reads
   them but discards (`sqlite_memory.ml:208-212`, underscore-prefixed);
   the SDK's `search_fts` internally bumps them via private `bump_usage`
   (`sqlite_memory.ml:327, 363, 379, 399, 417, 482`). The data is in the
   DB and being maintained — it just isn't surfaced through the SDK's
   public type. Downstream consumers needing usage stats from search
   results must do a supplementary SQL fetch (par-code v0.4.3 workaround
   in `Par_code_memory.recall`). **Severity**: medium (architectural
   paper-cut; the type design implies usage-tracking is unsupported,
   when in fact it's half-implemented but invisible).

   Suggested upstream fix: add `last_used_at : float option` and
   `usage_count : int` to `Memory_object.memory_object`. Update
   `row_to_memory` to populate them (read columns 8-9 instead of
   discarding). Update `Sqlite_memory.add` signature to NOT accept them
   (correct as-is: new memories start at 0/None). No schema migration
   needed — columns already exist.

## [2026-07-19] v0.4.2: critical fix — multi-turn conversation context (PAR SDK 0.7.8)

**变更前**: v0.4.0 and v0.4.1 shipped a binary bundling PAR SDK 0.7.8
*before* the engine.ml fix landed. PAR SDK's `Engine.run_agent` had a bug
at `engine.ml:1024-1029` (the `Stop`/`Content_filter` terminal branch of
the ReAct loop): the `add_assistant_message` call was missing — every
other terminal branch called it. The result: `Runtime.invoke` returned
an `invoke_result` whose `response.text` held the final assistant content
but whose `conversation.messages` was missing the corresponding
`{role=Assistant; ...}` entry. This silently degraded:

- Multi-turn coherence: the LLM could not see its own prior responses on
  subsequent turns (the conversation passed via `?conversation` lacked
  Assistant entries).
- Checkpoint-writer / extractor quality: the LLM saw only the user side
  of the dialogue.

**变更后**: PAR SDK 0.7.8 fixed the root cause via a single egress wrap
at the loop boundary (`engine.ml:1165`:

  `let conv_final = if needs_append then add_assistant_message conv_pre resp else conv_pre in`)

— eliminating the "remember-to-call-add_assistant_message" pattern that
had already produced one missing-branch bug. Oracle audited the fix
across three rounds of review; the final commit closed an idempotency
hole where the egress wrap could double-append in handoff scenarios.

par-code v0.4.2 rebuilds against the fixed PAR SDK 0.7.8. No par-code
source changes beyond version bump and documentation sync. Manual smoke
2026-07-19 confirmed: 2-turn session now produces `[System; User;
Assistant; User; Assistant]` in `conv.messages` (was `[System; User;
User]` before the fix); `/checkpoint` successfully stores; extraction
runs.

**原因**: multi-turn coherence is foundational to coding-agent quality.
v0.4.0 and v0.4.1 users have been silently affected. Critical-path
patch release — no other changes bundled.

**影响范围**: Binary-only rebuild. `dune-project`, `par_code.opam`,
`test/test_par_code.ml` (version assertion bumped 0.4.1 → 0.4.2),
`README.md` (Status line + roadmap), `CHANGES.md` (v0.4.2 section;
v0.4.1 Known Limitations note updated to point at v0.4.2 as the fix),
`docs/STRATEGY.md` (§8 + §9), this DECISIONS entry.

**回退方式**: Revert to PAR SDK pre-fix state and rebuild (no par-code
source rollback needed). Discouraged — the fix is architecturally
correct (single egress wrap is strictly better than 7 scattered inline
appends).

**已知限制**: None. The fix is closed-form — every Ok-bearing terminal
path now flows through the single egress wrap. PAR SDK 0.7.8's test
suite includes P0 handoff + generate coverage that exercises this path
(added in commit `0e835a1`).

### Historical reference

The bug was discovered during v0.4.1 manual smoke testing (2026-07-19)
when `/checkpoint` showed `[System; User; User]` instead of
`[System; User; Assistant; User; Assistant]`. Explore-agent diagnosis
2026-07-19 traced root cause to `engine.ml:1024-1029`. PAR SDK fix
landed upstream the same day.

## [2026-07-19] v0.4.1: async checkpoint via Eio.Fiber.fork (Oracle SAFE WITH CAVEATS)

**变更前**: v0.4.0 shipped checkpoint-writer + extractor as synchronous
`invoke_generate` calls inside the user's REPL turn. Every N turns (default
10) the user waited 2–5 s while the checkpoint LLM call completed before
the `par>` prompt returned. The v0.4.0 plan had flagged async as a target
but the ckpt_rt workaround (later eliminated) consumed the design surface;
the synchronous-at-turn-boundary path shipped.

**变更后**: `Par_code_checkpoint.run_checkpoint` now dispatches its
`invoke_generate ~save:false ~update_current:false` call via
`Eio.Fiber.fork ~sw:(Par.Runtime.cancellation_root rt)`. The user turn
returns immediately; the LLM call, JSON parse, store, and downstream
`run_extraction` all run in the background fiber. An `in_flight : bool ref`
in the REPL state throttles concurrent dispatches and is reset on every
fiber exit path (Ok/Error/exn) via `Fun.protect`. v0.4.0's
`~save:false ~update_current:false` isolation is preserved unchanged.

**原因**: synchronous checkpoint at every N turns was the most concrete
user-visible flaw in v0.4.0. PAR SDK 0.7.7 already ships `Eio.Fiber.fork`
and `Runtime.cancellation_root`; the v0.4.0 ckpt_rt elimination
([2026-07-18]) cleared the architectural surface needed to consume them
directly. Oracle review (2026-07-19) of every shared-state mutation in
`invoke_generate` (`runtime.ml:859-947`) returned **SAFE WITH CAVEATS**
under `~save:false ~update_current:false` for par-code's single-REPL
workload. The 9 engineering caveats are baked into the implementation.

**影响范围**: `lib/par_code_checkpoint.ml` (run_checkpoint / maybe_checkpoint
signatures gain `in_flight:bool ref`; new `format_checkpoints` and
`truncate_to_last_n` helpers also added in this version),
`lib/par_code_checkpoint.mli` (signature updates + new exposed vals),
`lib/par_code_extractor.ml` (local copy of last-N truncation helper),
`lib/par_code_repl.ml` (new `in_flight_checkpoint` ref in run state;
`/checkpoint` and `/checkpoints` command paths updated; periodic
`maybe_checkpoint` call site updated), `test/test_par_code_checkpoint.ml`
(5 new tests covering Pillar B truncation + Pillar C formatting),
`CHANGES.md` (v0.4.1 section), `docs/STRATEGY.md` (§8 + §9 updated),
`docs/DECISIONS.md` (this entry + 3 PAR SDK feedback items below).

**回退方式**: Revert to synchronous `invoke_generate` (drop the
`Eio.Fiber.fork` wrapper, drop `in_flight` plumbing). All other v0.4.1
changes (Pillar B truncation, Pillar C format_checkpoints, Pillar D
no-op confirmation) are pure additions and can stay.

**已知限制**:
1. Checkpoint/extraction LLM calls no longer appear in `rt.metrics` —
   the fiber's `ctx.metrics_accumulator` is discarded (no `merge_into`).
   Acceptable for v0.4.1; tracked for v0.5.0+ if metrics visibility
   becomes important.
2. `rt.last_llm_call_at` / `rt.last_llm_call_status` may briefly reflect
   the checkpoint call instead of the user's call (lost-update race on
   `runtime.ml:435-436, 442-443`). Diagnostic only; health snapshot
   tolerates stale reads.
3. Async return-immediately behavior verified by manual smoke rather than
   unit test. Mocking `invoke_generate` would require invasive functor
   refactor; deferred.
4. `compute_active_skill_effects` (`runtime.ml:886`) reads
   `rt.user_activated_skills` live (not snapshotted, unlike `invoke`
   at `runtime.ml:742`). Dormant race today — par-code never mutates
   this field after setup — but a future contributor adding mid-session
   skill toggling would activate it. Code comment in `run_checkpoint`
   flags this.

### Oracle evidence summary (full table in `.sisyphus/plans/v0.4.1.md`)

| Shared field | Touch under `~save:false ~update_current:false` | Race | Verdict |
|---|---|---|---|
| `rt.session_id` (`runtime.ml:861-867`) | Write only if None | None — REPL sets at first turn | SAFE |
| `Event_bus.current_session_id` (`event_bus.ml:141-142`) | Unconditional write, no mutex | Theoretical, always same value | SAFE |
| `rt.last_llm_call_{at,status}` (`runtime.ml:435-436,442-443`) | Write (record_llm_*) | Lost-update | SAFE (diagnostic) |
| `rt.metrics` (`metrics.ml:2-7`) | incr_llm via fiber-local ctx | None — invoke_generate never merges | SAFE |
| `rt.current_conversation` (`runtime.ml:938,944`) | Never read; write gated | None | SAFE |
| `rt.user_activated_skills` (`runtime.ml:886`) | Read live (not snapshot) | Dormant in par-code | SAFE |
| `rt.services.llm` | Concurrent HTTP | Stateless providers | SAFE |
| `save_conversation` (`runtime.ml:939-940`) | All paths gated | None | SAFE |

### 9 engineering caveats baked into implementation

1. `try ... with exn` inside fork body — `invoke_generate` handles LLM errors
   but PAR SDK or Eio can raise unexpected exceptions.
2. `~sw:(Par.Runtime.cancellation_root rt)` — not a fresh switch.
3. Snapshot `transcript` and `conv` by value before `Eio.Fiber.fork`.
4. `in_flight : bool ref` throttle; reset via `Fun.protect ~finally`.
5. Do NOT `Promise.await` the fiber handle — fire-and-forget.
6. All three REPL exit paths (SIGINT/EOF/`/quit`) let `rt.cancellation_root`
   teardown propagate cancellation via PAR SDK's normal close path.
7. Accept `rt.metrics` under-count (documented in CHANGES).
8. Accept `last_llm_call_*` flapping (documented in CHANGES).
9. Code comment flags the `user_activated_skills` live read.

### Type-mismatch note (why `Eio.Fiber.fork` instead of `Invoke_context.fork_invoke`)

`Invoke_context.fork_invoke` (`invoke_context.mli:96-100`) is typed for
closures returning `(invoke_result, error_category * conversation) result`,
but `Runtime.invoke_generate` returns `(generate_result, error_category *
conversation) result`. These are distinct types in `types.mli`. The
proposed `fork_invoke`-based sketch in the original v0.4.1 plan would not
have compiled. Using `Eio.Fiber.fork` directly (which is what `fork_invoke`
calls underneath, minus the type-restricted handle wrapping) is the
architecturally correct path. PAR SDK feedback item #3 tracks this gap.

## [2026-07-19] PAR SDK Feedback: 3 items surfaced by v0.4.1 async work

Per global AGENTS.md §1 and the par-code par-sdk-feedback skill, three
PAR SDK gaps surfaced during v0.4.1 implementation. Tracked here for
upstream action; none blocks v0.4.1.

1. **`Event_bus.set_session_id` writes without mutex** (`event_bus.ml:141-142`).
   `publish` reads under `Eio.Mutex.use_ro` (`event_bus.ml:56`), but the
   setter is bare assignment. In par-code's call pattern the value is
   always identical (read from already-set `rt.session_id`), so no
   observable race today. Future PAR SDK consumers that vary session_id
   per fiber would hit this. **Severity**: low (workaround: caller-side
   discipline).

2. **`rt.last_llm_call_at` / `rt.last_llm_call_status` are plain mutable**
   (`runtime.ml:435-436, 442-443`). Lost-update race under concurrent
   fibers. **Severity**: low (diagnostic only; readers at
   `runtime.ml:1776-1777` health snapshot and `par_capi.ml:1132-1136`
   FFI tolerate stale reads).

3. **`Runtime.invoke_async` lacks `?save` / `?update_current`** (re-affirmed
   from v0.4.0 feedback). The closure signature of
   `Invoke_context.fork_invoke` (`invoke_context.mli:96-100`) is typed
   for `invoke_result`, not `generate_result`. Both gaps force consumers
   needing async + isolation to bypass PAR SDK's async primitives and
   call `Eio.Fiber.fork` directly. **Severity**: medium (architectural
   paper-cut; encourages consumers to invent their own async patterns).

## [2026-07-18] Architecture: eliminate ckpt_rt, use PAR SDK 0.7.7 save/isolation controls

**变更前**：v0.4.0 used a separate checkpoint Runtime (`ckpt_rt`) with no-op persistence to isolate checkpoint/extractor `invoke_generate` calls from the user's Runtime. This was a ~50-line workaround for PAR SDK's lack of save/isolation controls.

**变更后**：PAR SDK v0.7.7 shipped `?save:bool` and `?update_current:bool` on `invoke_generate`, and `?conversation:` on `save_conversation`. par-code now runs checkpoint/extractor on the user's Runtime with `~save:false ~update_current:false`. The separate Runtime, no-op persistence, and second LLM service are eliminated. Exit paths use `save_conversation ?conversation:!conv` to save the authoritative ref directly.

**原因**：The ckpt_rt was a workaround for a PAR SDK limitation. With the limitation fixed at root (PAR SDK 0.7.7), the workaround is unnecessary overhead — a second Runtime, second LLM connection, and duplicate agent registrations. Removing it simplifies the architecture and reduces resource consumption.

**影响范围**：`lib/par_code_checkpoint.ml` (run_checkpoint/maybe_checkpoint use rt instead of ckpt_rt), `lib/par_code_extractor.ml` (invoke_generate gains ~save:false ~update_current:false), `lib/par_code_setup.ml` (removed ckpt_rt creation + agent registrations), `lib/par_code_repl.ml` (removed ~ckpt_rt parameter), `bin/main.ml` (simplified callbacks).

**回退方式**：Revert to ckpt_rt architecture. The checkpoint module still accepts `~rt` which can be either the user's or a separate Runtime.

**已知限制**：`invoke_generate` with `~save:false ~update_current:false` still mutates `rt.session_id` (if None), `event_bus`, and metrics. In par-code's single-threaded REPL, these are benign (session_id is already set, metrics inflation is negligible). Not full fiber-safe isolation — reduced shared-state dependency, not eliminated.

## [2026-07-16] v0.4.0 shipped — Long-session continuity

**变更前**：v0.3.3 shipped (hybrid memory search). v0.4.0 was unimplemented. Long sessions relied on the full conversation being passed to each invoke, eventually exceeding the model's context window with no recovery mechanism.

**变更后**：v0.4.0 shipped. Version bumped to 0.4.0 in dune-project + par_code.opam + test assertion. Tag v0.4.0 pushed; Release workflow built Linux x64/arm64 + macOS arm64 binaries successfully (all 4 jobs green); GitHub Release published. README/CHANGES/STRATEGY synced.

**原因**：v0.4.0 delivers the signature capability "hours-long sessions never lose the thread" via four pillars: (1) checkpoint-writer subagent on a separate isolated Runtime, (2) budgeted context injection (chars/4 heuristic compaction), (3) context reconstruction on resume, (4) periodic mid-session memory extraction. The separate Runtime architecture was Oracle-reviewed and confirmed as architecturally correct (R1/R3). Live testing verified all features end-to-end with real LLM calls, finding and fixing 7 bugs (think-tag JSON parsing, infinite loop, exception guard gaps, missing extractor registration on ckpt_rt, false compaction notices).

**影响范围**：2 commits — feat(v0.4.0) (14 files, +1120 lines) + release bump (7 files). New modules: par_code_checkpoint.ml/mli (351/60 lines), par_code_context.ml/mli (99/23 lines). New tests: 20 checkpoint tests. Users: `curl install.sh | bash` now installs v0.4.0; existing users get offered the upgrade.

**回退方式**：Git tag and GitHub Release are permanent. Code state can be reverted via `git revert`. Memory schema is backward-compatible (checkpoints table is additive).

**已知限制**：(1) Token estimation uses chars/4 heuristic (±20% accuracy). (2) Checkpoint calls are synchronous (~2-5s every N turns). (3) Checkpoint content quality depends on model capability (weaker models may return trivial/empty checkpoints). (4) PAR SDK feedback filed (3 items: invoke_generate auto-save inconsistency, current_conversation shared mutable, save_conversation lacks ?conv parameter).

## [2026-07-16] v0.4.0: separate checkpoint Runtime for isolation

**变更前**：par-code used a single `Runtime` instance for all LLM calls (main agent + memory extractor). The extractor ran synchronously at session exit, so no concurrency issue existed.

**变更后**：v0.4.0 adds a checkpoint-writer subagent that runs `invoke_generate` during the session (not just at exit). PAR SDK's `invoke_generate` clobbers `rt.current_conversation` (line 917) and auto-saves (line 918), which would corrupt the user's saved session if run on the shared Runtime. A **separate `Runtime` instance** (`ckpt_rt`) with no-op persistence is created at setup time. Checkpoint calls only affect `ckpt_rt`'s state. The user's `rt` is never touched.

**原因**：PAR SDK's `Runtime` has unprotected shared mutable state (`current_conversation`, `session_id`). Concurrent `invoke_generate` on the same runtime races — the last writer wins, potentially saving the checkpoint's conversation as the user's session. The separate Runtime eliminates this race class structurally rather than relying on cooperative-scheduling reasoning. Oracle confirmed this is the architecturally-correct choice (R1/R3).

**影响范围**：`lib/par_code_setup.ml` (creates `ckpt_rt`), `lib/par_code_repl.ml` (accepts `~ckpt_rt`), `bin/main.ml` (threads `ckpt_rt`). No PAR SDK changes.

**回退方式**：Remove `ckpt_rt`, pass `None` as the `~ckpt_rt` parameter. Checkpointing is disabled but all other functionality continues. The separate Runtime is a pure addition — no existing behavior changes when `ckpt_rt = None`.

**已知限制**：Creates a second LLM provider connection (minor resource overhead). The long-term clean fix is a PAR SDK `?persist:bool` parameter on `invoke_generate` (tracked as PAR feedback #1). When PAR ships that, the separate Runtime can be collapsed back to one with the flag.

## [2026-07-16] v0.4.0: Context Ledger pattern for checkpoint storage

**变更前**：No checkpoint mechanism existed. Long sessions relied on the full conversation being passed to each `invoke`, eventually exceeding the model's context window.

**变更后**：Checkpoint entries are structured JSON records (task, decisions, files_changed, interfaces, open_threads) stored in a `checkpoints` SQLite table with FTS5 index. Each entry is ~300 tokens. On resume, the most recent entries are rendered into a compact session brief injected as `system_prompt_appendix`.

**原因**：Research into production coding-agent continuity patterns identified "Context Ledger" (structured entries at semantic boundaries + retrievable pointers) as the highest-leverage approach. Unlike prose summarization (lossy, compounds errors across cycles), structured entries are compact and lossless — each entry captures what matters without degrading through repeated summarization.

**影响范围**：`lib/par_code_checkpoint.ml` (new, 328 lines), `test/test_par_code_checkpoint.ml` (new, 15 tests), `lib/par_code_memory.ml` (+raw_db accessor).

**回退方式**：Delete the `checkpoints` table and checkpoint module. The `checkpoints_fts` virtual table and triggers are safe to drop. No data dependency exists on checkpoint entries — they are pure additions to the session state.

**已知限制**：Each checkpoint is a full snapshot (no delta/incremental). FTS5 search is keyword-based (no semantic search yet). Delta checkpoints and embedding-based retrieval are deferred to v0.5.0+.

## [2026-07-16] v0.4.0: Budgeted context injection (chars/4 heuristic)

**变更前**：The full conversation was passed to every `invoke` call. No token budget checking. Long sessions would eventually hit the model's context window limit, causing truncated or failed calls.

**变更后**：Before each `invoke`, `Par_code_context.token_estimate` computes a rough token count (total chars / 4). If over `context_budget_tokens` (default 100000), older messages are replaced with a single summary message (from the most recent checkpoint) while the last 8 messages are kept verbatim. A notice is printed to stderr.

**原因**：A real tokenizer (per-model token tables, BPE-style) would add an external dependency and per-model tables. The chars/4 heuristic is deliberately conservative (over-estimates → compacts early) and sufficient for a v0.4.0 MVP. The PAR SDK's internal `context_strategy = Summarize` handles within-turn trimming; this par-code-level budgeting controls what reaches PAR in the first place.

**影响范围**：`lib/par_code_context.ml` (new, 99 lines), `lib/par_code_repl.ml` (budget check before invoke).

**回退方式**：Set `context_budget_tokens` to a very large value (e.g., 999999) in config. Compaction never triggers.

**已知限制**：±20% accuracy (chars/4 heuristic). A real tokenizer can replace this in v0.5.0+ without API changes — the `token_estimate` function signature stays the same.

## [2026-07-16] v0.4.0: Periodic mid-session memory extraction

**变更前**：Memory extraction ran only at session exit (synchronous, blocking the user for 2-5 seconds). Facts discovered during a long session weren't available as memories until the session ended.

**变更后**：The checkpoint cycle (every N turns) also triggers memory extraction via the checkpoint Runtime (`ckpt_rt`). Facts appear in the memory index mid-session. Exit-time extraction remains as a safety net (synchronous, unchanged from v0.3.1).

**原因**：The `fork_invoke` deferred item from v0.3.3 (DECISIONS.md [2026-07-11]) is consumed: the separate checkpoint Runtime provides the isolation that `fork_invoke` was meant to enable. Mid-session extraction makes long sessions more productive — the agent can recall facts it discovered earlier in the same session.

**影响范围**：`lib/par_code_checkpoint.ml` (calls `run_extraction` after storing checkpoint), `lib/par_code_repl.ml` (checkpoint cycle triggers both checkpoint + extraction).

**回退方式**：Disable checkpointing via `PAR_NO_CHECKPOINT=1`. Exit-time extraction still runs (v0.3.1 behavior).

**已知限制**：Extraction runs synchronously on `ckpt_rt` (~2-5s every N turns). True background fiber execution is a future enhancement. The `ckpt_rt`'s `invoke_generate` auto-save is a no-op (by design), so extracted conversations don't pollute the DB.

## [2026-07-15] v0.3.3 shipped — PAR SDK 0.7.3 + hybrid memory search

**变更前**：v0.3.2 shipped (Linux arm64). v0.3.3 unreleased with 6 commits on main: PAR SDK 0.7.3 consumption (per-turn memory injection, skill-workaround removed), `Sqlite_memory` storage migration (memory IDs int → UUID, schema auto-migrated from v0.3.0–v0.3.2), embedding API configuration (independent embedding provider), hybrid search infrastructure (FTS5 + vec0 + RRF), UX fixes (Ctrl-C saves session, config fallback), and doc sync.

**变更后**：v0.3.3 shipped. Version bumped to 0.3.3 in `dune-project`, `par_code.opam`, and `test/test_par_code.ml`. Tag `v0.3.3` pushed; Release workflow built Linux x64 + Linux arm64 + macOS arm64 binaries successfully (all 4 jobs green); GitHub Release published. README/CHANGES/STRATEGY synced to shipped state.

**原因**：The 6 unreleased commits formed a closed architectural-cleanup loop (consume PAR SDK 0.7.3 + standardize memory storage on PAR SDK `Sqlite_memory`). Holding them unshipped would defer the hybrid-search infrastructure value and inflate v0.4.0 into a large release. Shipping now clears the deck for v0.4.0 (long-session continuity: checkpoint-writer + `fork_invoke` background extraction).

**影响范围**：Release commit (`dune-project`, `par_code.opam`, `test/test_par_code.ml`) + doc-sync commit (`README.md`, `CHANGES.md`, `docs/STRATEGY.md`, `docs/DECISIONS.md`). No code changes in either commit. Users: `curl install.sh | bash` now installs v0.3.3; existing users get offered the upgrade via the startup version check.

**回退方式**：Git tag and GitHub Release are permanent (users may have already installed v0.3.3). Code state can be reverted via `git revert <release-sha>`. **Memory schema migration is NOT reversible** — v0.3.3's `Sqlite_memory` migration drops old tables after reading; users upgrading from v0.3.0–v0.3.2 should have exported memories first (`par memory export > backup.md`). See [2026-07-11] migration decision for details.

**已知限制**：(1) CI workflow's `ubuntu-24.04-arm` job failed during release due to a transient GitHub ARM-runner network issue (`ports.ubuntu.com` unreachable — IPv6 "Network is unreachable", IPv4 timeout); re-run separately. The Release workflow (Docker-based, AlmaLinux 8) was unaffected and produced correct arm64 artifacts. (2) vec0 extension availability varies by platform; degrades gracefully to FTS5-only when absent.

## [2026-07-11] v0.3.3: migrate memory storage to PAR SDK Sqlite_memory

**变更前**：par-code used a custom `Par_code_memory` module with its own schema (`id INTEGER PK`, `kind TEXT`, `citations TEXT`, `project_id TEXT`) and FTS5 keyword search only.

**变更后**：Storage layer delegated to PAR SDK 0.7.3 `Sqlite_memory`. Memory CRUD uses `Sqlite_memory.add/search/delete`; par-code-specific features (kind-grouped `render_index`, `export_markdown`, `prune_stale`, `search_history` via `conversations_fts`) kept as raw SQL wrappers. Memory IDs changed from `int` to UUID strings (`ext_id`). Old v0.3.0–v0.3.2 schema auto-migrated on first `open_db` (detects `kind` column, reads data, drops old tables, re-inserts preserving timestamps and usage stats).

**原因**：PAR SDK 0.7.3 shipped `Sqlite_memory` with FTS5 + vec0 vector search + RRF hybrid search (need #4). Migration enables future semantic search capabilities. par-code's custom schema is replaced by PAR SDK's standard schema (`ext_id`, `scope`, `metadata`, `categories`), reducing maintenance burden.

**影响范围**：`lib/par_code_memory.ml` (full rewrite), `lib/par_code_memory.mli` (id: int→string), `lib/par_code_memory_tools.ml` (id serialization), `lib/par_code_extractor.ml` (dedup type), `bin/main.ml` (CLI format strings), `bin/cli_args.ml` (id arg: int→string), `lib/dune` (+par.memory dependency), `test/test_par_code_memory.ml` (adapted for new types).

**回退方式**：Revert to old `Par_code_memory` module. The migration drops old tables after reading, so old data is lost without backup. Users upgrading to v0.3.3 should export memories first (`par memory export > backup.md`) if they want a safety net.

**已知限制**：vec0 扩展在极少数环境下可能不可用（自动降级为 FTS5 关键词搜索）。Embedding API 可通过 `par config` 单独配置（`embedding_base_url`、`embedding_model`、`embedding_dimension`），支持聊天和 embedding 使用不同 provider。

## [2026-07-11] Deferred: fork_invoke for background extraction (target v0.4.0)

**变更前**：Memory extraction runs synchronously at session exit, blocking the user for 2-5 seconds while the extractor agent runs one LLM call. No extraction happens during the session.

**变更后**（计划）：Use PAR SDK 0.7.3 `fork_invoke` to run extraction in a background fiber. User exits immediately; extraction completes asynchronously. Additionally, periodic mid-session extraction (every N turns) becomes possible.

**原因**：PAR SDK 0.7.3 shipped `fork_invoke` + `invoke_async` + fiber-local `invoke_context` (need #3). par-code's current synchronous-at-exit approach was a workaround for PAR SDK's lack of safe concurrent invoke.

**归属**：v0.4.0（长会话连续性）。fork_invoke 是 v0.4.0 checkpoint-writer subagent 的实现基础——后台提取只是顺手做的事，主线是"长时间会话不掉链子"。不单独版本化。

**已知限制**：PAR SDK `rt.current_conversation` 仍是共享可变状态，两个并发 invoke 会 race。使用时必须显式传 `?conversation`，且只在用户侧 invoke 上调 `save_conversation`，后台 invoke 不碰 `current_conversation`。

**回退方式**：维持现状（同步退出时提取），不影响功能。

## [2026-07-11] Deferred: migrate to PAR SDK Sqlite_memory for vector/hybrid search (独立基建版本)

> **Consumed [2026-07-11]**: Migration completed in v0.3.3. See [2026-07-11] v0.3.3 decision above. Embedding wiring deferred.

**变更前**：par-code 使用自建的 `Par_code_memory` 模块，仅支持 FTS5 关键词搜索。记忆检索依赖词面匹配——用户问"认证"搜不到写着"auth"的记忆。

**变更后**（计划）：迁移存储层到 PAR SDK 0.7.3 的 `Sqlite_memory`，获得 vec0 向量搜索 + RRF 混合搜索能力。记忆检索从关键词匹配升级为语义搜索。

**原因**：PAR SDK 0.7.3 shipped `Par.Memory` module (`Sqlite_memory`) with FTS5 + vec0 + RRF (need #4)。par-code 的 `Par_code_memory` 已验证模式可行，上游化是 STRATEGY.md §2 双角色职责。

**归属**：独立基建版本（v0.3.3 或 v0.4.0 与 v0.5.0 之间）。不绑定特定功能版本——它是存储层升级，用户面感知是"搜记忆更准了"。

**迁移要点**：
- `kind` (Preference/Convention/...) → `categories: ["preference"]`
- `project_id` → `scope: project_id`
- `citations` → `metadata: [("citations", `List [...])]`
- 保留 par-code 专有功能作为 wrapper：`render_index`（kind-grouped）、`export_markdown`、`prune_stale`、`search_history`（conversations_fts，PAR SDK 的 builtin 版本更弱）
- 需写 `Memory_service.memory_service` → `Types.memory_service` 类型适配器

**回退方式**：维持现状（FTS5 关键词搜索），不影响功能。

## [2026-07-11] Consume PAR SDK 0.7.3: remove skill workaround + adopt per-turn memory injection

**变更前**：PAR SDK 0.6.9 had two gaps: (1) Auto-trigger skills silently replaced the agent system prompt via `system_prompt_override`; par-code worked around this by downgrading Auto→Manual before registration. (2) `Runtime.make_agent` took `system_prompt` once at registration; par-code baked the memory index into the system prompt at session start (static for the entire session).

**变更后**：(1) Workaround removed — PAR SDK 0.7.3 strips `system_prompt_override = None` for Auto-trigger skills in `compute_active_skill_effects` (commit 344bef7). Builtin skills now register as-is. (2) Memory index is injected per-turn via `?system_prompt_appendix` parameter on `Runtime.invoke` — fresh on every turn, reflecting mid-session memory additions immediately.

**原因**：PAR SDK 0.7.3 shipped all four needs par-code raised (#1 Auto-skill fix, #2 per-turn system prompt, #3 fork_invoke, #4 Par.Memory). This change consumes #1 and #2 — the highest-value, lowest-risk improvements. #3 (background extraction) and #4 (Sqlite_memory migration) deferred to future versions.

**影响范围**：`dune-project` (par >= 0.7.3), `lib/par_code_setup.ml` (remove workaround + simplify system_prompt + pass mem_db to callback), `lib/par_code_repl.ml` (build_memory_appendix + ?system_prompt_appendix on invoke), `bin/main.ml` (pass mem_db through callback), `lib/par_code_setup.ml` make_persistence_service (forward ?scope parameter added in 0.7.3).

**回退方式**：Revert to PAR SDK 0.6.9 constraint, restore Auto→Manual workaround, restore static memory baking. But this loses per-turn memory freshness and requires maintaining the workaround.

**已知限制**：Memory index rendering runs once per turn (fast indexed query, <1ms). `fork_invoke` (#3) and `Sqlite_memory` migration (#4) not yet consumed — tracked for v0.4.0+.

## [2026-07-09] Auto-trigger skills downgraded to Manual (system_prompt_override fix)

> **Superseded [2026-07-11]**: PAR SDK 0.7.3 strips system_prompt_override for Auto skills. Workaround removed. See [2026-07-11] decision above.

**变更前**：par-code registered all PAR SDK builtin skills as-is. The `summarizer` and `rag-assistant` skills have `trigger=Auto` + `system_prompt_override=Some(Stable_prompt ...)`, causing them to activate on every turn and replace the agent's system prompt entirely via `apply_skill_effect_to_config` (PAR SDK `runtime.ml:406`).

**变更后**：Skills with `trigger=Auto` are downgraded to `trigger=Manual` before registration. The skills remain available for explicit activation but no longer auto-activate and clobber the system prompt.

**原因**：A user test session with a third-party LLM provider revealed the model responding as "expert summarizer" instead of the coding agent identity. Root cause: the summarizer skill's `Stable_prompt` override completely replaced par-code's `"You are par, an interactive coding assistant..."` system prompt on every turn. The model literally received the skill's override text as its system prompt.

**影响范围**：`lib/par_code_setup.ml` (skill registration — `List.map` downgrade before `register_skill`).

**回退方式**：Remove the `List.map` filter; register `Builtin_skills.builtin_skills` directly.

**已知限制**：`summarizer` and `rag-assistant` now require explicit user activation (Manual trigger). PAR SDK should fix the root cause: `trigger=Auto` skills should not carry `system_prompt_override`. Tracked as PAR SDK feedback item.

## [2026-07-09] SIGINT handler saves conversation before exit

**变更前**：Ctrl-C (SIGINT) killed the process immediately with no cleanup. Conversations from interrupted sessions were never persisted, making them invisible to `search_history`.

**变更后**：A `Sys.set_signal Sys.sigint` handler in the REPL calls `save_conversation` + `maybe_extract` before `exit 130`.

**原因**：User test session showed `search_history` returning 0 results after the previous session was terminated with Ctrl-C. The REPL had handlers for Ctrl-D (EOF) and `/quit` but none for SIGINT — the process died before `save_conversation` could run.

**影响范围**：`lib/par_code_repl.ml` (signal handler in `run`).

**回退方式**：Remove the `Sys.set_signal` call.

**已知限制**：If SIGINT arrives mid-stream during an LLM response, the conversation is saved in a potentially incomplete state. Acceptable — partial history is better than no history.

## [2026-07-09] system_prompt falls back to default when missing from config

**变更前**：`of_json`'s `get_s` returned `""` for missing string fields with no fallback. If `system_prompt` was absent from `config.json`, it silently became empty — unlike `temperature`/`max_iterations` which had explicit defaults.

**变更后**：`system_prompt` falls back to `default.system_prompt` when the field is empty or absent.

**原因**：Inconsistency with other config fields that had defaults. An empty `system_prompt` would cause `Runtime.make_agent` validation failure (`runtime.ml:115`) with a confusing error message.

**影响范围**：`lib/par_code_config.ml` (`of_json` function).

**回退方式**：Revert to `get_s "system_prompt"` without fallback.

**已知限制**：Only `system_prompt` has the fallback. Other string fields (`provider`, `api_key`, `model`, `persistence`) still return `""` for missing fields — correct behavior, as these must be explicitly set.

## [2026-07-06] v0.3.2: Linux arm64 pre-built binary via native ARM runner

**变更前**：Pre-built binaries only for Linux x86_64 and macOS arm64. ARM Linux users (Raspberry Pi, AWS Graviton) had to compile from source (~20-30 min on Pi).

**变更后**：Added `build-linux-arm64` CI job on GitHub's `ubuntu-24.04-arm` native ARM runner. Same AlmaLinux 8 Docker build base, same FTS5 sqlite3 amalgamation. install.sh and `par upgrade` recognize `aarch64`/`arm64`.

**原因**：User reported Raspberry Pi compilation pain. GitHub opened free ARM runners for public repos (2025). Same Dockerfile works for both architectures (architecture-aware opam download + tarball naming via `uname -m`). No cross-compilation complexity.

**影响范围**：release.yml (new job), Dockerfile (architecture-aware), install.sh (arm64 detection), par_code_upgrade.ml (arm64 platform), README platform table.

**回退方式**：Remove `build-linux-arm64` job from release.yml. ARM users fall back to source compilation.

**已知限制**：Alpine Linux (musl) still unsupported — static musl binary is a separate stretch goal.

## [2026-07-06] Auto-extraction at session exit (not background)

**变更前**：No auto-extraction. Memories only written via explicit `remember_memory` tool or `par memory add` CLI.

**变更后**：After REPL session exit, an extractor agent reads the transcript and writes salient memories.

**原因**：PAR SDK cannot safely run parallel/background agents (shared mutable state `current_conversation` corrupts on reentrant `invoke`). Synchronous extraction at exit avoids all concurrency issues. Cost: one LLM call (~2-5s) at exit, acceptable.

**影响范围**：lib/par_code_extractor.ml (NEW), lib/par_code_repl.ml (exit trigger), lib/par_code_setup.ml (extractor agent registration).

**回退方式**：Set PAR_NO_AUTO_EXTRACT=1 or auto_extract:false. Background extraction deferred to v0.3.2+ pending PAR SDK invoke_async support.

**已知限制**：Extraction runs once per session (at exit), not per-turn. No background extraction during active session.

## [2026-07-06] History search via FTS5 on raw messages_json

**变更前**：No way to search past session transcripts. Users had to manually resume individual sessions.

**变更后**：FTS5 virtual table `conversations_fts` indexes the `messages_json` column of the existing `conversations` table. `search_history` agent tool + `par memory search-history` CLI provide FTS5 BM25 search with snippet highlighting.

**原因**：FTS5 is already available (bundled sqlite3 with v0.3.0). Indexing raw JSON is pragmatic — JSON syntax noise dilutes BM25 ranking slightly, but `snippet()` extracts relevant fragments. A flattened text column would improve quality but needs a PAR SDK schema change (conversations table is created by Sqlite_persistence).

**影响范围**：lib/par_code_memory.ml (conversations_fts schema + search_history), lib/par_code_memory_tools.ml (search_history tool), bin/main.ml (CLI command).

**回退方式**：N/A (additive feature).

**已知限制**：History search is global, not project-scoped (conversations table lacks project_id column). FTS5 over JSON has minor quality degradation vs flattened text.

## [2026-07-06] v0.2.2 deferred; v0.3.0 prioritized

**变更前**：Roadmap had v0.2.2 (Windows native + code signing) as the next release after v0.2.1.

**变更后**：v0.2.2 deferred. v0.3.0 (project memory) is now the active development target.

**原因**：Research revealed the PAR SDK dependency stack cannot build on Windows today — `Eio.Process` (needed by PAR's MCP stdio transport and bash tool) is unimplemented on Windows (`failwith "process operations not supported on Windows yet"`). Shipping a Windows binary that crashes on first process spawn would be a scope compromise disguised as architecture (R1 violation). Code signing alone (without Windows) was too thin to justify a release.

**影响范围**：README roadmap table, STRATEGY.md §8 Roadmap Posture, release pipeline (no Windows CI job added).

**回退方式**：When eio upstream ships `Eio.Process` for Windows, re-scope v0.2.2 with Windows native + signing.

**已知限制**：Windows users must use WSL in the meantime.

## [2026-07-06] v0.3.0 memory architecture: SQLite+FTS5 over filesystem

**变更前**：No memory layer existed. Public reference projects in the same category use filesystem-based memory (markdown files + LLM-as-retriever).

**变更后**：SQLite-backed memory with FTS5 virtual table + BM25 ranking, per-project scoping. DB is source of truth; `MEMORY.md` is auto-generated export only.

**原因**：par-code is SQLite-native (par.db already exists, sqlite3-ocaml is a hard dep, pre-built binary bundles libsqlite3). FTS5 gives transactional writes + search for free. Filesystem-based memory would require parsing markdown back to structured data and loses transactional guarantees. Diverges from public reference projects' filesystem choice, which was driven by their runtime constraints, not a principled DB aversion.

**影响范围**：New module `lib/par_code_memory.ml`, new tools (`recall_memory`, `remember_memory`), new CLI subcommand group (`par memory`).

**回退方式**：N/A (new feature, no prior state to revert to).

**已知限制**：FTS5 unicode61 tokenizer is suboptimal for CJK (Chinese/Japanese/Korean) text — treats codepoints as individual tokens. Acceptable for v0.3.0 (most memories are English or mixed); revisit in v0.3.1+ if CJK recall quality is poor.

## [2026-07-06] v0.3.0 memory storage: shared par.db via PAR SDK accessor

**变更前**：PAR SDK's `Sqlite_persistence.t` was opaque — no way for downstream apps to add tables.

**变更后**：PAR SDK 0.6.9 adds `val raw_sqlite3_db : t -> Sqlite3.db` (1-line accessor). par-code opens a second connection to the same `~/.par/par.db` with WAL mode for memory tables.

**原因**：Per STRATEGY.md §2 dual-role mandate, when par-code finds a PAR limitation, the first response is to fix PAR. The accessor is read-only and trivially correct. Opening a separate `memory.db` was the fallback (Path C) if PAR didn't ship the accessor.

**影响范围**：PAR SDK 0.6.9 (new `raw_sqlite3_db` in `sqlite_persistence.mli`); par-code `lib/par_code_memory.ml` (opens same DB file, WAL mode).

**回退方式**：If the accessor causes issues, switch to separate `~/.par/memory.db` (Path C). Migration: copy memory tables to new DB, point `open_db` at the new path.

**已知限制**：Two connections to the same SQLite file requires WAL mode (enabled by `open_db`). If PAR SDK later switches away from SQLite, memory tables need migration.

## [2026-07-06] MEMORY.md as auto-generated export, not source of truth

**变更前**：Public reference projects treat their memory file (various naming conventions) as the source of truth — agent reads and writes it directly.

**变更后**：par-code's DB is the source of truth. `par memory export` generates a read-only `MEMORY.md` for human consumption / git commit. par-code never reads `MEMORY.md` back.

**原因**：DB-first gives transactional writes, FTS5 search, usage tracking, and per-project scoping for free. Filesystem-first would require parsing markdown back to structured data, which is fragile and loses these guarantees.

**影响范围**：`par memory export` command, README "Project Memory" section (documents the export-only contract).

**回退方式**：N/A (design decision, not a regression).

**已知限制**：If a user edits the exported `MEMORY.md` by hand, those edits are lost on the next export. Documented in the export command output.

## [2026-07-02] Founding: par-code as a PAR-SDK coding agent

**变更前**：—（新项目）

**变更后**：初始化 `par-code` —— 基于 PAR (Programmable Agent Runtime) SDK 的
交互式编码 Agent，同时作为 PAR 项目的实战验证案例。

**原因**：
- 充分利用 PAR SDK 的全部能力（ReAct、工具分发、类型安全 bash、MCP、skills、
  workflow、流式），从 coding 视角验证 PAR 成熟度。
- 继承 PAR 的 CLI 约定（cmdliner、bin/ 布局），保持 flag 兼容。

**关键决策**（经与用户确认）：
1. **集成路径**：OCaml 原生 SDK（`opam pin add par`），而非 Python binding 或包装 CLI
   二进制 —— 真正继承 PAR 的 OCaml CLI 代码，验证面最广。
2. **Agent 形态**：交互式编码助手（类主流编码 agent 终端 REPL）。
3. **MVP 范围**：v0.1.0 仅项目骨架 + README，不含 agent 逻辑。
4. **许可**：Apache-2.0（含专利授权，区别于 PAR 的 MIT）。
5. **仓库名**：`jcz2020/par-code`（公开）。

**影响范围**：整个仓库（dune 工程、bin/、lib/、test/、文档、CI）。

**回退方式**：删除仓库 / `git reset --hard`（初始 commit 前）。

**已知限制**：
- PAR 尚未发布到公开 opam 仓库，需 `opam pin add par https://github.com/jcz2020/par.git`。
- GitHub Actions（`.github/workflows/ci.yml`）已推送（gh token 已补 `workflow` scope）。

## [2026-07-02] Architecture: scheme-C bootstrap layer

**变更前**：par-code 依赖 PAR 的 `par_cli` 可执行包提供 bootstrap 能力
（配置解析、CLI 参数、启动流程）。

**变更后**：par-code 在 `lib/` 中实现自己的内部 bootstrap 层（Par_code_setup,
Par_code_config, Par_code_repl），不依赖 `par_cli`。

**原因**：`par_cli` 是可执行包（executable package），OCaml 的 dune 构建系统
不允许库链接可执行包。要使用 `par_cli` 的 bootstrap 能力，必须 fork 或重写，
而非直接依赖。因此选择自建轻量 bootstrap 层，通过 PAR SDK 的库接口（而非 CLI
接口）驱动 agent 循环。

**影响范围**：
- `lib/`：新增 Par_code_setup、Par_code_config、Par_code_repl 三个模块。
- `bin/`：仅负责命令行参数解析和调用 lib/ 层。
- 构建：`par_code` 库不再尝试链接 `par_cli`。
- 用户体验：配置路径 `~/.par/config.json`。

**回退方式**：若 PAR 未来暴露 bootstrap 库（library），可将三个模块迁移至
该库的 wrapper，现有 API 不受影响。

**已知限制**：
- 与 PAR 的 CLI flag 定义存在重复维护成本（PAR 升级 CLI 时需同步检查）。
- 配置路径与 PAR 分离，用户需分别管理两套配置。

## Roadmap（2026-07-02 经源码核查后确认）

> 先对 PAR 与对齐目标做了双侧源码逐条核查（PAR 9 大能力全部真实；目标 9 个招牌
> 特性全部实打实实现、非 stub；PAR 在记忆/上下文整块为零覆盖）。据此重定路线图。

每版交付**一个**用户可感知的核心功能（垂直薄片，做完即可演示）；版本号最小递增，
核心能力对齐前不升 1.0。

- **v0.1.0** ✅ 项目骨架（链接 PAR SDK，`par --version` 可用）。
- **v0.2.0** 能用：交互编码 agent（REPL + provider 配置 + read/write/edit/grep/find/bash + 流式 + 会话持久）。
- **v0.3.0** 记得住：项目记忆（MEMORY.md + FTS5 全文检索 + memory/history 工具）。
- **v0.4.0** 长程不断线：checkpoint-writer 子 agent + 预算式上下文注入 + 上下文重建（最硬一役，PAR 零覆盖块）。
- **v0.5.0** 先想后做：plan 模式（只读）+ build/plan 切换 + plan_enter/plan_exit。
- **v0.6.0** 会分身：general/explore 子 agent + actor 工具 + 任务树。
- **v0.7.0** 干到底：/goal + 独立 judge 模型 + doom_loop 检测。
- **v0.8.0** 择优：max-mode（N 路并行候选 + judge 选取）。
- **v0.9.0** 会自学：/dream + /distill + 自定义 slash 命令系统。
- **v0.10.0** 全流程编排：compose 模式 + 内置 plan/execute/review/tdd/debug/verify/merge skill。
- **v0.11.0** 连万物：MCP OAuth + 热重载 + 多源 skill（远程 URL/.claude/.agents 等）。
- **v0.12.0** 懂代码：LSP 集成（诊断/跳定义/引用/调用层级）+ lsp 工具。
- **v0.13.0** 安全可控：权限规则集（allow/ask/deny + 持久批准）+ 文件快照/undo。
- **v0.14.0** 好用好看：富 TUI（流式渲染 + 内联权限提示 + i18n）。
- **v1.0.0** 核心能力对齐里程碑（v0.2–v0.14 齐备 + 稳定化）。
- **1.x** 扩展轨（按需）：语音输入/控制、插件系统、codesearch、notebook_edit、apply_patch、LSP rename。

**排序原则**：先能用再出彩（0.2 地基）；招牌优先且难度爬坡（0.3–0.4 直接上记忆/长程
零覆盖块；0.5–0.8 自主性爬坡；0.9–0.10 自进化+编排）；安全/UX 收口（0.13–0.14 兜底 1.0）。

## [2026-07-02] 路线插入 v0.2.1：一键安装 + 自更新

> ⚠️ **范围已修订** — 本条的签名策略、Windows 处理、target 数量已被下一条
> `[2026-07-02] v0.2.1 范围修订` 更新（v0.2.1 改为 Linux+macOS only，Windows
> 整体推 v0.2.2，bundle C 库，CentOS 7 build base）。以下原文保留作历史审计；
> **实施时以下一条为准**。

**变更前**：v0.2.0 之后直接进 v0.3.0（项目记忆）。用户安装 par-code 必须先装
OCaml + opam，再 `opam pin add par`（源码编译 PAR SDK），再装 par-code。这是当前
最大的上手门槛。

**变更后**：在 v0.2.0 ✅ 与 v0.3.0 之间插入 **v0.2.1**——一键安装与自更新版本。
三大支柱：

1. **预编译二进制分发**（GitHub Releases，覆盖 linux-x64 / linux-x64-musl /
   darwin-arm64 / darwin-x64 / windows-x64 五个 target）。用户**无需**安装
   OCaml/opam/PAR 源码。opam 源码 pin 路径降级为"开发者路径"，仍保留。
2. **一键安装脚本**：`scripts/install.sh`（POSIX sh，Linux+macOS）和
   `scripts/install.ps1`（PowerShell 5.1+，Windows）。检测平台 → 下载对应包 →
   SHA256 校验 → 解压到 `~/.par/bin/` → 提示 PATH。
3. **内置 `par upgrade` 子命令**：自更新，不依赖系统包管理器。`--check` /
   `--to <ver>` / `--uninstall`。启动时后台版本检查（24h 缓存 + ETag，
   `PAR_NO_UPDATE_CHECK=1` 可关）。

**原因**：
- 当前安装链路（装 OCaml → 装 opam → pin PAR 源码 → 装 par-code）是用户上手最大
  阻力。业界公开参考实现（同类编码 agent CLI）**无一**强制用户装编译器工具链；
  全部走预编译二进制 + 安装脚本。par-code 必须对齐这一基线，否则 v0.3.0+ 的能力
  再强也没有用户量基础。
- "以后哪怕迭代再多次也能用"——CI 在 tag 推送时自动产出三平台二进制 + 校验文件 +
  版本清单，零人工介入；`par upgrade` 让用户不依赖任何包管理器即可升级。
- 插入 v0.2.1（而非把它塞进 v0.3.0）的原因：v0.3.0（项目记忆）已经是一个完整
  能力，再叠加分发系统会让 v0.3.0 范围过大；分发是独立垂直薄片，值得独占一个版本。

**签名策略（R1/R2 标注）**：

| 平台 | v0.2.1 决策 | 性质 | R1/R2 标注 |
|---|---|---|---|
| macOS | **不签名** | 架构正确 | **R1 = 架构正确**：CLI 经 `curl\|bash` 装到 `~/.par/bin/`，不经过 Gatekeeper（Gatekeeper 只拦 `.app` bundle 和带 quarantine 属性的浏览器下载）。业界公开参考项目的 macOS CLI 同样不签名，理由相同。**不是妥协，是判断**。可能永远不签（除非未来出 Desktop GUI）。 |
| Windows | **v0.2.1 不签，v0.2.2 签** | 范围妥协 | **R1 = 范围妥协**：未签名 Windows 二进制会触发 Defender 误报和 SmartScreen 警告（参考项目 issue 已实证），是真实 UX 问题。v0.2.1 不签**仅因为**云代码签名服务账户审核需 1-3 个工作日，会阻塞 v0.2.1 发布节奏。**R2 退役条件**：v0.2.2 发布签名版 Windows 二进制时，README 的"SmartScreen 绕过指南"同步删除，未签名状态正式退役。 |
| Linux | N/A | — | 无签名概念。 |

**R3（一次做对 vs 分两步）评估**：理想态是 v0.2.1 直接签 Windows。分两步合法，因
满足 R3 分步条件中的 (b) 依赖未完成的上游（签名账户审核）+ (c) 需未知技术验证
（云签名服务集成）+ (d) 用户明确指示。第 1 步（v0.2.1）已为第 2 步铺路：README
明确警告 + 本决策记录 + 退役条件齐备。

**R4 自问**：抛开开发周期，只看用户长远体验，v0.2.1 不签 Windows 还成立吗？答：
不签是**短期阵痛**（用户读一段绕过指南），换来的是 v0.2.1 能立即发布 + Windows
原生构建 spike 也能在 v0.2.1 周期内验证。若强行等签名账户下来再发，会让 Linux/
macOS 用户也陪等。分两步是主动提议，不是被动妥协。

**影响范围**：
- 路线图：README 路线表插入 v0.2.1 行；v0.3.0 及之后所有版本号顺延（实质上不变，
  仅 v0.2.x 段多一个版本）。
- 新增目录：`scripts/`（install.sh / install.ps1）。
- 新增 CI：`.github/workflows/release.yml`；`.github/workflows/ci.yml` 矩阵加
  `windows-2022`。
- 新增 lib 模块：`lib/par_code_upgrade.ml` + `.mli`。
- 改动：`bin/cli_args.ml` + `bin/main.ml`（加 `par upgrade` 子命令）。
- 文档：README 安装章节重写；CHANGES.md 在发布时加 v0.2.1-dev 段。
- 不影响：v0.2.0 现有功能（REPL/config/ask/persistence）冻结不动；`par_code.opam`
  作为开发者路径保留。

**回退方式**：
- 整个 v0.2.1 范围可逆：删除 `scripts/`、`release.yml`、`par_code_upgrade.ml`，
  还原 README/DECISIONS/CHANGES，路线表回到 v0.2.0 → v0.3.0 直连。
- Windows 原生构建若 spike 失败：Windows 在 v0.2.1 降级为 WSL 安装路径（install.ps1
  检测/安装 WSL 后跑 Linux 二进制），原生 Windows 推到 v0.2.2。spike 结果记录在
  本文件追加段落。

**已知限制**：
- **Windows 原生构建未验证**：OCaml + `eio` + `sqlite3` + `mirage-crypto-rng` 在
  `windows-2022` runner 上能否干净编译是 v0.2.1 启动时的第一个 spike 任务。
- **二进制大小未知**：静态/动态链接 PAR + sqlite3 + crypto 后的体积待首次 release
  实测。若 >50MB，v0.2.2 立项瘦身任务。
- **未签名 Windows 体验差**：v0.2.1 用户首次运行会看到 SmartScreen 警告，README
  需明确指引绕过（"More info" → "Run anyway"）。
- **arm64 Linux / arm64 Windows / baseline 变体不在 v0.2.1**：v0.2.1 只覆盖 4 个
  高流量 target（含 musl），arm 系列推到 v0.2.3+。
- **GitHub API 速率限制**：匿名 60 次/小时。`par upgrade --check` 必须用 ETag 条件
  请求（304 不计数）+ 24h 本地缓存。
- **首页安装 URL 待定**：install 脚本的 canonical URL（是 github.io / 自定义域 /
  GitHub Releases raw）在 v0.2.1 实施期决定。

**详细实施计划**：`.sisyphus/plans/v0.2.1.md`。

## [2026-07-02] v0.2.1 范围修订：Linux + macOS only，Windows 整体推 v0.2.2

**变更前**：v0.2.1 立项范围是"Linux + macOS + Windows 三平台一键安装 + 自更新"。Windows v0.2.1
不签名、签名推 v0.2.2；macOS 不签名（架构正确）；分发产物 5 个 target（linux-x64 / linux-x64-musl /
darwin-arm64 / darwin-x64 / windows-x64）。原 plan 在 `.sisyphus/plans/v0.2.1.md`（commit
`acbc469`）。

**变更后**：基于两份独立评审（plan 严苛性评审 + 架构评审）发现 4 个 BLOCKER 级工程根因，**v0.2.1
范围收缩**：

1. **平台收缩**：v0.2.1 只发 **Linux (x86_64, glibc ≥ 2.17) + macOS (arm64)** 两个 target。
   Windows（含签名）整体推到 **v0.2.2**。darwin-x64（Intel Mac）由"arm64 binary 走 Rosetta"覆盖；
   native x64 推到 v0.2.2 决策（universal lipo vs 永久 Rosetta-only）。linux-x64-musl 推到 v0.2.3
   且要求 musl-**static**（动态 musl 只在 Alpine 能跑，几乎零价值，已从范围移除）。

2. **C 库打包**（新增 IN）：v0.2.1 **bundle** `libsqlite3.so.0` + `libgmp.so.10`（Linux）/对应
   `.dylib`（macOS）到 tarball/zip，与 `par` 同目录，RPATH 设 `$ORIGIN`（Linux）/
   `@loader_path`（macOS）。**这一步同时是 v0.3.0 FTS5 的硬前置**（FTS5 是 sqlite3 编译期扩展；
   若 v0.2.1 走 system sqlite，v0.3.0 必须强制用户换 FTS5-enabled libsqlite3——跨发行版不可行）。
   典型"一次做对"原则（R3）应用：现在 bundle = v0.3.0 只重编 bundled sqlite，不是分发革命。

3. **Linux 构建 base 改为 CentOS 7**（glibc 2.17，manylinux 标准）：用 `container: centos:7`
   在 GitHub Actions 里跑。Ubuntu 22.04（glibc 2.35）构建的产物在 Ubuntu 20.04 / Debian 11 /
   RHEL 8 上跑不起来——评审指出原 plan 的 verification #1 只测 ubuntu:22.04 = 自测自。

4. **`par upgrade` 加 post-swap smoke test + rollback**：原 plan 直接 atomic replace，新版本
   启动 crash 无回滚。修订后：replace 后 fork 子进程跑 `par --version`（3s 超时），exit≠0 则
   reverse-swap 回 `.old` 并报错。代价 ~20 行代码，救命的鲁棒性。

5. **新增 `lib/par_code_version.ml` 生成模块**：解决"`par upgrade --check` 怎么知道当前版本"
   的实现空白。dune 规则从 `dune-project` 的 `(version)` 字段生成 `let version = "..."`。

6. **完整性模型显式化**：v0.2.1 完整性 = HTTPS + checksum（**仅防传输损坏，不防 MITM**）。
   真正的对抗完整性（签名）随 v0.2.2 Windows 一起。README + 本文件明确措辞，避免用户误以为
   checksum 是安全保证。

7. **CI cache 策略明确**：三层 cache（`setup-ocaml` 内置 + dune `_build` + PAR source pin）
   把首次 release 从 ~30min 压到 ≤15min。

8. **启动版本检查是"purely additive"**：与 v0.2.0 "frozen" Non-Goal 修订——加一条 stderr 行、
   不阻塞、`PAR_NO_UPDATE_CHECK=1` 可关。v0.2.0 REPL/config/ask 行为不变。

**原因**（评审关键发现摘要）：
- **Windows 承诺与 fallback 矛盾**：原 plan 的 "Windows spike 失败 → WSL fallback" 是伪清晰——
  WSL 不是 Windows-native（装机率 <5%），等于 silently 砍 Windows 但 README 还写"Works on
  Windows"。诚实做法是显式声明 "v0.2.1 = Linux+macOS only"，Windows 整体推 v0.2.2。
- **Linux glibc 兼容性是 silent breakage**：ubuntu-22.04 build 在企业主流发行版（Ubuntu 20.04
  LTS、Debian 11、RHEL 8）上启动失败。必须用 CentOS 7（glibc 2.17）做 build base 才能覆盖
  "几乎所有 Linux"。
- **C 库不 bundle = 二进制跑不起来**：`libsqlite3.so.0` + `libgmp.so.10` 在 minimal 容器 / 企业
  Server 上不存在。bundle 是 standard practice（Haskell Stack / Rust sqlite3 crate / esy-packed
  都这么做）。
- **darwin-x64 构建机制未定**：GitHub 已退役 Intel runner（`macos-13` 退出倒计时），`macos-15`
  是 M1。产 x64 native 需双 build + lipo，复杂度不值得（Intel Mac 已 EOL，Rosetta 兼容 arm64）。
- **musl-dynamic 几乎零价值**：原 plan 的 musl tarball 描述为"动态链接 musl"——只在 Alpine 能
  跑，而 Alpine 用户 `apk add` 装依赖本就能用 glibc 版。真 musl 价值在 static linking，推到 v0.2.3。

**R3（一次做对 vs 分两步）评估**：
- Windows：理想态是 v0.2.1 直接三平台。分两步合法（R3 b/c/d 全满足：Windows 原生构建未验证、
  签名基础设施账户审核延迟、用户明确指示）。第 1 步（v0.2.1 Linux+macOS）已为第 2 步（v0.2.2
  Windows）铺路：release.yml 预留 Windows job slot、CI Docker 化方便后续加 Windows 容器、bundle
  策略对 Windows DLL 同样适用。
- darwin-x64：分两步合法（Rosetta 是合理桥接，非"以后再说"）。
- sqlite3 bundle：**不分两步**——R3 直接一次做对。v0.3.0 FTS5 是真实 landmine。
- musl-static：分两步合法（v0.2.3 独立任务，v0.2.1 不阻塞）。

**R4 自问**：抛开周期，只看用户长远体验，v0.2.1 砍 Windows 还成立吗？答：成立。Windows 半
承诺（unsigned + Defender 误报 + SmartScreen 拦截）比"v0.2.1 不发 Windows，README 明确说 v0.2.2
带签名一起"用户体验更差。砍掉换诚实，且把签名基础设施 + Windows 原生构建验证（spike）放
到 v0.2.2 周期里专心做。

**影响范围**：
- README 路线表：v0.2.1 描述改为"Linux + macOS"；新增 v0.2.2 行（Windows native + 签名 +
  darwin-x64）。
- `.sisyphus/plans/v0.2.1.md`：整体重写（279 行 → ~350 行）。新增：bundle C 库、CentOS 7
  Docker build、post-swap smoke test、Version.ml 生成、4-wave dependency graph（移除原 spike
  节点）、可执行 verification 21 条（含 disclosure grep 命令 + e2e upgrade 脚本 spec）、
  CI cache 策略。
- 不影响：v0.2.0 现有功能冻结不变（除 purely additive 启动 hook）。
- v0.2.2 范围扩大：原仅"Windows 签名"，现 + "Windows 原生二进制 + install.ps1 + darwin-x64"。
  v0.2.2 立项时第一动作仍是"Windows 原生构建 spike"。

**回退方式**：
- 本决策本身可逆：还原 README v0.2.1 行 + 删除本 DECISIONS 段，回到 commit `acbc469` 状态。
- v0.2.1 实施过程中若 CentOS 7 上 OCaml 5.2 编译失败（gcc 4.8 太老）：fallback 到 Debian
  `bullseye`（glibc 2.31，gcc 10）。在 Wave 1 决策，记录在本文件追加段。

**已知限制**：
- **Intel Mac 用户**：v0.2.1 不发 native x64 二进制，靠 Rosetta 跑 arm64。性能损失 ~20-40%，
  对 CLI 可接受。native x64 在 v0.2.2 决策。
- **Alpine Linux 用户**：v0.2.1 不支持（glibc-only）。v0.2.3 跟随 musl-static 一起。
- **Windows 用户**：v0.2.1 不支持。v0.2.2 跟随签名一起（unsigned Windows 用户体验灾难，
  必须签）。
- **v0.2.1 完整性仅 HTTPS**：checksum 防传输损坏，不防 MITM。企业 / 高安全场景等 v0.2.2
  签名。
- **CentOS 7 OCaml 5.2 编译未验证**：gcc 4.8.5 可能太老。Wave 1 第一动作验证，失败则 fallback
  Debian bullseye。
- **bundle 后二进制 + 库体积**：估计 15-25MB。可接受，瘦身是后续可选项。

**评审证据**：
- Plan 严苛性评审（Momus）：11 BLOCKER + 12 FLAG + 15 NIT，总评 CONDITIONAL PASS。
- 架构评审（Oracle）：4 BLOCKER（glibc 兼容、darwin-x64 runner、C 库打包、Windows spike 语义）
  + 9 实现级 RISK + 4 可持续性 RISK，总评"不进实施，否则回炉"。
- 本修订解决全部 4 个架构 BLOCKER + 全部 plan BLOCKER 的根因。

**详细实施计划**：`.sisyphus/plans/v0.2.1.md`（已重写，反映本范围修订）。

## [2026-07-03] Linux bundle base: CentOS 7 + devtoolset-11

**变更前**：v0.2.1 计划假设 `centos:7` Docker base + 系统 gcc 4.8.5 即可编译 OCaml 5.x，glibc 2.17 baseline。

**变更后**：发现 OCaml 5.x 的 configure.ac 硬性拒绝 gcc < 4.9（exit code 69），原因：OCaml 5.x 运行时依赖 C11 `_Atomic` 与 `<stdatomic.h>`，gcc 4.8 不支持 C11。解决方案：在 `centos:7` 上安装 Software Collections（SCL）的 `devtoolset-11-gcc` + `devtoolset-11-gcc-c++`，构建命令用 `scl enable devtoolset-11 bash -c '...'` 包装获得 gcc 11。**glibc baseline 不变**（仍为 2.17，由 base image 决定），仅升级编译器。

**原因**：
- OCaml 5.x configure step 在 gcc 4.8.x 上直接 fail，不可绕过。
- CentOS 7 的 gcc 4.8.5 是系统默认，无法通过简单 yum upgrade 升级。
- SCL（Software Collections）是 Red Hat 官方支持的并行工具链方案，与 manylinux2014 wheel 构建使用的方法相同。
- 替代方案比较：(A) `debian:bullseye`（glibc 2.31，丢失 CentOS 7/Debian 10/Ubuntu 18.04 用户）;(C) `almalinux:8`（glibc 2.28，丢失 CentOS 7 用户）。Option B 是唯一保留原 plan "覆盖几乎所有 Linux" 承诺的方案。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`：base image 不变（仍 `FROM centos:7`），增加 EPEL + SCL 安装步骤，所有 build 命令在 `scl enable devtoolset-11` 子 shell 内执行。
- `release.yml`（待 Wave 3 编写）：build-linux job 引用此 Dockerfile，无需特殊改动。
- README（待 Wave 4 编写）：Linux 系统需求仍为 glibc ≥ 2.17，不变。
- `docs/STRATEGY.md` §Release Strategy：Linux baseline 仍为 glibc 2.17，不变。

**回退方式**：
- 若 SCL 在某些 CentOS 7 衍生镜像（Oracle Linux 7、Amazon Linux 2）上不可用：fallback 到 Option A `debian:bullseye`，README 改写 Linux 需求为 glibc ≥ 2.31，损失约 5-10% Linux 用户（CentOS 7/Debian 10/Ubuntu 18.04）。
- 若 devtoolset-11 不稳定：降级到 devtoolset-9（gcc 9，仍满足 C11 要求）。

**已知限制**：
- CentOS 7 已于 2024-06-30 EOL，`yum` 默认 repo 失效，需 sed 改道 `vault.centos.org`。
- `bubblewrap`（opam 沙箱依赖）在 CentOS 7 + Docker 组合下不稳，故构建用 `opam init --disable-sandboxing` 绕过。
- SCL 安装会增加 Docker 构建时间约 1-2 分钟（首次），通过 CI cache 缓解。
- 此方案仅解决"编译"问题；运行时不需要 SCL（最终用户的机器无需安装 devtoolset）。

## [2026-07-03] par_code_upgrade.ml HTTP client: Cohttp_eio.Client.call (GET via Par.Http_client TLS)

**变更前**：v0.2.1 plan §Pillar 3 设想 `par_code_upgrade.ml` 使用 `Par.Http_client.do_request` 发 HTTP 请求。

**变更后**：发现 `Par.Http_client.do_request` **硬编码 POST method**（http_client.ml:317，POST 是 `Cohttp_eio.Client.call` 的固定参数）。GET 请求（GitHub Releases API 的 `/releases/latest`、二进制资产下载）需要直接使用 `Cohttp_eio.Client.call ~sw ~headers client \`GET uri`。TLS 配置仍复用 PAR 的 `Par.Http_client.tls_config`（lazy_t）与 `tls_host_of_string`；构造 cohttp-eio client 时传入本地 `tls_wrapper` 复用 PAR 的 TLS 上下文。

**原因**：
- `Par.Http_client.do_request` 的签名 + 实现都是 POST-only，GET 路径不可达。
- 改 PAR SDK 暴露 GET 是 PAR 上游的决策（v0.6.6+ 候选项），par-code 不应为此阻塞。
- `cohttp-eio` 是 PAR 的既有 transitive 依赖（PAR 的 http_client.ml 已经使用），par-code 链接 par 时已经间接拉入 cohttp-eio 的代码；显式声明它为 par-code 的 direct 依赖只是把"既成事实"写进 manifest。

**影响范围**：
- `lib/dune`：`libraries` 字段增加 `cohttp-eio`、`tls-eio`、`digestif`（digestif 用于 SHA256 校验，与 HTTP 无关但同期加入）。
- `dune-project` 的 `(package ... (depends ...))`：必须增加 `cohttp-eio`、`tls-eio`、`digestif`（W4-T4 配套修改），以保持 `par_code.opam` 元数据完整。
- `lib/par_code_upgrade.ml`：`tls_wrapper` + `make_client` + `http_get` 三个本地 helper 直接使用 `Cohttp_eio.Client.call` + `Par.Http_client.tls_config`。
- 用户安装路径：`opam install par-code` 会显式安装这三个包（之前作为 par 的 transitive deps 也会安装，差异仅在 manifest 元数据）。
- 退役条件：当 PAR SDK v0.6.6+ 暴露 GET-able HTTP 接口时，把 `par_code_upgrade.ml` 改回使用 `Par.Http_client.do_request`，并把 `cohttp-eio`、`tls-eio` 从 par-code 的 direct deps 移除（恢复为 transitive）。

**回退方式**：
- 完全可逆：删除 `lib/dune` 中的 3 个 libraries 条目，删除 `dune-project` depends 中的对应条目，删除 `par_code_upgrade.ml` 中的 `tls_wrapper`/`make_client`/`http_get` helper。回到没有 upgrade 模块的状态。

**已知限制**：
- 显式 direct dep 会触发 opam solver 在 par-code 单独安装时（无 par）尝试拉 cohttp-eio，但 cohttp-eio 在 opam repo 一直存在，不会引入安装失败。
- 如果 PAR SDK 未来 rename 或 restructure 其 Http_client 模块，par-code 的 `tls_wrapper` 需要同步调整。这是 par-code 与 PAR 的既有耦合（不是新引入的）。

## [2026-07-03] Bundle libsqlite3 + libgmp next to `par` binary (R3 "do it right once")

**变更前**：v0.2.0 阶段，par-code 假设用户机器上有 `libsqlite3.so.0` 和 `libgmp.so.10`（通过 opam 系统依赖声明）。

**变更后**：v0.2.1 预编译二进制分发将 `libsqlite3.so.0`（Linux）/ `libsqlite3.0.dylib`（macOS）和 `libgmp.so.10` / `libgmp.10.dylib` 与 `par` 二进制放在同一目录，通过 RPATH `$ORIGIN`（Linux）/ `@loader_path`（macOS）让二进制优先找到 bundled 版本。

**原因**：
- 预编译二进制分发的基本要求是"用户机器什么都不用预装"。`libsqlite3` 和 `libgmp` 在 minimal 容器（Alpine、distroless）、企业 Server（RHEL 8 minimal）上均不存在；不 bundle = 二进制启动失败。
- **R3 "一次做对"原则的直接应用**：v0.3.0 计划引入 FTS5 全文检索，FTS5 是 sqlite3 的**编译期**扩展（`-DSQLITE_ENABLE_FTS5`）。如果 v0.2.1 用 system sqlite，v0.3.0 必须强制用户切换到 FTS5-enabled libsqlite3——这在跨发行版场景不可行。bundle 之后，v0.3.0 只是重编 bundled sqlite3，不是分发革命。
- 同类项（`libgmp`）：mirage-crypto-rng 间接依赖 libgmp，同理需要 bundle。
- 业界同类预编译 CLI 项目均采用 bundle 策略，已是标准做法。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`（W2-T2）：构建后将 `libsqlite3.so.0` + `libgmp.so.10` 复制到 `/out/`，`patchelf --set-rpath '$ORIGIN'` 设置 RPATH。
- `scripts/build-macos.sh`（W2-T3）：构建后将 `libsqlite3.0.dylib` + `libgmp.10.dylib` 复制到 staging 目录，`install_name_tool -add_rpath @loader_path par` + `-id @rpath/<name>` + `-change <abspath> @rpath/<name>`。
- `scripts/install.sh`（W1-T1）：解压 tarball/zip 到 `$PREFIX/bin/`，二进制与 dylib 同目录；RPATH/$ORIGIN 让运行时自动找到 bundled libs。
- 二进制大小：约 15-25 MB（含 libs）。可接受，瘦身是后续可选项。
- 退役条件：永远不会退役（bundle 是终态）。如未来切换到 static linking（musl），bundle .so 阶段会被 static .a 替代。

**回退方式**：
- Linux：删除 Dockerfile 中 `cp /usr/lib64/libsqlite3.so.0 /out/` 和 `cp /usr/lib64/libgmp.so.10 /out/` 两行 + `patchelf --set-rpath` 行。回到 system-lib 链接（但二进制将在 minimal 容器上启动失败）。
- macOS：删除 build-macos.sh 中的 `install_name_tool` 调用。

**已知限制**：
- bundle 的 .so 是 CentOS 7 构建的版本（glibc 2.17 baseline）。若用户机器 glibc < 2.17 仍会失败——但 glibc < 2.17 的 Linux 已绝迹。
- bundled sqlite3 不带 FTS5（v0.2.1 暂不需要）。v0.3.0 重编时切到 FTS5-enabled sqlite3 amalgamation 源码。
- macOS 上 `install_name_tool` 操作要求二进制未签名——v0.2.1 不签名（架构正确），符合。

## [2026-07-03] v0.2.1 integrity model: HTTPS + SHA256 checksum (transport corruption only)

**变更前**：v0.2.0 没有二进制分发，integrity 由 opam 系统保证（opam 本身有签名链路）。

**变更后**：v0.2.1 预编译二进制通过 GitHub Releases 分发，integrity = HTTPS + GitHub 基础设施 + SHA256 checksum 文件。**显式声明：仅防传输损坏，不防对抗性 MITM**。checksums.txt 与二进制一同发布在 release 中——一个能替换二进制的 MITM 也能替换 checksums.txt。

**原因**：
- HTTPS + GitHub 基础设施已覆盖绝大多数真实威胁模型（用户 ISP 注入广告、CDN cache poisoning、传输 bit rot）。
- SHA256 checksum 检测传输损坏（bit flip、truncated download）。
- 真正的对抗性 integrity（cosign/sigstore 签名 checksums、Authenticode 签名 Windows 二进制）需代码签名基础设施，与 v0.2.2 Windows 签名一并上线。
- 提前半步（仅签名 checksums.txt 但不签名二进制）的边际价值低——攻击者替换二进制 + 替换 checksums.txt 是单一动作。

**影响范围**：
- `scripts/install.sh`（W1-T1）：`verify_sha256` 函数下载 `<asset>.sha256` 与二进制一同校验。注释明确说明 "transport corruption detection only, NOT adversarial integrity"。
- `lib/par_code_upgrade.ml`（W1-T3）：`perform_upgrade` 调用 `verify_sha256 ~expected:hash archive` 校验下载内容。
- `README.md`（W4-T1）：install 章节明确措辞 "v0.2.1 integrity = HTTPS + transport-corruption check; adversarial integrity (signed checksums) lands in v0.2.2 with signing"。
- 退役条件：v0.2.2 上线签名 checksums.txt + Authenticode 签名 Windows 二进制时，本条目退役（措辞更新为"已签名"）。

**回退方式**：
- 移除 `verify_sha256` 调用 → 回到无校验（不可取，仅作回退路径描述）。
- 增加签名验证（cosign verify）——这是 v0.2.2 的工作，不在 v0.2.1 范围。

**已知限制**：
- 企业 / 高安全场景用户应等 v0.2.2 签名版本，或在 v0.2.1 自行 GPG-verify 下载内容。
- checksums.txt 与二进制同 release——MITM 攻击者可同时替换。GitHub Releases 的 HTTPS 是唯一防线。
- 没有 key rotation 机制——签名基础设施落地时（v0.2.2）再设计。

## [2026-07-03] Linux bundle base 从 CentOS 7 + devtoolset-11 切换到 AlmaLinux 8

> ⚠️ **取代上一条** `[2026-07-03] Linux bundle base: CentOS 7 + devtoolset-11`。以下为实际发布采用的决策。

**变更前**：v0.2.1 计划使用 `centos:7` + SCL `devtoolset-11`（gcc 11 via Software Collections），glibc 2.17 baseline。

**变更后**：改用 `almalinux:8`（stock gcc 8.5，glibc 2.28 baseline）。不再需要 SCL / devtoolset。

**原因**：
- CentOS 7 于 2024-06-30 EOL，`mirrorlist.centos.org` DNS 已下线。
- `vault.centos.org` 的 SCL 仓库路径不稳定——在 5 轮 CI 迭代中均无法可靠拉取 devtoolset-11。
- AlmaLinux 8 是 CentOS 8 的社区后继，stock gcc 8.5 已满足 OCaml 5.x 的 C11 atomics 要求（gcc ≥ 4.9），无需 SCL。
- glibc 从 2.17 升到 2.28：失去 CentOS 7 / Debian 10 / Ubuntu 18.04 用户（均已 EOL）。

**影响范围**：
- `scripts/docker/linux-bundle.Dockerfile`：`FROM almalinux:8`，`dnf install gcc`（不再需要 `scl enable devtoolset-11`）。
- README / CHANGES.md：Linux 需求从 glibc ≥ 2.17 改为 glibc ≥ 2.28。
- `release.yml`：step name 从 "CentOS 7" 改为 "AlmaLinux 8"。

**回退方式**：还原 Dockerfile 为 `FROM centos:7` + SCL 方案（但 CentOS 7 vault 不稳定，不推荐）。

**已知限制**：
- CentOS 7 / Debian 10 / Ubuntu 18.04 用户无法使用预编译二进制（均已 EOL）。
- 如未来需要覆盖 glibc < 2.28 的发行版，需引入 musl-static 构建（v0.2.3 计划）。



