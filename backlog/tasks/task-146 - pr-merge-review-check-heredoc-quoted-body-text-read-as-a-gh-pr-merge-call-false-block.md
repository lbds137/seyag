---
id: TASK-146
title: >-
  pr-merge-review-check: heredoc/quoted body text read as a gh pr merge call
  (false block)
status: Done
assignee:
  - Seyag
created_date: '2026-11-24T22:43:00Z'
updated_date: '2026-11-25T02:58:00Z'
labels:
  - hooks
dependencies: []
priority: high
ordinal: 145000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by lane B 11-24: `gh pr create ... --body-file - <<'EOF'` whose heredoc body held the literal text `gh pr merge <N> --disable-auto` and later '600 s' was blocked: the hook read the body text as a merge command, parsed PR #600 out of '600 s', failed the review fetch and blocked with MERGE REVIEW UNREADABLE ... PR #600 (not ackable). Expected: heredoc and quoted text are never a gh pr merge invocation; a gh pr create is never judged as a merge; the PR number comes only from the merge command's own argv. Workaround: write the body to a file and pass --body-file PATH. Fix with probe cases for: heredoc body naming gh pr merge, a quoted string naming it, and the real merge still caught. Replay against session logs before push (tests/replay-hook.sh).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause (driver-measured 11-24): the precise scan found no merge; extract() then checked quote balance on the RAW text, an apostrophe in the heredoc body ("#406's") read as an unclosed quote, and legacy_scan walked the body from `gh pr merge` to "600". Fix: the heredoc-stripped quote check applies only when no heredoc body can execute (no interpreter word, no substitution in an unquoted-delimiter body); otherwise the base raw check runs unchanged. Round 1 applied it unconditionally and the cross-family review caught under-arms: base caught R1a/R1b/R1c/R2 only via this fallback, because the precise scan misses them (TASK-152, TASK-153). Residuals: a quote unclosed OUTSIDE any heredoc still over-arms (bash rejects such a command anyway); a comment apostrophe still forces the fallback (TASK-154).

Residual, deliberate: the interpreter-word test is permissive textual, so any shell, eval, env, sudo, exec, xargs or source word outside the bodies (e.g. a PR title "env fix") keeps base behaviour, which still false-blocks an apostrophe-bearing body naming gh pr merge. It shrinks when TASK-152/153 make the precise scan reliable and the fallback can narrow. Measured: base vs fix over all 119 unique logged Bash commands mentioning `pr merge` (7 days): 118 identical, 1 changed (lane B's #600 false block, now clear).
<!-- SECTION:NOTES:END -->
