---
id: TASK-66
title: 'worktree-branch-guard: #366 PASS-round lows'
status: To Do
assignee: []
created_date: '2026-11-21T15:20:00Z'
labels:
  - guards
  - worktrees
dependencies: []
priority: medium
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Six lows from the #366 PASS review (claude-review on e5571c3):
1. `parse_worktree_add` ignores git's unique long-option prefixes. `--det` is a valid detach, but it is judged as an implied branch, which falsely denies an add that creates no branch. `--reas <text>` consumes only one word. Either match unambiguous prefixes or list this as a KNOWN BOUND.
2. The 0.3.202 CHANGELOG says "a repository cannot weaken what the cleaner deletes". A repo's `.claude/settings.json` `env` can still export these knobs. Narrow the wording to `.claude/seyag.toml` in the next release's notes.
3. The 0.3.202 CHANGELOG lists `SYG_WORKTREE_REGENERABLE` as newly refused, but it was already user-only through its `path` flag.
4. The suggested `worktree-agent-<slug>` can be an invalid ref (`..`, or a trailing `.lock` or `.`). Sanitise the slug.
5. Add probe cases:
   - `--orphan` without `-b` (implied);
   - a clustered `-fd` (detach);
   - a `git -C <repo>` implied add whose branch already exists.
6. `local_branch_exists` strips only `GIT_DIR` and `GIT_WORK_TREE`. Strip every repo-locating `GIT_*` variable: `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, `GIT_CEILING_DIRECTORIES`.
<!-- SECTION:DESCRIPTION:END -->
