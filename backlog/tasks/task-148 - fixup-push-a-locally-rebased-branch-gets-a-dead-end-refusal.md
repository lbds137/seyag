---
id: TASK-148
title: 'fixup-push: a locally rebased branch gets a dead-end refusal'
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-24T23:26:00Z'
labels:
  - bins
dependencies: []
priority: medium
ordinal: 147000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 11-24 on #404 (lane A). I ran git rebase origin/main by hand, then fixup-push and fixup-push --onto-base both refused 'remote branch has commits not in local' (bin/fixup-push line ~228, merge-base --is-ancestor R OLD), although git cherry showed every remote commit patch-equivalent in local. Recovery needed an owner-approved git reset --hard to the pre-rebase head. Fix (pick one, B's lane): (a) when every commit in mb..R is patch-equivalent to one in local (git cherry), accept and push with the lease, proving it like --onto-base does; or (b) at minimum, the refusal names the cause and the recovery: 'local looks rebased already: fixup-push --onto-base does the rebase itself; start from the pre-rebase head (reflog)'. Probe case: a locally rebased branch with all patches equivalent.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Split (Seyag B 11-24): part (a), the patch-identical rebase shape, ships in this PR (spec bfix). Part (b), a conflict-resolved rebase: owner ruling 11-24 (AUQ) YES to an explicit `--resolved` flag. Proof: same subjects in the same order; every file outside the base's own change set byte-identical to the remote; the push lists the resolved files for re-review; pinned lease. It follows as its own unit after (a) merges and also closes TASK-43 (release re-cut).
<!-- SECTION:NOTES:END -->
