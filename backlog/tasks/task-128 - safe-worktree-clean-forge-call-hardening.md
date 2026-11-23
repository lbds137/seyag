---
id: TASK-128
title: 'safe-worktree-clean: forge call hardening (kill-after, exit 137, missing timeout)'
status: To Do
assignee: []
created_date: '2026-11-23T19:47:00Z'
labels:
  - bin
  - worktrees
dependencies: []
priority: low
ordinal: 128000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the cross-family (council, OpenAI) review of TASK-127. These are outside that unit's diff, which only added the per-repo timeout latch.

1. `timeout 20 gh api …` sends TERM with no `--kill-after`, so a `gh` that ignores TERM can hold the run past 20 s. Add a short kill-after.
2. With a kill-after, a forced kill exits 137, which today is reported as "gh api failed (exit 137)" and does not set `PR_FORGE_TIMED_OUT`. Decide whether 137 latches too; if it does, use a neutral skip note.
3. With no `timeout` on PATH, the wrapper exits 127 and the note blames `gh api`. Detect the missing `timeout` and say so. Never fall back to an unbounded call.
4. The URL-shape note says "https, ssh:// or git@host:owner/repo", but the regexes also accept `http://` and any user name, not just `git`. Make the wording match the regexes.

All of these fail closed today: the tree stays `unmerged` and no verdict is wrong. Only the latency bound and the diagnostics are affected.
<!-- SECTION:DESCRIPTION:END -->
