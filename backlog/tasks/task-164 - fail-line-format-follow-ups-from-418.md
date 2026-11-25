---
id: TASK-164
title: 'FAIL line format: the #418 review lows and the mutation-canary default'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T07:40:00Z'
updated_date: '2026-11-25T11:00:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: medium
ordinal: 164000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From #418's claude-review (2026-11-25, PASS, four lows). All four are taken in one PR:
1. `skills/delegation/SKILL.md` still described `--expect` as checking a `^FAIL:` line. Reworded.
2. `--both` had no two-space case. Added `red2sp` with `green2sp` under `--both`, which pins the indented "here FAIL" echo.
3. `mutation-canary` defaulted `--fail-pattern` to `^FAIL:`, the same bug class as TASK-155: a canary over one of the 32 two-space probes read INCONCLUSIVE instead of caught. The default is now `^FAIL(:|  )`, the same pattern probe-red-check uses, and a probe case runs a two-space probe with the default.
4. The fixture header in `tests/probe-red-check.probe.sh` said "three" new probes. The count is dropped.
Sweep: `git grep -n -E "\^FAIL|FAIL:\*|'FAIL:'"` over plugins and tests (non-probe files) found the two bins and the skill line. That sweep missed README.md. #420's review found it there, and `git grep -n -E '\^FAIL:' -- ':!*.probe.sh' ':!backlog/' ':!CHANGELOG.md'` turned up 2 README sites, both stale: the mutation-canary row's default, and the probe-red-check row, stale since #418. Both are fixed. Case 41 pins the `--fail-pattern '^FAIL:'` opt-out (inconclusive, exit 2).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Red-checked: mutation-canary case 40 fails at origin/main, where the old default read the two-space line as inconclusive (rc 2). Council gpt-5.5 review found no blocker. The contract it named is accepted and recorded here: under the default, a column-0 `FAIL  ` line is a failure label, so a probe must not print one as information. Checked 2026-11-25 over all 64 distinct emitting lines in the 32 probes: each one is a failure message (a fail helper, an `||` branch or an `else` branch), and none is informational. A caller who needs the old reading passes `--fail-pattern '^FAIL:'`. #420's review lows, taken with TASK-163: this `updated_date` had stayed at `created_date`, and the mutation-canary header's `--fail-pattern` line was long with mixed quoting; it is now one short line. The style lows (quote the pattern in the INCONCLUSIVE message, a validation helper, a shared default constant across the two bins) were ruled out: the message is pinned verbatim, and two bins do not justify a shared library.
<!-- SECTION:NOTES:END -->
