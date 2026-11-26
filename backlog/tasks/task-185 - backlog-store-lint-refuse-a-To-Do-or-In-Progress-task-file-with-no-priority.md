---
id: TASK-185
title: 'backlog store lint: refuse a To Do or In Progress task file with no priority'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T20:19:00Z'
updated_date: '2026-11-26T11:52:00Z'
labels:
  - bin
  - backlog
dependencies: []
priority: medium
ordinal: 184000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-72 (Seyag A). TASK-72 ships a PreToolUse guard (backlog-priority-guard) that blocks CLI creates and status moves leaving a task without a priority. It cannot see frontmatter hand-edited via Edit/Write or sed, nor task restore of an archived priority-less task. A store lint bin (B lane: plugins/seyag/bin) would catch the resulting file state. Note: wiring a store lint here also meets the CLAUDE.md condition that keeps the backlog-only direct-to-main path closed, so landing it is an owner decision on that path too.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Owner ruling 2026-11-26 (AskUserQuestion, "Open it"): once backlog-lint merges, the CLAUDE.md backlog-only direct-to-main path opens, with a local `backlog-lint` pass as the store-lint condition. The CLAUDE.md edit is lane A's (Seyag A); B messages A at merge. Shipped as plugins/seyag/bin/backlog-lint + tests/backlog-lint.probe.sh; case 10 pins the copied has_priority rule against hooks/backlog-priority-guard.sh (mutation-canary: caught), case 11 runs the lint on this repo store in CI.

Review (Sonnet, cross-family for the Gemini-authored code) lows: fixed summary-line split (unreadable vs priority), --store -h ordering, non-UTF-8 filename print, README probe-hermeticity wording. Ruled out: sharing has_priority via a lib (would edit lane A hooks; probe case 10 pins behaviour, mutation-canary caught a drift). Deferred, shared with backlog-priority-guard (change both together): BOM-prefixed frontmatter is skipped, an indented priority: inside a block scalar counts, a status with a trailing # comment never matches. backlog.md 1.55.3 writes none of these; trigger: a store file in one of those forms.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped in #441 (code af50fb3, merged 2026-11-26 10:37Z via automerge, claude-review PASS). backlog-lint refuses To Do / In Progress task files with no priority. Five review lows carried in the Seyag B role file Next, to ride the next backlog-lint PR.
<!-- SECTION:FINAL_SUMMARY:END -->
