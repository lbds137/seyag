---
id: TASK-154
title: >-
  pr-merge-review-check: the open-quote fallback is not comment-aware; it drops
  numberless/selector merges and keeps a false block
status: To Do
assignee: []
created_date: '2026-11-25T02:25:00Z'
updated_date: '2026-11-25T02:49:00Z'
labels:
  - hooks
dependencies: []
priority: medium
ordinal: 151000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-146 review (driver-measured 11-24): extract()'s `strip_quoted` check does not skip `#` comments, so an apostrophe in a comment sends the command to legacy_scan. (1) Under-arm: `# it's ready\ngh pr merge --rebase` (numberless) and `# it's ready\ngh pr merge feature-x` (selector): scan_invocations resolves numberless/selector, but the fallback returns legacy_scan's result, which reports neither, so nothing is armed (base and fix alike). (2) False block: `# #406's PR\n` before lane B's TASK-146 command still arms #600. Design tension: the extract() docstring says fallback steps report no numberless or selector; decide whether a precise numberless/selector result should win over the legacy fallback.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Also from the TASK-146 round-2 review (low, not a regression: still blocked as unresolvable): `$(cat <<'EOF'\ngh pr merge -t it's 2002 ...\nEOF\n)` at command position. Base armed 2002 via legacy_scan; the fix flags it unresolvable and refuses. Also: two of the five round-1 probe cases pass through existing paths and never reach heredoc_bodies_inert (they pin, they do not prove the fix).
<!-- SECTION:NOTES:END -->
