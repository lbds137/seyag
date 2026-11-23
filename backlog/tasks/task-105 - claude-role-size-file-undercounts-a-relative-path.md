---
id: TASK-105
title: 'claude-role --size --file undercounts a relative path'
status: To Do
assignee: []
created_date: '2026-11-22T23:20:00Z'
labels:
  - bin
  - peer-ask
dependencies: []
priority: low
ordinal: 105000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`claude-role --size --file` with a relative path undercounts against the session-start limit. The size line renders `{path}` as given (`plugins/seyag/bin/claude-role:161,171`, and `--file` is stored as given at line 276), while the SessionStart hook passes the absolute path, so the rendered text is shorter. Observed gap 41 chars (9896 vs 9937).

Fix: resolve `--file` to an absolute path before measuring.

Probe: relative and absolute `--file` on the same file report equal sizes.

Note: `claude-role` lives in this repo at `plugins/seyag/bin/claude-role`, so the fix lands here.
<!-- SECTION:DESCRIPTION:END -->
