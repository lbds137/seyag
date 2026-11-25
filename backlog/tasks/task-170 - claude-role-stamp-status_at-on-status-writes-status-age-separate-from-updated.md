---
id: TASK-170
title: >-
  claude-role: stamp status_at on status writes (status age separate from
  updated:)
status: To Do
assignee: []
created_date: '2026-11-25T08:06:00Z'
labels:
  - claude-role
  - feature
dependencies: []
priority: medium
ordinal: 163000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generic ask from a fleet consumer. Today every write verb (status, holds, need, need-done, note, next) bumps `updated:`, so a reader cannot tell how old the status text is: a session can add notes for hours while its status line goes stale and `updated:` still looks fresh.

Ask:
- Every `claude-role --set status=...` writes `status_at: <same format as updated:>`. A write with the same text stamps it too, so a session can confirm a still-true status without rewording it.
- No other verb bumps it.
- Expose it in `--json` (and `--board` if cheap).
- Probe pins: a same-text status write bumps status_at; --note, --next and holds= do not.

Consumer: a fleet STATUS-STALE check reads status_at when present (status older than the session's last activity by more than 2h), falling back to the 48h `updated:` rule when absent, so nothing breaks before this ships.

Related: TASK-140 item 2 (skip `-archive-` stems in the role loops) is the single fix for ghost rows; readers enumerate through `claude-role --list/--json`. Positive control (requester, on 0.3.225): a copy of a retired archive file in a temp SYG_ROLE_DIR still lists as a second live role.

Owner: bin/** lane.
<!-- SECTION:DESCRIPTION:END -->
