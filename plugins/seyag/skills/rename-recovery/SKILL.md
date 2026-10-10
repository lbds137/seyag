---
name: rename-recovery
description: 'Recover Claude Code session state after a project folder rename or move: relocate transcripts and session subdirs to the new project key, patch background-job state pointers, repair git worktrees, verify nothing still writes to the old location. Use when a project folder was or will be renamed or moved and its sessions, background jobs or worktrees must follow it.'
---

# Rename recovery

A folder rename moves the code, not the sessions. Claude Code files every session's history under a project key derived from its cwd, and background jobs carry absolute paths in their state. This skill is the procedure that makes both follow the folder. It is proven by a live recovery, not designed; run the steps in order.

## The core fact

Transcripts do NOT follow a folder rename. A session keeps writing under the OLD project key, `~/.claude/projects/<key>/`, until the recovery runs. The key is the cwd path with every `/` and `.` replaced by `-`: `<home>/Projects/notes` → `-home-<user>-Projects-notes`. Before moving anything, confirm the rule on disk with `ls ~/.claude/projects/`: other punctuation in a path may map too, and the real directory name is the authority.

So the recovery runs after the rename, promptly, and never while a session still writes to the old key.

## 1. Precondition: nothing writes to the old key

Both checks pass = safe:

1. No live `claude` process has the old path as its cwd: for each running `claude` pid, `readlink /proc/<pid>/cwd` does not start with the old path. `lsof` on the old key dir is NOT sufficient: Claude Code appends to the transcript and closes it, so an actively writing session shows no open file.
2. The old key dir's newest mtime stays still across a quiet minute.

Stopped background jobs count as safe. A live interactive session must be closed first; that is the owner's action, not the skill's.

## 2. Move the transcripts

1. `mkdir -p` every NEW key dir first: the exact key for the new cwd, plus every worktree-embedded key. A session whose cwd is `<parent>/.claude/worktrees/<name>` lives under `<parent-key>--claude-worktrees-<name>`; regenerate each from the new parent path.
2. `mv` everything in each old key to its new key:
   - every `<session-id>.jsonl`;
   - its matching per-session subdir when it has one: the directory named `<session-id>` beside it, holding session-attached files such as subagent transcripts and captured errors;
   - every other entry in the key dir: the project's auto-memory lives there as `memory/`, alongside occasional files.

   A jsonl without a subdir is normal, not an orphan. `mv`, never `cp`: the move must be byte-identical.
3. Verify: the counts of `*.jsonl` and of subdirs are equal before and after. The only orphan worth flagging is a `<session-id>/` subdir whose jsonl did not move.

## 3. Patch background-job state

For every `~/.claude/jobs/<id>/state.json`, patch exactly three fields:

- `cwd` and `worktreePath` where they START WITH the old path: replace that prefix with the new path (worktree jobs carry the old path as a prefix).
- `linkScanPath` where it contains the OLD KEY: replace the old key with the new key, worktree-embedded keys included. It names a transcript under `~/.claude/projects/<key>/`, so an old-path → new-path substitution never matches it.

Leave everything else alone:

- The historical text fields `name`, `detail`, `output`, and any shell labels inside them: they are log records, not pointers.
- `linkScanOffset`: it is a byte offset into the file `linkScanPath` names, and the byte-identical move keeps it valid.

## 4. Repair git worktrees

If the project uses git worktrees, run `git worktree repair` from its main checkout: worktree metadata stores absolute paths, which the rename broke. The worktree DIRECTORIES move with the project folder; worktree sessions' transcripts were already moved in step 2 (their embedded keys were created there); their background jobs are patched in step 3 through `worktreePath`.

## 5. Verify, and only then clean up

- Resume one moved session by id (`claude --resume <session-id>`) from the session's own new cwd, the main checkout or its worktree, since the lookup is key-based, and confirm its history is there.
- Respawn or inspect one patched background job and confirm its cwd is the new path.
- Confirm the old key no longer grows: nothing still writes to it.

Never delete the old key before all three pass: it is the only backup. A wrong move is undone by moving back; there is no rebuild.
