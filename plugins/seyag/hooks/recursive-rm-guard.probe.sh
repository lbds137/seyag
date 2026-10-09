#!/bin/bash
# Fixture check for recursive-rm-guard.sh: exit-code table over the command shapes that matter,
# plus the message's pinned phrases.
# Usage: hooks/recursive-rm-guard.probe.sh   (from anywhere)

set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recursive-rm-guard.sh"
fail=0
# The session running the probe may itself be a job: every case sets CLAUDE_JOB_DIR explicitly
# (empty = no job) so the exemption never depends on the caller's environment.
JOBDIR=""
run() { # $1 want-rc, $2 command, $3 payload cwd (optional)
  local rc shown=$2
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  printf '%s' "$2" | jq -Rsc --arg d "${3:-}" '{tool_input: {command: .}} + (if $d == "" then {} else {cwd: $d} end)' |
    CLAUDE_JOB_DIR="$JOBDIR" bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ ${#shown} -gt 200 ] && shown="${shown:0:40}...[${#2} bytes]...${shown: -30}"
  if [ "$rc" = "$1" ]; then echo "ok   [$rc]: $shown ${JOBDIR:+(job)}"; else echo "FAIL [$rc want $1]: $shown ${JOBDIR:+(job)}"; fail=1; fi
}
# A heredoc past Linux's 128 KiB cap on one env string (MAX_ARG_STRLEN) in front of a case.
BIGDOC=$'git commit -F - <<\'EOF\'\n'"$(printf '%*s' 214000 '' | tr ' ' x)"$'\nEOF\n'
CACHE_HOOK="$(dirname "$HOOK")/cache-rm-redirect.sh"
defer() { # $1 command: this guard passes it AND cache-rm-redirect blocks it (the deferral contract)
  run 0 "$1"
  local rc
  jq -nc --arg c "$1" '{tool_input: {command: $c}}' | bash "$CACHE_HOOK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 2 ]; then echo "ok   [cache-rm-redirect 2]: $1"; else echo "FAIL [cache-rm-redirect $rc want 2]: $1"; fail=1; fi
}

# Blocked: each recursive flag spelling.
run 2 'rm -r build'
run 2 'rm -R build'
run 2 'rm -rf build'
run 2 'rm -fr build'
run 2 'rm -Rf build'
run 2 'rm -rvf build'
run 2 'rm -f -r build'
run 2 'rm --recursive --force build'
run 2 'rm -rf -- build'
run 2 'sudo rm -rf /opt/thing'
run 2 'env FOO=1 rm -rf build'
run 2 'FOO=1 command rm -rf build'
run 2 'rm -rf build 2>/dev/null'
run 2 'rm -rf "$TMPDIR/scratch"'
# Blocked: command boundaries from the shared splitter.
run 2 $'cd /tmp\nrm -rf x'                      # a newline ends the cd
run 2 $'cd /tmp && rm -rf \\\nx'                # backslash-newline continues the rm
run 2 'cd /tmp; rm -rf x'
run 2 'true && (cd /tmp && rm -rf x)'
run 2 'if [ -d x ]; then rm -rf x; fi'
run 2 'for d in a b; do rm -rf "$d"; done'
run 2 "bash -c 'rm -rf x'"
run 2 "sh -c 'cd /tmp && rm -rf x'"
run 2 $'cat <<\'EOF\' | bash\nrm -rf x\nEOF'
run 2 $'bash <<\'EOF\'\nrm -rf x\nEOF'
run 2 "watch 'rm -rf /home/example/x'"               # watch runs its joined args via sh -c
run 2 'watch -n5 rm -rf /home/example/x'
run 2 "watch -q 3 'rm -rf /home/example/x'"           # -q/--equexit take a value
run 2 "watch --equexit 3 'rm -rf /home/example/x'"
run 2 "builtin trap 'rm -rf x' EXIT"
run 2 "builtin eval 'rm -rf x'"
# Blocked: find and xargs.
run 2 'find . -delete'
run 2 'find /tmp/x -name "*.log" -delete'
run 2 'find . -exec rm -rf {} +'
run 2 'find . -type d -name build -exec rm -r {} \;'
run 2 'ls -d build* | xargs rm -rf'
run 2 'find . -name build -print0 | xargs -0 rm -rf'
# Blocked: a mixed cache + non-cache target (the non-cache one needs approval).
run 2 'rm -rf node_modules dist'
run 2 'find . -name __pycache__ -o -name build -delete'
run 2 'find node_modules -delete'   # cache-rm-redirect judges find by -name only, so no deferral
# Blocked: mass deletes without -r (driver decision 2026-09-27): find -exec rm, xargs/parallel rm.
run 2 'find . -exec rm {} \;'
run 2 'find ~ -type f -exec rm {} +'
run 2 'ls | xargs rm -f'
run 2 'ls | xargs rm'
run 2 'parallel rm ::: a b'
# Blocked: shapes a reviewer showed passing (round 2).
run 2 'find . -name node_modules -prune; ls ~ | xargs -n 1 rm -rf'  # that find does not feed this xargs
run 2 'xargs -a list.txt rm -rf'
run 2 'find . -name node_modules; xargs rm -rf < list.txt'          # an earlier pipeline's find
run 2 'find . -name node_modules | grep -v keep | xargs rm -rf'    # a filter sits between them
run 2 $'# it\'s fine\nrm -rf /home/example/x'                       # apostrophe in a comment
run 2 $'echo hi # don\'t worry\nrm -rf /home/example/x'
run 2 "sudo bash -c 'rm -rf /home/example/x'"
run 2 "timeout 60 bash -c 'rm -rf /home/example/x'"
run 2 'eval rm -rf /home/example/x'
run 2 'echo "rm -rf /home/example/x" | bash'
run 2 'bash <<< "rm -rf /home/example/x"'
run 2 "rm \$'-rf' /home/example/x"                                   # ANSI-C quoted flag
run 2 'rm $"-rf" /home/example/x'
run 2 'rm --recu /home/example/x'                                    # a prefix of --recursive
run 2 'rm --r /home/example/x'
run 2 'rm -rf 2>&1 /home/example/x'                                  # the & of a redirection
run 2 'rm -rf &>/dev/null /home/example/x'
run 2 'r\m -rf /home/example/x'                                      # prefilter vs escaped name
run 2 "r''m -rf /home/example/x"
run 2 'setsid rm -rf /home/example/x'
run 2 'stdbuf -o L rm -rf /home/example/x'
run 2 'distrobox enter tools -- rm -rf /home/example/x'
run 2 'coproc rm -rf /home/example/x'
run 2 'ls | xargs --max-args 1 rm -rf'
run 2 'ls | xargs --some-future-option 1 rm -rf'                   # unknown long option: value consumed
# Blocked: shapes a reviewer showed passing (round 3).
run 2 "${BIGDOC}rm -rf build"                                     # a command past 128 KiB
run 2 $'trap \'rm -rf "$tmp"\' EXIT; tmp=$(mktemp -d)'            # a trap action is a command
run 2 "trap -- 'rm -rf build' EXIT INT"
run 2 'watch rm -rf /home/example/x'
run 2 'watch -n 5 rm -rf /home/example/x'                            # -n takes a value
run 2 'watch --interval 5 -d rm -rf /home/example/x'
run 2 'pkexec rm -rf /opt/thing'
run 2 'pkexec --user root rm -rf /opt/thing'
run 2 'unbuffer rm -rf /home/example/x'
# Allowed: not a recursive or mass delete.
run 0 'rm file.txt'
run 0 'rm -f file.txt'
run 0 'rm -fv a b'
run 0 'rm -- -r'                                 # a file named -r, not a flag
run 0 'rm -- -r build'                           # two files: -r and build
run 0 'rm -f -- -rf notes'
run 0 'find . -name "*.log"'
run 0 'git rm -r --cached dir'                   # argv[0] is git
run 0 '# rm -rf /home/example/x'                    # a comment is not a command
run 0 'echo a#b; echo $#'                        # mid-word # and $# are not comments
run 0 'echo "rm -rf x"'                          # quoted text, not a command
run 0 $'echo "cd /tmp\nrm -rf x"'                # a quoted newline is text
run 0 $'cat > notes.md <<\'EOF\'\nrm -rf x\nEOF'  # heredoc data, not a command
run 0 'grep -rn "rm -rf" .'
run 0 'npm run format'
run 0 "trap 'rm -f lock' EXIT"                  # a trap action with a single-file rm
run 0 'trap - EXIT'
run 0 "trap '' INT"
run 0 'trap -p EXIT'
run 0 "${BIGDOC}ls"                             # a long command with no delete
run 0 ''
# Allowed here: cache-only deletes defer to cache-rm-redirect, which must block each one.
defer 'rm -rf node_modules'
defer 'rm -rf a/__pycache__ .pytest_cache'
defer 'find . -name __pycache__ -type d -exec rm -rf {} +'
defer 'find . -name __pycache__ -print0 | xargs -0 rm -rf'
defer 'find . -name node_modules -print0 | xargs -0 -n 1 rm -rf'
defer 'env rm -rf node_modules'
defer 'nice -n 5 rm -rf node_modules'
defer 'sudo -u root rm -rf node_modules'
defer 'timeout 60 rm -rf node_modules'
defer 'find . -name node_modules -exec env rm -rf {} +'
# Job scratch exemption: strictly inside $CLAUDE_JOB_DIR/tmp passes, everything else blocks.
TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/job/tmp/scratch" "$TMP/outside"
ln -s "$TMP/outside" "$TMP/job/tmp/escape"
JOBDIR="$TMP/job"
run 0 'rm -rf $CLAUDE_JOB_DIR/tmp/scratch'
run 0 'rm -rf "${CLAUDE_JOB_DIR}/tmp/a" "$CLAUDE_JOB_DIR/tmp/b/c"'
run 0 "rm -rf $TMP/job/tmp/scratch"                     # the same place as an absolute path
run 0 'rm -rf $CLAUDE_JOB_DIR/tmp/*'
run 0 'find $CLAUDE_JOB_DIR/tmp/scratch -delete'
run 0 'rm -rf scratch' "$TMP/job/tmp"                  # relative, resolved against payload cwd
run 0 'rm -rf $CLAUDE_JOB_DIR/tmp/x node_modules'       # the cache half is cache-rm-redirect's
run 2 'rm -rf scratch' "$TMP/outside"                  # relative, but cwd is outside
run 2 'rm -rf scratch'                                  # relative with no cwd: unresolvable
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp'                      # the tmp dir itself
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/'
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/../x'                 # .. steps out
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/escape/'              # a symlink inside tmp pointing outside
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/x build' "$TMP/outside" # mixed: build resolves outside tmp
run 2 'rm -rf $CLAUDE_JOB_DIR/other'
run 2 'rm -rf $T'                                       # unresolvable variable
run 2 'rm -rf $(mktemp -d)'
run 2 'rm -rf $CLAUDE_JOB_DIR/*/x'                      # the glob's folder is not under tmp
run 2 'find $CLAUDE_JOB_DIR/tmp/x /tmp/y -delete'
run 2 'ls | xargs rm -rf'
run 2 'cd /home/example && rm -rf Projects/x' "$TMP/job/tmp"             # cd before a relative target
run 2 'env -C /home/example rm -rf Projects/x' "$TMP/job/tmp"            # a runner that changes dir
run 2 'sudo -D /home/example rm -rf Projects/x' "$TMP/job/tmp"
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/{a,../..}'                          # brace expansion
run 2 'ln -s /home/example $CLAUDE_JOB_DIR/tmp/l && rm -rf $CLAUDE_JOB_DIR/tmp/l/'
run 2 'mv /home/example/x $CLAUDE_JOB_DIR/tmp/x; rm -rf $CLAUDE_JOB_DIR/tmp/x'
run 2 'CLAUDE_JOB_DIR=/home/example; rm -rf $CLAUDE_JOB_DIR/tmp/x'
run 2 'export CLAUDE_JOB_DIR=/home/example; rm -rf $CLAUDE_JOB_DIR/tmp/x'
JOBDIR="$TMP/no-such-job"                                # a job dir that does not exist
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/scratch'
JOBDIR=""                                                # no job at all (interactive session)
run 2 'rm -rf $CLAUDE_JOB_DIR/tmp/scratch'
run 2 "rm -rf $TMP/job/tmp/scratch"
# Bypass: the owner approved this deletion.
run 0 'SYG_ALLOW_RM=1 rm -rf build'

# The message names the target and carries the pinned phrases.
msg=$(jq -nc --arg c 'cd /tmp && rm -rf build-output' '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOK" 2>&1 >/dev/null)
for phrase in 'RECURSIVE-RM GUARD' 'rm -rf build-output' 'unrecoverable' 'NEW directory' \
  '$CLAUDE_JOB_DIR/tmp' 'safe-clean' 'SYG_ALLOW_RM=1' 'approved in this conversation' \
  'check gitignored' 'literal $CLAUDE_JOB_DIR/tmp/<name> path' 'outside a job'; do
  case "$msg" in
    *"$phrase"*) echo "ok   message carries: $phrase" ;;
    *) echo "FAIL message lacks: $phrase"; fail=1 ;;
  esac
