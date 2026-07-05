# par-code 项目规则

> 项目级规则。优先级高于全局 `~/.config/opencode/AGENTS.md`。
> 仅记录与本项目强相关的硬约束；通用规范看全局。

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
  git tag -d v0.3.2
  git tag -a v0.3.2 -m "v0.3.2 — ..."
  git push origin :refs/tags/v0.3.2
  git push origin v0.3.2
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
