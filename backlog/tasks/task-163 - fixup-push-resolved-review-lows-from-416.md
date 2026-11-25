---
id: TASK-163
title: 'fixup-push --resolved: the #416 review lows'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T06:30:00Z'
updated_date: '2026-11-25T11:18:00Z'
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
1. Probe the REFUSE side of the base-path skip: an intermediate commit puts non-base content into a base-only file and the tip restores it. Done: v18 (mutation canary: dropping the inter_set clause turns v18 red).
2. Give the `rem_commits` count mismatch its own refusal text instead of `git rev-list failed`. Done: "git listed N remote commit(s) where it counted K", pinned by v19 (git wrapper drops one line).
3. v16 and v17 should assert that the rebase actually conflicted (reuse the `setup_conflict_fixture` check), so they cannot pass vacuously. Done: one helper, conflict_rebase_onto_main, fails the case when the rebase does not conflict or --continue fails.
4. Put probe ids v13..v17 back in order. Done: v13..v19 in order.
5. The intermediate content of resolved files is not proven. Accepted: a resolved file's content is the resolution itself, and the tip check plus the overlap list put it in front of the re-review; recorded here so it is not re-raised.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Council review (gpt-5.5; cross-family lanes closed) found no correctness issue. Taken: the helper's `rebase --continue` is now checked. Ruled out, with reasons: a quoted wrapper heredoc (case aj uses the same unquoted form, and the inputs are a SHA range and a git path); trap cleanup for the wrapper dir (`$WORK` is already removed by the probe's EXIT trap); an over-cap `status_at` case (the existing "first status= write adds status_at" case covers it); `if/else` in place of `&& ok || bad` (that chain is the probe files' convention, and `ok` always returns 0).
<!-- SECTION:NOTES:END -->