done
lines=$(printf '%s\n' "$msg" | wc -l)
if [ "$lines" -le 15 ]; then echo "ok   message is $lines lines"; else echo "FAIL message is $lines lines (> 15)"; fail=1; fi
case "$msg" in
  *safe-worktree-clean*) echo "FAIL a non-worktree message names safe-worktree-clean"; fail=1 ;;
  *) echo "ok   a non-worktree message leaves safe-worktree-clean out" ;;
esac
# A blocked delete under .claude/worktrees also names safe-worktree-clean.
msg=$(jq -nc --arg c 'rm -rf .claude/worktrees/agent-x' '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOK" 2>&1 >/dev/null)
case "$msg" in
  *'safe-worktree-clean --repo <repo> [--apply] (it judges the seven SAFE criteria first)'*)
    echo "ok   a worktree delete's message names safe-worktree-clean" ;;
  *) echo "FAIL a worktree delete's message lacks the safe-worktree-clean line"; fail=1 ;;
esac
lines=$(printf '%s\n' "$msg" | wc -l)
if [ "$lines" -le 16 ]; then echo "ok   worktree message is $lines lines"; else echo "FAIL worktree message is $lines lines (> 16)"; fail=1; fi
# The hint follows the delete's TARGET, not the text: a cd into a worktree before an unrelated
# scratch delete blocks without it.
c='cd /srv/team/repo/.claude/worktrees/agent-x && T=$(mktemp -d) && rm -r "$T"'
msg=$(jq -nc --arg c "$c" '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOK" 2>&1 >/dev/null)
case "$msg" in
  *safe-worktree-clean*) echo "FAIL a delete merely next to a worktree path names safe-worktree-clean: $c"; fail=1 ;;
  RECURSIVE-RM*) echo "ok   blocks without the worktree line: $c" ;;
  *) echo "FAIL not blocked: $c"; fail=1 ;;
