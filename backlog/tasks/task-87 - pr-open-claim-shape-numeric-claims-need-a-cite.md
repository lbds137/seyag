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

Owner: Seyag (lane A; the code is `plugins/seyag/hooks/lib/claim-shapes.sh` and the pr-body-ref-gate probe). Seyag B grounded it; its spec sits in the B clone's gitignored dispatch folder as `b87-spec-for-A.md`. Shape: numbers with units go in `CLAIM_SHAPE_PR_BODY_EXTRA_REGEX`, not CORE (CORE also scans code comments through pr-merge-review-check).

Folded in (found 2026-11-24 while grounding): `pr-body-ref-gate.sh` fails open when `--body-file` names a path built from a variable set earlier in the same command (the documented gap at `plugins/seyag/hooks/pr-body-ref-gate.sh:78-90`). PR #393 was opened that way, and rule 2 never scanned its body; `--check` on the same file blocks it (rc 2). The spec names two fix options.
<!-- SECTION:DESCRIPTION:END -->
