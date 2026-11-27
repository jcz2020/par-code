# par-code 项目知识库

> 项目级规则 + 项目地图。优先级高于全局 agent 指令文件。本文件是全库索引；模块细节在各子目录 AGENTS.md，此处不重复。

**Generated:** 2026-11-27 · **Commit:** 8d9cfe9 · **Branch:** main

## OVERVIEW

par-code 是基于 PAR SDK 的 OCaml 终端编码 agent：`par` 启动 REPL，agent 能读写编辑代码、跑 bash、跨会话记忆项目知识；同时是 PAR SDK 的验证项目——每个功能反哺 PAR 的能力缺口。栈：OCaml 5.4 + dune + Cmdliner + Eio + PAR SDK（Runtime.invoke → ReAct）+ SQLite（WAL，FTS5 + vec0）。当前 `dune-project` 版本 0.15.8；发布史以 `CHANGES.md` 为权威。

## STRUCTURE

```
par-code/
├── bin/              # Cmdliner CLI：main.ml 739 行，36 flag → bin/AGENTS.md
├── lib/              # 42 .ml + 27 .mli，~17k LOC，flat 布局，Par_code_* 前缀 → lib/AGENTS.md
├── test/             # Alcotest 35 exe / 595 用例 → test/AGENTS.md
│   └── integration/  # 13 个 bash/tmux e2e 文件 + harness.sh → test/integration/AGENTS.md
├── scripts/          # install.sh / build-macos.sh / checksums.sh / docker/linux-bundle.Dockerfile
├── docs/             # DECISIONS.md（append-only 决策账本）+ STRATEGY.md（已过时）
├── spike/            # Notty 探针，仍在编译
├── examples/flows/   # flow JSON fixtures
├── .github/          # ci.yml（push/PR matrix）+ release.yml（stable tag 触发）
└── dune-project      # 版本号 + PAR 依赖；无根 dune 文件（配置在 dune-project + per-dir dune）
```

调用链：`bin/main.ml`（Cmdliner 分发）→ `lib/par_code_setup.ml`（建 Runtime、注册 tools/agents/中间件）→ PAR SDK ReAct loop → `~/.par/par.db`（SQLite WAL：memory_entries / conversations / checkpoints）。根文件另有 `Makefile`、`README.md`（用户文档）、`CHANGES.md`（发布记录）、`.editorconfig`。

## WHERE TO LOOK

| 任务 | 位置 | 备注 |
|---|---|---|
| lib 模块职责 / 接口 / lib 级约定 | `lib/AGENTS.md` | 模块地图、LOC、约定、反模式全在彼处 |
| CLI 子命令 / flag / 分发 | `bin/AGENTS.md` | 唯一 OCaml 入口；触 11 个 lib 模块，全库最宽耦合 |
| 单测约定 / 版本断言 | `test/AGENTS.md` | 单个 `test/dune` stanza，chdir 隔离；版本断言在 `test/test_par_code.ml:2` |
| e2e harness | `test/integration/AGENTS.md` | `run.sh`、`harness.sh` API、loopback fault server |
| 自定义 skill / 命令 | `lib/par_code_skills.ml` + `lib/par_code_distill.ml` | `/skills` + `/distill`；manual-only；细节在 `lib/AGENTS.md` |
| 安装 / 打包 / 平台 | `scripts/` | 无子 AGENTS.md（score 3）；平台与 FTS5 规则见本文件 |
| 查"为什么做了 X" | `docs/DECISIONS.md` | append-only，~140 条，6 字段格式 |
| CI / 发布流水线 | `.github/workflows/` | release.yml 只认 stable tag，actions 按 commit SHA 钉 |

## CODE MAP

| Symbol | 类型 | 位置 | 外部引用* | 角色 |
|---|---|---|---|---|
| `Par_code_ui` | module | `lib/par_code_ui.ml` | 483 | 渲染内核：抽象层 + 表格 / 成本 / 工具行 |
| `Par_code_memory` | module | `lib/par_code_memory.ml` | 153 | 记忆层（SQLite WAL + FTS5/vec0） |
| `Par_code_config` | module | `lib/par_code_config.ml` | 132 | 配置加载 / 合并（805 行） |
| `Par_code_mode` | module | `lib/par_code_mode.ml` | 124 | Plan/Build 模式状态 |
| `Par_code_ui_markdown` | module | `lib/par_code_ui_markdown.ml` | 120 | streaming markdown→ANSI 状态机；`has_pending` 供工具行前刷半行 |
| `Par_code_goal` | module | `lib/par_code_goal.ml` | 77 | 持久 goal 状态 |
| `Par_code_plan_tools` | module | `lib/par_code_plan_tools.ml` | 73 | plan 工具族 |
| `Par_code_screen` | module | `lib/par_code_screen.ml` | 63 | 全屏 TUI，2291 行，全库最大文件 |
| `Par_code_checkpoint` | module | `lib/par_code_checkpoint.ml` | 63 | 长会话连续性；手动 /checkpoint 不触发提取 |
| `Par_code_setup.setup_runtime` | val | `lib/par_code_setup.ml` | 每个子命令 | Runtime 引导，全库汇聚点 |
| `Par_code_repl.run` / `run_single_shot` | val | `lib/par_code_repl.ml` | 8（+~20 内部依赖） | REPL 循环 / `par ask`；1842 行的 hub |

