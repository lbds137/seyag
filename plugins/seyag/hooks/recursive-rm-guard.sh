#!/bin/bash
# PreToolUse:Bash hook (seyag plugin): block recursive and mass deletes that lack the owner's
# approval.
#
# The File Deletion Protocol (global CLAUDE.md: list what goes, check gitignored, wait for her
# yes; never `rm -rf` without approval) was prose only, and prose did not hold: 119 recursive rm
# commands in 7 days of session logs, drivers and workers alike, in every project.
#
# Blocks (exit 2) a Bash command in which any simple command
#   - runs `rm` with a recursive flag: a short cluster holding r or R (-r, -rf, -fr, -Rf, -rvf)
#     or any `--r...` prefix of --recursive, before a `--` terminator (`rm -- -r` deletes a
#     file named -r);
#   - runs `find ... -delete`, or `find ... -exec/-execdir/-ok rm ...` (any rm flags, any path);
#   - runs `xargs rm ...` or `parallel rm ...` (any rm flags: a mass delete).
# A single `rm file` / `rm -f file` is not blocked.
# The analysis is lib/delete_commands.py, shared with cache-rm-redirect. Its commands come from
# the shared splitter (lib/shell_quotes.py): newlines, chains, subshells, comments, `$'...'`
# words, wrapper strings (`bash -c`, `sh -c`, `eval`, a `trap` action, also behind
# sudo/timeout/env), here-strings and `echo ... |` fed to a shell, and heredoc bodies fed to a
# shell are all read as bash reads them; quoted text (`echo "rm -rf x"`) and heredoc data are
# not commands. Runner prefixes (sudo, doas, pkexec, env, nice, nohup, setsid, stdbuf,
# unbuffer, watch, coproc, command, exec, time, timeout, ionice, xargs, parallel,
# `distrobox enter NAME --`, VAR=val assignments) come off with their option values.
#
# Defers (exit 0) when EVERY delete in the command is a cache delete that cache-rm-redirect
# itself blocks (delete_commands.cache_only), so its more specific safe-clean message wins.
#
# Exempt (owner decision 2026-09-27): a delete whose every target (find: every start path)
# resolves strictly below $CLAUDE_JOB_DIR/tmp, the session's job scratch dir, removed with the
# job. Resolution: a literal $CLAUDE_JOB_DIR / ${CLAUDE_JOB_DIR} prefix, an absolute path, or a
# relative path against the payload's cwd, then realpath (so `..` and symlinks cannot step
# out). Not exempt: the tmp dir itself; any other variable ($T), a substitution, `~`, a brace
# expansion, a glob whose folder is outside tmp, targets read from stdin; a relative target when
# the command changes directory (cd/pushd/popd, env -C, sudo -D); anything at all when the
# command runs ln/mv/install/`cp -s` or assigns, exports or unsets CLAUDE_JOB_DIR. One target
# that is not exempt blocks the whole command. The job dir comes from CLAUDE_JOB_DIR in the
# hook's environment; without one (no job) nothing is exempt.
#
# Out of scope: an `rm -r` inside a script FILE the command runs (a `trap` cleanup in foo.sh);
# the hook sees only the Bash tool command. Also not seen: a command inside a QUOTED
# substitution or a backtick span, and `find -exec sh -c '...rm -r...'`.
#
# When a blocked command's rm target or find root is a .claude/worktrees path (merely naming
# one, e.g. in a cd, is not enough), the message also points at safe-worktree-clean, which judges
# an agent worktree before removing it.
#
# Nudges, never blocks: a command that is not blocked but runs `git worktree remove` with -f or
# --force (also behind git's global options or a runner prefix) passes with one line of
# additionalContext pointing at safe-worktree-clean. Whoever insists simply proceeds.
#
# Bypass: put SYG_ALLOW_RM=1 in the command, ONLY for a deletion the owner
# approved in this conversation.
# Fail-open: no python3/jq, unparsable input or command, lib import failure → exit 0.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
case "$CMD" in *SYG_ALLOW_RM=1*) exit 0 ;; esac
# Cheap prefilter, deliberately loose so the word splitter decides: an r followed anywhere later
# by an m (rm, r\m, r''m), a -delete, or an ANSI-C / locale string that could spell either.
case "$CMD" in
  *r*m* | *-delete* | *\$\'* | *\$\"*) ;;
  *) exit 0 ;;
