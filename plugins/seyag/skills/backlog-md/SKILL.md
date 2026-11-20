---
name: backlog-md
description: Conventions for a project that opted into backlog.md as its tracking surface (settings env SYG_TRACKING_SURFACE=backlog-md). Use when filing, updating, archiving or reading tasks in the project's backlog/ store, when recording a disposition per the core rules, or when asked to set up the opt-in.
---

# Backlog.md Tracking Surface

Conventions for sessions working in a project that uses `backlog.md` as its durable task tracker.

## 1. Opt-in precondition

This skill applies **only** when the project's tracked `.claude/settings.json` pins the surface:

```json
{
  "env": {
    "SYG_TRACKING_SURFACE": "backlog-md"
  }
}
```

This is a hard precondition. If `.claude/settings.json` has no `"SYG_TRACKING_SURFACE": "backlog-md"` pin, the project has no `backlog.md` surface: do not create one, do not invoke `backlog.md`, and do not offer to set it up unless explicitly asked. The pin is a project decision: only the tracked `.claude/settings.json` counts — a pin in `settings.local.json` or a user-level env does not opt the project in.

## 2. Ownership split

- The adopting project pins `backlog.md` in its own manifest (`package.json`) and owns both the `backlog/` store and the package version.
- Seyag never bundles, installs or updates `backlog.md`, and never assumes a store exists.
- Version-specific CLI behavior is defined strictly by the project's pinned version — check the project's scripts and the CLI's own help output, never memorized flags or subcommands.

## 3. Store layout

By `backlog.md` convention, a `backlog/` directory at the repository root holds `config.yml` and `tasks/`, plus `archive/`, `completed/`, `decisions/`, `docs/` and `drafts/` created by `backlog.md` itself, and `milestones/` where the project uses them.

- `config.yml` carries the project name (e.g. `example-app`), the status list, labels, the task prefix and similar store-wide settings.
- Task files live at `backlog/tasks/task-N - Title.md` with YAML frontmatter fields `id` (`TASK-N`), `title`, `status`, `assignee`, `created_date`, `labels`, `dependencies` and `ordinal`.
- Treat this layout and frontmatter as the shape to expect, not a schema this skill enforces.

```markdown
---
id: TASK-12
title: Validate webhook retry backoff in example-app
status: To Do
assignee: []
created_date: '2026-03-15 10:00'
labels:
  - reliability
dependencies: []
ordinal: 1000
---

## Description

Ensure `example-app` bounds retry intervals when downstream endpoints return 503.
```

## 4. CLI conventions

- **Prefer the CLI over hand-editing task files.** The CLI is the writer of record for `id` assignment, `ordinal` ordering and `status` moves.
- Run commands through the project's own wiring (its pinned package and manifest scripts, such as a store validation or lint script), and run the project's lint gate after filing or updating entries.
- Direct file edits are reserved for cases the pinned CLI cannot express, and even then touch only markdown body text — never frontmatter fields owned by the CLI.

## 5. Session-side flows

- **Filing a found task** (core rules § *Fix what you touch, file what you find*): When an out-of-scope defect turns up beyond the edited lines in `example-app` (for example, `"Fix stale cache header on example-app health route"`), file it via the project's wired CLI instead of silently fixing or dropping it. Record the file path and observed evidence in the task body, then run the project's store lint gate.
- **Writing a disposition onto an existing entry** (core rules § *Everything not done gets a disposition when you decide*): Every decision not to build an item records one of the four states in the same session: **shipped**, **obsolete** (checked against the code, not assumed), **ruled out** (reason recorded where the next session will look), or **deferred** (with a trigger that promotes it). Apply any status transition through the CLI and write the disposition rationale and evidence into the entry body so it survives compaction.
- **Done and archive flow**: Transition finished or retired entries through the project's CLI so the task moves into `completed/` or `archive/` per the store's workflow. Never delete an entry merely for age, and never reuse an existing `TASK-N` identifier.
- **Reading the store for the "raised this before" search order** (core rules § *"I've raised this before" is a search order*): Before replying to a prior-art question or filing a new entry, search `tasks/`, `completed/`, `archive/`, `drafts/` and `decisions/` across at least three vocabulary variants. Name the matching entry, its current state and its blocker, and leave parked entries for the owner to promote rather than silently re-filing them.

### Claiming across sessions

When several driver sessions share one store, a session claims a task before starting it: set
`assignee` to that session's name (e.g. `assignee: [project-a]`) and move `status` to
`In Progress` in the same CLI pass that starts the work, and move it off `In Progress` when the
unit ends. A session never edits another session's in-progress task body; coordination notes go
in the task's own description or the project's session role files. Role files keep each
session's handoff and progress; the store keeps the queue.

## 6. Guardrails

- **Stale opt-in check:** If `SYG_TRACKING_SURFACE=backlog-md` is pinned in settings but `backlog/` or `backlog/config.yml` is missing, the opt-in is stale — report the missing store and do not initialize or create one.
- **Commit discipline:** Store changes ride the session's working branch: a filed task or written disposition lands in the same PR as the change that prompted it, or in its own commit on that branch, so it survives the merge. Never commit outside the session's own branch — the backlog-only direct commit in this section is the one exception — and never leave store changes as uncommitted files that a worktree cleanup or transfer could discard.
- **Backlog-only direct commits:** A commit that touches only `backlog/**` may go straight to the project's integration branch (the branch the project merges work into) without a PR, after the project's store lint passes. A store change made as part of other work still rides that work's branch or PR, and a project's CLAUDE.md can still forbid the direct path — the project wins.
