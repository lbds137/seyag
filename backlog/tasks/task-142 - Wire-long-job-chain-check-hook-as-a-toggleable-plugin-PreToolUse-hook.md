---
id: TASK-142
title: Wire long-job-chain-check --hook as a toggleable plugin PreToolUse hook
status: Done
assignee:
  - Seyag
created_date: '2026-11-24T17:52:00Z'
updated_date: '2026-11-26T03:31:00Z'
labels:
  - extraction
  - hooks
dependencies: []
priority: medium
ordinal: 142000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After TASK-141 ships long-job-chain-check, wire its --hook mode into hooks.json behind its own toggle (hook-wiring probe, replay-hook --since 7), so a machine no longer wires it by absolute path in settings. Trigger: TASK-141 merged.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Known gap to decide before wiring the hook as blocking (found in #404 round 2): long-job-chain-check folds $( … ) and backticks into one word and does not recurse, so 'x=$(long-job run x -- a && b)' is not refused although b runs at once outside the job (same as the original machine checker; the probe pins it as clean, tests/long-job-chain-check.probe.sh case 'folds $(...) into one word'). Fix: recurse into $( ) bodies like eval, then flip that probe case to refuse.

Second known gap (#404 round-3 review): heredoc bodies are parsed as commands. In cat <<'EOF' … EOF, or a gh pr create --body-file - heredoc quoting 'long-job run x -- a && b', the checker skips only the delimiter word and refuses on the body lines; long-job run itself also exits 2 when its parent Bash call holds such a heredoc. Same false-block class as TASK-146. Fix before wiring the hook as blocking: skip heredoc bodies (<<, <<- with quoted or bare delimiter) up to the delimiter line; probe both forms.

#404 final-review gaps (11-24): (1) `if long-job run … && …`, `while …` and `! long-job run … && …` are missed: shell keywords hide argv[0] from the chain check. (2) eval with several args re-joins the unquoted words, so the check sees a different argv than bash; note the limit in the docstring.

Claimed by Seyag (lane A) 2026-11-25. Touches B-owned plugins/seyag/bin/long-job-chain-check and its shared probe tests/long-job-chain-check.probe.sh (B told by SendMessage); bin/long-job's parent-command check inherits the fixes.

Shipped in 0.3.229: checker gaps fixed, hook long-job-chain-guard wired (component long-job-chain). Review dispositions: Sonnet fresh-context BLOCK (quadratic cost, hook exit-2 fail-closed) fixed in round 2; council gpt-6.2 quote-split regression fixed; deferred findings in TASK-189, 190, 192.
<!-- SECTION:NOTES:END -->
