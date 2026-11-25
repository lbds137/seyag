---
id: TASK-150
title: 'scope-drift: follow-ups from the round-2 review'
status: To Do
assignee: []
created_date: '2026-11-25T00:45:00Z'
labels:
  - bin
  - tests
dependencies: []
priority: low
ordinal: 150000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Low findings from the cross-family re-review of scope-drift round 2 (TASK-74, VERDICT: PASS), deferred from that PR and collected here. None gives a false clean on bash >= 4.4.
1. Bash floor: `mapfile -d` and the `wait $!` process-substitution check need bash >= 4.4. Guard at the top (`BASH_VERSINFO`) with exit 2 and a named reason, so an older bash (macOS /bin/bash 3.2) refuses instead of reaching the check with a stale `$!`.
2. The `git ls-files failed` branch has no probe case: case 25's corrupt index makes `git diff` fail first. Find a fixture where only `ls-files` fails, or record why none exists.
3. The `--numstat` and `-U0` reads for a listed manifest are unchecked: a git failure prints `(+0 -0)` with no lines. The path stays listed and exit stays 1, so the count is misleading but nothing passes falsely. Check the status and print `?` counts.
4. Case 27 covers untracked nested manifests only; add a TRACKED nested manifest (`sub/dir/package.json` modified) through the `:(top,literal)` pathspec.
5. delegation SKILL.md fresh-review bullet: "...the spec never named, and on a routed lane..." can read as a fourth scope-drift item; a semicolon before "and on a routed lane" separates it. Optional: place the Scope drift bullet after "Check each reported deviation".
6. Known limit, documented in --help: `--exclude-standard` honours the user's global excludes and `.git/info/exclude`, so an untracked manifest matching one is not reported. Decide whether to drop the global excludes or keep it documented.

From the round-3 review (2026-11-24, Sonnet). The medium finding (shallow clone) and the low (base ahead of HEAD) were fixed in round 4.
7. Unborn HEAD (a repo with no commits): `--base REF` reports `shares no history with HEAD`, which is misleading. Detect an unborn HEAD and say so.
8. When `--base REF` is reduced to its fork point, the summary names only the fork sha. Consider `vs <sha> (fork point of REF)`; case 34 pins the current line.
9. delegation SKILL.md line 153: optionally note that any `--base` ref is reduced to its fork point.
10. Probe gaps: no case for REF == HEAD, and case 35 does not assert that stdout is empty.
<!-- SECTION:DESCRIPTION:END -->
