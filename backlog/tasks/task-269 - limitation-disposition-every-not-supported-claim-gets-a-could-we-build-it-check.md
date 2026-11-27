---
id: TASK-269
title: 'Limitation disposition: every "not supported" claim gets a "could we build it?" check'
status: To Do
priority: medium
labels: [rules, hooks, continuous-improvement]
created_date: '2026-11-27'
---

## Description

Owner direction (11-27): when an agent says something is not currently supported (a tool refuses an input shape, a command skips a case, a feature is missing), the agent must not just accept it and move on. It should ask whether the limitation could be removed, and if it could, file it with a priority on the owning project's tracking surface. The aim is continuous improvement: a limitation is a candidate fix, not a fact of life.

The current rules cover only part of this. "Everything not done gets a disposition" covers work the agent declines. "Fix what you touch, file what you find" covers defects. Neither one clearly covers a capability gap in the tooling that the agent works around and then forgets.

Motivating shape (generic): a relay CLI refused a two-question ask ("single-question relay refuses partial answers"). The agent drove the UI by hand, which worked but left no log entry. A stop command skipped one session type, and the agent quit that session by hand. Only the first gap got filed, and only because the owner asked.

## Proposed shape (decide at pickup)

- **Rule clause** (one line, folded into "Everything not done gets a disposition"): a limitation hit or reported ("X doesn't support Y", "refuses", "no way to") gets a disposition in the same turn: filed (with a task id), ruled out (with the reason), or already tracked (with the id).
- **Hook** (mechanical trigger): a Stop-time check over the final message. When it matches a limitation phrase ("not supported", "doesn't support", "refuses", "no way to", "can't do") with no task id or "ruled out" nearby, it nudges once: "limitation named without a disposition". It is advisory, like the existing status-claim cite hook.
- **Workaround detector** (optional): when an agent routes a tool's refusal through a manual path (raw keystrokes, hand edits), the same nudge fires.

## Acceptance

- The rule clause lands, and it reads well beside the existing disposition rule.
- The hook has probes: a positive case (a limitation with no id, which nudges), a negative case (a limitation plus a task id, which stays silent) and a false-positive guard (quoted tool output that contains "refuses", which stays silent).
