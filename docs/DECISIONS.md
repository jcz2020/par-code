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
- GitHub Actions 工作流文件（`.github/workflows/ci.yml`）需 token 具备 `workflow`
  scope 才能 push；当前 gh token 仅有 `gist/read:org/repo`，待刷新后补推。

## Roadmap

- **v0.1.0** — 项目骨架 + README（本次）。
- **v0.2.0** — 交互式 REPL：config 向导、多轮对话、内置文件工具、类型安全 bash、
  流式输出、SQLite 持久化。
- **v0.3.0** — 自定义代码工具（AST 感知编辑、语义搜索）+ skill 打包。
- **v0.4.0** — MCP client 集成（filesystem/git/GitHub）+ 多步 workflow。
