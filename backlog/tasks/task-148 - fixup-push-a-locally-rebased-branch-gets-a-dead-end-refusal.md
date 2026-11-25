---
id: TASK-148
title: 'fixup-push: a locally rebased branch gets a dead-end refusal'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-24T23:26:00Z'
updated_date: '2026-11-25T05:09:00Z'
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

Part (b) shipped (Seyag B 11-25, spec bfix2): `--resolved`, proving the ruled shape plus two stricter checks: every file only the base changed is byte-identical to the base, and every intermediate rebased commit changes only files in the base's or the branch's final change set (cross-family review finding: without it a file added in commit 1 and deleted in the tip would publish unseen). Without the flag the refusal now names `--resolved`.

#409 review lows: (1) remote merge-commit refusal probe: shipped (v11), with its own wording; (2) exit-4 "moved by another process" probe: shipped (v12); (3) separate wording for the merge-commit and empty-range refusals: shipped; (4) one `git log -p | git patch-id` pass per range: ruled out on merit. patch-id prints nothing for an empty-diff commit, so a batched pass silently drops it where the per-commit loop refuses, and the process-count gain is negligible at PR-branch sizes.
<!-- SECTION:NOTES:END -->
