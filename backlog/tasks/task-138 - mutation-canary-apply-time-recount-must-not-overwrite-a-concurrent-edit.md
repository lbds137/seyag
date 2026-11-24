---
id: TASK-138
title: 'mutation-canary: apply-time recount must not overwrite a concurrent edit (#395 review lows)'
status: To Do
assignee: []
created_date: '2026-11-24T15:30:00Z'
labels:
  - mutation-canary
dependencies: []
priority: low
ordinal: 138000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two lows from the PR #395 review, both on the apply-time recount path (`plugins/seyag/bin/mutation-canary`, the `py_rc -eq 4` branch).

1. If the target changes after the `.orig` backup but before the apply step reads it, the recount fails and the tool exits 2. Cleanup then runs the live restore, and with no `.mutant` yet it copies `.orig` over the target, which discards the edit the recount just detected. The window is narrow: an edit made during the baseline run is already in `.orig` (probe case 30). Intended fix, following the owner's 2026-11-24 ruling for the manual `--restore` path (refuse with exit 3 and keep the journal when later edits cannot be told apart): on rc 4, when the target differs from `.orig`, keep the journal and exit 3 instead of restoring.
2. The rc-4 message reads "old text occurs 0 times ... must be unique" when the text is gone. Say "not found at apply time" for the zero case.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 rc 4 exits 3, keeps the journal and leaves the target as edited; a probe case pins it (an injected edit between backup and apply, or a documented reason it can't be seamed)
- [ ] #2 the zero-count rc-4 message says "not found at apply time"; a probe case pins the text
<!-- AC:END -->
