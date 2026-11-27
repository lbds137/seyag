---
id: TASK-268
title: 're-vendor cloud-gate: test-only judges hard stop only (stop_pct chain is a burn-posture fossil, DP 11-27)'
status: Done
assignee:
  - Seyag
created_date: '2026-11-27T19:05:00Z'
labels:
  - hooks
  - lane-a
dependencies: []
priority: high
ordinal: 268000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-263 follow-along, relayed via Seyag B from DP-B and verified against deck-platform origin/main: upstream `bin/cloud-gate` changed on 11-27 — marker `78ef44b1974c194e` (full sha256 `78ef44b1974c194ee4313d607c21f50035609c98da6a3235f40f70e9e4b1b0d0`, = `CLOUD_GATE_BODY_DIGEST` in `bin/cloud-launch:98`). The test-only class now judges week_pct against the week hard stop only (`CLOUD_GATE_WEEK_STOP` > 98) and NEVER the usage reading's stop_pct: the old "hard stop = the reading's stop_pct" chain was built under the 11-24 burn posture whose stop_pct read 98, and a standing week's stop_pct 80 wrongly refused week 90 (F3, found by the 11-27 gate-order probe launches; DP `bin/cloud-gate:9-14` comment names the fossil). Seyag's vendored copy (PR #462, merged acd7a8c) predates this: re-copy the body under the seyag header, bump the probe's `want_digest` to `78ef44b1974c194e`, and rewrite the four seam cases to the new semantics — including pinning the F3 shape (extreme stop_pct must not judge test-only) as the regression the fossil fix landed for. Fast-follow PR (the vendoring PR is merged; nothing to rebase). No repo wiring beyond the hook file, no bump/CHANGELOG (repo-level `.claude/` precedent). Queued behind TASK-267's in-flight dispatches (one gemini worker at a time on this Deck's memory).
<!-- SECTION:DESCRIPTION:END -->

## Disposition

<!-- SECTION:NOTES:BEGIN -->
Shipped via #465 (48aedd5, automerge, 14/14 checks green at cf37eae): body re-vendored cmp-identical to deck-platform `f5382ec1` (marker `78ef44b1974c194e`), probe 52→57 assertions — fossil case inverted to the fleet-98 go pin, F3 red case, `week >= eff` boundaries (50/50, 98/98), stale-band cases folding the carried #462 low 2. agy gemini review PASS (no findings); claude-review PASS. Carried: 2 claude-review lows (negative greps — the reading's stop_pct must be absent from test-only output; the stale-under warning must be absent from stdout) ride the next cloud-gate-area PR with #462 lows 1 and 6. TASK-269 checked for a trivially same-area low this session: none (rules/Stop-hook area), stays To Do.
<!-- SECTION:NOTES:END -->
