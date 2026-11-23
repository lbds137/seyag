---
id: TASK-125
title: 'handoff-pick-check stale-pick trigger: #384 review lows'
status: To Do
assignee: []
created_date: '2026-11-23T18:19:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 125000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the claude-review comment on PR #384 (the stale-pick trigger plus the `queued_command` fix), 7 lows, none blocking. Items 1 to 6 are code, probe and prose; item 7 was a PR-body note and needs no repo change.

1. **Coupling.** `stale_pick_verdict` imports `handback_tasks`, which calls `_main()` at import time with no `if __name__ == "__main__"` guard. "The import is safe today only because `HT_TRANSCRIPT` is popped first." If `_main` ever falls back to another env var or path, the import writes to stdout inside the VERDICT capture and every stop silently fails open. Fix: guard the module-level call behind `__main__` and have the gate's `-c` call `handback_tasks._main()` explicitly.
2. **`<bash-input>` skip.** In the walk back, `<bash-input>` entries are skipped like slash-command echoes, but `!cmd` bash-mode input is the owner typing at the session. Decide whether it counts as owner activity for the "no owner turn since" premise, and put a one-line comment on the choice (the replay found no false positives, so this is a judgment call).
3. **Probe the skip prefixes.** Case 8 probes only the `<command-name>` prefix; the `<local-command` and `<bash-input>` prefixes in `COMMAND_PREFIXES` have no probe, so a typo there would go unnoticed.
4. **Probe the order.** No case covers a notification turn that also writes a handoff (`newest_write_off` set). It must take the existing `missing:emitter` path, not the stale path; the code is right (the stale check runs only when `newest_write_off is None`) but nothing pins that order.
5. **`agents/implementer.md` fragment.** The sentence "The spec's verification list is a floor, not a ceiling. Never a command the spec marked…" is a fragment. The review suggests: "It never extends to a command the spec marked 'driver runs after the report', even the project's own suite."
6. **CHANGELOG category.** The stale-pick trigger is new blocking behaviour with its own component and toggle, so it fits `### Features`, not `### Improvements`. Fix in the next CHANGELOG touch (a note or a moved line; the 0.3.214 section is already released).
7. **PR body hygiene.** The PR description named private sessions or projects in a public repo. No repo change; keep public PR text to neutral labels.

Check each against the code before building (core: boards are snapshots).
<!-- SECTION:DESCRIPTION:END -->
