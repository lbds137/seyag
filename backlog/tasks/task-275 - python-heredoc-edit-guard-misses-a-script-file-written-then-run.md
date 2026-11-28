---
id: TASK-275
title: 'python-heredoc-edit-guard: misses a script file written then run'
status: To Do
assignee: []
created_date: '2026-11-28T16:07:00Z'
labels:
  - hooks
  - guards
dependencies: []
priority: medium
ordinal: 275000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported 2026-11-28 by a peer session: a headless worker in another project did nearly every source edit of one round by writing a rewrite script to a file (`cat > /tmp/x.mjs <<'EOF' … EOF`) and then running it (`node /tmp/x.mjs`), in the same command or a later one. The guard's check 1 only matches inline shapes (`python -c`/`-`, a heredoc piped into python, `node -e`/`-p`/`--eval`), so the two-step form passes. The worker never set the override env var and reported the bypass itself. The current mitigation (worker specs say Edit/Write only) holds only as long as workers comply.

Shape (two halves, both stateless):
- Same command: a heredoc or redirect writing a script file (.py/.mjs/.js/.cjs/.pl) plus an interpreter call on that same path later in the command. Run checks 2 and 3 on the heredoc body.
- Later command: an interpreter run on an existing script file under a temp or scratch dir (`/tmp`, `$TMPDIR`, the session scratch dir). Read the file (size cap, fail-open) and run checks 2 and 3 on its content. The file exists by PreToolUse time, so no write ledger is needed.

Keep check 3's read-modify-write test, so generators that write derived output still pass. Before shipping, replay against local session logs (`tests/replay-hook.sh python-heredoc-edit-guard --since 7`) and sample the new blocks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Same-command write-then-run of a read-modify-write script blocks; probe cases for node and python
- [ ] #2 Later-command run of a temp/scratch script whose content is read-modify-write blocks; a generator script (reads A, writes B) passes
- [ ] #3 Fail-open on an unreadable, oversized or missing file; the override env var still bypasses
- [ ] #4 Replay over 7 days of session logs, blocked set sampled and recorded in the PR
<!-- AC:END -->
