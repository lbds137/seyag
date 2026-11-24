---
id: TASK-136
title: 'core rules: cut asks the Autonomy rules say are not the owner''s (owner ruling 2026-11-23)'
status: Done
assignee:
  - Seyag
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
Requested by a coordinating session. The measurement covered 409 AskUserQuestion asks over 7 days. A Sonnet judge re-read the 119 candidates and rated 32 as should-not-ask: 18 technical choices that already had a recommendation, 11 re-confirms and 3 tool probes. Another 26 were borderline. The figures and item ids are in that session's own task notes.

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
- [x] #1 core.md Autonomy carries ruling 1, net size not grown (cut elsewhere to pay for it)
- [x] #2 Items 2 and 3 each land as a rule line or are ruled out with the reason recorded here
- [x] #3 review-response's ASK clause is kept, narrowed or cut, with the reason recorded
<!-- AC:END -->

## Implementation Notes
<!-- SECTION:NOTES:BEGIN -->
Dispositions (0.3.222):
1. Ruling 1 landed in core.md § Autonomy, replacing the plan-mode sentence it subsumes; "taste" joins the owner's list there and in the formal-channel line. Paid for by cutting three sentences the new line or a neighbour already covers (Escalate's "no escalation" tail, Most-correct's "no speed-vs-correctness menus", the refresh line's framing clause). Net -10 bytes.
2. Shipped as a clause on the memory-gate sentence in § Other defaults: approved work a reaper or crash killed re-runs once the gate passes, unasked.
3. Shipped by narrowing § Safety's ask-first line: it names a local `git merge` in a rebase-only project and says merging a green PR through the repo's merge path (Dependabot included) needs no yes. That bare `git merge` item is the likeliest source of the "merging into main always needs your yes" misread; a repo whose merge path is a review workflow still merges through that workflow.
4. Narrowed, not cut, in the review-response skill (it lands as its own change in that skill's lane). The test-assertion Ask is kept: it rests on § Safety (a test is never changed just to get past it), and the measurement rated those asks borderline, not should-not-ask. The async-boundary Ask becomes a decided item with a required council or advisor second opinion, cited in the round report: the Ask's stated reason is that no test gate catches a wrong call, which is a correctness risk that ruling 1 routes to a second opinion rather than to the owner. External-contract changes stay an Ask (outside this task's measurement).
<!-- SECTION:NOTES:END -->
