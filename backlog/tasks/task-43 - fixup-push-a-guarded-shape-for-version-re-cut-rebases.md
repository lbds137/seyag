---
id: TASK-43
title: 'fixup-push: a guarded shape for version re-cut rebases'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-20T04:03:00Z'
updated_date: '2026-11-25T05:09:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: low
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
fixup-push refuses a release-collision re-cut with no guarded alternative: its squash shape proves new tree == old tree, its --onto-base shape proves patch-id-identical commit lists, and its remote check refuses a locally rewritten branch ("remote branch has commits not in local") — so rebasing a release branch onto a base that already took the same release number has no proof path and lands as an unsanctioned force push. Add a shape (e.g. --recut) proving the rewrite is exactly a rebase plus a re-cut: the non-release commits keep an ordered patch-id list identical to the pre-rebase list, and the only differing commit is the release/notes one, confined to the version file and the changelog. Observed 2026-11-19 (PR #355): re-cut 0.3.194 to 0.3.195 after #354 took the number; fixup-push refused both shapes and the push went out via --force-with-lease without a tool proof.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Closed by `fixup-push --resolved` (TASK-148 part b, Seyag B 11-25), not a separate `--recut`. #355's commits (`gh pr view 355 --json commits`) show the re-cut landed as a new commit ("release: re-cut as 0.3.195") on top of rebased commits that kept their subjects. So `--resolved` covers it: the conflicted version file and changelog print as re-review lines, and the re-cut commit rides along as a counted local-only commit.
<!-- SECTION:NOTES:END -->
