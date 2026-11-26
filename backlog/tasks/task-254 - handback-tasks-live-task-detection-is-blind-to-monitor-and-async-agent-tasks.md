---
id: TASK-254
title: 'handback_tasks: live-task detection is blind to Monitor and async Agent tasks'
status: To Do
assignee: []
created_date: '2026-11-26T16:08:00Z'
labels:
  - hooks
  - lane-a
dependencies: []
priority: medium
ordinal: 254000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`hooks/lib/handback_tasks.py` (`live_task_ids` / `scan_entries`) counts a task as live only when it was started by a Bash call whose result carries `toolUseResult.backgroundTaskId`. Two other kinds of background work are invisible to it:

- **Monitor**: the tool result is `toolUseResult: {"taskId", "timeoutMs", "persistent"}`, with no `backgroundTaskId`.
- **Async Agent**: the tool result is `{"isAsync": true, "status": "async_launched", "agentId": ...}`. Its end notice is a `<task-notification>` carrying `<task-id>` = the agentId, `<tool-use-id>` and `<output-file>`.

Found during TASK-121 part 2 by reading transcripts (shapes observed in local session logs, 2026-11-26). The cause is from code-reading; no runtime repro has been made yet.

Effect: the stale-pick trigger's live-work exemption (trigger (d) in `handoff-pick-check`) blocks a notification turn even while a Monitor or an async Agent is still running. The prose-pick trigger added under TASK-121 reuses the same exemption, so it has the same blind spot.

Why it is not a one-line fix:
- Monitor event notifications are `<task-notification>` entries with `<task-id>` and `<summary>Monitor event: ...` but NO `<status>` tag. `scan_entries` currently ends a task on a notification with no status, so simply adding Monitor ids would end them at their first event.
- The real end-of-Monitor record (expiry or stop) has not been identified yet. Candidate: `attachment.type == "task_status"` records, which carry `taskId`, `taskType` (`local_bash` | `local_agent`), `status` (`running` | `completed`) and, for monitors, `shell.kind == "monitor"`.
- `scan_entries` is shared with `handback-live-task-gate`, so a change there alters that gate too.

Fix shape: identify the Monitor and async-Agent terminal records (capture them live); have `scan_entries` track those ids and end them only on their own terminal record (a status-less Monitor event keeps the task live); add probe cases to both the `handoff-pick-check` and `handback-live-task-gate` probes; replay both hooks.
<!-- SECTION:DESCRIPTION:END -->
