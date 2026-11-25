---
id: TASK-150
title: 'scope-drift: follow-ups from the round-2 review'
status: Done
assignee:
  - Seyag B
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
5. (Semicolon fixed in the lane-B knobs PR; the optional bullet move stays open.) delegation SKILL.md fresh-review bullet: "...the spec never named, and on a routed lane..." can read as a fourth scope-drift item; a semicolon before "and on a routed lane" separates it. Optional: place the Scope drift bullet after "Check each reported deviation".
6. Known limit, documented in --help: `--exclude-standard` honours the user's global excludes and `.git/info/exclude`, so an untracked manifest matching one is not reported. Decide whether to drop the global excludes or keep it documented.

From the round-3 review (2026-11-24, Sonnet). The medium finding (shallow clone) and the low (base ahead of HEAD) were fixed in round 4.
7. Unborn HEAD (a repo with no commits): `--base REF` reports `shares no history with HEAD`, which is misleading. Detect an unborn HEAD and say so.
8. When `--base REF` is reduced to its fork point, the summary names only the fork sha. Consider `vs <sha> (fork point of REF)`; case 34 pins the current line.
9. delegation SKILL.md line 153: optionally note that any `--base` ref is reduced to its fork point.
10. Probe gaps: no case for REF == HEAD, and case 35 does not assert that stdout is empty.

From the round-4 review (2026-11-24, Sonnet, PASS):
11. In a shallow repo, a truly unrelated REF also falls back to diffing against REF as given, so it produces a whole-tree out-of-scope list instead of exit 2. The two cases cannot be told apart there. Reword the warning to "no merge-base found (shallow clone, or unrelated history)" while keeping the `shallow clone: no merge-base` prefix that case 36 matches.
12. (Fixed in the lane-B knobs PR.) The "is ahead of HEAD" stderr note is not described in `--help` or the README row. Add one clause to each.
13. Case 36 should also assert that stderr lacks `shares no history`. Add a detached-HEAD or `--base HEAD` case asserting there is no ahead note (this overlaps item 10).

From #411's claude-review (2026-11-24, PASS, lows only). Its config-loading, exit-2 wording and semicolon lows were fixed in the lane-B knobs PR; the rest:
14. Glob wording: inside an entry that contains `*`, `[` and `?` are glob syntax too, but the README's "(`[` and `?` are not glob syntax)" note can read as covering every entry. Scope that note to exact entries, or escape them in glob entries.
15. The `## Files` heading match is case-sensitive and rejects a trailing ` (...)`; indented sub-bullets are ignored. Both fail safe (more drift reported, never less). Decide whether to loosen either.
16. A path deleted from the index but still on disk (untracked) shows as all-added.
17. The default base's "no base" error should mention a shallow clone as a possible cause.
18. The built-in manifest list misses pom.xml, Gradle files, *.csproj, deno.json/deno.lock, mix.exs/mix.lock, Package.swift/Package.resolved and go.work; `*.lock` files outside the list are never reported.
19. Strip a leading `./` from scope entries; today `./src/a.sh` never matches `src/a.sh`, so it reads as drift.

From #413's claude-review (2026-11-24, PASS, lows only):
20. `--help` and the README row don't say that SYG_SCOPE_DRIFT_MANIFESTS is also read from the user and project config files.
21. No probe case for the user config file (`$XDG_CONFIG_HOME/seyag/config.toml`).
22. Optional: one sentence noting that project config comes from CLAUDE_PROJECT_DIR/$PWD, not from `--worktree`.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
- Item 1: shipped (edit 1: bash >= 4.4 guard before any other code; `--help` exit-2 clause; probe case 39 static check).
- Item 2: shipped (case 42 uses a fake git on PATH that fails only `ls-files`; the fixture is not corrupt-index based).
- Item 3: shipped (edit 10: checked numstat and `-U0` reads; `(+? -?)` and `(git diff failed; lines not shown)`; cases 43).
- Item 4: shipped (case 44: tracked nested `sub/dir/package.json` through `:(top,literal)`).
- Item 5: ruled out: the optional move of the Scope drift bullet. Running the tool first and then checking each reported deviation is the right order.
- Item 6: ruled out as a change: global excludes kept (user-level ignores hide editor and OS junk that would otherwise list as out of scope on every run); documented in `--help` and the README row (edit 11).
- Item 7: shipped (edit 2: unborn-HEAD exit 2 with `HEAD has no commits yet`; case 40).
- Item 8: shipped (edit 5: `vs <sha> (fork point of REF)` on the clean and drift lines when the base is reduced; cases 34 and 37 updated).
- Item 9: shipped (edit 15: delegation SKILL.md Scope-drift bullet notes that any `--base` is reduced to its fork point; bullet not moved).
- Item 10: shipped (case 35 asserts empty stdout; case 41 covers `--base HEAD` and `--base $base` with no fork-point label and no ahead note).
- Item 11: shipped (edit 3: shallow warning reads `(shallow clone, or unrelated history)`, keeping the `shallow clone: no merge-base` prefix; case 36 asserts it).
- Item 12: already fixed (lane-B knobs PR): the ahead note is described in `--help` and the README row.
- Item 13: shipped (case 36 asserts stderr lacks `shares no history`; case 41 covers `--base HEAD` with no ahead note).
- Item 14: shipped (edit 13: glob note scoped to entries containing `*` in `--help` and the README row).
- Item 15: shipped, case-insensitive heading match only (edit 7; case 47). Ruled out: indented sub-bullets (they annotate the parent entry, so counting them would let prose widen scope), and a trailing parenthetical (`## Files (out of scope)` would turn a forbidden list into scope).
- Item 16: shipped (edit 9: a manifest in both the diff and the untracked list takes the git-diff branch and prints `[untracked copy on disk]`; case 45).
- Item 17: shipped (edit 4: no-base error names a missing remote or a shallow clone; case 50).
- Item 18: shipped (edit 8: manifest list and is_lockfile extended; case 48).
- Item 19: shipped (edit 6: leading `./` stripped from scope entries; case 46).
- Item 20: shipped (edit 12: `--help` and the README row say `SYG_SCOPE_DRIFT_MANIFESTS` is also read from the user and project config files; case 49 covers the user file).
- Item 21: shipped (case 49: user config file `syg_scope_drift_manifests`).
- Cross-family review (council, gpt-5.5, 2026-11-25): one fix taken — git numstat's `-<TAB>-` for a binary file was normalised to `(+0 -0)` (reads as no change; `bun.lockb` is in the list); tracked and untracked binaries now print `(binary)` (case 51). Ruled out: "a failed numstat/-U0 read can exit 0" (false: a listed manifest always makes exit 1); explicit-fd PID capture (same `wait $!` pattern as the file's other reads, correct on bash >= 4.4); malformed numstat validation and an unchecked `rev-parse --short` (git output for a verified sha and one literal path); multiple spaces after `##` and `../` entries (both fail safe: more drift, never a false clean).
- Item 22: shipped (edit 12: `--help` and the README row say the project file comes from `CLAUDE_PROJECT_DIR` (else the current directory), not `--worktree`).
<!-- SECTION:NOTES:END -->
