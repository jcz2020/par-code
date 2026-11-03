# par-code 项目知识库

> 项目级规则 + 项目地图。优先级高于全局 agent 指令文件。本文件是全库索引；模块细节在各子目录 AGENTS.md，此处不重复。

**Generated:** 2026-11-03 · **Commit:** 7130653 · **Branch:** main

## OVERVIEW

par-code 是基于 PAR SDK 的 OCaml 终端编码 agent：`par` 启动 REPL，agent 能读写编辑代码、跑 bash、跨会话记忆项目知识；同时是 PAR SDK 的验证项目——每个功能反哺 PAR 的能力缺口。栈：OCaml 5.4 + dune + Cmdliner + Eio + PAR SDK（Runtime.invoke → ReAct）+ SQLite（WAL，FTS5 + vec0）。当前 v0.8.2；发布史以 `CHANGES.md` 为权威。

## STRUCTURE

```
par-code/
├── bin/              # Cmdliner CLI：main.ml 分发 + cli_args.ml（29 flag）→ bin/AGENTS.md
├── lib/              # 30 个核心模块，flat 布局，Par_code_* 前缀 → lib/AGENTS.md
├── test/             # Alcotest 单测（26 exe）→ test/AGENTS.md
│   └── integration/  # bash/tmux e2e harness → test/integration/AGENTS.md
├── scripts/          # install.sh / build-macos.sh / checksums.sh / docker/linux-bundle.Dockerfile
├── docs/             # DECISIONS.md（决策账本）+ STRATEGY.md（战略快照）
├── .github/          # ci.yml（push/PR matrix）+ release.yml（stable tag 触发）
└── dune-project      # 版本号 + PAR 依赖；无根 dune 文件（配置在 dune-project + per-dir dune）
```

调用链：`bin/main.ml`（Cmdliner 分发）→ `lib/par_code_setup.ml`（建 Runtime、注册 tools/agents/中间件）→ PAR SDK ReAct loop → `~/.par/par.db`（SQLite WAL：memory_entries / conversations / checkpoints）。根文件另有 `Makefile`、`README.md`（用户文档）、`CHANGES.md`（发布记录）、`.editorconfig`。

## WHERE TO LOOK

| 任务 | 位置 | 备注 |
|---|---|---|
| lib 30 个模块的职责 / 接口 / lib 级约定 | `lib/AGENTS.md` | 模块地图在彼处 |
| 自定义 skill / 命令 | `lib/par_code_skills.ml` + `/skills` | v0.9.0 W0/W1；manual-only |
| CLI 子命令 / flag / 分发 | `bin/AGENTS.md` | `main.ml` 触 10 个模块，全库最宽耦合 |
| 单测约定 / 版本断言 | `test/AGENTS.md` | 版本断言硬编码在 `test/test_par_code.ml:2` |
| e2e harness | `test/integration/AGENTS.md` | `run.sh`、setup_home 契约、dead endpoint |
| 安装 / 打包 / 平台 | `scripts/` | linux-x64（glibc ≥ 2.28）/ linux-arm64 / darwin-arm64；`install.sh` 拒装 `/`、`/bin`、`/usr`、`/usr/bin`、`/usr/local` |
| 查"为什么做了 X" | `docs/DECISIONS.md` | append-only 决策账本，78 条 |
| CI / 发布流水线 | `.github/workflows/` | release.yml 只认 stable tag，actions 按 commit SHA 钉 |
| 架构决策完整推理 | 本地 gitignored 计划目录 | 仅本地，不入库 |

## CODE MAP

