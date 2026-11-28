---
id: TASK-121
title: 'handoff-pick-check part 2b: the "X is next, nothing started" trigger (deferred, measure-only)'
status: To Do
assignee:
  - Seyag
created_date: '2026-11-23T14:28:00Z'
updated_date: '2026-11-28T04:45:00Z'
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

Status 2026-11-26: part 2a shipped in 0.3.231, the prose-pick trigger (toggle `prose-pick`, override `SYG_PROSE_PICK_RE`). It blocks once when a no-handoff turn's closing text names `/clear` or `/compact` as a present pick and the turn ran no pick command. It defers while a background shell task is live and carries the obligation forward to the turn where that work ends.

Measured on local replays with `tests/replay-stop-hook.sh` and a prototype of the hook (counts of turn ends; text samples are not recorded here):
- A naive shape (a pick word anywhere in the closing text with no emitter call) tripped 442 turn ends in 7 days, about 20% of them real prose picks.
- The shipped per-sentence shape tripped 113 of those 442. About 109 were real prose picks or claimed-queued picks; 4 were forecasts or mentions. All 4 sentences from the originating incident trip.
- On a held-out week the shape was never tuned on (226 prototype trips), it matched 66: 64 real, and 2 forecasts with a claim word ("stands once/after X"; the claim branches don't check future markers).
- For scale, trigger (a) (a handoff written without the emitter call) blocked 426 times in the same 7 days, counted from the live "Stop hook feedback" entries in the logs: 280 edit-path writes, 120 command writes, 24 both, 2 neither.

Ruled in as accepted residuals, bounded by block-once: a forecast with a claim word or no future marker can fire; a negated pick ("/clear is not scheduled") can fire; `keep` named only in prose is not detected (too common as an ordinary word); the live-task exemption is blind to Monitor and async-Agent tasks (TASK-254).

Part 2b, the "X is next, nothing started" trigger: DEFERRED, measure-only. No precise shape found: closings that name a next unit while a background agent, CI run or worker is still going are the common case, and the prose-pick trigger now covers the incident shape that left sessions idle (a pick named but not run). Trigger: an observed idle where the closing named a next unit, ran no pick command and named no pick in prose.

Scope narrowed 2026-11-27 (owner priorities, relayed by Deck; triage pass 11-27): parts 1 and 2a are shipped, so this task now covers only part 2b, measure-only until the trigger above fires. The carried review lows below stay attached to it.

Review lows from the 0.3.231 council review (gpt-6.2-sol), carried to the next touch of this hook: a failed live-task lookup reads as "no live tasks"; a failed `.prose` marker write still fires; the regex is a keyword heuristic (negation, quoted examples).
<!-- SECTION:NOTES:END -->
