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

## Roadmap（2026-07-02 经源码核查后确认）

> 先对 PAR 与对齐目标做了双侧源码逐条核查（PAR 9 大能力全部真实；目标 9 个招牌
> 特性全部实打实实现、非 stub；PAR 在记忆/上下文整块为零覆盖）。据此重定路线图。

每版交付**一个**用户可感知的核心功能（垂直薄片，做完即可演示）；版本号最小递增，
核心能力对齐前不升 1.0。

- **v0.1.0** ✅ 项目骨架（链接 PAR SDK，`par-code --version` 可用）。
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
