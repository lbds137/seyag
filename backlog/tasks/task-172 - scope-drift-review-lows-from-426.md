---
id: TASK-172
title: 'scope-drift: the #426 review lows'
status: In Progress
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
