---
id: TASK-118
title: 'implementer: no hand-back while its own background tasks still run; log-line waiters need a timeout and a liveness check'
status: Done
assignee: []
created_date: '2026-11-23T05:40:00Z'
labels:
  - hooks
  - delegation
dependencies: []
priority: high
ordinal: 118000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen twice in one downstream repo, and once in this repo's TASK-61 dispatch (the worker's first completion notice said it was "waiting on its own background work"): the `seyag:implementer` agent hands back its report while background waiters it started are still running. They are shell loops polling every few seconds for a test run's "finished" log line. When the watched run dies early (killed by the agent's own timeout, or a port collision with a second run), the loop polls forever and keeps the parent's subagent open until the parent kills the PIDs by hand.

Fix structurally, not in prose:
- a SubagentStop hook (component of its own, with its toggle) that lists the stopping agent's live background tasks and blocks the stop with their ids and the stop command (or stops them itself, if the harness exposes a safe way: measure what the hook payload carries first);
- implementer.md and the delegation spec template: any wait-for-log-line loop carries a timeout and checks that the watched process is still alive on each poll.

Probe: an agent payload with a live background task blocks; none passes; the toggle disables it. Check the SubagentStop payload shape with a live capture before designing (no SubagentStop hook exists in `plugins/seyag/hooks/hooks.json` today).

Capture result (2026-11-23): SubagentStop fires after the report is already delivered through the SubagentHandback tool call, so blocking there is too late; the gate is a PreToolUse hook on SubagentHandback instead (deny verified live). Evidence summarized in the hook header.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped as handback-live-task-gate (component handback-tasks), a PreToolUse hook on SubagentHandback rather than SubagentStop; implementer.md and the delegation spec template carry the waiter rule.
<!-- SECTION:FINAL_SUMMARY:END -->
