---
id: TASK-278
title: 'security-sweep skill: asks by analogy quote sink and source beside the cited ruling'
status: To Do
assignee: []
created_date: '2026-11-28T17:56:50Z'
labels:
  - skills
  - security
dependencies: []
priority: medium
ordinal: 278000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by a peer session's CodeQL dismissal audit on 2026-11-28. An asked dismissal "under the same ruling as #N" was approved for an alert whose sink expression and taint source both differed from #N's. It was a real finding and was fixed days later. In `plugins/seyag/skills/security-sweep/SKILL.md` §2, the moved-copy checks (line 25) guard auto-dismissals against this, but item 2 (line 22, asked dismissals) has no matching check for an ask made by analogy.

Proposed line, next to the moved-copy checks: "An ask that extends an earlier ruling ("same as #N") shows the new alert's sink expression and taint source beside #N's, quoted as file:line on the default branch; any difference makes it a new alert, argued on its own evidence."

Optional companion for item 2: replace the category list "concrete evidence (e.g., unreachable path, test-only fixture, false positive)" with "the flagged line and the line that makes it safe (guard, clamp, build fact), quoted file:line".

No probe reads this SKILL.md (checked with git grep over tests/). It needs a PR, because the skill-file exemption does not apply. A wording pass may tighten the text.

Promote when: the next PR that touches skills/security-sweep, or the next A-lane release batch after FASTER TESTS 6/N.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 §2 carries the asks-by-analogy check (sink + source quoted file:line beside #N's; any difference = new alert)
- [ ] #2 the companion evidence wording is decided (adopted or ruled out with a reason)
- [ ] #3 the requesting session is told the version it shipped in
<!-- AC:END -->
