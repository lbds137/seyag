---
id: TASK-97
title: 'promise-ledger-check: Bash crediting counts read-only mentions with stderr redirects'
status: To Do
assignee: []
created_date: '2026-11-22T18:25:00Z'
labels:
  - stop-hook
dependencies: []
priority: medium
ordinal: 97000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`promise-ledger-check.sh`'s `BASH_WRITE_RE` matches `>>?` inside `2>&1` and `2>/dev/null`, so a read-only Bash mention of a ledger path with a stderr redirect credits as a filing.

Fix: switch `promise-ledger-check.sh` to `turn_scan.bash_write_targets` and add a probe case in `plugins/seyag/hooks/promise-ledger-check.probe.sh`. Found by the TASK-58 grounding.

Also: its `TRACKER_CLI_RE` scans the raw command, so `grep -rn "backlog task create" …` or a `git commit -m` mentioning it credits as a filing. Switch it to `lesson-claim-check.sh`'s `is_tracker_filing` over `turn_scan.command_argvs`, which checks command position after runner unwrap.
<!-- SECTION:DESCRIPTION:END -->
