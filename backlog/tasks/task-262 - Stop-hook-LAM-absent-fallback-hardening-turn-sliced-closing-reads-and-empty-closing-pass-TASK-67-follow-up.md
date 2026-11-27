---
id: TASK-262
title: >-
  Stop-hook LAM-absent fallback hardening: turn-sliced closing reads and
  empty-closing pass (TASK-67 follow-up)
status: To Do
assignee: []
created_date: '2026-11-27T14:41:00Z'
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
