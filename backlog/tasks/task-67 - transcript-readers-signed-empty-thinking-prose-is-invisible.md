---
id: TASK-67
title: >-
  Transcript readers: assistant prose recorded as signed empty thinking blocks
  is invisible
status: Done
assignee:
  - Seyag B
created_date: '2026-11-21T15:23:00Z'
updated_date: '2026-11-27T18:57:00Z'
labels:
  - hooks
  - transcripts
dependencies: []
priority: high
ordinal: 67000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Some assistant prose is recorded in the session transcript as a `thinking` block that has an empty `thinking` field and only a `signature`, with no `text` block. It was measured on 2026-11-21 over 2 days of main-lane logs:
- **Opus 5.5:** 858 of 9,908 messages have at least two thinking blocks and no text block. 3,067 messages have text.
- **Sonnet 5.5:** 22 of 1,830.
- **Haiku 5.5:** 1 of 328.
- **AskUserQuestion messages:** 23 of 143 have this shape.

The ask-pointer incident that motivated TASK-65 is one of them. Its `!` line was never readable from the transcript.

Every hook that reads assistant text from the transcript cannot see this prose and fails open. These include:
- `turn-end-shape-gate`
- `promise-ledger-check`
- `handoff-pick-check`
- `blocking-question-channel-check`
- `ask-command-echo-check`, in its text-after-ask fallback (the Stop envelope's `last_assistant_message` may still carry the text)
- `ask-pretext-guard`

To do:
1. Confirm the shape at runtime: write known prose, then check whether a record with the empty, signed thinking shape replaced it.
2. Measure each hook's miss rate with the replay tools.
3. Decide per hook whether `last_assistant_message`, or another source, can recover the text, and record each hook's bound in its header.

Done (2026-11-27, #458, merge 6df41e8): the premise inverted under measurement — the shape is redacted thinking (Anthropic-lane only), it coexists with a separate text entry per response, and the Stop envelope's `last_assistant_message` carries the prose verbatim on current Claude Code. Prose is not lost on the recorded shape; the residual blind spot is only the LAM-absent fallback path (older versions), bounded in all five hook headers. Fallback hardening filed as TASK-262. Review PASS (claude-review rounds 1-4; council r1); two header-wording lows carried to the TASK-262 header sweep.
<!-- SECTION:DESCRIPTION:END -->
