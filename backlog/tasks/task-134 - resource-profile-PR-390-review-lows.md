---
id: TASK-134
title: 'resource-profile: PR #390 review lows'
status: Done
assignee: []
created_date: '2026-11-24T02:04:00Z'
updated_date: '2026-11-24T02:26:00Z'
labels:
  - tests
  - resource-profile
dependencies: []
priority: low
ordinal: 134000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Six lows from the claude-review comment on PR #390 (TASK-123). 1) --profile semantics: low only reflects ceiling<nproc under auto; SYG_MAX_PARALLEL=1 alone prints normal, and Deck saw low at ceiling 7 < nproc 8, which reads like pressure. 2) source= follows the profile's origin, not the binding ceiling's knob. 3) run-probes.sh calls resource-profile even at -j 1. 4) -j over 9 digits (folded into TASK-133). 5) CHANGELOG 0.3.218 lists the SYG_MEM_GATE_MIN_MB host flag under Bug Fixes though it is behaviour-breaking for a repo that set it in project config: add a correction note in the next release. 6) --jobs --help exits 0: pin the --help-anywhere behaviour in the probe and the usage text.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped in 0.3.219. (1) --profile/profile= is low under SYG_RESOURCE_PROFILE=low or when any knob sets a ceiling with 2*ceiling <= nproc; (2) source= follows the binding ceiling knob (apply_ceiling records it; ties keep SYG_MAX_PARALLEL first), profile origin when no ceiling; (3) run-probes.sh calls resource-profile only for -j N > 1; (4) 9-digit -j cap (TASK-133); (5) CHANGELOG 0.3.219 Breaking Changes carries the SYG_MEM_GATE_MIN_MB host-flag correction note; (6) --help-anywhere documented in usage, --jobs --help (exit 0) and --jobs=--help (exit 2) pinned. Also committed the backlog.md 1.55.3 pnpm-lock.yaml (owner ruling 11-23).
<!-- SECTION:FINAL_SUMMARY:END -->
