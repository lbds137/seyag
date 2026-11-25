---
id: TASK-161
title: >-
  pr-merge-review-check: #412 review lows (variable-named shells, inert-path
  probes, single strip pass)
status: To Do
assignee: []
created_date: '2026-11-25T04:18:00Z'
labels:
  - hooks
  - pr-merge-review-check
dependencies: []
priority: low
ordinal: 153000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the claude-review of #412 (TASK-146, VERDICT PASS, all low):

1. Under-arm, not a regression: `"$SHELL" <<'EOF'\n# it's fine\ngh pr merge 2002\nEOF` (also "$BASH", $0, python3 <<EOF with os.system) has no interpreter word, so heredoc_bodies_inert() returns True and nothing arms. Base caught it only through the apostrophe; the apostrophe-free form was already missed. Candidate fix: count any $-expanded word in command position as an interpreter (and consider python/perl/ruby/node).
2. Probe gaps: no case for the quote-split word ba"sh", for eval/source/./xargs/env/sudo/exec, for the `.` alternation, or for a quoted-delimiter (<<"EOF" / <<\EOF) body holding $( and an apostrophe that must stay inert (assert no fetch).
3. Efficiency: _strip_heredoc, heredoc_openers and strip_heredoc_bodies each walk the text; return the stripped text from heredoc_bodies_inert() (None when not inert) and reuse it in extract().
4. Nit: r"[\\\\'\"]" lists the backslash twice; r"[\\'\"]" is the same class.

Finding 5 (interpreter words anywhere, e.g. a title "env fix", keep the old false block) is already recorded on TASK-146; narrowing to command-position words via simple_commands is the follow-up if it recurs.
<!-- SECTION:DESCRIPTION:END -->
