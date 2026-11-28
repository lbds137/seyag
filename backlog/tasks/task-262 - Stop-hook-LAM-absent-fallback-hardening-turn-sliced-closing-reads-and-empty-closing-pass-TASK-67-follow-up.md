---
id: TASK-262
title: >-
  Stop-hook LAM-absent fallback hardening: turn-sliced closing reads and
  empty-closing pass (TASK-67 follow-up)
status: Done
assignee:
  - Seyag
created_date: '2026-11-27T14:41:00Z'
updated_date: '2026-11-28T11:15:00Z'
labels:
  - hooks
dependencies: []
priority: medium
ordinal: 262000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-67 (header bounds) measured the LAM-absent fallback paths of the Stop hooks and landed bounds only; the hardening itself is this task, not widened into that PR. All paths here fire only when the Stop envelope's last_assistant_message is blank/absent (older Claude Code in the public audience; current CC carries the field, probed 2026-11-27).

1. promise-ledger-check: closing_text fallback (lib/turn_scan.py:101-112, fed the whole tail at promise-ledger-check.sh:156) can judge a PRIOR turn's closing when the current turn's closing prose is invisible (Anthropic-lane signed-empty-thinking recording, TASK-67) or absent. Turn-slice the fallback (pattern: handoff-pick-check.sh:289).
2. blocking-question-channel-check: same fallback shape (:153-158), same stale-tail FP (trailing '?' or pending marker on prior-turn text). Same turn-slice.
3. ask-command-echo-check: no empty-closing guard (:178-220) — blank LAM + invisible closing yields empty fenced list and blocks once demanding a repeat that was written. Add a deliberate empty-closing disposition (pass fail-open, or fail-closed on purpose) + probe row.
4. Probe rows per change with an est-shaped final entry fixture: content [{type:thinking,thinking:'',signature:'sig'}], no text block (fixture keys not key-shaped).
5. Measurement: est-conditioned replay attribution (replay trips cannot currently be attributed to the est shape); pre/post numbers per testing-discipline.

Evidence 2026-11-27: replay --since 7, LAM-absent worst case — recorded-file trips vs live blocks: promise-ledger 55 vs 1, blocking-question 57 vs 1, echo-check 8 vs 0 (correlative, not est-attributed). hooks/** is Seyag's lane; Seyag B's TASK-67 PR carries the header bounds with the cross-lane sanction note (A ruling 11-27).
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped by lane A (B parked) in 0.3.241 (#472). With last_assistant_message blank or absent, promise-ledger, lesson-claim and blocking-question read the current turn's last text after its last tool call (the whole tail only with no turn boundary in view); ask-command-echo-check passes a turn ending on signed-empty thinking (fail open, policy pinned by a probe row). Probe rows from the shared tests/stop-turn-fixture.sh go red on the pre-fix hooks and green after. replay-stop-hook now attributes each trip's closing shape.

Replay --since 7, pre (03:04) / post (04:38) 2026-11-28, trips/turn ends: promise-ledger 50/7761 -> 51/7832; blocking-question 169/7783 -> 167/7837; ask-command-echo 8/7800 -> 8/7844; lesson-claim 19/7817 -> 18/7856. Every trip in both runs is `closing: visible`: zero signed-empty closings in the window, so the est shape does not explain the 55-vs-1 recorded/live gap cited above. Measured effect of the fix: 3 false positives removed (blocking-question x2, lesson-claim x1), all turns cut off by compaction right after a tool result, where the old fallback judged earlier mid-turn narration. The one post-only promise-ledger trip is in a file written after the pre pass read it (new log content, inferred). Council review (gpt-5.5) found no correctness blocker; the signed-empty pass is kept on purpose (the closing is the unreadable entry). Follow-up filed: TASK-271 (handoff-pick-check, same fallback shape).
<!-- SECTION:FINAL_SUMMARY:END -->
