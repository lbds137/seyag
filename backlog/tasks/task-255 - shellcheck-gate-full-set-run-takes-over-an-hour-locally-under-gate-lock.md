---
id: TASK-255
title: 'shellcheck-gate: full-set run takes over an hour locally under gate-lock'
status: Deferred
assignee: []
created_date: '2026-11-26T16:15:00Z'
labels:
  - bin
  - lane-b
dependencies: []
priority: high
ordinal: 255000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by a consumer session (2026-11-26), observed by that session, not reproduced here: a full-set `shellcheck-gate -S warning $(bash tests/shell-files.sh)` held the gate lock for over 60 minutes, twice in one morning. It was still advancing chunk by chunk through `xargs -n 20 -P 1 uvx --from shellcheck-py ...`. The same check runs in about a minute in CI, and 3 files take about 1 s locally without the lock. Gates queued behind it timed out, including another project's worker gates, which hit a 1 h print timeout.

Hypothesis (the reporter's, unmeasured): per-chunk `uvx` startup under load dominates.

Fix shape: measure first (time per chunk; `uvx` resolve versus shellcheck itself; the lock wait versus the run). Then cut the cost, e.g. resolve the shellcheck binary once and run chunks against it directly, or use bigger or parallel chunks within the memory gate. Record the before/after numbers here. Related: TASK-256 (gate-lock hold limit and holder report).

**Measured (Seyag A, 2026-11-26 ~11:20 local, load average 42 on 8 cores, no lock taken):** the hypothesis does not hold.
- `uvx --from shellcheck-py shellcheck --version` takes 0.26 s.
- One 20-file chunk takes 8.2 s with the resolved binary and 7.8 s through uvx.
- Full set, 231 files: 249 s one file at a time. Per 20-file chunk, as the gate runs it: 12 chunks, 4–29 s each (about 3 min in all), peak RSS 56–870 MB per chunk. The heaviest single file (`tests/claude-usage.probe.sh`) peaks at 761 MB and takes 12 s.

So shellcheck-gate itself costs about 3–4 min, not an hour. A likely confound: `fuser` on the lock lists the holder and every waiter alike, and a process's age includes its time in the queue, so an hour-old shellcheck-gate process may have spent most of that hour waiting. At 11:22 the real holder, read from `/proc/locks` (the entry without `->`; the pid shown can be an exited flock child, so map it through `fuser`), was a gate-lock running another project's full test suite, about 70 min old, with three waiters. Re-scope: the drag is the long suites serialized under one machine-wide lock, which TASK-256 covers. What is left here: confirm, at the next report, whether any shellcheck-gate run held (not waited on) the lock for more than ~10 min. If none did, close this as obsolete with these numbers.

Counter data point (the machine-management session's 11:07 read; the holder mapping is its inference from pid adjacency, not checked): the `/proc/locks` holder was an exited flock child, probably of a gate-lock whose shellcheck child had then been running for 28 min, after about 50 min of waiting. If that mapping is right, one shellcheck phase did hold the lock for 28+ min, against 3 min unlocked. A candidate cause is swap pressure (about 6.8 GB of swap in use that morning). Before closing, reproduce under memory pressure, or time the next real run's shellcheck phase while it holds the lock.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Deferred, not obsolete (Seyag B, 2026-11-26). The 28-min counter data point has not been ruled out. The TASK-256 PR gives the trigger: gate-lock now writes a holder record, and a waiter prints the holder's label (`shellcheck-gate`) and hold age. shellcheck-gate also now runs on the light lock, after a memory bar of floor + its 874 MB peak, so it no longer starts under swap pressure. Promote this task when a waiter's line shows a `shellcheck-gate` holder held for more than ~10 min. Close it as obsolete if a week of fleet runs shows none.
<!-- SECTION:NOTES:END -->
