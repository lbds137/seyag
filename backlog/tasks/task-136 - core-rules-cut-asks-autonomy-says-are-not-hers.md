---
id: TASK-136
title: 'core rules: cut asks the Autonomy rules say are not hers (owner ruling 2026-11-23)'
status: To Do
assignee: []
created_date: '2026-11-24T04:40:00Z'
labels:
  - rules
  - mining
dependencies: []
priority: high
ordinal: 136000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the fleet's platform session (its TASK-324). The measurement covered 409 AskUserQuestion asks over 7 days. A Sonnet judge re-read the 119 candidates and rated 32 as should-not-ask: 18 technical choices that already had a recommendation, 11 re-confirms and 3 tool probes. Another 26 were borderline. The figures and item ids are in that session's task notes.

Owner ruling, 2026-11-23 23:22 EST, the option picked on that session's ask: "Decide, report". The option text, which is the asking session's wording: "Pick the recommendation, say why in the report. When genuinely unsure, an optional council or advisor second opinion first, never a box to you. Product, spend, data and taste stay yours."

The changes to make, in generic wording, cutting before adding (core.md is always-loaded):
1. Autonomy: a technical choice that already has a recommendation is decided and reported, never asked. When unsure, an optional council or advisor second opinion comes first. This is the ruling above.
2. Approved work killed by a low-memory reaper or a crash is re-run once the memory gate passes, with no ask. Eight such asks were seen.
3. Merging a green PR, Dependabot included, needs no ratification from the owner where the repo's merge path allows it. One session claimed "merging into main always needs your explicit yes".
4. Weigh whether review-response's "ASK when it changes an async boundary or an existing test assertion" clause still earns its place under ruling 1. Seven asks it produced were rated purely engineering. This is a skill change, not core.md.

Related and already tracked: force-push `!` lines handed to the owner for squash/amend! rewrites are TASK-85 and TASK-43 (fixup-push shapes).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 core.md Autonomy carries ruling 1, net size not grown (cut elsewhere to pay for it)
- [ ] #2 Items 2 and 3 each land as a rule line or are ruled out with the reason recorded here
- [ ] #3 review-response's ASK clause is kept, narrowed or cut, with the reason recorded
<!-- AC:END -->
