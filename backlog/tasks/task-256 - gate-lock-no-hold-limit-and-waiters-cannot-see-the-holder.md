---
id: TASK-256
title: 'gate-lock: no hold limit, and waiters cannot see the holder'
status: Done
assignee:
  - Seyag B
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped by Seyag B in the TASK-256 PR (with TASK-186). Decisions, each with its reason:

1. **Hold cap: warn, never break.** `SYG_GATE_LOCK_HOLD_CAP_S` (default 3600, 0 = off) only appends `; past the hold cap (<cap>)` to a waiter's holder line. A waiter cannot release another process's flock; breaking the lock means killing another session's gate, which stays a human decision.
2. **Holder record inside the lock file.** `/proc/locks` names the exited `flock` child, not the holder, so on acquire gate-lock writes `key=value` lines (pid, /proc start time, pid namespace, since, label, command basename, directory basename) into the lock file itself (same inode, never `mv`) and truncates it on release. The record is readable inside sandboxes, so it carries basenames only; the full cwd is read live from `/proc/PID/cwd` by a waiter in the same pid namespace. Across namespaces the line says `unverified`; a dead pid says `stale record`; no record falls back to the open-fd list, labelled "holder or waiter; age includes queue time", which never fires the cap.
3. **Waiter report.** One blocking `flock` keeps queue order (a `flock -w` retry loop was measured to reorder waiters: started first, acquired last); a background reporter with the lock fd closed prints the holder every `SYG_GATE_LOCK_REPORT_S` (default 300, 0 = off) and exits when its gate-lock is gone.
4. **Light lock.** `SYG_GATE_LOCK_CLASS=light` (an env var, not a flag, so callers still work with an older gate-lock on PATH) queues on a derived lock (`X.lock` -> `X.light.lock`; `gate-lock --light-path` prints it), one light gate at a time, then waits until MemAvailable >= `SYG_MEM_GATE_MIN_MB` + `SYG_GATE_LOCK_PEAK_MB` (the gate's recorded peak), up to `SYG_GATE_LOCK_MEM_WAIT_S` (900 s), else exit 125. A light gate without a recorded peak runs as heavy, with a note. Inside a `long-job --heavy` unit the light lock is per job (`NAME@gate.light.lock`). These conditions are the machine-management session's (2026-11-26).
5. **shellcheck-gate is light**, with `SYG_SHELLCHECK_PEAK_MB` default 874. Measured 2026-11-26 on 233 files in 12 sequential 20-file chunks at load average 20–43: with -x, peak RSS 874 MB in 262 s; without -x, 853 MB in 244 s. So the bar is 2048 + 874 = 2922 MB. Re-measure when the file set grows.
<!-- SECTION:NOTES:END -->
