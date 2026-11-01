# par-code 项目规则

> 项目级规则 + 项目地图。优先级高于全局 `~/.config/opencode/AGENTS.md`。
> 新会话读完此文件即可干活。

---

## 0. 项目地图

### 这是什么

par-code 是一个基于 PAR SDK 的 OCaml 终端编码 agent。用户通过 `par` 命令启动 REPL，agent 能读写编辑代码、跑 bash、跨会话记忆项目知识。同时是 PAR SDK 的验证项目——每个功能都反哺 PAR 的能力缺口。

### 当前状态

- **版本**：v0.7.4（见 `dune-project`）
- **PAR SDK 依赖**：0.12.0-beta+（CI/release/打包脚本/源码安装器 5 处统一钉 `github.com/jcz2020/par.git` 的 **v0.12.0-beta.20261023 tag**，不钉分支 tip；本机 switch 同样钉该 tag）
- **opam switch**：`/root/dev/PAR`（OCaml 5.4.1）
- **已发布**：v0.2.1（安装器）、v0.3.0（项目记忆）、v0.3.1（自动提取）、v0.3.2（arm64）、v0.3.3（PAR SDK 0.7.3 + 混合搜索）、v0.4.0（长会话连续性）、v0.4.1（异步 checkpoint）、v0.4.2（多轮上下文 critical fix）、v0.4.3（UX quick patch：/cost + config show + memory fix）、v0.4.5（UI 抽象层 + streaming markdown）、v0.5.0（Plan Mode：只读 planner + 模式切换 + plan 持久化）、v0.5.1（Plan CLI + Git Tools：par plan list/show/prune + git_status/git_log）、v0.5.2（streaming fallback fix）、v0.5.3（REPL rendering fixes：tool 去重 + /dev/tty + 诊断）、v0.5.4（Session management：par session list/show/fork + partial ID resume + Ctrl+C 干净退出）、v0.5.5（hotfix：Plan Mode tool-filter 名称修正 + startup version-notice + REPL prompt flush + `<think>` tag 中间件 + session scope 写侧修正）、v0.5.6（审计 W2-3 + UX 打磨：par config set 全 20 字段 + install.sh source compile fallback + par memory prune --dry-run + memory prefix 解析 + /session 对齐 + legacy scope 迁移 + streaming `<think>` strip，PAR SDK 0.8.3）、v0.6.0（子 agent 委派：delegate 工具 + explore（只读）/ general（全能力）subagent）、v0.6.1（install/upgrade 修正：install.sh stale-binary 权限守护 + par upgrade source-fallback 对齐 + Filename.temp_file 清理）、v0.6.2（UTF-8 REPL 输入：linenoise bundled-C + CJK backspace 不再乱码 + Ctrl+C crash 修正）、v0.7.0（目标驱动自主性：/goal 命令 + 独立 judge 模型 + doom-loop 检测 + goal_done 工具 + --goal CLI flag，PAR SDK 0.8.6）、v0.7.1（planner 预算 + REPL exit-path hotfix：planner_max_iterations 配置 + early_stopping_method Generate + 统一 exit_normally ()）、v0.7.2（goal 可用性加固：三类 bash approval + planner synthesis fallback + doom-loop v2 + goal 生命周期管理 + no-progress / completion-claim 守护）、v0.7.3（自主 goal 链式执行：run_chain 驱动 + par --goal 自动启动链 + PAR SDK 0.10.0 mid-invoke 取消 + error-streak 守护 + goal_auto_chain 开关）、v0.7.4（provider 报错韧性：裁切后孤儿 tool result 清除 + provider 拒绝 payload dump + CI/release SDK tag 钉住使产物可复现）

### 架构概览

