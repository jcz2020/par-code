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



