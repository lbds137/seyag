---
id: TASK-189
title: >-
  long-job-chain-check under-arms: stdin-shell heredoc inside a substitution,
  unquoted eval with escaped operators
status: To Do
assignee: []
created_date: '2026-11-26T01:23:00Z'
updated_date: '2026-11-26T01:31:00Z'
labels:
  - hooks
  - false-negative
dependencies: []
priority: low
ordinal: 188000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the TASK-142 review (2026-11-25). (1) `echo $(bash <<EOF` / `long-job run x -- a && b` / `EOF` / `)` is clean but runs the chain: heredoc bodies are stripped before substitution_spans sees the text, so the stdin-shell exception never applies inside a span. An unquoted-delimiter heredoc body holding `$(long-job … && …)` also runs but is clean (pinned in the probe as the accepted under-arm). (2) Unquoted `eval long-job run x -- a \&\& b`: bash strips the backslashes and eval runs `&&` as an operator, but the checker sees escaped words and returns clean; the docstring eval claim covers only the single-quoted form. (3) A literal U+E002 (mask placeholder) inside an eval argument is reversed to `&` and false-refuses (contrived; HEAD gave clean).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Council review 2026-11-25: interior+tail concatenation can glue outer arguments onto an inner command. 'echo "$(long-job)" run demo && echo done' refuses as 'long-job run demo' (the old checker: clean). Contrived; the fix shape is to keep inner and outer scopes apart (check the enclosing command's operator, not a synthetic string).
<!-- SECTION:NOTES:END -->
