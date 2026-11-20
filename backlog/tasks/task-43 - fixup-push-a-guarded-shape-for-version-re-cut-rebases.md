---
id: TASK-43
title: 'fixup-push: a guarded shape for version re-cut rebases'
status: To Do
assignee: []
created_date: '2026-11-20T04:03:00Z'
labels:
  - bin
  - tests
dependencies: []
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
fixup-push refuses a release-collision re-cut with no guarded alternative: its squash shape proves new tree == old tree, its --onto-base shape proves patch-id-identical commit lists, and its remote check refuses a locally rewritten branch ("remote branch has commits not in local") — so rebasing a release branch onto a base that already took the same release number has no proof path and lands as an unsanctioned force push. Add a shape (e.g. --recut) proving the rewrite is exactly a rebase plus a re-cut: the non-release commits keep an ordered patch-id list identical to the pre-rebase list, and the only differing commit is the release/notes one, confined to the version file and the changelog. Observed 2026-11-19 (PR #355): re-cut 0.3.194 to 0.3.195 after #354 took the number; fixup-push refused both shapes and the push went out via --force-with-lease without a tool proof.
<!-- SECTION:DESCRIPTION:END -->
