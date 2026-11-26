---
id: TASK-195
title: >-
  probe run leaves .cache/mise and .local/state in the worktree root; mise go
  resolve noise fails silence asserts
status: To Do
assignee: []
created_date: '2026-11-26T03:10:00Z'
labels:
  - probes
  - tests
dependencies: []
priority: medium
ordinal: 195000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-11-26 (Seyag B). A full `tests/run-probes.sh -j 4` in a linked worktree left untracked `.cache/mise/` (subdirs rclone, node, go, lockfiles, uv, aqua-*) and `.local/state/` in the worktree root, both timestamped 01:31, during that run; a later run in a sibling worktree left none. In the same run, `pr-merge-review-check.probe.sh` and `pr-merge-review-check-review.probe.sh` failed their "expected silence" asserts on stderr `mise WARN Failed to resolve tool version list for go: [~/.config/mise/config.toml] go@1.27: git ls-remote ... failed: exit code 64;git shim: unexpe...`; the same probe on main a few minutes later printed no mise warning. Inference, not yet confirmed: a probe runs a mise shim with an empty or relative HOME/XDG_CACHE_HOME, so mise uses a cwd-relative cache, finds it empty, and tries `git ls-remote` for the fuzzy `go = "1.27"` pin through the probe's git shim. Candidates (git grep for empty HOME): `pr-merge-review-check*.probe.sh:225-226` (`CASE_HOME=''`), `run.probe.sh:102,130` (`HOME=`), `route-check.probe.sh:126` (`env -i ... HOME=`). A quick repro (`HOME= XDG_CACHE_HOME= node --version` from an empty dir) created nothing, so the trigger is narrower. Fix shape: find the probe that writes the dirs (run each candidate with cwd in an empty dir and check for `.cache`), give it a temp HOME/XDG_CACHE_HOME (or MISE_CACHE_DIR), and add a suite-level check that run-probes leaves no new untracked dirs in the repo root.
<!-- SECTION:DESCRIPTION:END -->
