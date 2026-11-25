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
ordinal: 170000
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

Related: TASK-140 (ghost rows from archive copies; its notes carry the consumer's positive control).

Owner: bin/** lane.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Consumer contract (confirmed 2026-11-25 by the consumer, which has already shipped its reader):
- `status_at:` uses the same local-time format as `updated:` (`YYYY-MM-DD[ HH:MM]`).
- It lives wherever `updated:` lives. The reader accepts it at the top level or under `metadata:`.
- Every `--set status=` write stamps it, including a write with unchanged text. No other verb touches it.
- No deadline: without the field, the reader falls back to the 48h `updated:` rule.
<!-- SECTION:NOTES:END -->