\* 外部引用为 lib/bin/test 中 `Module.` 限定引用的实测计数，签名变更按此排爆炸半径。公共面：27 个 `.mli`；其余模块未封装，bin 直接依赖其表面，改它们等于改 bin。

## CONVENTIONS

仅列跨模块约定；lib 内部约定（per-turn 记忆注入、辅助 agent `~save:false`、128k `context_window_override`、`think_tag_strip` 本地构造、800 行限制、原子写）见 `lib/AGENTS.md`。

- 对话超过 `context_budget_tokens` 时，老消息替换为最近 checkpoint 摘要（v0.4.0+）
- 每次 invoke / 落库前 `Par_code_payload.sanitize` 清洗会话：删孤立 tool result、非对象 tool_call 参数归一 `{}`；所有 agent 带 `context_window_override`（默认 128000）+ `context_strategy:None`（v0.8.1+）
- v0.8.2 交互约定：工具/状态行前先 flush pending markdown；`/cost` 只展示真实计数器；手动 `/checkpoint` 不触发提取；doom-loop action-streak 排除 bash/编辑（细节在 `lib/AGENTS.md`）
- v0.9.0 W0/W1/W2（进行中）：用户 skill 放在 `./.par/skills/<id>/skill.md` 或 `~/.par/skills/`；只有 Manual trigger 会被注册为 `/<id>`；SDK 不读 `body_path`，par-code 自己读正文；`/distill` 生成提案、确认后原子写盘，`--force` 先备份（细节在 `lib/AGENTS.md`）
- bash approval 三类：`ask` / `auto_project` / `always`；goal 活跃时 `ask` 自动升级 `auto_project`；持久化在 `.par/approvals.json`
- PAR SDK 依赖 `0.18.0-beta.20261122`；tag 固定 6 处：`dune-project:34` 地板 + `ci.yml:45` + `release.yml:139` + `docker/linux-bundle.Dockerfile:99` + 两个读取方（`install.sh:409` / `build-macos.sh:134` 从 dune-project 解析）；linenoise ≥ 1.3 为 bundled-C 依赖（UTF-8 REPL 输入）
- 缩进：OCaml 2 空格、dune 1 空格（`.editorconfig`）
- 历史记录 append-only：`CHANGES.md` 记"做了什么"、`DECISIONS.md` 记"为什么"，条目只追加不改写

## UNIQUE STYLES

- 中文 prose + 英文 section header（本文件与子目录 AGENTS.md 同款）
- 决策记录走 6 字段格式：tag / before / after / reason / scope / rollback，先记账再动手
- Makefile 仅 5 个 target（build / test / clean / install / dev-deps），其余一律直接 dune

## ANTI-PATTERNS (THIS PROJECT)

硬约束——违反即事故：

