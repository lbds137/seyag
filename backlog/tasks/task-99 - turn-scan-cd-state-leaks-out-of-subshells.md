---
id: TASK-99
title: 'turn_scan: cd state leaks out of subshells'
status: Done
assignee: []
created_date: '2026-11-22T19:55:00Z'
labels:
  - stop-hook
priority: low
dependencies: []
ordinal: 99000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`turn_scan.bash_write_targets('(cd hooks; true); echo > x')` returns `['hooks/x']`, but the write lands outside `hooks/`, since the `cd` inside the subshell does not persist.

This is an over-credit, so it is a false pass for `lesson-claim-check.sh`: a write outside a surface can credit a surface.

The same class: an escaped `\>` (`echo \> hooks/x`) still reads as a redirect, because `strip_quoted_indexed` un-escapes it before redirect detection, and an unterminated quote falls back to the raw text.

These are rare, so they are deferred. Promote it if a replay or a review shows a real instance.

Obsolete after round 2: cd tracking removed; escaped or commented commands give no credit.
<!-- SECTION:DESCRIPTION:END -->
