---
id: TASK-160
title: >-
  long-job: display-name variable, slice/property passthrough on run, optional
  load wait (wrapper parity)
status: Done
assignee:
  - Seyag B
created_date: '2026-11-25T04:08:00Z'
updated_date: '2026-11-25T18:00:00Z'
labels:
  - long-job
  - feature
dependencies: []
priority: medium
ordinal: 152000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Generic ask from a deployment that wraps long-job: three mechanisms so a local wrapper can become a pure exec wrapper.

1. Display name: long-job hardcodes its own name in messages and hints ("long-job: ended: act on the result above", "run long-job wait NAME --poll", "long-job status"). A wrapper that execs the read verbs therefore changes the "<runner>: ended" sentinel its callers wake on, and the hints name the default state dir. Honour a display-name variable in every message and hint; reuse SYG_LONG_JOB_CMD, which long-job-chain-check already reads.
2. Slice / systemd property passthrough on `run`: `--slice NAME` and a repeatable `-p KEY=VALUE` passed to systemd-run, so a deployment can put plain jobs in a weighted slice with a memory backstop.
3. Load wait: optionally run `load-gate --wait` inside the unit after the memory wait (a flag, or as part of the --heavy port in TASK-145).

Why: without 2 and 3 wrapping regresses every job (slice placement, load wait); without 1, delegating only wait/status breaks the documented "<runner>: ended" wake rule. Until these ship the requester keeps run/wait/status local and uses only long-job-chain-check.

Owner: bin/** lane. Related: TASK-145 (--heavy port).

11-25 (Seyag): item 3 ships with TASK-145 (--heavy runs `load-gate --wait` after the memory wait); this task keeps items 1 and 2. Acceptance for item 2: a --heavy job never lands in a low-weight slice the caller set for plain jobs (heavy jobs run one at a time under the gate lock, and a low CPU weight starved suite timeouts upstream: 1829 s with 2 timeouts vs 672 s outside the slice, same tree).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-25 (Seyag B, claimed): items 1-2 (item 3 shipped with TASK-145). Shared probe: tests/long-job.probe.sh.

Shipped items 1-2 (b160 PR). Item 1: messages, hints, the log header, the inhibitor --who/--why and the in-unit wrapper's lines use the basename of SYG_LONG_JOB_CMD's first word (validated; else long-job); the wrapper takes it as its second argument through the --lock re-exec. usage() synopsis keeps long-job. Item 2: run --slice NAME (dropped with a stderr note under --heavy) and repeatable -p/--property KEY=VALUE; StandardInput/Output/Error refused (they carry the job's log) and Slice refused (would bypass the heavy drop). Decided: -p applies to --heavy too; the intended use is a memory backstop, and CPU weighting belongs in the slice. Probe: 106/106 with a live user manager; 11 new cases fail on origin/main's long-job. Council gpt-5.5 review: no defects; ruled out multi-line systemd-run failure prefixing (pre-existing shape; only the ended sentinel is a contract), --nice/--mem-max range checks (unchanged options; systemd rejects, recorded as exit 5), --property=KV form (no = forms in the parser), and the read throwaway '_'. knobs.tsv/config.md description shortened to fit the 220-char cap.
<!-- SECTION:NOTES:END -->
