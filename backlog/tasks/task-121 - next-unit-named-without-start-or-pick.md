---
id: TASK-121
title: 'handoff-pick-check: block once when a turn names the next unit but neither starts it nor runs the pick command'
status: In Progress
assignee:
  - Seyag
created_date: '2026-11-23T14:28:00Z'
labels:
  - hooks
  - stop-gate
dependencies: []
priority: high
ordinal: 121000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Request from the machine-management session (2026-11-23). A turn can end by naming the next unit ("X is next", "Next is TASK-N") without starting it and without running the pick command (`SYG_PICK_CMD`). Nothing then happens: with no pick event, the host has nothing to act on. It was seen 3 times on one machine in one night, with sessions idle for up to ~8h until the owner nudged them by hand. The core rule "never end a turn on a stated intention" is not enforced anywhere.

Gap, checked against `plugins/seyag/hooks/handoff-pick-check.sh` on 0.3.212: emitter mode only fires when the turn wrote a handoff (trigger (a)). A next-unit closing without a handoff write passes silently.

Shape: an extension of handoff-pick-check, not a new hook.
- Add a second trigger, only when `SYG_PICK_CMD` is set: the final assistant text matches a next-unit pattern, AND the turn made no pick-command call, AND the turn started no work after the naming.
- Block once per turn with "start the named unit, or run the pick command".
- Give it its own `SYG_DISABLE` key.

Second shape (same source, same day): a session ran the pick command, then a notification-only turn (a background task finished; no user input) replied and ended without re-running it, so the pick went stale. Later the session told the owner "the /clear is already queued" without re-running it, which was false. So the check also covers:
- notification-only turns, which end with no fresh pick;
- a final text that claims a pick is queued while the turn made no pick-command call.

Open design points, for whoever builds it:
- **Next-unit pattern.** It needs precision against the replay corpus. Many closings legitimately say "next" while a background agent or CI is still running.
- **Whether live background work exempts the turn.** One option is an Agent or Monitor launched this turn, reusing handback-live-task-gate's task scan.
- **What the host-side companion covers.** The fleet runner is getting an idle-nudge, filed separately on the host side.

Gate it with `tests/replay-stop-hook.sh` and sample its blocked set before it ships.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Status 2026-11-23: part 1 shipped in 0.3.214 (#384): handoff-pick-check blocks once when a background-task notification starts a turn that ends without re-running the pick command after an earlier clear/compact pick (the second shape above), toggle `stale-pick`.

Part 2 (text triggers: "X is next" with no start, and a pick claimed as queued but never run) is deferred. Trigger: the next observed idle that part 1 misses, or a free slot after TASK-123. Measure precision on a replay first (`tests/replay-stop-hook.sh --since 7`).

Council deferrals from the #384 review (gpt-6.2-sol), recorded as decided:
- Pick request with no tool_result, or a non-executed `false && pick keep`, counts as a pick: DEFERRED. This is existing emitter-mode behaviour that both triggers share. Trigger: the next emitter-mode touch, or one observed false pass in a replay.
- Same-entry pick vs handoff ordering (`off >= newest_write_off` at entry granularity): DEFERRED, existing behaviour, same trigger.
<!-- SECTION:NOTES:END -->
