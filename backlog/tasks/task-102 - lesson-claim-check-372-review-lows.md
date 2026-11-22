---
id: TASK-102
title: 'lesson-claim-check: #372 review lows (TASK-N filing credit, $(...) wording, surface regex, rule wording, import cost, consumer docstring)'
status: To Do
assignee: []
created_date: '2026-11-22T21:40:00Z'
labels:
  - stop-hook
dependencies: []
priority: low
ordinal: 102000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
These are the lows from the claude-review of #372 (TASK-58), which merged. The reviewer traced them by reading the code and did not run them, so reproduce each one before fixing it.

1. **Bare task-id filing credit.** In `DEFAULT_FILING_RE`, the `\bTASK-\d+\b` alternative credits a status SendMessage ("TASK-58 is merged, thanks") as a filing. That over-credits. Tighten it to a filing verb near the id, and pin both sides with probes.
2. **Recursion wording.** The docstring and header say "no recursion into `$(...)`", but `simple_commands` splits an unquoted `$(…)` at its parens, so the redirect inside it may still be seen. Either make the wording accurate or pin the case with a `bwt_check`, in whichever direction it really goes.
3. **Surface regex too broad.** `DEFAULT_SURFACE_RE` matches `.git/hooks/…`, `/tmp/hooks/…` and any `settings.json`, such as `.vscode/settings.json`. Consider excluding `.git/` and `/tmp/` and anchoring `settings.json` under `.claude/`.
4. **Rule stricter than the hook.** core.md says "an artifact named in that message", but the hook credits any same-turn surface write without checking that the message names it. Align the two, or state the gap in the hook header.
5. **Import cost.** Importing `turn_scan` loads all of `shell_quotes.py` (about 3,000 lines, no bytecode cache under `-B`) on every Stop, including for `promise-ledger-check`, which uses none of it. Import lazily inside `bash_write_targets` / `command_argvs`. Measure before and after.
6. **Stale consumer docstring.** The `shell_quotes.py` CONSUMERS entry for `lib/turn_scan.py` lists `substitution_spans` and `wrapped_command_strings`, which round 2 removed. Trim it to the real imports.
7. **Test gap.** Add `npx` / `npm exec` tracker-filing probes; only `pnpm` is pinned.
<!-- SECTION:DESCRIPTION:END -->
