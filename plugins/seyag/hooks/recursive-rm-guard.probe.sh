#!/bin/bash
# Fixture check for recursive-rm-guard.sh: exit-code table over the command shapes that matter,
# plus the message's pinned phrases.
# Usage: hooks/recursive-rm-guard.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/recursive-rm-guard.sh"
fail=0
# The session running the probe may itself be a job: every case sets CLAUDE_JOB_DIR explicitly
# (empty = no job) so the exemption never depends on the caller's environment.
JOBDIR=""
# Session scratch exemption inputs, set explicitly per case too: the scratch root fixture (a
# nonexistent dir until the scratch section), and the toggle (empty = on).
SROOT="/nonexistent-scratch-root"
EXEMPT=""
run() { # $1 want-rc, $2 command, $3 payload cwd (optional), $4 payload session_id (optional)
  local rc shown=$2
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  printf '%s' "$2" | jq -Rsc --arg d "${3:-}" --arg s "${4:-}" '{tool_input: {command: .}} + (if $d == "" then {} else {cwd: $d} end) + (if $s == "" then {} else {session_id: $s} end)' |
    CLAUDE_JOB_DIR="$JOBDIR" SYG_SCRATCH_ROOT="$SROOT" SYG_SCRATCH_RM_EXEMPT="$EXEMPT" bash "$HOOK" >/dev/null 2>&1
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
run 2 $'x=$(cd b\nrm -rf n)'                    # a newline inside $() separates the interior's rm
run 2 'echo "$(rm -rf X)"'
run 2 $'echo "$(cat <<EOF | bash\nrm -rf X\nEOF\n)"'  # a body fed to a shell inside a quoted span runs
run 2 $'echo `bash <<EOF\nrm -rf X\nEOF\n`'
run 2 'x="$(rm -rf X)"'
run 2 'echo `rm -rf X`'
run 2 'x=`rm -rf X`'
run 2 'echo "`rm -rf X`"'
run 2 'echo $(echo "$(rm -rf X)")'
run 2 '`rm -rf X`'
run 2 '(`rm -rf X`)'
run 2 'echo "$(`rm -rf X`)"'
run 2 'if `rm -rf X`; then :; fi'
run 2 'true; `rm -rf X`'
run 2 '`true; rm -rf X`'
run 2 '2>/dev/null rm -rf X'
run 2 '> f rm -rf X'
run 2 'function f { rm -rf X; }; f'
run 2 'time -p rm -rf X'
run 2 'echo "a # b `rm -rf X`"'
run 2 'echo a#`rm -rf X`'
run 2 $'bash -c \'echo `rm -rf X`\''
run 2 $'eval \'echo `rm -rf X`\''
run 2 $'bash <<\'EOF\'\necho "$(rm -rf X)"\nEOF'
run 2 $'cat <<\'EOF\' | bash\necho "`rm -rf X`"\nEOF'
run 2 'time -p `rm -rf X`'
run 2 'function f { `rm -rf X`; }'
run 2 'case a in a) `rm -rf X`;; esac'
run 2 'ls\) `rm -rf X`'
run 2 'prog\(1\) `rm -rf X`'
run 2 $'echo a\\\n# `rm -rf X`'
run 2 'echo `echo \`rm -rf X\``'
run 2 'echo "`echo \`rm -rf X\``"'
run 2 '$(a) `rm -rf X`'
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
# Blocked: mass deletes without -r: find -exec rm, xargs/parallel rm.
run 2 'find . -exec rm {} \;'
run 2 'find ~ -type f -exec rm {} +'
run 2 'ls | xargs rm -f'
run 2 'ls | xargs rm'
run 2 'parallel rm ::: a b'
# Blocked: wrapper-hidden mass deletes (found in review).
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
# Blocked: shapes past earlier size/command boundaries (found in review).
run 2 "${BIGDOC}rm -rf build"                                     # a command past 128 KiB
run 2 $'trap \'rm -rf "$tmp"\' EXIT; tmp=$(mktemp -d)'            # a trap action is a command
run 2 "trap -- 'rm -rf build' EXIT INT"
run 2 'watch rm -rf /home/example/x'
run 2 'watch -n 5 rm -rf /home/example/x'                            # -n takes a value
run 2 'watch --interval 5 -d rm -rf /home/example/x'
run 2 'pkexec rm -rf /opt/thing'
run 2 'pkexec --user root rm -rf /opt/thing'
run 2 'unbuffer rm -rf /home/example/x'
run 2 $'# <<x\nrm -rf build\nx'                                   # comment-hidden opener does not swallow rm
run 2 $'echo "<<x"\nrm -rf build\nx'                              # quote-hidden opener does not swallow rm
# A later quoted word after the target, so each case needs the heredoc opener scan, not just
# unterminated-quote recovery, to keep the rm visible.
run 2 $'git commit -m "$(cat <<\'EOF\'\nSupport 27" monitors\nEOF\n)"\nrm -rf build; echo "x"'
run 2 $'echo ${x:-$(cat <<A\nit\'s\nA\n)}\nrm -rf build; echo \'x\''
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
run 0 'echo hi # `rm -rf X`'
run 0 $'# `rm -rf X`\necho hi'
run 0 $'echo a \\\n# `rm -rf X`\necho b'
run 0 $'echo a\\\\\n# `rm -rf X`\necho b'
run 0 $'cat > f <<\'EOF\'\necho "$(rm -rf X)"\nEOF'
run 0 'echo a#b; echo $#'                        # mid-word # and $# are not comments
run 0 'echo "rm -rf x"'                          # quoted text, not a command
run 0 $'echo \'$(rm -rf X)\''
run 0 $'echo \'`rm -rf X`\''
run 0 'echo "\$(rm -rf X)"'
run 0 'echo "\`rm -rf X\`"'
run 0 $'git commit -m "$(cat <<\'EOF\'\nrm -rf X\nEOF\n)"'
run 0 $'echo "cd /tmp\nrm -rf x"'                # a quoted newline is text
run 0 $'cat > notes.md <<\'EOF\'\nrm -rf x\nEOF'  # heredoc data, not a command
run 0 $'cat > README.md <<\'EOF\'\nClean with:\n```\nrm -rf build\n```\nEOF\n'  # fenced heredoc data is data too
# A span deep inside a double-quoted -m word is data — the separator
# before it sits in quoted prose, not at a command boundary. The multi-line
# row's rm is mid-sentence there; the same-line `;` variant is the one a raw
# window would misread.
run 0 $'git commit -m "Subject\n\n$(cat <<EOF\nClean with: rm -rf build\nenv | cat\nEOF\n)"'  # span deep in a quoted word is data
run 0 $'git commit -m "WIP; $(cat <<EOF\nrm -rf x\nEOF\n)"'                                    # same-line separator variant
# A (#N) line in a heredoc BODY is data to the span walk too: it opens no
# comment there, so the span terminates and the backtick span's second-line
# rm (which bash runs) stays visible to the guard.
run 2 $'git commit -m "$(cat <<EOF\nFix the parser (#149)\nEOF\n)"; echo `cd b\nrm -rf n`'
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
# Session scratch exemption: <root>/<sid> (0700, owned by the user), keyed on the payload's sid.
SROOT="$TMP/sroot"
SID=sess-AAA
mkdir -m 700 "$SROOT" "$SROOT/$SID" "$SROOT/other-sess" "$SROOT/$SID/x"
mkdir -p "$TMP/real-dir"
ln -s "$TMP/real-dir" "$SROOT/linked-sess"
ln -s "$TMP/outside" "$SROOT/$SID/escape"
run 0 "rm -rf $SROOT/$SID/x" "" $SID
run 0 "find $SROOT/$SID/x -delete" "" $SID
run 0 "rm -rf $SROOT/$SID/new/deep" "" $SID
run 0 "rm -rf $SROOT/$SID/*" "" $SID
run 0 'rm -rf x' "$SROOT/$SID" $SID                                   # relative, payload cwd inside
JOBDIR="$TMP/job"
run 0 "rm -rf $SROOT/$SID/a \$CLAUDE_JOB_DIR/tmp/b" "" $SID           # both roots in one command
run 2 "rm -rf $SROOT/$SID/a /tmp/elsewhere" "" $SID                   # one target outside both
run 0 'rm -rf $CLAUDE_JOB_DIR/tmp/scratch'                           # job tmp alone, no session id
JOBDIR=""
run 2 "rm -rf $SROOT/$SID" "" $SID                                    # the dir itself
run 2 "rm -rf $SROOT/$SID/" "" $SID
run 2 "rm -rf $SROOT" "" $SID                                         # the root
run 2 "rm -rf $SROOT/other-sess/x" "" $SID                            # another session's dir
run 2 "rm -rf $SROOT/$SID/x"                                          # payload without session_id
run 2 "rm -rf $SROOT/linked-sess/x" "" linked-sess                    # sid dir is a symlink
run 2 "rm -rf $SROOT/$SID/../other-sess/x" "" $SID                    # .. steps out
run 2 "rm -rf $SROOT/$SID/escape/" "" $SID                            # symlink inside, pointing out
run 2 "rm -rf $SROOT/nosuch/x" "" nosuch                              # sid dir does not exist
mkdir -m 700 "$SROOT/bad sid!" "$SROOT/bad sid!/x"                   # real dirs, so only the pattern refuses
run 2 "rm -rf '$SROOT/bad sid!/x'" "" 'bad sid!'                      # sid fails the pattern
run 2 "rm -rf $SROOT/other-sess/x" "" "$SID/../other-sess"            # a path-shaped sid that resolves to a real dir
run 2 "ln -s /home/example $SROOT/$SID/l && rm -rf $SROOT/$SID/l/" "" $SID
run 2 "cd $SROOT/$SID && rm -rf x" "$SROOT/$SID" $SID                 # cd before a relative target
run 2 "rm -rf $SROOT/$SID/x \$T" "" $SID
run 2 "find $SROOT/$SID/x /tmp/y -delete" "" $SID
# Globs and find shapes, for BOTH roots (job tmp, session dir): <p>/gx/escape is a symlink out.
JOBDIR="$TMP/job"
mkdir -p "$TMP/job/tmp/gx/a" "$SROOT/$SID/gx/a"
ln -s "$TMP/outside" "$TMP/job/tmp/gx/escape"
ln -s "$TMP/outside" "$SROOT/$SID/gx/escape"
for P in '$CLAUDE_JOB_DIR/tmp' "$SROOT/$SID"; do
  run 2 "rm -rf $P/gx/..*/x" "" $SID
  run 2 "rm -rf $P/gx/.[.]/x" "" $SID
  run 2 "rm -rf $P/gx/[.][.]/x" "" $SID
  run 2 "rm -rf $P/gx/.?/x" "" $SID
  run 2 "rm -rf $P/gx/escap?/" "" $SID
  run 2 "rm -rf $P/gx/*/*" "" $SID
  run 2 "rm -rf $P/gx/*/" "" $SID
  run 2 "rm -rf $P/gx/.*" "" $SID                                     # a dotfile glob can match ..
  run 2 "find $P/gx/a -exec rm -rf $TMP/outside {} +" "" $SID         # an operand besides {}
  run 2 "find $P/gx/a -exec rm -rf {}/../.. \\;" "" $SID
  run 2 "find -L $P/gx -delete" "" $SID
  run 2 "find -H $P/gx -delete" "" $SID
  run 2 "find $P/gx -follow -delete" "" $SID
  run 0 "rm -rf $P/gx/x*" "" $SID
  run 0 "rm -rf $P/*" "" $SID
  run 0 "find $P/gx/a -exec rm -rf {} +" "" $SID
  run 0 "find $P/gx/a -exec rm -rf {} \\;" "" $SID
  run 0 "find $P/gx/a -delete" "" $SID
  # Round 3: find is exempt only in an allowlisted shape; D is P as a concrete path (payload cwd).
  D=${P/\$CLAUDE_JOB_DIR/$TMP/job}
  run 2 "find $P/gx/a - $TMP/outside -delete" "" $SID                  # - , !x and (x are start paths
  run 2 "find $P/gx/a '!x' $TMP/outside -delete" "" $SID
  run 2 "find $P/gx/a '(x' $TMP/outside -delete" "" $SID
  run 2 "find '!x' -delete" "$D/gx" $SID                              # a start word like !x or (x: not judged
  run 2 "find '(x' -delete" "$D/gx" $SID
  run 2 "find -O3 $TMP/outside -delete" "$D/gx" $SID
  run 2 "find -O3 -L $P/gx -delete" "$D/gx" $SID
  run 2 "find -D exec $TMP/outside -delete" "$D/gx" $SID
  run 2 "find -- $TMP/outside -delete" "$D/gx" $SID
  run 2 "find -files0-from $TMP/list -delete" "$D/gx" $SID
  run 2 "find $P/gx/a -exec rm -rf -- -victim {} +" "" $SID
  run 2 "find $P/gx/a -exec rm -rf - {} +" "" $SID
  run 2 "mkdir -p $P/gx/- && find $P/gx/a -execdir rm -rf -- -/../../../../tmp/outside {} +" "" $SID
  run 2 "find $P/gx/a -exec rm -f -- {} +" "" $SID                     # -- is not in the allowlist
  run 2 "find $P/gx/a -execdir rm {} +" "" $SID
  run 2 "find $P/gx/a -ok rm {} \\;" "" $SID
  run 2 "find $P/gx/a -o -delete" "" $SID
  run 2 "find -D tree $P/gx/a -delete" "" $SID
  run 2 "find $P/gx/a -newer /etc/passwd -delete" "" $SID
  run 2 "find $P/gx/a -exec env rm {} +" "" $SID                       # no runner inside -exec
  run 2 "find $P/gx/a -exec rm -rf {} + -delete" "" $SID               # exactly one action
  run 2 "find $P/gx/a ! -name x -delete" "" $SID
  run 2 "find $P/gx/a -name a -delete -print" "" $SID                  # the action is last
  run 2 "rm -rf $P/gx/@(..)/x" "" $SID                                 # extglob
  run 2 "rm -rf $P/gx/+(.)/x" "" $SID
  run 2 "shopt -s extglob; rm -rf $P/@(..)/x" "" $SID
  run 2 "shopt -s globskipdots; rm -rf $P/gx/a" "" $SID                # any shopt: no exemption
  run 2 "set +o noglob; rm -rf $P/gx/a" "" $SID
  run 2 "set -o noglob; rm -rf $P/gx/a" "" $SID
  run 2 "rm -rf $P/gx/a\\*" "" $SID    # a backslash is not a plain word
  run 2 "SYG_SCRATCH_ROOT=/x; rm -rf $P/gx/a" "" $SID
  run 2 "declare SYG_SCRATCH_ROOT; rm -rf $P/gx/a" "" $SID
  run 2 "rm -rf -- -victim" "$TMP/outside" $SID                        # a target after -- is still judged
  run 0 "rm -rf -- -victim" "$D/gx" $SID
  run 0 "find $P/gx/a -name a -delete" "" $SID
  run 0 "find $P/gx/a $P/gx/b -type f -mtime +1 -delete" "" $SID
  run 0 "find $P/gx/a -exec rm -rf {} \\;" "" $SID
  run 0 "find $P/gx/a -exec /bin/rm -f {} +" "" $SID
  run 0 "find $P/gx/a -name a -newer $P/gx/b -print -delete" "" $SID
  # Round 4: only plain-word deletes are exempt; each of these splits differently in bash than in
  # the guard's splitter (dequoted redirection words, $() splitting, quoted variables), or tampers.
  run 2 "rm -rf $P/gx/a '>' $TMP/outside" "" $SID
  run 2 "rm -rf '>' $TMP/outside" "" $SID
  run 2 "rm -rf $P/gx/a \\> $TMP/outside" "" $SID
  run 2 "find $P/gx/a '>' $TMP/outside -delete" "" $SID
  run 2 "find $P/gx/a -exec rm -rf '>' $TMP/outside {} +" "" $SID
  run 2 "rm -rf $P/gx/a -f\${IFS}$TMP/outside" "" $SID
  run 2 "rm -rf $P/gx/a -f\$(:) $TMP/outside" "" $SID
  run 2 "rm -rf $P/gx/a -f\"\$(: '\"')\" $TMP/outside -f\"\"" "" $SID
  run 2 "find $P/gx/a -delete; find $TMP/outside \$(:) -delete" "" $SID
  run 2 "rm -rf '$P/gx/a'" "" $SID                                     # any quote but a lone pair of "
  run 2 "rm -rf $P/gx/a '>'" "" $SID
  run 2 "CLAUDE_JOB_DIR[0]=$TMP/outside; rm -rf $P/gx/a" "" $SID
  run 2 "declare -n R=CLAUDE_JOB_DIR; R=$TMP/outside; rm -rf $P/gx/a" "" $SID
  run 2 "declare -n R=SYG_SCRATCH_ROOT; R=$TMP/outside; rm -rf $P/gx/a" "" $SID
  run 2 "env -S 'X=1 CLAUDE_JOB_DIR=$TMP/outside rm -rf \$CLAUDE_JOB_DIR/tmp/a'" "" $SID
  run 2 "env -S 'rm -rf a'" "$D/gx" $SID
  run 2 "env -iC$TMP/outside rm -rf a" "$D/gx" $SID
  run 2 "env --chd=$TMP/outside rm -rf a" "$D/gx" $SID
  run 2 "env --split-string='rm -rf a'" "$D/gx" $SID
  run 2 "parallel rm -rf ::: $P/gx/a :::: $TMP/list" "" $SID
  run 2 "parallel --workdir $TMP/outside rm -rf ::: a" "$D/gx" $SID
  run 2 "find $P/gx -maxdepth 0 -exec ln -s $TMP/outside $P/gx/l \\; && rm -rf $P/gx/l/" "" $SID
  run 2 "bash -O extglob -c 'rm -rf $P/gx/a'" "" $SID
  run 2 "sh +O extglob -c 'rm -rf $P/gx/a'" "" $SID
  run 2 "echo '' ; rm -rf $P/gx/a" "" $SID                              # a quoted word anywhere in the command
  # Plain-word spellings of the tampering, so only the variable rule (not the plain gate) can stop them.
  run 2 "CLAUDE_JOB_DIR[0]=$TMP/outside && rm -rf $P/gx/a" "" $SID
  run 2 "declare -n R=CLAUDE_JOB_DIR && R=$TMP/outside && rm -rf $P/gx/a" "" $SID
  run 2 "export SYG_SCRATCH_ROOT && rm -rf $P/gx/a" "" $SID
  run 2 "env SYG_SCRATCH_ROOT=/x rm -rf $P/gx/a" "" $SID
  run 2 "rm -rf" "" $SID                                               # an empty target list is never exempt
  run 2 "rm -rf --" "" $SID
  run 0 "rm -rf $P/gx/a && mkdir $P/gx/a" "" $SID
  run 0 "rm -rf $P/gx/a $P/gx/b" "" $SID
  run 0 "rm -rf \"$P/gx/a\"" "" $SID
  run 0 "cd /tmp && rm -rf $P/gx/a" "" $SID
done
run 2 "rm -rf '>' $TMP/outside" ""                                     # no session id, no roots: an empty target list
run 2 "rm -rf '\$CLAUDE_JOB_DIR/tmp/x'" "$TMP/outside"
run 2 "cd $TMP/outside && rm -rf \\\$CLAUDE_JOB_DIR/tmp/x"
run 2 "rm -rf \$CLAUDE_JOB_DIR/tmp/x '>' /home/u/y"
run 0 'rm -rf "$CLAUDE_JOB_DIR/tmp/x"'
run 0 'rm -rf $CLAUDE_JOB_DIR/tmp/a $CLAUDE_JOB_DIR/tmp/b'
run 0 'cd /tmp && rm -rf $CLAUDE_JOB_DIR/tmp/x'
for V in 'CLAUDE_JOB_DIR+=/x' 'declare CLAUDE_JOB_DIR' 'typeset -x CLAUDE_JOB_DIR=/x' 'local CLAUDE_JOB_DIR' 'readonly CLAUDE_JOB_DIR=/x' \
  'export CLAUDE_JOB_DIR' 'printf -v CLAUDE_JOB_DIR %s /x' 'read CLAUDE_JOB_DIR'; do
  run 2 "$V; rm -rf \$CLAUDE_JOB_DIR/tmp/a" "" $SID
done
# The scratch root itself: a symlink to a dir holding <sid> (link path and real path both blocked),
# a relative root, a root owned by someone else (not testable without root: the check is read, not run).
mkdir -p "$TMP/realroot/$SID/x"
ln -s "$TMP/realroot" "$TMP/linkroot"
JOBDIR=""
SROOT="$TMP/linkroot"
run 2 "rm -rf $SROOT/$SID/x" "" $SID
run 2 "rm -rf $TMP/realroot/$SID/x" "" $SID
SROOT="relative-root"
mkdir -p "$TMP/cwdroot/relative-root/$SID/x"
# the hook process resolves the relative root against its own cwd, so run it from there
pushd "$TMP/cwdroot" >/dev/null || exit 1
run 2 "rm -rf relative-root/$SID/x" "$TMP/cwdroot" $SID
popd >/dev/null || exit 1
SROOT="$TMP/sroot"
chmod 755 "$SROOT/$SID"
run 0 "rm -rf $SROOT/$SID/x" "" $SID                                 # mode is scratch-dir's check, not the guard's
chmod 700 "$SROOT/$SID"
EXEMPT=0
run 2 "rm -rf $SROOT/$SID/x" "" $SID                                  # toggle off
EXEMPT=""
SROOT="/nonexistent-scratch-root"
run 2 "rm -rf $TMP/sroot/$SID/x" "" $SID                              # root knob points elsewhere
# Bypass: the owner approved this deletion.
run 0 'SYG_ALLOW_RM=1 rm -rf build'

# The message names the target and carries the pinned phrases.
msg=$(jq -nc --arg c 'cd /tmp && rm -rf build-output' '{tool_input: {command: $c}}' | CLAUDE_JOB_DIR="" bash "$HOOK" 2>&1 >/dev/null)
for phrase in 'RECURSIVE-RM GUARD' 'rm -rf build-output' 'unrecoverable' 'NEW directory' \
  '$CLAUDE_JOB_DIR/tmp' 'safe-clean' 'SYG_ALLOW_RM=1' 'approved in this conversation' \
  'check gitignored' '`scratch-dir NAME`' 'each target is a literal path inside it' 'anywhere else'; do
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
  *'safe-worktree-clean --repo <repo> [--apply] (it judges its SAFE criteria first)'*)
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
