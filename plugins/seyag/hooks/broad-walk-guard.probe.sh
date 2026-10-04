#!/bin/bash
# Fixture check for broad-walk-guard.sh: exit-code table over the command shapes that matter.
# Usage: hooks/broad-walk-guard.probe.sh   (from anywhere)

set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/broad-walk-guard.sh"
fail=0
run() { # $1 want-rc, $2 command, $3 cwd (default: a project folder)
  local rc shown=$2
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  printf '%s' "$2" | jq -Rsc --arg d "${3:-$HOME/Projects/seyag}" '{tool_input: {command: .}, cwd: $d}' |
    bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ ${#shown} -gt 200 ] && shown="${shown:0:40}...[${#2} bytes]...${shown: -30}"
  if [ "$rc" = "$1" ]; then echo "ok   [$rc]: $shown (in ${3:-project})"; else echo "FAIL [$rc want $1]: $shown"; fail=1; fi
}
# A heredoc past Linux's 128 KiB cap on one env string (MAX_ARG_STRLEN) in front of a case.
BIGDOC=$'git commit -F - <<\'EOF\'\n'"$(printf '%*s' 214000 '' | tr ' ' x)"$'\nEOF\n'

# Blocked: walks of /, /home, the home folder or the Drive mount.
run 2 'find / -name errors.go'
run 2 'find / -path /home/deck/gdrive -prune -o -name "*.go" -print 2>/dev/null | head'
run 2 'find ~ -name foo'
run 2 'find $HOME -type f'
run 2 'find "${HOME}/" -newer x'
run 2 'find /home -name x'
run 2 'find ~/gdrive/Books -name "*.pdf"'
run 2 'find ~/gdrive -maxdepth 2 -name x'       # shallow, but inside the mount
run 2 'find ~/gdrive -maxdepth 1'              # any depth at the mount root lists the Drive
run 2 'find ~/gdrive/Books -maxdepth 2 -name x' # below the top level, but two levels deep
run 2 'find /tmp ~/gdrive -maxdepth 1'
run 2 'find ~/gdrive/Books -maxdepth 1 -maxdepth 5' # GNU find honours the LAST -maxdepth
run 2 'find ~ -maxdepth 1 -maxdepth 5'
run 2 'cd /tmp && find -L / -name x'
run 2 'du -sh ~'
run 2 'du -sh /* 2>/dev/null'  # the shell expands /* to every top-level folder
run 2 'du -sh ~/* | sort -h'
run 0 'du -sh ./*'
run 2 'grep -rn TODO ~'
run 2 'grep -R foo /'
run 2 'rg pattern ~'
run 2 'fd errors.go /'
run 2 'sudo find / -xdev -name x'
run 2 'timeout 60 find / -name x'
run 2 'find . -name x' "$HOME"
run 2 'du -sh .' "$HOME/gdrive"
# Command boundaries come from the shared splitter (lib/shell_quotes.py simple_commands).
run 2 $'cd /tmp\nfind / -name x'               # a newline ends the cd
run 2 $'cd /tmp && find \\\n/ -name x'         # backslash-newline continues the find
run 2 "bash -c 'find / -name x'"
run 0 $'echo "cd /tmp\nfind / -name x"'       # a quoted newline is text, not a boundary
run 2 $'# it\'s here\nfind / -name x'           # an apostrophe in a comment opens no quote
run 2 $'echo hi # don\'t worry\nfind / -name x'
run 0 '# find / -name x'                        # a comment is not a command
run 2 "sudo bash -c 'find / -name x'"           # a runner before the wrapper
run 2 "timeout 60 bash -c 'find / -name x'"
run 2 'eval find / -name x'                     # eval joins its arguments
run 2 'env find / -name x'
run 2 'bash <<< "find / -name x"'               # a here-string fed to a shell
run 2 'echo "find / -name x" | bash'            # echo piped into a shell
run 2 "watch -n 5 'find / -name x'"             # watch runs its joined args via sh -c
run 2 "watch -q 3 'find / -name x'"             # -q/--equexit take a value too
run 0 "watch -n 5 'ls -la'"
# A walker given no path walks the cwd.
run 2 'grep -rl "SEB" --include="*.md" 2>/dev/null | head' "$HOME/gdrive/Books"
run 2 'du -sh' "$HOME"
run 2 'rg pattern' "$HOME"
run 0 'ls | rg pattern' "$HOME"                 # rg fed by a pipe reads stdin
run 0 'grep -rn TODO' "$HOME/Projects/seyag"
run 0 'ls -la /proc/$(pgrep -f x | head -1)/fd 2>&1 | tail' "$HOME"   # /fd is the rest of a word
# A command past 128 KiB still reaches the analysis.
run 2 "${BIGDOC}find / -name x"
run 0 "${BIGDOC}find . -name x"
# An option's value is not a path: these walk the cwd (the home folder).
run 2 'rg -n -C 3 foo' "$HOME"
run 2 'rg -t md foo' "$HOME"
run 2 'rg --context 3 foo' "$HOME"
run 2 'grep -rn -A 3 foo' "$HOME"
run 2 'grep -rnC 3 foo' "$HOME"                  # a cluster ending in a value flag
run 2 'grep -rnA3 foo' "$HOME"                   # the value attached to the cluster
run 2 'fd -e md foo' "$HOME"
run 2 'fd -x rm foo' "$HOME"                     # -x's command is not a path either
# fd's -x/-X command ends at a `;` word; fd reads its own args again after it.
run 2 'fd -x echo {} \; foo /'
run 2 "fd -x echo {} ';' foo ~"
run 2 'fd --exec echo {} \; foo /'
run 2 'fd -X ls \; -e md . ~/gdrive'
run 2 'fd foo --search-path ~/gdrive'
run 2 'fd foo --base-directory /'
run 2 'rg --files ~'                             # --files takes no pattern: every operand is a path
run 2 'rg --files /'
run 2 'rg --files ~/gdrive/Books | head'
run 0 'rg -n foo -g "*.ts" src' "$HOME"
run 0 'rg -n -C 3 foo src' "$HOME"
run 0 'fd -e md foo src' "$HOME"
run 0 'grep -rnC3 foo src' "$HOME"
run 0 'grep -r -e foo src' "$HOME"
run 0 'fd -e md foo src -x wc -l /' "$HOME"      # / belongs to the command fd runs
# Allowed.
run 0 'find . -name "*.go"'
run 0 'find ~/Projects/seyag -name "*.sh"'
run 0 'find ~/go/pkg/mod -maxdepth 3 -name errors.go'
run 0 'find / -maxdepth 1 -type d'
run 0 'find ~ -maxdepth 2 -name "*.md"'
# -maxdepth 1 below the mount's top level is one readdir, like ls (the path need not exist).
run 0 "find '$HOME/gdrive/Shared/Project Files/Archive/Notes' -maxdepth 1 -type d | wc -l"
run 0 'find ~/gdrive/Books -maxdepth 1'
run 0 'find ~ -maxdepth 5 -maxdepth 1' # last -maxdepth wins: 1, so only one readdir at the mount root
run 0 'du -sh /tmp/node-compile-cache'
run 0 'grep -n foo ~/.bashrc'
run 0 'grep foo /etc/hosts'
run 0 'grep -rn TODO .'
run 0 'rg -n pattern ~/Projects'
run 0 'ls ~/gdrive'
run 0 'echo "find / is dangerous"'
run 0 'git log --grep=find'
run 0 'SYG_ALLOW_BROAD_WALK=1 find / -name x'
run 0 ''
exit $fail
