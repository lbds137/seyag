---
id: TASK-277
title: 'worktree-gitfile-check: replace per-file wc/tr/dirname/basename forks with builtins'
status: To Do
assignee: []
created_date: '2026-11-28T17:49:44Z'
labels:
  - bin
  - faster-tests
  - security
dependencies: []
priority: medium
ordinal: 277000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while profiling FASTER TESTS 6/N (safe-worktree-clean-apply-hold probe), 2026-11-28 on 0.3.244. `plugins/seyag/bin/safe-worktree-clean` runs `bash worktree-gitfile-check` once per judged tree. Under `strace -f` across the whole apply-hold probe (147/147 ok), its 270 calls took 88 s of the tool's 231 s, about 38% (strace inflates wall time about 2.5x, so roughly 35 s real). Run alone on a clean fixture tree, one call takes 105 ms (mean of 20) and forks 23 processes: 9 wc, 5 realpath, 3 tr, 2 dirname, 2 basename, 1 find, 1 bash.

The 9 wc and 3 tr are the per-file size / NUL / line-count checks (`bytes=$(wc -c)`, `tr -d '\0' | wc -c`, `wc -l`), run on each file it reads. A candidate builtin form: under `LC_ALL=C`, `IFS= read -r -d '' -n 4097 x < file`. rc 0 with `${#x}` < 4097 means a NUL was found, `${#x}` = 4097 means oversize, and rc 1 means EOF with x the whole content, bytes = `${#x}` and lines = the count of `\n` in x. dirname/basename on realpath'd paths can become parameter expansions; root `/` and trailing-slash cases need checking. realpath -e/-m has no builtin equivalent and stays.

This is the guard that runs before any `git -C` into a tree, so it gets its own unit: an in-script profile first, every changed check pinned by tests/worktree-gitfile-check.probe.sh (a NUL-byte, an oversize and a multi-line gitfile at minimum), and a cross-family review.

Promote when: FASTER TESTS 6/N has merged (next in the series), or any PR that touches worktree-gitfile-check.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 per-call forks measured before and after (strace -f -e execve), with the 105 ms baseline re-measured
- [ ] #2 every refusal reason byte-identical; worktree-gitfile-check probe covers NUL, oversize, multi-line and empty gitfiles on both the old and new code
- [ ] #3 interleaved serial A/B of the apply-hold probe, at least 3 runs per arm, recorded in the PR
- [ ] #4 cross-family review before merge
<!-- AC:END -->
