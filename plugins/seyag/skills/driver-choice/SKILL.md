---
name: driver-choice
description: 'Which model should drive a session: classify the next unit of work (big-picture or drain) and recommend the big-picture lane only when the cheaper lane would do the unit clearly worse, at a clean boundary with the handoff on disk. Use at session start, when a new theme begins, when the work class changes (design to drain or back), when the weekly meter crosses the memory''s wind-down threshold, or when the owner asks which model should drive.'
---

# Driver choice

The strongest model burns the shared week fastest, so it is spent only where it clearly earns it. Best tool first, then the cheapest that does the job: a unit goes to the big-picture lane only when the orchestrator lane would do it clearly worse, never to fill the big-picture model's own cap. The session's job is to notice when the next unit belongs in the other lane and to say so at a moment when switching costs nothing.

## Lanes

Name lanes, not model versions; which model fills each lane, the wind-down threshold and the spend posture are machine-local policy in the shared memory ("Model roles + usage posture"), not in this skill.

| Lane | Work class | Examples |
|---|---|---|
| **Big-picture** (strongest reasoning) | Judgment that the diff can't be checked against: the shape of a thing, or a ruling, and only where the drain lane would do it clearly worse | Design and architecture; audits and session mining; process policy (rules, skills, hooks); a new subsystem; plans of record; reviews of a design |
| **Drain** (orchestrator, cheaper) | Work whose target is already settled and the job is to reach it | Ports, sweeps, backlog drains, filing, applying review rounds, routine fixes, bookkeeping, babysitting CI |

Inside any session, mechanical work still goes to workers (the `delegation` skill). The lane question is about the DRIVER's own reasoning on the unit, not the unit's total line count: a big-picture driver that specs and dispatches a drain is fine; a drain driver ruling on a design is the miss.

Ambiguous class → the lane you are already in. Half design, half drain → split it: design on the current driver, the drain dispatched.

## The meter

The plan meter (`claude-usage` here; the memory names it) prints the weekly usage. Read it before the recommendation; never quote an old reading. The wind-down threshold and the LARGE-unit hold live in the memory.

1. **Drain units** always go to the orchestrator lane (recommend a switch if you are the big-picture driver).
2. **A big-picture unit** goes to the big-picture lane only when the orchestrator lane would do it clearly worse, and the recommendation names why. Otherwise it goes to the orchestrator.
3. **At or past the memory's weekly wind-down threshold**, everything goes to the orchestrator lane, and LARGE units are held per the memory.

For "will the next units fit the week" questions, run usage-sweep --since <session start> --points for this project's meter points, instead of eyeballing from the live percentage.

## When to say it

Only at a clean boundary: gates green, no agent or worktree in flight, and the handoff (the role file's Handoff and Next, or the project's status file) written to disk and said to be written. A switch is `/clear`, not `/compact`: the new driver must start from the disk handoff, not a summary. Then `/model`. At session start, `/model` alone.

The recommendation is one line with its numbers, and it ends the turn as a blocking question (`AskUserQuestion`, two options: switch now, or stay):

> Next unit "<name>" is <class>; <why the cheaper lane would be clearly worse, or suffices>. Meter: week <N>% (wind-down <threshold>). Recommend `/clear` then `/model <lane's model, from the memory>`; handoff written.

Then stop. The owner types `/model`; a session never switches itself. If she declines, that is session state: don't re-raise it in this session unless the unit class changes or the meter crosses the wind-down threshold.

## After a switch

The status line flags a session whose effort differs from its model's intended level (a switch can leave the old effort behind). The value is the owner's `/effort`, so name the flag if it shows and don't suggest a setting.

## Boundary

This skill picks the driver's lane. Which worker tier a dispatch gets is the `delegation` skill's call, and how much of the week has been spent is the `usage-audit` skill's.