```
用户
 │
 ▼
bin/main.ml ── Cmdliner CLI 入口
 │  ├── par (默认) → par_code_repl.ml (REPL 循环)
 │  ├── par ask    → par_code_repl.ml (单次问答)
 │  ├── par config → par_code_config.ml (配置向导)
 │  ├── par upgrade→ par_code_upgrade.ml (自更新)
 │  ├── par memory → par_code_memory.ml (记忆管理 CLI)
 │  └── par plan   → par_code_plan_tools.ml (plan 文件管理 CLI)
 │
 ▼
lib/par_code_setup.ml ── Runtime 引导层
 │  ├── 创建 PAR Runtime (persistence + LLM + embeddings)
 │  ├── 注册 builtin tools + bash tool + memory tools + goal_done/delegate/plan_submit/write_plan_file 工具（内置工具随 SDK 版本增加，v0.7.5 起含 `apply_patch`；planner/explore 走白名单，拿不到写工具）
 │  ├── 注册 "par" agent + "memory-extractor" agent (提取) + "planner" agent (v0.5.0+, plan mode 用的只读 agent) + "judge" agent (v0.7.0+, 独立 judge 模型) + "plan-synthesizer" agent (v0.7.2+, planner fallback) + "explore" agent (v0.6.0+, 只读 subagent) + "general" agent (v0.6.0+, 全能力 subagent)
 │  ├── 注册 checkpoint-writer agent (v0.4.0+, 通过 ~save:false ~update_current:false 在用户 Runtime 上跑)
 │  ├── 创建 checkpoint schema on mem_db (v0.4.0+)
 │  ├── 安装 bash 自动批准 hook (v0.4.0+); 加载 .par/approvals.json 批准模式 (v0.7.2+)
 │  ├── 安装 think_tag_strip 中间件（v0.5.5+，本地 23 行构造，PAR SDK 不通过 facade 重新导出；退役条件：切换到 Par.Think_tag_strip.create()）
 │  └── 传 mem_db 给 REPL（用于 per-turn 记忆索引注入）
 │
 ▼
PAR SDK (Runtime.invoke → ReAct loop → tool dispatch → LLM)
 │
 ▼
~/.par/par.db ── SQLite (WAL mode)
 ├── memory_entries + memory_entries_fts + memory_entries_vec (PAR SDK Sqlite_memory 管控)
 ├── conversations (PAR 管控) → conversations_fts (par-code 加的 FTS5 索引)
 ├── events / task_states / workflow_states (PAR 管控)
 ├── checkpoints + checkpoints_fts (par-code v0.4.0+, 长会话连续性)
 └── (par-code v0.3.3: 存储 delegated to Sqlite_memory，schema 自动迁移)
```

### 文件索引

