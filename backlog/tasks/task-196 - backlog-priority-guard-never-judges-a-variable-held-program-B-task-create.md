---
id: TASK-196
title: backlog-priority-guard never judges a variable-held program ($B task create)
status: To Do
assignee: []
created_date: '2026-11-26T08:15:00Z'
updated_date: '2026-11-26T08:41:00Z'
labels:
  - hooks
  - false-negative
dependencies: []
priority: medium
ordinal: 194000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-26 while bisecting TASK-191. `B=node_modules/.bin/backlog; $B task create foo` exits 0 (unjudged) while `backlog task create foo` is blocked: cli_of compares argv[0]'s basename against PROGRAMS, and `$B` is never expanded, though shell_state tracks variable assignments. The header's ACCEPTED GAPS lists only argument words starting with $, not a variable-held program. Fix: resolve argv[0] through the walk's tracked vars when it is a bare `$NAME`/`${NAME}` with a known value (unknown value: allow, as today), with a probe fixture for both. Or, if ruled out, add the form to ACCEPTED GAPS.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Second form, same class: single-quoted text piped into a shell (printf %s 'npx backlog task create foo' | bash) is not judged. Measured at base 931edde: rc 0. Listed in the guard header's ACCEPTED GAPS since TASK-191.

Third form (TASK-191 review 4, execution-confirmed): `shell_quotes.wrapped_command_strings` does not know `$SHELL -c`, `$BASH -c`, a globbed shell path (`/bin/ba?h -c`), `source`/`.` reading `/dev/stdin <<<` or `<(…)`, or `flock F -c` (unconfirmed: `su -c`, `ash`/`mksh`/`fish -c`, `ssh host …`). A single-quoted `$(npx backlog task create foo)` run by one of them is rc 0 at base, and was rc 2 only when a shell word elsewhere armed extract-everything. Since TASK-191 a shell word inside a backlog create/edit argument no longer arms it, so `backlog task edit 1 -t 'bash'; $SHELL -c '$(npx backlog task create foo)'` went 2 → 0. PR 442 review round 1 narrowed this: any read of `$_`, `$0`, `$BASH`, `$SHELL` or a `${!…}` indirection now turns the prose discount off (`shell_quotes._SHELL_VALUE_READ`), so the decoy form of `$SHELL -c`/`$BASH -c` is rc 2 again; without a decoy they stay rc 0 as at base, and the globbed path, `source`, `flock -c` remain open with or without the decoy. Fix direction: add these wrapper shapes to `wrapped_command_strings`, each as a `run 2` probe row, with and without the decoy.
<!-- SECTION:NOTES:END -->
