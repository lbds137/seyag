---
id: TASK-198
title: >-
  claude-role #440 review lows: name=value path args to awk, check-to-open race,
  probe shim shebang
status: To Do
assignee: []
created_date: '2026-11-26T08:40:00Z'
labels:
  - claude-role
  - review-followup
dependencies: []
priority: low
ordinal: 198000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude review lows from PR #440 (TASK-178), which merged as bc30274 with verdict PASS.
(1) `--list` passes role paths to one awk process as bare arguments, and awk treats `identifier=value` as an assignment. With a relative SYG_ROLE_DIR such as `lane=b`, every path is consumed as an assignment and the list comes back empty with exit 0. That is the silent direction for fail-closed privacy pre-checks. Fix: prefix relative paths with `./` (or pass the list some other way), and add a probe case with a `x=y` directory.
(2) A file that vanishes between the -f/-r pre-check and awk opening it (for example, a concurrent --set archive rotation) still makes gawk fatal and drops the later rows with exit 0. Fix: in awk, skip unopenable files with a note (a BEGIN pre-pass over ARGV using getline < file), or catch awk's nonzero exit and fall back.
(3) The shims in tests/claude-role.probe.sh hardcode `#!/bin/bash`. Use `#!/usr/bin/env bash`, which is portable in a public repo.
<!-- SECTION:DESCRIPTION:END -->
