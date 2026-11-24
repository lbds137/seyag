---
id: TASK-146
title: >-
  pr-merge-review-check: heredoc/quoted body text read as a gh pr merge call
  (false block)
status: To Do
assignee: []
created_date: '2026-11-24T22:43:00Z'
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
