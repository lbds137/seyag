---
id: TASK-101
title: 'Testing-discipline skill: measure-then-fix suite performance, plus a test-writing checklist'
status: To Do
assignee: []
created_date: '2026-11-22T20:40:00Z'
labels:
  - skill
  - owner-ask
priority: high
dependencies: []
ordinal: 101000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner ask, for every project, relayed by the machine-management session in its own paraphrase.

Why:
- Suites fight over the machine when several run at once.
- The owner has repeatedly asked "can we make these tests faster?", and the answer was that the tests were written inefficiently. She wants them written well in the first place.

Shape: a skill, generic and configurable.

1. **Measure-then-fix procedure.**
   - Before anyone says "it's slow": take the suite's wall time and its slowest-N tests.
   - Set a per-suite time budget and flag regressions against it.
   - Then fix in this order: shared fixtures over per-test setup, process isolation only where it is needed, no real sleeps or timeouts in unit tests (fake timers), and parallelism sized to the machine rather than set to max.
   - Record before and after numbers.
2. **A checklist for writing tests well.**
3. **A named trigger:** the suite runs over N minutes (a knob), the owner asks about speed, or a new suite or test file is written.

Source material is a mature private project's testing skill, guide, migration lessons and per-utility WHY docs. Draw on its lessons only. None of its names, paths or vocabulary go into this repo (public repo rule).

Out of scope: the machine-side half (a CPU gate so suites run one at a time). The machine-management session owns that.

Queue: after TASK-58 ships, ahead of TASK-61, as an owner ask. Spec it with the reuse-scout and eval skills in mind; the measurement step may be worth a bin helper. Decide that during spec.
<!-- SECTION:DESCRIPTION:END -->
