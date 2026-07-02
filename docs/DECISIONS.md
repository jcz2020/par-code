# Decisions

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
2. **Agent 形态**：交互式编码助手（类 Claude Code 终端 REPL）。
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

