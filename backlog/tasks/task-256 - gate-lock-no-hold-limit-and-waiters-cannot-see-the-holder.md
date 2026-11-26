---
id: TASK-256
title: 'gate-lock: no hold limit, and waiters cannot see the holder'
status: To Do
assignee: []
created_date: '2026-11-26T16:15:00Z'
labels:
  - bin
  - lane-b
dependencies: []
priority: high
ordinal: 256000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by a consumer session (2026-11-26) after one holder kept the gate lock for over 72 minutes while other gates queued behind it (see TASK-255 for why that run was slow). There are two gaps:

1. **No hold limit.** A holder can keep the lock indefinitely, and waiters time out instead. Decide on a cap (configurable by env), and on what happens at the cap: warn the waiters, or let a waiter break the lock once the holder is past the cap. Breaking a live holder's lock is a design decision; record it here.
2. **Waiters get no report of who holds the lock.** The reporter had to use `fuser -v` on the lock file plus `/proc/PID/cwd` to find the holder. A waiter should print the holder's pid, cwd, command and age, e.g. from a holder record that gate-lock writes next to the lock on acquire.

Probes: a fixture holder that sleeps; a waiter must name it, and the cap behaviour must be pinned.

Update (2026-11-26): TASK-255's measurements show that shellcheck-gate needs about 3 min; the hour-long holds were other gates' full suites. `fuser` cannot tell a holder from a waiter (the true holder is the `/proc/locks` entry without `->`), so the holder report in gap 2 is what would have prevented the misdiagnosis. Priority raised to high: the machine-management session reports this lock queue as the biggest drag on the fleet's throughput. A third gap worth deciding here: whether long suites should hold a machine-wide exclusive lock at all, or whether light gates (shellcheck, single probes) should get a separate lock or a shared mode, so they don't queue behind 50-minute suites.
<!-- SECTION:DESCRIPTION:END -->
