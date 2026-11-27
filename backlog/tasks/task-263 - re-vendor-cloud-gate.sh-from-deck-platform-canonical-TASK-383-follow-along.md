---
id: TASK-263
title: re-vendor cloud-gate.sh from deck-platform canonical (TASK-383 follow-along)
status: Done
assignee:
  - Seyag
created_date: '2026-11-27T15:52:00Z'
updated_date: '2026-11-27T17:51:00Z'
labels:
  - hooks
  - lane-a
dependencies: []
priority: medium
ordinal: 263000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Routed from Deck Platform B via Seyag B (2026-11-27), facts verified locally by Seyag B. Deck Platform B landed the canonical cloud-gate body on deck-platform origin/main (TASK-383 adoption). New deltas vs seyag's vendored copy: `--class implementation|test-only` judging (S3 ruling 2), seam precedence CLOUD_GATE_WEEK_STOP > stop_pct > 98, and the 16-hex body-sha256 header convention. Canonical body digest c24563808b610e7f (pinned as CLOUD_GATE_BODY_DIGEST in deck-platform bin/cloud-launch; the body ships on origin/usage-meter beside usage.json).

Verified by Seyag B 11-27: seyag's vendored .claude/hooks/cloud-gate.sh whole-file digest = 36a7aa9d575b15f5 (predates the new body — matches DP-B's claim); deck-platform bin/cloud-gate @ deck-platform origin/main carries the new markers (19 hits).

Task: re-copy the canonical body into seyag .claude/hooks/cloud-gate.sh, keeping the vendored copy byte-identical to the canonical body (assert by digest), and extend tests/cloud-gate.probe.sh to pin the 16-hex body-sha256 header convention. Source-of-truth order per DP-B: deck-platform bin/cloud-gate changes first, seyag copies after — if the copy surfaces a canonical-side gap, that goes back to Deck Platform B, not fixed here.

Owner: lane A (hooks/** + repo .claude/ wiring). Queue position: after the ft-envprint FASTER-TESTS PR lands (Seyag, 11-27).
<!-- SECTION:DESCRIPTION:END -->