esac

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# The command goes to python on fd 3, never through the environment: Linux caps one env string
# at 128 KiB (MAX_ARG_STRLEN), and python failing to exec would fail open.
# Exit 10 (not 0) means "allow, with the worktree-removal nudge"; 11 means "block, and an rm target
# or find root is in a .claude/worktrees path".
HITS=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF'
import os, re, sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from delete_commands import analyze, cache_lines, cache_only, job_scratch, worktree_target
from shell_quotes import command_pipelines, unwrap_runners

# git's global options that take the next word as their value.
GIT_VALUE_OPTS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env")


def forced_worktree_remove(argv):
    if not argv or os.path.basename(argv[0]) != "git":
        return False
    i = 1
    while i < len(argv) and argv[i].startswith("-"):
        i += 2 if argv[i] in GIT_VALUE_OPTS else 1
    rest = argv[i:]
    return rest[:2] == ["worktree", "remove"] and any(
        a == "--force" or re.fullmatch(r"-f+", a) for a in rest[2:])


text = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
hits, dir_changed, relinked = analyze(text)
try:  # the nudge must never cost the block below
    ALLOW = 10 if any(forced_worktree_remove(unwrap_runners(raw)[0])
                      for pipeline in command_pipelines(text) for raw in pipeline) else 0
except Exception:
    ALLOW = 0
if not hits:
    sys.exit(ALLOW)
if all(cache_only(h) for h in hits) and cache_lines(hits):
    sys.exit(ALLOW)  # cache-rm-redirect blocks these with its safe-clean message
# The session's job scratch dir. Claude Code sets CLAUDE_JOB_DIR in the hook's environment
# (observed on live hook processes); an interactive session without a job dir gets no exemption.
job_dir = os.environ.get("CLAUDE_JOB_DIR", "")
cwd = os.environ.get("CWD", "")
if not relinked and all(
        cache_only(h) or job_scratch(h, job_dir, cwd, dir_changed) for h in hits):
    sys.exit(ALLOW)
for h in hits:
    line = h["line"]
    print(line if len(line) <= 160 else line[:157] + "...")
sys.exit(11 if worktree_target(hits) else 0)
PYEOF
)
PY_RC=$?
if [ "$PY_RC" = 10 ]; then
  jq -nc --arg ctx "worktree removal is gated by safe-worktree-clean — run it first; it removes SAFE trees on --apply" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
  exit 0
fi
[ "$PY_RC" = 0 ] || [ "$PY_RC" = 11 ] || exit 0

[ -n "$HITS" ] || exit 0

WORKTREE_HINT=""
[ "$PY_RC" = 11 ] && WORKTREE_HINT=$'\n'"  - agent worktrees: safe-worktree-clean --repo <repo> [--apply] (it judges the seven SAFE criteria first)."

cat >&2 <<EOF
RECURSIVE-RM GUARD — a recursive or mass delete needs the owner's approval

This command deletes recursively, or many files at once:
$(printf '%s\n' "$HITS" | sed 's/^/  - /')

Gitignored data is unrecoverable once deleted, so every such delete waits for the
owner's approval, scratch included. Instead:
  - put scratch under \$CLAUDE_JOB_DIR/tmp, removed with the job; rm -r there is allowed when
    each target is a literal \$CLAUDE_JOB_DIR/tmp/<name> path (not \$T, not \$(mktemp -d));
  - outside a job, leave scratch where it is or make a NEW directory rather than emptying one;
  - regenerable caches: safe-clean <path> (safe-clean --dry-run shows what would go).${WORKTREE_HINT}
Prefix SYG_ALLOW_RM=1 ONLY for a deletion the owner approved in this conversation
(File Deletion Protocol: list what goes, check gitignored, wait for her yes).
EOF
exit 2
