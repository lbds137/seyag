---
id: TASK-279
title: 'backlog-md skill: rank within a priority bucket by ordinal'
status: To Do
assignee: []
created_date: '2026-11-28T18:06:24Z'
labels:
  - skills
dependencies: []
priority: medium
ordinal: 279000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by a peer session on 2026-11-28. Priority buckets (high/medium/low) are too coarse. Inside a bucket, sessions pick by habit or creation order, and the owner has no way to say "top of medium". backlog.md already carries a per-task `ordinal`, which the skill mentions only as CLI-owned (`plugins/seyag/skills/backlog-md/SKILL.md:59`). It auto-fills as id×1000, so today it encodes age, not rank.

Proposed convention for the skill:
1. Pick order is priority, then ordinal, then id.
2. A low ordinal is a deliberate rank, set when the owner places a task ("near the top of medium"), with her ruling quoted in the task notes.
3. New tasks keep the auto ordinal, i.e. the back of their bucket.
4. A session choosing its next unit lists with ordinal sort inside the chosen priority.

Unverified (the CLI was not on PATH when this was filed): the peer says `task edit --ordinal N` and `task list --sort ordinal` exist. Probe both with `--help` before writing them into the skill, as the command-blocks-are-code rule requires. tests/backlog-md.probe.sh reads this SKILL.md, so check what it pins before editing. Cut before adding: the skill is 9.2 KB.

Promote when: the next A-lane release batch after FASTER TESTS 6/N (alongside TASK-278), or the next PR that touches skills/backlog-md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 the CLI flags are verified with --help, and the skill's command lines are run once as written
- [ ] #2 the skill states the pick order, the meaning of a deliberate ordinal, and the default for new tasks
- [ ] #3 backlog-md probe green
- [ ] #4 the requesting session is told the version it shipped in
<!-- AC:END -->