| 文件 | 职责 | 读它当你需要 |
|---|---|---|
| `lib/par_code_approvals.ml` | Bash 批准模式存储（.par/approvals.json）+ 工作区分类 (v0.7.2+) | 改 bash approval 逻辑、加新 approval 模式 |
| `lib/par_code_approvals.mli` | Approvals 公共 API (v0.7.2+) | 查 approvals 接口签名 |
| `lib/par_code_chain.ml` | 纯链式决策模块：should_continue、continuation_message、cancel_outcome 映射、sigint_action 阶梯、run_goal_evaluation IO 伴生 (v0.7.3+) | 改 goal chain 决策逻辑、停止条件 |
| `lib/par_code_chain.mli` | Chain 公共 API (v0.7.3+) | 查 chain 接口签名 |
| `lib/par_code_checkpoint.ml` | Checkpoint 存储 + 序列化 + 异步 dispatch (v0.4.0+) | 改 checkpoint 逻辑、加新 subagent |
| `lib/par_code_checkpoint.mli` | Checkpoint 公共 API (v0.4.0+) | 查 checkpoint 接口签名 |
| `lib/par_code_config.ml` | 配置类型 + JSON 序列化 + 向导（35 字段，含 atomic write） | 加配置项、改默认值 |
| `lib/par_code_config_wizard.ml` | 交互式配置向导（从 par_code_config.ml 拆出，800 行文件限制） | 改配置向导交互流程 |
| `lib/par_code_context.ml` | Token 估算 (chars/4) + 对话压缩 | 改 context budget 逻辑 |
| `lib/par_code_context.mli` | Context 压缩公共 API | 查 compact 接口 |
| `lib/par_code_delegate.ml` | delegate 工具绑定：explore（只读 subagent）/ general（全能力 subagent） (v0.6.0+) | 改 subagent 委派逻辑、加新 subagent 类型 |
| `lib/par_code_delegate.mli` | Delegate 公共 API (v0.6.0+) | 查 delegate 接口签名 |
| `lib/par_code_doom_loop.ml` | doom-loop 检测器 v2：identical-failing-bash streaks、near-identical edits (shingle Jaccard)、same-kind action streaks; Nudge→Force_judge→Abort 阶梯 + 事件记录 (v0.7.2+) | 改 doom-loop 检测逻辑、调整阈值 |
| `lib/par_code_doom_loop.mli` | Doom loop 公共 API (v0.7.2+) | 查 doom loop 接口签名 |
| `lib/par_code_extractor.ml` | 会话结束时自动提取记忆 | 改提取逻辑、prompt |
| `lib/par_code_git_tools.ml` | git_status/git_log read-only tool bindings for planner (v0.5.1+) | 改 git 工具、加新 git 相关工具 |
| `lib/par_code_git_tools.mli` | Git tools 公共 API (v0.5.1+) | 查 git 工具接口签名 |
| `lib/par_code_goal.ml` | 目标状态机：Active/Met/Aborted/Paused/Blocked + .par/goals/current.json 持久化 (v0.7.0+) | 改目标生命周期逻辑 |
| `lib/par_code_goal.mli` | Goal 公共 API (v0.7.0+) | 查 goal 接口签名 |
| `lib/par_code_goal_tools.ml` | goal_done agent 工具 (v0.7.0+) | 改 goal_done 工具逻辑 |
| `lib/par_code_goal_tools.mli` | Goal tools 公共 API (v0.7.0+) | 查 goal tools 接口签名 |
| `lib/par_code_judge.ml` | 独立 judge agent：verdict 解析 + evaluate_goal (v0.7.0+) | 改 judge 评估逻辑、prompt |
| `lib/par_code_judge.mli` | Judge 公共 API (v0.7.0+) | 查 judge 接口签名 |
| `lib/par_code_memory.ml` | 记忆层：Sqlite_memory 代理 + FTS5/vec0 搜索 + 迁移 + 索引渲染 | 改记忆 schema、加搜索功能 |
| `lib/par_code_memory.mli` | Memory 公共 API | 查 memory 接口签名 |
| `lib/par_code_memory_tools.ml` | 3 个 agent 工具 (recall/remember/search_history) | 加新工具给 LLM 用 |
| `lib/par_code_mode.ml` | Mode state (Plan/Build) + switch + agent_id_for + label (v0.5.0+) | 改 mode 逻辑、加新 mode |
| `lib/par_code_mode.mli` | Mode 公共 API (v0.5.0+) | 查 mode 接口签名 |
| `lib/par_code_plan_tools.ml` | plan_enter/plan_exit tool bindings + plan_submit/write_plan_file + persist_plan_file + list_plans/show_plan/prune_plans (v0.5.0+) | 改 plan 工具、加新 plan 相关工具 |
| `lib/par_code_plan_tools.mli` | Plan tools 公共 API (v0.5.1+) | 查 plan 工具接口签名 |
| `lib/par_code_progress.ml` | no_progress 检测 + completion-claim 启发式（EN+CN 关键词 + 否定处理）(v0.7.0+) | 改 progress 检测规则 |
| `lib/par_code_progress.mli` | Progress 公共 API (v0.7.0+) | 查 progress 接口签名 |
| `lib/par_code_repl.ml` | REPL 循环 + 单次问答 + /goal 命令 + run_chain 链驱动（Ui.render_* 渲染） | 改交互行为、加 slash 命令 |
| `lib/par_code_session.ml` | Session management：list/load/fork/resolve_id (v0.5.4+) | 改 session 逻辑、加新 session 相关功能 |
| `lib/par_code_session.mli` | Session management 公共 API (v0.5.4+) | 查 session 接口签名 |
| `lib/par_code_setup.ml` | Runtime 引导：创建 runtime、注册 tools/agents（含 judge/delegate/goal_done/plan_submit/write_plan_file）、think_tag_strip 中间件、bash 审批 hook、tool 描述覆盖 | 集成新功能到 runtime |
| `lib/par_code_ui.ml` | UI 抽象层：composable styled images + ANSI + render_* API (v0.4.5+) | 改渲染逻辑、加新的 render_* 函数 |
| `lib/par_code_ui.mli` | UI 公共 API (v0.4.5+) | 查 Ui 接口签名 |
| `lib/par_code_ui_markdown.ml` | Streaming markdown → ANSI 状态机 (v0.4.5+) | 改 markdown 渲染规则 |
| `lib/par_code_ui_markdown.mli` | Markdown SM 公共 API (v0.4.5+) | 查 markdown 接口签名 |
| `lib/par_code_upgrade.ml` | 自更新：下载、校验、原子替换 | 加平台支持、改升级逻辑 |
| `lib/par_code_upgrade.mli` | Upgrade 公共 API | 查 upgrade 接口 |
| `bin/cli_args.ml` | Cmdliner 参数定义（含 --goal） | 加 CLI 参数 |
| `bin/main.ml` | 命令分发 + 子命令组 | 加子命令 |
| `scripts/build-macos.sh` | macOS 构建脚本 | 同上 |
| `scripts/checksums.sh` | Release 校验和生成 | 改 release checksum 逻辑 |
| `scripts/docker/linux-bundle.Dockerfile` | Linux 构建容器 (AlmaLinux 8 + FTS5) | 改构建依赖、加编译选项 |
| `scripts/install.sh` | POSIX sh 一键安装器 | 加平台、改安装逻辑 |
| `scripts/sqlite-amalgamation.version` | sqlite3 版本锁 (单一整数) | 升级 sqlite3 |
| `docs/STRATEGY.md` | 战略快照：定位、用户、路线图姿态 | 理解"为什么" |
| `docs/DECISIONS.md` | 决策记录 (6 字段格式) | 理解"为什么做了 X" |
| `.github/workflows/release.yml` | Tag 触发的多平台发布流水线 | 改 CI、加平台 |
| `.github/workflows/ci.yml` | push/PR 触发的测试流水线 | 改 CI matrix |
| `.sisyphus/plans/v*.md` | 版本实现计划 (gitignored, 本地) | 理解架构决策的完整推理 |

