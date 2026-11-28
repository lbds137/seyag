---
id: TASK-89
title: 'Edit not-found PostToolUse hint: re-Read the exact range'
status: Deferred
assignee: []
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-28T01:55:00Z'
labels:
  - hooks
dependencies: []
priority: high
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1115-16 (counts 39/30: items/sessions). After an Edit fails with string-not-found, a PostToolUse hint tells the session to re-Read the exact line range before retrying, instead of guessing the text again.
<!-- SECTION:DESCRIPTION:END -->

## Disposition

<!-- SECTION:NOTES:BEGIN -->
Deferred 2026-11-27 (Seyag); owner confirmed "Deferred" by AskUserQuestion 2026-11-27, over a core.md rule line or dropping it. No hook surface exists on Claude Code 2.1.332.

Probe, headless haiku in a scratch dir with `--settings` logging hooks (PreToolUse Edit, PostToolUse Read|Edit, PostToolUseFailure with no matcher):
- An Edit whose old_string is absent: the transcript shows `<tool_use_error>String to replace not found in file.\nString: …`. No hook fired: no PreToolUse, no PostToolUse, no PostToolUseFailure. Reproduced in 2 runs.
- Positive controls in the same settings: a successful Edit fired PreToolUse and PostToolUse; a Read of a missing file fired PostToolUseFailure.
- So the not-found rejection happens before the tool-hook pipeline. A PreToolUse hint on the retry Edit is also ruled out: a retry reaches the hook only when its old_string is found, which is exactly when no hint is needed.
- Not varied: other Edit validation errors (multiple matches, unread file).

Measured need, 7 days of transcripts, deduped by tool_use_id: 115 not-found Edits in 74 sessions. The next call on the same file was:

| Next call on the file | Count |
|---|---|
| Another Edit that failed again | 6 |
| A successful Edit | 59 |
| Bash | 26 |
| A Read | 21 |
| None | 3 |

Correction, same night: the first count (44 failed again, 52 ok, 12 Bash, 7 Read) also read the `api-request-blob` transcript entries, which replay earlier history. The owner's AskUserQuestion carried that wrong 44. The table above reads only `assistant`/`user` entries, deduped by tool_use id. The need is small: a blind re-guess follows about 1 in 19 not-found Edits.

Promotion trigger: Claude Code emits a hook event (PostToolUseFailure or a new one) for input-validation-rejected tool calls. Re-run the probe on each Claude Code minor bump that mentions hooks. A product-feedback draft is queued asking for that event. Built then: a PostToolUseFailure hint for Edit not-found, naming the line range nearest the old_string's first line.
<!-- SECTION:NOTES:END -->
