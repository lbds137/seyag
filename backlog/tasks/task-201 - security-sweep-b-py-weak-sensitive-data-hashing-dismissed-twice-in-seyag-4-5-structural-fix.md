---
id: TASK-201
title: >-
  security-sweep (b): py/weak-sensitive-data-hashing dismissed twice in seyag
  (#4, #5) - structural fix
status: To Do
assignee:
  - Seyag B
created_date: '2026-11-26T13:54:00Z'
labels:
  - security
dependencies: []
priority: low
ordinal: 199000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-144 rule (b): a rule's second dismissal files a structural fix. Live `security-sweep --json` on this repo (2026-11-26) shows dismissed_by_rule {"py/weak-sensitive-data-hashing": 2}: alerts #4 and #5, both dismissed 2026-10-18 as false positive ("SHA-256 of a random high-entropy API key used only as a cache..."), path plugins/seyag/bin/api-credit; both now carry fixed_at (code moved/changed since).

Options in the skill's order: (1) not test-only, so no paths-ignore; (2) by-design sink: hash the key through a construct CodeQL does not treat as password hashing (e.g. hmac with a fixed label, or hashlib.blake2b keyed) or add a models-as-data barrier; (3) else record an accepted risk (won't fix). Check the current api-credit code first: if the hashing is gone, close as obsolete with the evidence.

Also seen in a consumer repo (not filed here): another rule dismissed 3x as won't fix in a legacy tree; that repo's own session owns it.
<!-- SECTION:DESCRIPTION:END -->
