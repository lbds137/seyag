---
id: TASK-140
title: 'claude-role: write handoff archives into an archive/ subfolder'
status: To Do
assignee: []
created_date: '2026-11-24T17:00:00Z'
labels:
  - claude-role
  - bin
dependencies: []
priority: medium
ordinal: 140000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by a coordinating session. When a role file passes the size cap, `claude-role` moves its oldest Handoff notes to `<stem>-handoff-archive-<YYYY-MM-DD>.md` beside the role file (`plugins/seyag/bin/claude-role:793`, documented at lines 41 and 163). These archives carry role frontmatter, so `claude-role --list` (line 255) lists them as roles: a retired-archive file shows as a second copy of its role.

Fix: write archives to an `archive/` subfolder beside the role file, keeping the same file name. This also lets a retention prune match one directory. A `--list` filter alone would fix the listing but not the pruning.

Owned by the bin lane (`plugins/seyag/bin/**`).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A cap-triggered archive lands at `<roles dir>/archive/<stem>-handoff-archive-<date>.md`, creating the folder if needed; the probe pins the path
- [ ] #2 `claude-role --list` never lists a file under `archive/`, and existing archives beside role files are either migrated or filtered out (decision recorded); the probe pins it
- [ ] #3 The help text (lines 41 and 163) and the session-start role instructions name the new location
<!-- AC:END -->
