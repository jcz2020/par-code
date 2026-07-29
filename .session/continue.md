# Session Handoff — 2026-07-29

## Last shipped

**v0.5.1 — Plan CLI + Git Tools** (tag v0.5.1, all 3 platforms built, Release published)

4 items from v0.5.0 §17:
- `par plan list/show/prune` CLI subcommands
- `git_status` + `git_log` read-only tools for planner agent

Also consumed PAR SDK 0.8.0-beta approval API changes (3 persistence fields + 4 event variants + invoke_result approval_pending).

## What's next

**v0.6.0 — Subagent delegation** (per README roadmap):
- general/explore subagents
- actor tool
- task tree

Two PAR SDK feedback items from v0.5.0 will shape the design:
1. Plan/task primitive (medium priority) — v0.6.0 subagent coordination needs structured plan handoff
2. First-class mode concept (low priority) — re-evaluate if more modes are added

Before starting v0.6.0, recommend the "C → B" approach: spend half a day evaluating whether these PAR SDK gaps are truly blocking (must be upstream) or par-code can cleanly work around them.

## Technical notes for next agent

- PAR SDK is now at **0.8.0-beta.20260729** (upstream bumped from 0.7.8). The approval workflow features are available but par-code only has stub-level consumption (empty match arms + wired-but-unused persistence functions). Full approval UI is a future feature.
- `parse_plan_timestamp` uses Fliegel-Van Flandern algorithm (NOT the JDN float formula — that had a +0.5 day bug). Don't revert it.
- `parse_git_status` splits branch on `...` (three dots), NOT `.` (single dot). Branches like `feature/v0.5.1` must work.
- Git tools use `Eio.Process.spawn ~sw:tok.switch` for fiber safety. Don't switch to `Unix.open_process_in`.

## Files to know

| File | Purpose |
|---|---|
| `lib/par_code_git_tools.ml` | git_status/git_log tool bindings |
| `lib/par_code_plan_tools.ml` | plan tools + list/show/prune + timestamp parser |
| `lib/par_code_setup.ml` | tool/agent registration (planner has 9 tools now) |
| `bin/main.ml` | CLI: `par plan list/show/prune` added |

## Session stats

- Commits: 2 (release: v0.5.1 + fix: PAR SDK approval API)
- Tests: 211 passing (14 suites)
- Platforms: Linux x64/arm64 + macOS arm64 all green
