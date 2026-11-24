---
id: TASK-57
title: 'session-log grep: fast prefilter, plus prompt-history and mined-corpus sources'
status: In Progress
assignee:
  - Seyag B
created_date: '2026-11-21T05:10:00Z'
updated_date: '2026-11-24T13:45:00Z'
labels:
  - session-log
  - owner-friction
  - peer-ask
dependencies: []
priority: high
ordinal: 57000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner friction (relayed by the machine-management session, 2026-11-20). An "I've raised this before" search went wrong: `session-log grep -i '<phrase>'` timed out at the Bash tool's 120 s over about 380 transcripts. The session fell back to ad-hoc rg over the project transcripts and wrongly told the owner "no record exists". The hit was in the prompt history (`${CLAUDE_CONFIG_DIR:-~/.claude}/history.jsonl`) and in the mined corpus, and session-log searches neither: its help says it reads top-level transcripts under the projects dir, an app export, and the mining ledger only.

Build:
1. Speed: a raw-bytes prefilter (rg/grep -l over the files, or a per-line substring check before json.loads) so only candidate files and lines are decoded. Measure before and after on the real ~380-transcript set; target well under the 120 s tool timeout, with the number stated.
2. Sources: add the prompt history and both mined-corpus roots (`~/.claude/mined-corpus/` and `~/.claude/projects/*/mined-corpus/`) as grep sources, each labelled in the output, each with a knob (env + config.toml) and a way to exclude it.
3. Then one core line in § "I've raised this before": name `session-log grep` as the one search to run, so the order is mechanical. Cut a line elsewhere first (core byte ceiling).
Probes: a hit only in history, a hit only in the corpus, the prefilter keeping results identical to the unfiltered run on a fixture, and a timing guard if one can be made non-flaky.
<!-- SECTION:DESCRIPTION:END -->
