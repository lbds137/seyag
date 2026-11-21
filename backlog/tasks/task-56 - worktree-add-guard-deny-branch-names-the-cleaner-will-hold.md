---
id: TASK-56
title: 'worktree-add guard: deny branch names the cleaner will HOLD'
status: To Do
assignee: []
created_date: '2026-11-21T05:10:00Z'
labels:
  - guards
  - worktrees
  - owner-friction
  - peer-ask
dependencies: []
priority: high
ordinal: 56000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner-directed (relayed by the machine-management session, 2026-11-20). Miss: a session ran `git worktree add -b <name> .claude/worktrees/<dir> <base>` with a branch name that fails safe-worktree-clean's branch check, so the cleaner held a fully merged tree (hold reason branch-name) and a routine removal needed the owner's approval.

The pattern is the knob SYG_WORKTREE_BRANCH_RE (plugins/seyag/bin/safe-worktree-clean ~L633: unset or empty means `^worktree-agent-`; knobs.tsv row; worktree-transfer reads it too). The relay quoted `^(worktree-|cmp-)`, likely this machine's configured value. The guard must read the same knob through config_env with the same empty-means-default rule, so the two can't drift; extracting the default into one shared constant is fine.

Build, hook by fit: a PreToolUse Bash clause in live-checkout-guard (it already parses `worktree add`) or a sibling guard with its own toggle. When a `git worktree add` (any -C/cwd form) targets a path under `.claude/worktrees/` and creates a branch (-b/-B NAME) that fails the pattern, deny with the fix ("name it worktree-agent-<slug>", rendered from the active pattern where possible). An invalid regex stays allowed and warns, matching the cleaner's own "not a valid extended regex" hold.
Probes: bad name under .claude/worktrees → deny; a matching name → pass; no -b on an existing branch → pass; a path outside .claude/worktrees → pass; the knob set to a custom pattern → follows it.
Replay against local logs first (tests/replay-hook.sh live-checkout-guard --since 7) and sample the blocked set.
<!-- SECTION:DESCRIPTION:END -->