| Symbol | 类型 | 位置 | 外部引用* | 角色 |
|---|---|---|---|---|
| `Par_code_setup.setup_runtime` | val | `lib/par_code_setup.ml` | 每个子命令 | Runtime 引导，全库汇聚点 |
| `Par_code_repl.run` / `run_single_shot` | val | `lib/par_code_repl.ml` | bin | REPL 循环 / `par ask` |
| `Cmd.eval` | term | `bin/main.ml` 末尾 | — | CLI 总入口 |
| `Par_code_ui_markdown` | module | `lib/par_code_ui_markdown.ml` | 110 | streaming markdown→ANSI 状态机；`has_pending` 供工具行前刷半行 |
| `Par_code_ui` | module | `lib/par_code_ui.ml` | 103 | 渲染抽象层 + 表格/成本/工具行 |
| `Par_code_memory` | module | `lib/par_code_memory.ml` | 86 | 记忆层 |
| `Par_code_mode` | module | `lib/par_code_mode.ml` | 73 | Plan/Build 模式状态 |
| `Par_code_plan_tools` | module | `lib/par_code_plan_tools.ml` | 59 | plan 工具族 |
| `Par_code_checkpoint` | module | `lib/par_code_checkpoint.ml` | 53 | 长会话连续性；手动 /checkpoint 不触发提取（v0.8.2+） |
| `Par_code_payload.sanitize` | val | `lib/par_code_payload.ml` | 8 | invoke / 落库前的会话清洗 |

\* 外部引用为 bin+test 中 `Module.` 限定引用的实测计数，签名变更按此排爆炸半径。公共面：23 个 `.mli` 共 204 `val` + 31 `type`；7 个模块无 `.mli`（config / config_wizard / extractor / memory_tools / repl / repl_io / setup），bin 直接依赖其未封装表面，改它们等于改 bin。

## CONVENTIONS

仅列跨模块约定；lib 内部约定（per-turn 记忆注入、辅助 agent `~save:false`、128k `context_window_override`、`think_tag_strip` 本地构造、800 行限制、原子写）见 `lib/AGENTS.md`。

- 对话超过 `context_budget_tokens` 时，老消息替换为最近 checkpoint 摘要（v0.4.0+）
- 每次 invoke / 落库前 `Par_code_payload.sanitize` 清洗会话：删孤立 tool result、非对象 tool_call 参数归一 `{}`；所有 agent 带 `context_window_override`（默认 128000）+ `context_strategy:None`（v0.8.1+）
- v0.8.2 交互约定：工具/状态行前先 flush pending markdown；`/cost` 只展示真实计数器；手动 `/checkpoint` 不触发提取；doom-loop action-streak 排除 bash/编辑（细节在 `lib/AGENTS.md`）
- v0.9.0 W0/W1（进行中）：用户 skill 放在 `./.par/skills/<id>/skill.md` 或 `~/.par/skills/`；只有 Manual trigger 会被注册为 `/<id>`；SDK 不读 `body_path`，par-code 自己读正文（细节在 `lib/AGENTS.md`）
- bash approval 三类：`ask` / `auto_project` / `always`；goal 活跃时 `ask` 自动升级 `auto_project`；持久化在 `.par/approvals.json`
- PAR SDK 依赖 ≥ 0.12.0-beta.20261023（v0.7.5+）；tag 固定 6 处：`dune-project` 地板 + 5 个安装点；linenoise ≥ 1.3 为 bundled-C 依赖（UTF-8 REPL 输入）
- 缩进：OCaml 2 空格、dune 1 空格（`.editorconfig`）
- 历史记录 append-only：`CHANGES.md` 记"做了什么"、`DECISIONS.md` 记"为什么"，条目只追加不改写

## UNIQUE STYLES

- 中文 prose + 英文 section header（本文件与子目录 AGENTS.md 同款）
- 决策记录走 6 字段格式：tag / before / after / reason / scope / rollback，先记账再动手
- Makefile 仅 5 个 target（build / test / clean / install / dev-deps），其余一律直接 dune

## ANTI-PATTERNS (THIS PROJECT)

硬约束——违反即事故：