### 关键约束速查

- PAR SDK 不可改（§1）
- 版本号不可自动 bump（§2）
- FTS5 必须从 amalgamation 编译（§3）
- 并行 agent 禁止 git 写操作（§4）
- 记忆索引通过 `?system_prompt_appendix` per-turn 注入（不再 bake 到注册时 system prompt）
- checkpoint / extraction 通过 `~save:false ~update_current:false` 在用户 Runtime 上跑（v0.4.1 消除 ckpt_rt，不再用独立 Runtime）
- 当对话超过 `context_budget_tokens` 时，老消息会被替换为最近的 checkpoint 摘要（v0.4.0+）
- 披露规则：committed 产物不得出现外部项目/公司名（见全局 AGENTS.md §2）
- PAR SDK 依赖 ≥ 0.10.0（mid-invoke 取消能力，doom-loop abort 用）
- linenoise ≥ 1.3 为 bundled-C 依赖（UTF-8 REPL 输入，v0.6.2+）
- think_tag_strip 中间件为本地 23 行构造（PAR SDK 通过 middleware hook 提供但不通过 facade 重新导出；退役条件：切换到 `Par.Think_tag_strip.create()` 当 PAR SDK 暴露该接口）
- bash_approval 三类模式：`ask`（每次确认）、`auto_project`（工作区内自动批准）、`always`（全部自动）；goal 活跃时 `ask` 自动升级为 `auto_project`；批准模式持久化到 `.par/approvals.json` (v0.7.2+)

---

## 1. PAR SDK 边界（硬约束）

**永远不可擅自更改 `/root/dev/PAR`（PAR SDK 项目）。** PAR 与 par-code 是同一所有者下的独立项目，par-code 依赖 PAR 但无权反向修改。

### 允许