1. **PAR SDK 边界**：永不改 `/root/dev/PAR`。编辑 / 创建 / 删除 / `git commit` / `git push` / rebase / 提 PR 全禁止（有 push 权限也不提）；读 PAR 源码理解 API 允许。需要 PAR 改动时，**唯一动作是报缺陷**：先按六字段记进 `docs/DECISIONS.md`（文件 + API + 理由 + 紧迫性），再以本项目身份在 `jcz2020/par` 开 GitHub issue（`gh issue create --repo jcz2020/par`，正文写文件、用 `--body-file`）；即使用户已裁定要改，也走 issue，不在 PAR 仓库改代码 / 提交 / 提 PR。报完**等 PAR 项目自己修**，修好发版后 par-code 再跟进验证；**不在 par-code 侧自建替代实现** —— 绕开会把缺陷盖住，抵消本项目作为 PAR 验证案例的意义（STRATEGY §2：发现限制时第一反应是修 PAR，而不是绕开）。误改了：`git -C /root/dev/PAR status` → `checkout -- .` 回滚 → 报告，等指示。
2. **版本号不可自动 bump**：`dune-project` 的 `(version …)` 只在用户明确说"发布"时改；同步改 `test/test_par_code.ml:2` 断言；commit `dune build` 重新生成的 `par_code.opam`。
3. **FTS5 必须从 amalgamation 编译**（`-DSQLITE_ENABLE_FTS5`），OS 包 sqlite3 不进 release binary。版本锁 `scripts/sqlite-amalgamation.version`（Linux Dockerfile 与 macOS 脚本共用同一版本号）；Dockerfile 提取版本只用 `grep -E '^[0-9]+'`，绝不用 `cat | tr -d`（注释行会被拼进去）。
4. **并行 agent 禁止 git 写操作**（`stash` / `checkout -- .` / `revert` / `reset` / `clean`）；build 失败只修自己的文件，不动别人的；隔离验证用 `dune build` 的 `_build/`。违反会互相覆盖丢工作（v0.3.1 Wave 1 踩过）。
5. **PAR SDK 钉 tag，不钉分支 tip**：地板写在 `dune-project:34` 的 `(par (>= 0.18.0-beta.20261122))`；硬编码在 3 处安装点（`.github/workflows/ci.yml:45` / `.github/workflows/release.yml:139` / `scripts/docker/linux-bundle.Dockerfile:99`）。`scripts/install.sh` 与 `scripts/build-macos.sh` 从 dune-project 读取同一版本再 pin（各自写死的那份曾与源码脱节，报成 opam 的“no matching version”）；`release.yml` / Dockerfile 里的旧版本注释只是 cosmetic，不参与 pin。
6. **披露规则**：committed 产物不得出现外部项目 / 公司名。
7. `lib/par_code_version.ml` 由 dune 生成（gitignored），不可手编。

## COMMANDS

```sh
make dev-deps     # 安装 opam 依赖（par --deps-only --with-test；pin 用 #5 的 tag，不钉 tip）
dune build        # = make build；重新生成 par_code.opam + lib/par_code_version.ml
dune runtest      # = make test；35 个 Alcotest exe / 595 用例
bash test/integration/run.sh    # e2e；tmux 可选（缺失 = SKIP = pass）；仅 Linux
dune exec -- par --version; dune exec -- par; dune exec -- par ask "…"
scripts/build-macos.sh [ver]    # dylib bundle + install_name/RPATH 重写（有意不签名）
scripts/checksums.sh            # checksum-*.txt → checksums.txt
docker build --build-arg VERSION=… -f scripts/docker/linux-bundle.Dockerfile --output type=local,dest=artifacts/ .
```

发布（仅在用户明确说"release"后）：bump 流程见 ANTI-PATTERNS #2 → push stable tag `vX.Y.Z`（无 pre-release 后缀）→ release.yml：linux-x64 → linux-arm64 → macos → coordinate → GitHub Release。

## NOTES

- `docs/` 的 v*.md、*-ROADMAP.md 是历史文档，不是现状；`STRATEGY.md` 停在 v0.8.2，其 API 引用可能过时，当前 `.mli` 为权威
- `docs/DECISIONS.md` 3440 行、~140 条，append-only；`STRATEGY.md` 400 行已过期
- CI 只容忍 PAR pin 的 exit code 31，其他非零一概失败；matrix：ubuntu-22.04 / ubuntu-24.04-arm / macos-15（OCaml 5.4.0），integration 仅 Linux
- CI 失败后重发：fix → push main → 删旧 tag → 建新 tag → push tag；release.yml `cancel-in-progress: false`
- 本机可验证：Termux 自身没有 OCaml，但 Ubuntu proot 里有 `~/.opam/5.4.0`（OCaml 5.4.0 + dune 3.24.2）和现成脚本 `~/par-code-build.sh` / `~/par-code-test.sh`；把脚本**路径**交给 `proot-distro login ubuntu -- /bin/bash <script>`（不要用 `bash -lc` 内联，`$()` 会被外层展开）。作者 Linux 主机的 switch 是 `/root/dev/PAR`（OCaml 5.4.1）
- 子目录知识库：`lib/`、`bin/`、`test/`、`test/integration/`——细节在彼处，本文件不重复；`scripts/`、`docs/` 无子文件（分数不足），跨切面规则只在本文件
- 超 800 行限额的文件：`screen` 2291、`repl` 1842、`ui` 1123、`setup` 960、`config` 805、`bin/main.ml` 739——新增功能优先拆模块，勿继续堆行
