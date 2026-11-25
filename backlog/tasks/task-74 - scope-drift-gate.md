---
id: TASK-74
title: 'delegation: scope-drift gate before landing a worker diff or PR'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-22T05:50:00Z'
updated_date: '2026-11-25T03:21:25Z'
labels:
  - delegation
  - review
dependencies: []
priority: high
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Before a worker diff or PR lands, list:
- changed manifest and lockfile entries (added or upgraded dependencies);
- changed paths outside the spec's `## Files in scope`.

Non-empty output needs either a named reviewer sign-off line or a spec amendment.

Shape:
- a plugin bin, `scope-drift --spec FILE [--base SHA] [--worktree DIR]`, that prints both lists and exits non-zero when either is non-empty;
- a delegation-skill step that runs it at the full-diff read;
- review briefs gain one line: "check scope drift: new deps, out-of-scope files, interface/data-model changes not in the spec".

Covers the common ecosystems' manifests (package.json, pnpm/npm/yarn locks, pyproject/uv/requirements, Cargo, go.mod), each behind a table the project can extend.

TASK-77(g) adds generated structure-snapshot diffs as a third list.
<!-- SECTION:DESCRIPTION:END -->

## Notes

Shipped in #411 (bin, probe, delegation-skill step, review-brief line). The review lows went into the next lane-B PR: config loading, the exit-2 wording and the skill semicolon were fixed there, and the rest are on TASK-150. The structure-snapshot list stays with TASK-77(g).
