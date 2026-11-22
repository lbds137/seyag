---
id: TASK-98
title: 'Stop hooks duplicating the turn-scan block: move to lib/turn_scan.py'
status: To Do
assignee: []
created_date: '2026-11-22T18:26:00Z'
labels:
  - stop-hook
  - refactor
dependencies: []
priority: low
ordinal: 98000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hooks under `plugins/seyag/hooks/` that still inline the `TAIL_BYTES` tail-read and `is_genuine_user` turn-bounding block (found with `grep -ln 'is_genuine_user\|TAIL_BYTES' plugins/seyag/hooks/*.sh`):

- `plugins/seyag/hooks/ask-command-echo-check.sh`
- `plugins/seyag/hooks/ask-pretext-guard.sh`
- `plugins/seyag/hooks/blocking-question-channel-check.sh`
- `plugins/seyag/hooks/handoff-pick-check.sh`
- `plugins/seyag/hooks/queued-message-receipt.sh` (matched `TAIL_BYTES=4000000`, though it scans `queue-operation` lines via `tail -c` + `jq` rather than Python `is_genuine_user`)

(`plugins/seyag/hooks/promise-ledger-check.sh` and `plugins/seyag/hooks/lesson-claim-check.sh` already use `plugins/seyag/hooks/lib/turn_scan.py` from TASK-58.)

Each Python-inlining hook should move onto `lib/turn_scan.py` (extending the helper where a hook filters `isSidechain`, `"Stop hook feedback:"`, or tracks record byte offsets) with its `.probe.sh` unchanged.
<!-- SECTION:DESCRIPTION:END -->
