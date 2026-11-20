---
id: TASK-8
title: 'split-scout: rank directories as split candidates'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:59:00Z'
labels:
  - bin
  - skills
dependencies: []
priority: medium
ordinal: 8000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generic tool that ranks tool-directory trees as split candidates. Signals: size (non-test
lines, file count), 30-day churn, co-change coupling from git history (files changing
together across dirs = one hidden unit; same-dir files that never co-change = two units),
optional import fan-in/fan-out adapter (e.g. dependency-cruiser JSON), junk-drawer dirs
(utils/helpers/common) over a size threshold. Output: ranked table plus --json for briefing.
Top candidate goes to the owning repo's design session, never straight to a refactor.
Slot: after the mining asks-lens hands off. Design notes live in a private planning doc.

Needs owner: promote split-scout to a build unit? (parked since 2026-11-17; design notes in the private planning doc)

Owner ruled 2026-11-19 (AUQ): promote to a build unit. First stop is the owning repo's design session (this body's signals list is the input), never a direct refactor.
<!-- SECTION:DESCRIPTION:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-11-19T21:21:00Z

---

Design notes from the stood-down parallel session (2026-11-19, unclaimed-overlap run): no reusable churn/co-change code exists in the repo yet. Advisor spec items: nesting rule (show the deepest dir that explains the mass); unmeasured vs cohesive coupling (min support, longer coupling window); mass-commit cap; renames; a --now clock seam for the probe; flags only, no env knobs (python bins do not load config.toml, per TASK-4); positive-control against the 2026-11-17 baseline measurement in the machine's private planning doc (vendor-agnostic factory plan, section 5); a trigger line in design-boulder; leave TASK-30 (another session's in-progress claim) and the TASK-33 node_modules/pnpm-lock residue out of that unit PR.

---
<!-- COMMENTS:END -->
