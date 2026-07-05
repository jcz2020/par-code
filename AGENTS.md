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

## 2.（预留 — 后续规则加在这里）
