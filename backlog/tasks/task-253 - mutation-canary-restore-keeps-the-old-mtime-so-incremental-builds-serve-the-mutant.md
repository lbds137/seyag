---
id: TASK-253
title: >-
  mutation-canary: --patch restore keeps the old mtime, so incremental builds
  serve the mutant
status: To Do
assignee: []
created_date: '2026-11-26T15:20:00Z'
updated_date: '2026-11-27T15:19:00Z'
labels:
  - bin
  - lane-b
dependencies: []
priority: high
ordinal: 253000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by a consumer session via the machine-management session (2026-11-26). After a `--patch` run, the source file comes back byte-identical, but an mtime-based incremental build (`tsc -b`, and any build cache keyed on mtime) still serves the mutant. The restored source is older than the build output the mutant produced, so the build treats it as up to date. Observed by the consumer: the compiled file lacked the fix's token (0 matches) until a `touch` of the source and a rebuild (1 match). The next canary run on the same file then reported "baseline red".

Cause, from reading the code (not confirmed at runtime): `restore_targets` copies the original back with `cp -p`, which restores its pre-run mtime.

Fix shape: after a successful restore, set each restored file's mtime to now, so it is newer than any output built from the mutant. Keep the byte-identical check. Optionally, print one line warning that build caches may still hold the mutant. Probe: a fixture whose build step skips work on mtime (e.g. a `make` rule, or a CMD that compares mtimes) and that must rebuild after the restore.

Owner: lane B (bin/**). The consumer has a workaround (touch after restore), so this is not urgent.

Update 2026-11-27 (the machine-management session re-reported the same defect, apparently without connecting it to this entry): second consumer occurrence — 3 phantom test failures for ~80 min before the cause was traced (mutated emit left in the build output with a newer mtime than the restored source). Requested fix menu: rebuild, or delete the affected emit / tsbuildinfo, after restore — or at minimum warn that build outputs may be stale. Priority raised medium -> high: the touch workaround did not prevent this burn, and the fix is small.
<!-- SECTION:DESCRIPTION:END -->
