---
id: TASK-96
title: 'session-log grep: #371 review lows (corpus stat race, tilde in corpus knob, history dedup role, per-entry hit, memory and chunksize)'
status: To Do
assignee: []
created_date: '2026-11-22T18:10:00Z'
labels:
  - session-mining
dependencies: []
priority: low
ordinal: 96000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
These are the low findings from the #371 review (verdict PASS), still open:

1. `corpus_files` (`os.lstat`) and `grep_tasks` (`os.stat`) do not catch `OSError`. A corpus file that is renamed away mid-walk crashes grep with a traceback. Fix: skip the file and warn, as `scan_file` does.
2. `SYG_SESSION_LOG_CORPUS` entries are not tilde-expanded. A `~/...` value set in an env file silently matches nothing. Fix: apply `os.path.expanduser` per entry.
3. The 2 s history dedup in `merge_grep` counts transcript hits of any role. Under `--role all`, a nearby agent or tool hit can hide a history hit. Fix: restrict `near` to hits whose role starts with `user`.
4. `_history_hits` can print two lines for one prompt (display plus a pasted body) while the tail counts it once. Fix: stop at the first match per entry, or document the behaviour.
5. `scan_file` reads the whole file, and `-i` adds a lowered copy. Peak memory per worker is therefore about 2× the largest file, with up to 4 workers. `ex.map` also runs with `chunksize=1` over thousands of small files. Measure streaming against whole-file reads, and try a chunksize.

Probes: one case each for items 1–4, plus a timing note for item 5.

Recorded here, not code: the #371 core.md edit also removed "and enumerate the parts if that helps" (§ Answer her questions first), and "task files" and "before replying" from the "raised this before" line. The PR body named only the net byte change.
<!-- SECTION:DESCRIPTION:END -->
