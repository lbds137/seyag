---
id: TASK-77
title: 'architecture model: short intent map, generated structure snapshots, flow invariants, owned limits'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - architecture
  - skills
dependencies: []
priority: medium
ordinal: 77000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A skill and a small tool, per repo. It is shaped by a heavy consumer's report of what its existing tools miss: its boundary rules and byte-compared generated artifacts "never lied", while its long hand-written map was stale on arrival.

(a) **Intent map, kept short** (about 30 lines: component roles and main flows). It changes only with design decisions and carries an as-of line and a freshness check. Everything else is generated.

(b) **Generated structure snapshots**: module and boundary graph, public surfaces, dependency list. They are committed and byte-compared in CI, so a new surface is a one-line diff a reviewer must close.

(c) **Checked sequence invariants per flow** ("A must happen before B"). Structure tools can't express ordering. A real bug class, a check running after the step it should gate, got past every structural check.

(d) **Owned limits.** Any code comment that declares a known limit or "not verified" must cite a tracker id, enforced by a check. Unowned limits were re-fixed one probed shape at a time over three rounds.

(e) **A decision index per component**: each parameter or behaviour maps to the ruling that set it, with a link, so sessions stop re-deriving or reversing decisions.

(f) **A checkout-state probe for handoffs**:
- stale build outputs;
- generated code built from another branch;
- a shared checkout on another session's branch;
- a worktree removed mid-session.

(g) **Ties to TASK-74:** the scope-drift gate treats a snapshot diff as an architecture change that needs reviewer sign-off or an intent-map edit. Delegation specs and handoffs cite the map instead of re-describing structure.

Likely splits into one task per letter when it is promoted. (d) and (f) can ship first, since neither needs the map.
<!-- SECTION:DESCRIPTION:END -->