1. **PAR SDK 边界**：永不改 `/root/dev/PAR`。编辑 / 创建 / 删除 / `git commit` / `git push` / rebase / 提 PR 全禁止（有 push 权限也不提）；读 PAR 源码理解 API 允许。需要 PAR 改动：先在 DECISIONS 记录需求（文件 + API + 理由 + 紧迫性）→ 向用户陈述 → **等用户决定**，期间按 PAR 现状推进或 par-code 侧绕开。误改了：`git -C /root/dev/PAR status` → `checkout -- .` 回滚 → 报告，等指示。
2. **版本号不可自动 bump**：`dune-project` 的 `(version …)` 只在用户明确说"发布"时改；同步改 `test/test_par_code.ml:2` 断言；commit `dune build` 重新生成的 `par_code.opam`。
3. **FTS5 必须从 amalgamation 编译**（`-DSQLITE_ENABLE_FTS5`），OS 包 sqlite3 不进 release binary。版本锁 `scripts/sqlite-amalgamation.version`（Linux Dockerfile 与 macOS 脚本共用同一版本号）；Dockerfile 提取版本只用 `grep -E '^[0-9]+'`，绝不用 `cat | tr -d`（注释行会被拼进去）。
4. **并行 agent 禁止 git 写操作**（`stash` / `checkout -- .` / `revert` / `reset` / `clean`）；build 失败只修自己的文件，不动别人的；隔离验证用 `dune build` 的 `_build/`。违反会互相覆盖丢工作（v0.3.1 Wave 1 踩过）。
5. **PAR SDK 钉 tag，不钉分支 tip**：`v0.12.0-beta.20261023` 固定 6 处——`dune-project`（地板）+ 5 个安装点（`.github/workflows/ci.yml` / `.github/workflows/release.yml` / `scripts/docker/linux-bundle.Dockerfile` / `scripts/build-macos.sh` / `scripts/install.sh`）。
6. **披露规则**：committed 产物不得出现外部项目 / 公司名。
7. `lib/par_code_version.ml` 由 dune 生成（gitignored），不可手编。

## COMMANDS

```sh
make dev-deps     # 安装 opam 依赖（par --deps-only --with-test；pin 用 #5 的 tag，不钉 tip）
dune build        # = make build；重新生成 par_code.opam + lib/par_code_version.ml
dune runtest      # = make test；25 个 Alcotest exe
bash test/integration/run.sh    # e2e；tmux 可选（缺失 = SKIP = pass）；仅 Linux
dune exec -- par --version; dune exec -- par; dune exec -- par ask "…"
scripts/build-macos.sh [ver]    # dylib bundle + install_name/RPATH 重写（有意不签名）
scripts/checksums.sh            # checksum-*.txt → checksums.txt
docker build --build-arg VERSION=… -f scripts/docker/linux-bundle.Dockerfile --output type=local,dest=artifacts/ .
```

发布（仅在用户明确说"release"后）：bump 流程见 ANTI-PATTERNS #2 → push stable tag `vX.Y.Z`（无 pre-release 后缀）→ release.yml：linux-x64 → linux-arm64 → macos → coordinate → GitHub Release。

## NOTES

- `docs/` 的 v*.md、*-ROADMAP.md 是历史文档，不是现状；其 API 引用可能过时，当前 `.mli` 为权威
- CI 只容忍 PAR pin 的 exit code 31，其他非零一概失败；matrix：ubuntu-22.04 / ubuntu-24.04-arm / macos-15（OCaml 5.4.0），integration 仅 Linux
- CI 失败后重发：fix → push main → 删旧 tag → 建新 tag → push tag；release.yml `cancel-in-progress: false`
- 开发机 opam switch（Linux 主机）：`/root/dev/PAR`（OCaml 5.4.1）；当前 Termux checkout 无 OCaml 工具链，改动验证走 GitHub Actions CI
- 子目录知识库：`lib/`、`bin/`、`test/`、`test/integration/`——细节在彼处，本文件不重复
