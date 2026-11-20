---
id: TASK-24
title: 'implementer/delegation docs: flag the unicode-escape transport hazard'
status: To Do
assignee: []
created_date: '2026-11-19T14:24:00Z'
updated_date: '2026-11-20T02:22:00Z'
labels:
  - skills
dependencies: []
priority: low
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The implementer agent doc and the delegation spec template gain one line: `\uXXXX` escapes in
written content can decode in transport, so authored strings must be probed at runtime or
built via character codes. Own small PR.
<!-- SECTION:DESCRIPTION:END -->
