---
id: TASK-93
title: 'Optional event hook: SYG_EVENT_CMD receives one JSON line per session event'
status: To Do
assignee: []
created_date: '2026-11-22T17:00:00Z'
labels:
  - hooks
  - peer-ask
dependencies: []
priority: medium
ordinal: 93000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer ask, relayed by the machine-management session (owner direction: a fleet manager should receive pushed session events instead of polling sessions). This is a generic mechanism only. The consumer is machine-local and never named in this repo.

When the settings env `SYG_EVENT_CMD` is set, plugin hooks pipe one JSON line to it on stdin: `{"ts","session_id","cwd","kind","detail"}`. Delivery is fire-and-forget:
- a short timeout;
- the run is detached, with output discarded;
- it never blocks, and never changes the hook's exit code or output.

When the env is unset, behaviour does not change.

First kinds:
- `pick-named`: the handoff-pick Stop gate saw a closing message naming `/clear`, `/compact` or keep. `detail` is the pick.
- `ask-open`: a turn ended with an `AskUserQuestion` pending.
- `handoff-written`: a role or handoff file was written this turn.
- `idle`: a turn ended with no pending ask.

Constraints:
- The knob runs a command, so it is refused from project scope. Use the same mechanism as the other command knobs (`_SYG_CFG_PROJECT_EXEC` / `_PROJECT_EXEC` and their probe parity). Check the TASK-78 bypass class too.
- It ships with its own toggle; the knob itself is the toggle.
- It gets a knobs.tsv row and regenerated `docs/config.md`.
- Emit the events from one shared shell helper, never copied into each hook.

Probes:
- with the knob set, a fake command records exactly one line per kind;
- with it unset, nothing runs;
- a failing command and a slow command (past the timeout) leave the hook's exit code, stdout and stderr byte-identical to the unset run;
- project-scope config refuses the knob.

Before shipping, replay the Stop path against 7 days of logs.
<!-- SECTION:DESCRIPTION:END -->
