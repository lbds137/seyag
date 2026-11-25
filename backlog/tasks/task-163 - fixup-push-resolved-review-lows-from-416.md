---
id: TASK-163
title: 'fixup-push --resolved: the #416 review lows'
status: To Do
assignee:
  - Seyag B
created_date: '2026-11-25T06:30:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: low
ordinal: 163000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #416's claude-review (2026-11-25, PASS, lows). Each item's disposition:
1. Probe the REFUSE side of the base-path skip: an intermediate commit puts non-base content into a base-only file and the tip restores it. To do.
2. Give the `rem_commits` count mismatch its own refusal text instead of `git rev-list failed`. To do.
3. v16 and v17 should assert that the rebase actually conflicted (reuse the `setup_conflict_fixture` check), so they cannot pass vacuously. To do.
4. Put probe ids v13..v17 back in order. To do.
5. The intermediate content of resolved files is not proven. Accepted: a resolved file's content is the resolution itself, and the tip check plus the overlap list put it in front of the re-review; recorded here so it is not re-raised.
<!-- SECTION:DESCRIPTION:END -->
