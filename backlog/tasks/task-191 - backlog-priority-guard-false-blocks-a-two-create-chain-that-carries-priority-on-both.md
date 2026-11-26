---
id: TASK-191
title: >-
  backlog-priority-guard false-blocks a create quoted in single-quoted prose
  when a shell word or heredoc marker appears anywhere in the command
status: In Progress
assignee:
  - Seyag
created_date: '2026-11-26T01:24:00Z'
updated_date: '2026-11-26T08:15:00Z'
labels:
  - hooks
  - false-positive
dependencies: []
priority: high
ordinal: 190000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-11-25 (TASK-142 driver). Root cause (bisected 2026-11-26): the judged create was the `backlog task create … -d "…"` QUOTED inside a later `task edit --append-notes '…'` argument, not either real create. Those used `$B task create`, which the guard never judges at all (TASK-196). A shell word (bash/sh/eval) or a `<<` anywhere in the text, here in quoted prose, turns lib substitution_span_offsets to its documented fail-closed extract-everything path. On that path a word-start `#` inside single quotes desyncs its in_single_quotes flag. walk() then pairs the extracted prose span with the argv word that spells it, so the quoted create is judged as a live command.

Minimal: `echo 'bash runs'; backlog task edit 1 --append-notes 'x `backlog task create foo` y'`.

Fix shape: an opt-in on walk (default off) that drops a pending span whose opener the bash-words scanner (_scan) places inside a single-quoted region, never inside a heredoc body. Wrapper strings (bash -c, eval, pipe to a shell) are re-walked unquoted and stay judged.

Second sighting 2026-11-26: the claim edit carrying this description was itself blocked.
<!-- SECTION:DESCRIPTION:END -->