esac

# Nudge: a forced `git worktree remove` passes (exit 0) with one line of additionalContext.
nudge() { # $1 want "yes" or "no", $2 command
  local out rc ctx
  out=$(jq -nc --arg c "$2" '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOK" 2>/dev/null)
  rc=$?
  ctx=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null)
  if [ "$1" = yes ] && [ "$rc" = 0 ] && [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = PreToolUse ] \
    && [ "$ctx" = "worktree removal is gated by safe-worktree-clean — run it first; it removes SAFE trees on --apply" ]; then
    echo "ok   nudges, allows: $2"
  elif [ "$1" = no ] && [ "$rc" = 0 ] && [ -z "$out" ]; then
    echo "ok   no nudge: $2"
  else
    echo "FAIL [nudge want $1, rc $rc, out '$out']: $2"; fail=1
  fi
}
nudge yes 'git worktree remove --force .claude/worktrees/agent-x'
nudge yes 'git -C /srv/team/repo worktree remove -f .claude/worktrees/agent-x'
nudge yes 'git -c core.x=1 worktree remove -ff locked-tree'
nudge yes 'cd /srv/team/repo && sudo git worktree remove --force wt'
nudge yes 'git worktree remove wt --force'
nudge no 'git worktree remove wt'
nudge no 'git worktree list --porcelain'
nudge no 'echo "git worktree remove --force wt"'
nudge no 'safe-worktree-clean --repo /srv/team/repo --apply'
run 2 'git worktree remove --force wt && rm -rf /srv/team/other'   # a block still wins
exit $fail
