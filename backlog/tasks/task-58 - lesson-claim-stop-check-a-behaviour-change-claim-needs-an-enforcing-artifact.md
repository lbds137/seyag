---
id: TASK-58
title: 'Lesson-claim Stop check: a behaviour-change claim needs an enforcing artifact'
status: To Do
assignee: []
created_date: '2026-11-21T05:20:00Z'
labels:
  - stop-hook
  - owner-friction
  - peer-ask
dependencies: []
priority: high
ordinal: 58000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner directive (relayed by the machine-management session, 2026-11-20). The owner: "this isn't the first time a Claude session said it learned a lesson despite that not being possible without written surviving artifacts and/or enforcement." A closing message claims a behaviour change ("lesson learned", "next time I'll", "I'll remember to", "going forward I'll", "won't happen again", "noted for the future"); a session keeps nothing across /clear, so the claim is false unless a surviving artifact enforces it. Today promise-ledger-check credits a role-file write as a ledger (its default path regex, plugins/seyag/hooks/promise-ledger-check.sh ~L123), so "lesson, now in my notes" passes.

Build, hook by fit: a Stop check (a sibling of promise-ledger-check, or a mode of it, with its own toggle) that fires on a first-person lesson or behaviour-change claim in the closing text. It passes only when the same turn wrote an enforcement surface (rules/, skills/, hooks/, a CLAUDE.md, settings) or filed a tracker item for one (a backlog create, or a SendMessage filing it with the owning session). Role files and memory notes do NOT count for this class. Block text: either build or file the rule, hook or skill now, or drop the claim and say plainly that nothing enforces it.
Plus one core sentence: a session never says it has learned something unless an artifact named in the same message enforces it. Cut a line elsewhere first (core byte ceiling).
Probes: claim plus only a role-file write → block; claim plus a hooks/ edit → pass; claim plus a tracker filing → pass; a past-tense quote ("a lesson from the incident doc") → pass. Enforcement-surface and phrase lists are knobs. Replay against 7 days of logs (tests/replay-stop-hook.sh --since 7) and sample the blocked set before shipping.
Queue: after TASK-57 unless the owner reorders.
<!-- SECTION:DESCRIPTION:END -->
