---
id: TASK-202
title: 'security-sweep: dismissal-history follow-ups from the PR 445 reviews'
status: To Do
assignee: []
created_date: '2026-11-26T18:40:00Z'
labels:
  - security
  - lane-b
dependencies: []
priority: low
ordinal: 202000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Low findings from the two review rounds of PR 445 (TASK-144, merged as fec3720). Two of them change what users see (2 and 3), so they are filed rather than carried to the next PR.

From round 2:
1. Docs overstate the history refetch. A fresh 300 s surface-cache hit serves the cached history too, not only `--session-line` and `--warm-cache`.
2. The history fallback on a fetch error has no age cap and prints nothing to stderr, so a stale "dismissals outrun fixes" suffix can last indefinitely while fetches keep failing. Cap the fallback's age, or say so on stderr.
3. There is no toggle for the outrun suffix on the session line. The component-toggle rule wants one.
4. The closed-alert listing pages every closed alert and caches each one. Large repos need a cap, for example on the window or the page count.
5. `history_view` truncates the comment a second time. Drop the second truncation, or comment why it is there.

From round 1, carried until now:
6. The probe has no case for the stale fallback, a corrupt cached history, or history under `--cap`, and no mutation canary over the history code.
7. Cases H2 and H3 read the cache that H1's `--no-cache` run wrote, so the cases share state.
8. A stale-fallback cache rewrite keeps the old `fetched_at` with a fresh history. This is undocumented.
<!-- SECTION:DESCRIPTION:END -->
