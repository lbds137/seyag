---
id: TASK-181
title: 'handoff-pick-check: a pick chained after an ambiguous command segment is not seen (false block)'
status: To Do
assignee: []
created_date: '2026-11-25T19:20:00Z'
labels:
  - hooks
  - stop-gate
  - false-positive
dependencies: []
priority: medium
ordinal: 181000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the Deck session on 11-25: the gate fired twice that day after `session-pick keep` had run and succeeded as the last segment of the same Bash call that edited the role file. The shape was `sed '…' roles/<role>.md; grep -c …; session-pick keep`.

The cause is confirmed at runtime. `turn_scan.command_argvs` returns no argv for a command it reads as ambiguous (a backslash, `$'`, a quoted `#`). With no argv, `emitter_calls` never sees the chained pick, and the gate blocks once. The hook header documents this as an accepted residual ("run the pick as its own call"). It is not rare, though. Deck's transcripts from 11-25 hold 20 Bash calls that edit a role file and end in `session-pick keep`. `command_argvs` returned 0 argvs for 5 of them: 4 carried a backslash (sed `s/…/` bodies) and 1 a quoted `#`. Every one of those 5 would block.

Fix direction, to be decided in the unit: when `command_argvs` yields nothing, parse only the command's tail. That is the text after the last top-level `;`, `&&` or newline that a conservative scan can find outside quotes. If the tail alone parses unambiguously and is an emitter argv, count it. The fallback must not count a pick inside a quoted string, heredoc or `bash -c` body. The probes pin that, plus the 5 recorded shapes, using invented paths.

The alternative is to keep the residual and make the block text say "run the pick as its own Bash call". That is cheaper, but it keeps costing a round trip per handoff. Either way, update the header's residual note.
<!-- SECTION:DESCRIPTION:END -->
