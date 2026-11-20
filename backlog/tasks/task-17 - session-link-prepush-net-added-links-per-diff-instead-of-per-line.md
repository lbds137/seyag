---
id: TASK-17
title: 'session-link/prepush: net added links per diff instead of per line'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - hooks
  - probes
  - owner-decision
dependencies: []
priority: medium
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A link on a '+' line that the same diff also removes (same full token, by count) is not
NET-NEW and should not block: net at the session-link layer only (the private-term guard
shares the outbound scan and must stay unchanged). Per diff call on commit; per commit on
push — never across the pushed range (a link added in unpushed commit A and edited in B must
still block on A). All three scanners change together; merge-diff scans keep current
behavior. Probes: same link on an edited line passes; a changed id blocks; A-then-B push
blocks naming A; a new untracked file blocks; a private term on an edited line is unchanged;
a file move passes via per-commit netting; untouched link plus unrelated edit passes.

This relaxes a secret guard: ask the owner before dispatching the implementation.

Needs owner: may the session-url scanner net added links per diff (a link the same diff removes is not new)? It relaxes a secret guard; the design and probe list in this body are the recommendation.
<!-- SECTION:DESCRIPTION:END -->
