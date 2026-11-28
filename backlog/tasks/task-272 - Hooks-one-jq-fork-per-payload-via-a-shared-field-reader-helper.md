---
id: TASK-272
title: 'Hooks: one jq fork per payload via a shared field-reader helper'
status: To Do
assignee: []
created_date: '2026-11-28T12:05:00Z'
labels:
  - hooks
  - performance
  - tests
dependencies: []
priority: medium
ordinal: 272000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-28 (FASTER TESTS prep, driver-side measurement on 14cdc20). 27 hooks parse the same $INPUT with 2-4 separate `$(jq ... <<<"$INPUT")` calls (grep `\$\(jq [^|]*<<<"\$INPUT"` over plugins/seyag/hooks/*.sh minus probes; 4: pr-monitor-reminder, ask-command-echo-check; 3: 15 hooks incl. recursive-rm-guard, private-term-guard, upstream-submission-guard; 2: 10 hooks). Two guards already do one fork with `@sh` assignments + eval (cwd-drift-guard.sh, live-checkout-guard.sh), and they carry the same copy-pasted `def s` normaliser (NUL drop, trailing-newline strip, tostring) for parity with `$()` reads.

Measured (load ~2, pycache prefix set): one jq call 5.6 ms; one recursive-rm-guard call 79 ms = ~17 ms bash+3 jq, ~24 ms python -I startup, ~19 ms lib imports (11 ms stdlib re), rest bash forks. Its probe: 464 cases, 45.2 s without prefix / 37.6 s with; collapsing its 3 jq to 1 projects ~5 s (~13%). Production: TASK-199 found hooks run in parallel (wall max 59 ms), so live sessions gain CPU, not latency; the main win is suite wall + CPU.

Shape: a sourced hooks/lib helper owning the `s` def and the one-fork read (fields named by the caller), the two existing guards moved onto it, then the 25 others migrated in batches. Each hook keeps its own fail-open shape (`|| exit 0` vs `|| VAR=""`) and its `// empty` semantics (a false value reads empty); parity is checked per hook by its existing probe plus a malformed-JSON and a non-string-field case. Sequence after ftpyc (FASTER TESTS 3/N), and fold pr-merge-review-check's review-field read (ftmrc spec step 3) onto the helper if it lands first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Shared helper in plugins/seyag/hooks/lib with the s normaliser defined once; cwd-drift-guard and live-checkout-guard use it
- [ ] #2 Every hook found by the grep reads its payload fields in one jq fork, or the task records why it cannot
- [ ] #3 Per-probe before/after wall times recorded for the migrated hooks (serial, prefix set), and the suite total
<!-- AC:END -->