- 在 par-code 仓库内（`/root/dev/PAR-CODE/`）任何工作
- **读取** PAR 源码用于理解依赖、API 表面、行为（read-only 探查）
- **向用户提 PAR 需求**：明确说明改哪个文件、加什么 API、为什么、紧迫性

### 禁止

- 编辑、创建、删除 `/root/dev/PAR/` 下任何文件
- 在 `/root/dev/PAR/` 里跑 `git commit` / `git push` / `git rebase` 等任何写操作
- 给 PAR 仓库提 PR（即使有 push 权限也不提，除非用户明确说"提 PR"）
- 把 PAR 的修改"顺手"夹在 par-code 的 commit 里

### 当 par-code 需要 PAR 改动时

1. 在 par-code 的 plan / DECISIONS 里记录需求（文件路径 + 改动内容 + 理由 + 紧迫性）
2. 在对话里向用户陈述需求
3. **等用户决定**：用户自己改 PAR，或授权我去改，或让我先绕开（在 par-code 侧 workaround）
4. 用户没回之前，par-code 这边按"PAR 当前状态"推进，不假设 PAR 会改

### 违反处理

如果误改了 PAR：
1. 立即 `git -C /root/dev/PAR status` 检查破坏面
2. `git -C /root/dev/PAR checkout -- .` 回滚（PAR 仓库干净时才有效）
3. 向用户报告：改了什么、为什么、已回滚
4. 等用户指示

---

## 2. Release 流程

### 版本号

- **不可自动 bump**：任何版本号变更（`dune-project` 里的 `(version "...")`）必须等用户明确说"发布"/"release"。
- 发布时同步改 `test/test_par_code.ml` 里的版本断言。
- `dune build` 会自动重新生成 `par_code.opam`——记得 commit 它。

### Tag 触发 CI

- 正式 release 用 tag `v[0-9]+.[0-9]+.[0-9]+`（无 pre-release 后缀）。
- push tag 触发 `.github/workflows/release.yml`：build-linux-x64 + build-linux-arm64 + build-macos → coordinate → GitHub Release。
- **CI 失败后重新发布**：fix → commit → push main → 删旧 tag → 建新 tag → push tag：
  ```sh
  git tag -d vX.Y.Z
  git tag -a vX.Y.Z -m "vX.Y.Z — ..."
  git push origin :refs/tags/vX.Y.Z
  git push origin vX.Y.Z
  ```

### 支持的平台

| 平台 | CI runner | 备注 |
|---|---|---|
| Linux x86_64 (glibc ≥ 2.28) | `ubuntu-latest` + AlmaLinux 8 Docker | glibc 2.28 基线 |
| Linux arm64 (aarch64) | `ubuntu-24.04-arm` + AlmaLinux 8 Docker | 原生 ARM runner，不交叉编译 |
| macOS arm64 | `macos-15` | Apple Silicon 原生 |

---

## 3. FTS5 硬约束

**bundled sqlite3 必须从 amalgamation 源码编译，带 `-DSQLITE_ENABLE_FTS5`。** OS 包自带的 sqlite3 不保证有 FTS5，不能用于 release binary。

- 版本锁定在 `scripts/sqlite-amalgamation.version`（单一整数，如 `3460000` = 3.46.0）
- Linux Dockerfile 和 macOS build script **共用同一个版本号**
- Dockerfile 里从 version 文件提取版本时，必须用 `grep -E '^[0-9]+'`（不能用 `cat | tr -d`——注释行会被拼进去）

---

## 4. 并行 agent 操作规则

多个 agent 并行修改同一个 git working tree 时：

- **禁止任何 agent 执行 git 写操作**（`git stash`、`git checkout -- .`、`git revert`、`git reset`、`git clean`）
- build 失败时只能修自己的代码，**不动其他文件**
- 如果需要隔离测试，用 `dune build` 在 `_build/` 里验证，不用 git 操作

违反后果：并行 agent 的 stash/checkout 会互相覆盖，丢失其他 agent 的工作（已在 v0.3.1 Wave 1 踩过）。

---

## 5.（预留 — 后续规则加在这里）
