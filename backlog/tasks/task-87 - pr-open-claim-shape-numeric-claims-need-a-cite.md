---
id: TASK-87
title: 'pr-open claim-shape: numeric claims need a cite'
status: To Do
assignee: []
created_date: '2026-11-22T16:45:00Z'
labels:
  - pr
  - claims
dependencies: []
priority: high
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1115-13 (counts 56/37: items/sessions). A number in a PR body, such as a count, a duration or a size, needs a file:line or command cite, or a "not verified" hedge, like the other claim shapes the gate already checks.

Code: `plugins/seyag/hooks/lib/claim-shapes.sh` and `tests/pr-body-ref-gate.probe.sh`.

Shape (grounded 2026-11-24 at main 5d79a8f; re-verify cites first):
- Put the numeric shape in `CLAIM_SHAPE_PR_BODY_EXTRA_REGEX`, not CORE: CORE is also scanned against added code comments by pr-merge-review-check. CORE already catches some counted nouns (`N tests`, `N files`, `the N ...`).
- Match a number (decimals allowed, with or without a space) followed by a unit: durations (`ms`, `s`, `sec(onds)`, `min(utes)`, `h`, `hours`, `days`), sizes (`B`, `KB/MB/GB`, `KiB/MiB/GiB`, `bytes`), percentages (`N%`, anchored without a trailing `\b`), ratios (`Nx`, `N×`), and counted nouns CORE lacks (`cases`, `probes`, `lines`, `hits`, `rows`, `sessions`, `items`, `tokens`, `runs`, `transcripts`).
- Never match version strings, `#NNN` refs, dates, clock times, task ids or bare numbers.
- Decide whether `not re-measured` and `estimated` join the hedge vocabulary in `CLAIM_CITE_EXEMPT_REGEX`, or whether a prose source ("measured in the #371 commit body") must become a backticked command.
- Probe cases: block `Suite time drops from 135 s to 54 s.`, `Cuts the payload by 40%.`, `3x faster on the real set.`, `Scans 380 transcripts.`; pass a backticked-command cite, a `file:line` cite, a "not verified" hedge, and `Release 0.3.205.`, `Follows #371.`, `Merged 2026-11-24 at 13:50Z.`; pr-merge-review-check's probe stays green unchanged (proves CORE did not move).

Folded in (found 2026-11-24): `pr-body-ref-gate.sh` fails open when `--body-file` names a path built from a variable set earlier in the same command (the documented gap at `plugins/seyag/hooks/pr-body-ref-gate.sh:78-90`). PR #393 was opened that way, and rule 2 never scanned its body; `--check` on the same file blocks it (rc 2). Fix options: resolve `NAME=value` assignments made earlier in the same command, or fail closed (block with "body file not resolvable; use a literal path") when a `--body-file` path holds a `$` the hook cannot expand.
<!-- SECTION:DESCRIPTION:END -->
