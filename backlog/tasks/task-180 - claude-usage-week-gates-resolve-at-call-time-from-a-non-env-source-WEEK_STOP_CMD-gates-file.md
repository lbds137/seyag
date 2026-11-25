---
id: TASK-180
title: >-
  claude-usage: week gates resolve at call time from a non-env source
  (WEEK_STOP_CMD + gates file)
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-25T19:03:00Z'
updated_date: '2026-11-25T19:15:00Z'
labels:
  - claude-usage
dependencies: []
ordinal: 179000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ask from the machine's platform session, 11-25. A session's env is frozen at launch, so a stale inherited CLAUDE_USAGE_WEEK_RESERVE_CMD gives a wrong --posture reserve (fixture: posture source says 95/98, bare claude-usage --posture prints 75/80), and CLAUDE_USAGE_WEEK_STOP has no _CMD form, so the stop is always frozen. Shape (decided, Seyag B): (1) CLAUDE_USAGE_WEEK_STOP_CMD mirroring WEEK_RESERVE_CMD: integer 1-99 under the same 5 s timeout, wins the slot, static WEEK_STOP as fallback; (2) an optional gates file at ${XDG_CONFIG_HOME:-$HOME/.config}/claude-usage/gates (path overridable by a seyag config.toml knob, not env), an executable run per call under a 5 s timeout whose stdout is KEY=VALUE lines; only the gate keys (CLAUDE_USAGE_WEEK_RESERVE[_CMD], CLAUDE_USAGE_WEEK_STOP[_CMD], the ZAI reserve pair) are accepted, the others are reported and ignored; accepted keys override the inherited env for that call; a timeout or bad line falls back to env with a stderr note. Not sourced (no arbitrary env pollution, bounded time). (3) --help states each gate's source order (gates file > env _CMD > env static > default) and how an explicit override is expressed. Probe: the fixture repro (75/80 -> 95/98 via the gates file), timeout, rejected key, missing file.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Consumer requirement (platform session, 11-25): run the gates file with the inherited env visible (plain child of claude-usage, no env -i), so it can keep an explicit override and replace only known-stale defaults. Acceptance includes their fixture going from 75/80 to 95/98 in every arm. Reply to them with the merge sha.
<!-- SECTION:NOTES:END -->
