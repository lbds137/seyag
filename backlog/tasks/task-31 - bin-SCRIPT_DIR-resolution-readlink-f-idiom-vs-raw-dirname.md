---
id: TASK-31
title: 'bin SCRIPT_DIR resolution: readlink -f idiom vs raw dirname'
status: To Do
assignee: []
created_date: '2026-11-19T18:03:00Z'
labels:
  - bin
dependencies: []
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Class sweep during b-shchk1 review (fable, 11-19): plugins/seyag/bin/shellcheck-gate needed readlink -f "${BASH_SOURCE[0]}" because a symlinked invocation resolves SCRIPT_DIR through the link and mis-derives the repo root (fable finding 1 trigger D). Five bin scripts already use the readlink -f idiom (classifier-denials, claude-role, claude-usage, driver-clone, safe-worktree-clean); three derive SCRIPT_DIR with raw cd dirname and would mis-resolve under the same symlinked invocation: bin/lines-check:145, bin/pr-closeout:40, bin/pr-open:79. Unbroken in practice today: PATH access goes through dev-docs bin wrappers that exec the real script by absolute path, so BASH_SOURCE is never a symlink. Trigger: next touch of any of the three scripts, or the next wrapper/symlink wiring change.
<!-- SECTION:DESCRIPTION:END -->
