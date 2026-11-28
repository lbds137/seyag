---
id: TASK-274
title: 'pr-body-ref-gate: --check mode promises a retry it never grants'
status: To Do
assignee: []
created_date: '2026-11-28T15:20:00Z'
labels:
  - hooks
  - pr
dependencies: []
priority: low
ordinal: 274000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-28 opening PR #473 through `pr-open`. The claim-scan block prints "A retry proceeds once this body's text is unchanged, within the same UTC day." (plugins/seyag/hooks/pr-body-ref-gate.sh:1212-1213 on befdbe1) in every mode, but `--check` deliberately never reads or writes ack state (:1116-1118). So `pr-open`'s preflight tells the reader a retry will pass, and the unchanged retry blocks again. Fix: print the retry sentence only when CHECK_MODE is 0; in check mode, say the preflight never acks and the lines must be cited or hedged. Then update the probe that pins the block text.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `--check` block output carries no retry-proceeds sentence and names cite-or-hedge as the only way through
- [ ] #2 Hook-mode block output is unchanged
<!-- AC:END -->
