---
id: TASK-172
title: 'scope-drift: the #426 review lows'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T13:08:00Z'
updated_date: '2026-11-25T14:16:51Z'
labels:
  - scope-drift
dependencies: []
priority: low
ordinal: 172000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #426's claude-review (2026-11-25, PASS, six lows), all deferred. Trigger: the next `plugins/seyag/bin/scope-drift` touch, or the next free lane-B slot.
1. Re-wrap the `usage()` manifests paragraph to about 95 columns.
2. Drop the doubled "shallow clone" in the shallow-clone warning, and update probe case 36 to match.
3. Add a comment that the `*.lock` pattern is a deliberate fail-safe catch-all.
4. Add manifests: `Directory.Packages.props`, `*.fsproj`, `*.vbproj`, `libs.versions.toml`.
5. Skip the `-U0` read when `binary=1` (nothing to read).
6. Probes: a binary lockfile with an untracked copy on disk; a binary non-lockfile manifest; a note on case 39 that it does not exercise the version compare.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-25 (Seyag B). All six shipped: (1) usage() manifests paragraph re-wrapped to 95 columns; (2) shallow warning reads `(or unrelated history)`, case 36 asserts the doubled text is gone; (3) comment above `manifest_globs` marks `*.lock` as a deliberate fail-safe catch-all; (4) `libs.versions.toml`, `*.fsproj`, `*.vbproj`, `Directory.Packages.props` added as non-lockfile manifests, case 48 extended to eight; (5) the `-U0` read is skipped when `binary=1`; (6) case 52 (index-deleted binary lockfile prints `(binary) [untracked copy on disk]`), case 53 (binary non-lockfile pom.xml prints `(binary)` and a logging fake git shows no `-U0` call), case 39 comment says it pins only the guard's position. Mutation: reverting (5) turns case 53 red. Council gpt-5.5 review: no defects; suggestions ruled out against the code (binary resets per path at the loop top, no `set -e`, `is_lockfile` already uses `${1##*/}`, `*.lock` breadth is deliberate).
<!-- SECTION:NOTES:END -->
