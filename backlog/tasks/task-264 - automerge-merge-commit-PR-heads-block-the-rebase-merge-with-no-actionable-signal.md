---
id: TASK-264
title: >-
  automerge: merge-commit PR heads block the rebase merge with no actionable
  signal
status: To Do
assignee: []
created_date: '2026-11-27T16:12:00Z'
updated_date: '2026-11-27T16:19:00Z'
labels:
  - ci
  - automerge
  - lane-a
dependencies: []
priority: low
ordinal: 264000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-11-27 on PR #457 (reported by the Deck Platform session, facts verified on their side). The repo is rebase-only (`gh api repos/lbds137/seyag --jq '{merge: .allow_merge_commit, squash: .allow_squash_merge}'` → both false), and the automerge job runs `gh pr merge --rebase`. When a PR branch resolves a conflict with origin/main by merging main in, the head carries a merge commit and GitHub refuses the rebase ("This branch can't be rebased") — automerge can never complete, and `fixup-push` also refuses such heads ("refused: merge commits in range"), so neither the job nor the tooling can consume the repaired head. The only recovery is a human rebuild: a linear branch cut from fresh main (what #460 is — #457 closed with the rationale).

Fix shapes to weigh (engineering call at pickup time, not all required):
1. The automerge job pre-checks rebaseability (or detects the merge-commit head) and fails early with an actionable message naming the linear-branch rebuild path.
2. A probe pins the behavior: a merge-commit head under an automerge watch produces the actionable failure, never a silent hang or a retry loop.
3. Optional: the pr-ci-wait watcher surfaces the unrebaseable state as its own sentinel rather than a generic timeout.

Also worth deciding deliberately: should PR branches ever merge main in when the automerge path expects linear heads, or should the convention be "cut a fresh branch" with the job's error message teaching it?

Owner: lane A (.github/workflows automerge job); `fixup-push` is bin/** (lane B) and relevant only as context for the refused-head shape. Priority low: one occurrence so far, recovery exists, and the failure is visible in CI rather than silent.

Pickup note 2026-11-27 (the Deck Platform session, which observed the case live on #457): weigh the pair "early failure in the job" + "pr-ci-wait unrebaseable sentinel" first; the supersession path (fresh linear branch, new PR, close old) is the verified no-force-push remedy, and #457's dropped-dispatch event self-healed on a synchronize push without a rerun.
<!-- SECTION:DESCRIPTION:END -->
