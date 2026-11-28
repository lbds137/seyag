---
id: TASK-17
title: 'session-link/prepush: net added links per diff instead of per line'
status: Done
assignee:
  - Seyag
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-28T01:35:00Z'
labels:
  - hooks
  - probes
  - owner-decision
dependencies: []
priority: high
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

Owner ruled 2026-11-19 (AUQ, the seyag session): net them - build the unit. Dispatch-ready; the design and probe list in this body are the spec skeleton.
<!-- SECTION:DESCRIPTION:END -->

## Disposition

<!-- SECTION:NOTES:BEGIN -->
Shipped in 4808e08 (0.3.185, 2026-11-18); this entry was left open. Checked 2026-11-27 against main: session-url-gate.sh passes `net_tokens` to lib/outbound.py, and lib/prepush_scan.py nets links per commit (`removed` counter in `_scan_lines`); private-term-guard unchanged (net_tokens is opt-in). All seven listed probes present: hooks/session-url-gate.probe.sh "edited line keeps its link", "edited line changes the link id", "push: commit A adds link, commit B edits that line keeping it" (names A, not B), "same file added in the same command blocks", "git mv of a committed file holding a link", "untouched link + unrelated edit"; hooks/private-term-guard.probe.sh "edited term line still names staged lines"; plus tests/git-hooks.probe.sh pre-push rows. Date oddity, not resolved: the commit is dated 2026-11-18, the entry's owner ruling 2026-11-19 (the ruling was recorded in 23d0c57; the ask may predate its record). It does not change Done: the code and probes are on main.
<!-- SECTION:NOTES:END -->
