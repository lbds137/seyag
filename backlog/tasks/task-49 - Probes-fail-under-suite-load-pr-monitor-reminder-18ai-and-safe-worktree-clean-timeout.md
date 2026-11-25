---
id: TASK-49
title: >-
  Probes fail under suite load: pr-monitor-reminder 18ai and safe-worktree-clean
  timeout
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-21T02:47:00Z'
updated_date: '2026-11-25T14:18:24Z'
labels:
  - probes
  - flake
dependencies: []
priority: medium
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full gate on the 0.3.198 branch (2026-11-20, swap ~5.5 GB) failed two probes this branch does not touch, both pass run alone: pr-monitor-reminder case 18ai ('git push origin feat-y:@' banner rev refs/heads/main) failed only under -j 4; safe-worktree-clean hit the run-probes timeout (exit 124) and took 4m17s alone vs 123.9 s in probe-durations.tsv. Find what in 18ai depends on timing or shared state, and whether safe-worktree-clean's timeout or duration needs revisiting (or splitting).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-30 profiled tests/safe-worktree-clean.probe.sh as the shellcheck memory outlier (~3.7 GB); its runtime under load may share a cause.

2026-11-24 (Seyag B): timed out (exit 124 at the 600 s cap) in `bash tests/run-probes.sh -j 4` on worktree-agent-b82 rebased on 9450989; alone right after, `timeout 600 bash tests/safe-worktree-clean.probe.sh` passed in 594 s, against 123.9 s recorded at tests/probe-durations.tsv:88. Not separated yet: probe regression vs machine load (other lanes ran suites concurrently). Next check: time it alone on an idle machine.

11-24: under run-probes -j 4 on a loaded machine safe-worktree-clean hit the 600 s cap (exit 124, lj-gate2); solo it took 353 s, rc 0.

11-24 again: lj-gate3 (-j 4) on #404 round 2 hit the 600 s cap (exit 124); solo rerun same tree rc=0 in 279 s.

11-24 (#404 rebased tree, -j 4): worker-sandbox 'wall knob live' failed at ms=2501 against its 2000 ms wall-clock limit (tests/worker-sandbox.probe.sh ~line 503, which times the whole sandboxed call, startup included); the solo rerun passed in 24 s total. Same load class; safe-worktree-clean hit the 600 s cap again (solo 325 s).

2026-11-24 evening (Seyag B), two more `-j 4` gates:
- bfix (PR #409): only safe-worktree-clean failed (exit 124). Alone it passed: 332 ok, 0 fail, real 5m16s.
- bscope (TASK-74): three probes failed: safe-worktree-clean (exit 124), `plugins/seyag/hooks/launch-record.probe.sh` case "1. unset dir", and `tests/worker-sandbox.probe.sh` "wall knob live" (rc=0, ms=2231, out=`192.0.2.1 error [Errno 113] No route to host`, ctl=`timed out`). Run alone in the same tree, launch-record passed (rc 0, 13 ok) and worker-sandbox passed (rc 0).
Both new failures look timing-dependent; that is an inference, not yet runtime-confirmed. launch-record case 1 and worker-sandbox's live wall check join this task's list of probes that fail only under load.
- bscope after the rebase onto f08ffa0 (PR #411): `plugins/seyag/hooks/dispatch-posture-gate.probe.sh` case "env unset + non-JSON stdin exits 0" exited 141 under `-j 4`, and passed alone (rc 0). Exit 141 is SIGPIPE: inferred, not traced. Fix shape: drain or ignore SIGPIPE in the probe's stdin writer, or have the hook consume stdin before an early exit. Not a retry.
- bknobs (scope-drift config follow-up), `-j 4`: 126/128. safe-worktree-clean exit 124 again, and `tests/long-job.probe.sh` "wait --poll running" failed. Its output held rc 4 and the `running` line, so the only assertion left at `tests/long-job.probe.sh:325` is the `$((SECONDS - s)) -le 2` timing bound (inferred from the message; the elapsed time was not printed). Alone in the same tree: 80 passed, 0 failed. Fix shape: print the elapsed seconds in the failure message, and widen the bound or measure only the `--poll` call itself.
- r225 release gate (#417, `-j 4` on fe4b5be, reported by lane A 2026-11-25): safe-worktree-clean exit 124 at the 600 s cap. Run alone right after, it passed (rc 0) in 455 s real. Compare 123.9 s at `tests/probe-durations.tsv:88` and earlier solo runs of 279-353 s. That points to a probe-time regression and not only load, but this is inferred, not separated, since other lanes may have been running suites. Next step: time the probe solo on an idle machine at fe4b5be and at an older ref, then bisect if it is slower.

2026-11-25 (Seyag B, claimed). Measured with one wrapper (bash `time`, a timestamp per output line) on a near-idle machine (load ~2):
- safe-worktree-clean alone at e58b8a9: 226 s real (user 98, sys 120), 332 ok, rc 0. At 45682db (the 11-10 ref that recorded 123.9 s): 138.7 s, 250 ok. Time grew 65% from 33% more checks and about 23% more per check; the new checks are the heavier multi-repo sweeps. That reads as growth, not a tool regression (inferred from the ratios; not profiled per case). No single hotspot: the largest gap is PM2(f) at 12.8 s, every other one under 9 s.
- Full `bash tests/run-probes.sh -j 4` with SYG_PROBE_TIMEOUT=1800 (this lane's suite plus one extra swc run): 128/128 green; safe-worktree-clean took 253.8 s, security-sweep 178.3 s was next. So `-j 4` alone stays far under 600 s. The recorded exit-124s line up with other sessions' suites running at the same time (inferred: solo runs on a busy machine took 279-594 s, per the notes above).
- Lane B disposition: split the swc probe at its section boundary (single-repo checks / the P1-P48 + PM sweep and apply-hold checks) through a sourced `tests/safe-worktree-clean-fixture.sh` (precedent: `tests/sandbox-capable.sh`). Drop the `-le 2` bound in `tests/long-job.probe.sh`: a --poll that blocked would die at `timeout 5` with rc 124, never 4. Drop `ms < 2000` in worker-sandbox 7c: the "No route to host" vs "timed out" contrast is the proof, and ms includes sandbox startup.
- Lane A (hook probes), specs sent to Seyag A 2026-11-25. 18ai, hypothesis: `hooks/pr-monitor-reminder.sh:618` gives a fake gh only `timeout 2`, which load can exceed (only the banner assert failed; from code reading, not runtime-confirmed). dispatch-posture-gate O9's 141 is a SIGPIPE race: the hook exits before reading stdin. launch-record case 1 needs RC and err printed before it can be diagnosed.
- Lane B part merged as #427 (793a167; claude-review PASS with three lows, filed as TASK-173; gate 129/129; council gpt-5.5 review, no defects; mutation parity 150 FAIL / 182 ok old vs split). The task stays In Progress until lane A lands or files the three hook items.
<!-- SECTION:NOTES:END -->
