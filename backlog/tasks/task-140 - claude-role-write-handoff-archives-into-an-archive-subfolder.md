---
id: TASK-140
title: 'claude-role: write handoff archives into an archive/ subfolder'
status: To Do
assignee: []
created_date: '2026-11-24T17:00:00Z'
labels:
  - claude-role
  - bin
dependencies: []
priority: medium
ordinal: 140000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by a coordinating session. When a role file passes the size cap, `claude-role` moves its oldest Handoff notes to `<stem>-handoff-archive-<YYYY-MM-DD>.md` beside the role file (the `arch_path = os.path.join(...)` line in the cap-archive block). On the requesting machine this left 59 archive files mixed in with the role files.

The cap-generated archives are not what `--list` misreads. They start with `# <stem> Handoff archive` and have no frontmatter, so `field()` returns no role for them and the board, `--json` and `--list` all skip them; `tests/claude-role.probe.sh` pins that header. The duplicate the requester saw is a hand-made file: one `<stem>-retired-archive-<date>.md`, a copy of a whole role file with its frontmatter. Of the 59 archive files observed, it is the only one starting with `---`, and `--list` shows it as a second row for its role.

So there are two separate fixes:
1. Tidiness and retention: cap archives go to `archive/` beside the role file, which gives a retention prune one directory to match.
2. The duplicate row: the role readers (board, `--json`, `--list`) skip any file whose stem contains `-archive-`, since a hand-made archive can still carry frontmatter. Move the observed retired copy into `archive/` as well; the roles glob `"$ROLES"/*.md` does not recurse, so anything under `archive/` is already ignored.

Owned by the bin lane (`plugins/seyag/bin/**`).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A cap-triggered archive lands at `<roles dir>/archive/<stem>-handoff-archive-<date>.md`. `archive/` is created before the `.tmp` file is opened, not just before the `os.replace`. The success message prints `archive/<name>` so it still points at the file. The probe pins the path and the message.
- [ ] #2 Every `for f in "$ROLES"/*.md` loop (the board, `--json`, `--list` and the earlier reader) skips a role-dir file whose stem contains `-archive-` even when it has `role:` frontmatter. The probe pins this with a fixture that has frontmatter (a retired copy), alongside a positive control showing the same file without the `-archive-` stem does list.
- [ ] #3 Existing beside-the-file archives are migrated into `archive/` (by a one-shot `claude-role --migrate-archives` or a documented `mv` line, with the choice recorded), the hand-made retired copy included.
- [ ] #4 The usage comment (`# Handoff notes to <stem>-handoff-archive-…`) and the role-instructions paragraph beginning "Before a /clear" name the new location. These are the only two mentions: `hooks/session-start.sh` has no archive wording.
<!-- AC:END -->
