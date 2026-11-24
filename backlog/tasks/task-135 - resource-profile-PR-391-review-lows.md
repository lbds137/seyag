---
id: TASK-135
title: 'resource-profile: PR #391 review lows'
status: To Do
assignee: []
created_date: '2026-11-24T03:29:00Z'
labels:
  - tests
  - resource-profile
dependencies: []
priority: low
ordinal: 135000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Four lows from the claude-review on PR #391 (0.3.219, verdict PASS). 1) tests/resource-profile.probe.sh section 7: the two original --profile labels still name the old rule ("ceiling 3 < nproc 8", "ceiling 3 >= nproc 2"); relabel to 2*ceiling <= nproc wording. 2) No auto row with a ceiling between nproc/2 and nproc (e.g. auto ceiling 3 at nproc 5: was low, now normal); the SYG_MAX_PARALLEL=5/7 rows cover the branch but not auto directly. 3) Usage text: the "--help anywhere among the arguments" line sits at two-space indent and runs past the width the other rows keep; fold it into the --help row or wrap it like the print profile= continuation; the --profile line is also long. 4) CHANGELOG 0.3.219 Breaking Changes: the 0.3.218 correction note could read as a new break in 0.3.219; consider prefixing it "(no change in 0.3.219)". Ship with the next resource-profile touch or the next release batch.
<!-- SECTION:DESCRIPTION:END -->
