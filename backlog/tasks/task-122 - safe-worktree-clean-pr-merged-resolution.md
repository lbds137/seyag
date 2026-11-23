---
id: TASK-122
title: 'safe-worktree-clean: resolve a tree whose HEAD is a merged PR''s head commit as pr-merged'
status: Done
assignee: []
created_date: '2026-11-23T16:15:00Z'
labels:
  - bin
  - worktrees
dependencies: []
priority: high
ordinal: 122000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Request from the machine-management session (2026-11-23), owner priority: worktree-removal asks reach the owner several times a day. In repos that rebase-merge or squash-merge, the base gets new SHAs, so a finished PR's worktree carries commits that nothing on the base points at. It is held as unmerged/refs, and the session asks.

- Add a resolution `pr-merged`. It applies when the tree's only commit-carrying hold reasons are unmerged/refs, the tree is clean and is no session's live cwd, and its HEAD equals the `headRefOid` of a PR the forge reports MERGED (`gh pr list --state merged --search <sha> --json number,headRefOid`). The backup is still taken. The forge call is optional and fails closed: with no gh or no network the tree stays HOLD.
- Make `pr-merged` part of the `--apply-eligible` default set, or put it behind an opt-in env the host sets.
- A repo that integrates on a non-default branch (for example `develop`) must be judged against that branch. Check that `SYG_WORKTREE_BASE` is honoured per repo in `--all` sweeps.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped as the reason code `pr-merged` in `safe-worktree-clean`. The check runs only for a tree whose reasons are all in the removable-by-approval set and include `unmerged` or `detached-unreferenced`. It makes one `gh api repos/<owner/repo>/commits/<sha>/pulls` call (20 s timeout, host from the base remote's URL) and matches only a PR whose `head.sha` equals the tree's full HEAD, whose `merged_at` is set and whose `base.ref` is the branch of the effective base (`--base`, then `SYG_WORKTREE_BASE`, then the origin default). An intermediate commit of a merged PR also returns the PR, so the exact head match is the load-bearing check. Every failure (no gh, non-zero exit, timeout, bad JSON, no match, a remote URL that is not a forge form) leaves the reasons exactly as judged, so the plan id does not churn. On a match the `unmerged` entry becomes `pr-merged`, and a `*-refs` reason is dropped when its tips are all ancestors of the merged head or of the base. `pr-merged` is approvable, not commit-carrying (the PR's head commit stays at the forge; the backup bundles it), and joins the `--apply-eligible` universe, opt-in through `SYG_WORKTREE_ELIGIBLE_REASONS`; nothing is eligible by default. New user-only knob `SYG_WORKTREE_PR_CHECK` (default on; 0 skips the lookup; 1 also prints lookup failures on stderr). Folded in the swc lows from the PR #313 review (L1-L7). The per-repo base finding for multi-repo sweeps went to TASK-126.
<!-- SECTION:NOTES:END -->
