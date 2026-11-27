---
id: TASK-259
title: 'core.md: encode the lows-carry disposition'
status: Done
assignee:
  - Seyag A
created_date: '2026-11-26T22:37:00Z'
updated_date: '2026-11-27T00:23:00Z'
labels:
  - rules
dependencies: []
priority: high
ordinal: 259000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner ruling 2026-11-26: a low/nit PR-review finding is not filed as a task - it rides the next PR in the same area, carried until then as one line on the session's handoff surface (role-file Next or the project status file) naming the source PR, and listed in the fixing PR's body. Still filed as before: medium and above, anything user-visible, security- or data-touching, anything that cannot fit a same-area PR, and flaky-probe or incident findings. Before each PR, fold in easy low tasks from the same files/area under that PR's own review and gate, closing each citing the PR; never widen the PR into unrelated areas, never delay a high. Seyag A encodes it generically in rules/core.md; the review-response skill half is B's (spec by SendMessage). Rides on the same core.md touch: line 20 'spending' -> 'spend' (#397 review low 4); xfam #320 low 1 (fold-ledgers.md) - tighten the fresh-context-review line. Once shipped, propose deleting the memory (proposed to the owner 2026-11-26, at the merge).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
One PR: two core.md bullets in 'Fix what you touch, file what you find' + the two folds + version bump 0.3.234 + CHANGELOG section; agy gemini worker; cross-family fresh-context review; bash tests/run-probes.sh -j 4
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Done in two halves, both merged 2026-11-27. Seyag A's core.md half: PR #452 (merge commit e827009, release 0.3.234) — the lows-carry exception and pre-PR fold bullets in 'Fix what you touch, file what you find'; the ride-along folds verified landed: 'spend' at plugins/seyag/rules/core.md:10 and :20, the tightened fresh-context-review line at :43. Seyag B's skill half: PR #454 (merge commit cefc74d) — the lows-carry disposition in plugins/seyag/skills/review-response/SKILL.md, the pre-PR fold in plugins/seyag/skills/pr-monitoring/SKILL.md, five-section round report; its PASS round carried five wording lows, riding the next same-area PR per this task's own ruling. Memory-deletion proposal (feedback_review_lows_ride_next_pr) was made 2026-11-26 per this entry; delete on the owner's yes.
<!-- SECTION:NOTES:END -->
