---
id: TASK-155
title: 'probe-red-check: accept the two-space `FAIL  <label>` format'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T03:50:00Z'
updated_date: '2026-11-25T06:42:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: medium
ordinal: 155000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
probe-red-check counts only `^FAIL:` lines (`plugins/seyag/bin/probe-red-check` `classify_base`: the `grep -c '^FAIL:'` count, the `FAIL:*` match for `--expect`, and the evidence echoes that grep `^FAIL:`). Probes that print `FAIL  <label>` (two spaces, e.g. `tests/scope-drift.probe.sh`) therefore read INCONCLUSIVE on a real red, or WRONG REASON with `--expect`.

Inventory (2026-11-24, `git grep -l -E 'FAIL  ' origin/main -- '*.probe.sh'`, positive control: scope-drift.probe.sh is listed): 32 probe files contain the two-space form; some build the line in a helper, so the count is of source files, not of emitted lines. 77 contain `FAIL:`.

Fix: accept both formats everywhere the bin reads a failing line, e.g. `^[[:space:]]*FAIL(:|[[:space:]]{2})`, in the count, the `--expect` match and the echoes; pin the two-space format in `tests/probe-red-check.probe.sh` (a red probe printing only `FAIL  label` reads RED, and `--expect label` matches it). Re-take the inventory with the fix's own regex over a freshly fetched tree before closing. Raised by lane A, 2026-11-24.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped: `FAIL_RE='^FAIL(:|  )'` at every site where the bin reads a failing line (the count, the `--expect` match, the echoes). It is anchored at column 0 on purpose, unlike the suggested `^[[:space:]]*`, because the bin indents its own evidence echoes with two spaces and no probe prints an indented FAIL line. A negative fixture case (`  FAIL:` indented, `FAILED`, `FAIL` with one space) pins that choice: those lines read as INCONCLUSIVE. Red-checked: the new probe cases fail against origin/main, where the old bin read the two-space line as INCONCLUSIVE. Inventory re-taken 2026-11-25 on a fresh fetch: 32 probe files contain `FAIL  ` and 107 match `FAIL(:|  )`. Council gpt-5.5 review found no blocker. Its other lows (helper functions, `grep -E --`, the `[ ][ ]` spelling) were ruled out as style with no behaviour change.
<!-- SECTION:NOTES:END -->
