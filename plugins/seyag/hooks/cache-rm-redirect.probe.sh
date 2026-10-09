#!/bin/bash
# Fixture check for cache-rm-redirect.sh: exit-code table over the command shapes that matter.
# Usage: hooks/cache-rm-redirect.probe.sh   (from anywhere)

set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cache-rm-redirect.sh"
fail=0
run() { # $1 want-rc, $2 command
  local rc shown=$2
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  printf '%s' "$2" | jq -Rsc '{tool_input: {command: .}}' | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ ${#shown} -gt 200 ] && shown="${shown:0:40}...[${#2} bytes]...${shown: -30}"
  if [ "$rc" = "$1" ]; then echo "ok   [$rc]: $shown"; else echo "FAIL [$rc want $1]: $shown"; fail=1; fi
}
# A heredoc past Linux's 128 KiB cap on one env string (MAX_ARG_STRLEN) in front of a case.
BIGDOC=$'git commit -F - <<\'EOF\'\n'"$(printf '%*s' 214000 '' | tr ' ' x)"$'\nEOF\n'

# Blocked: hand-rolled cache deletion.
run 2 'rm -rf node_modules'
run 2 'rm -r plugins/seyag/hooks/lib/__pycache__/'
run 2 'cd sub && rm -Rf .pytest_cache .ruff_cache'
run 2 'rm --recursive --force htmlcov'
run 2 'find . -name __pycache__ -type d -exec rm -rf {} +'
run 2 'find . -name "__pycache__" -delete'
run 2 'find . -name __pycache__ -print0 | xargs -0 rm -rf'
run 2 'sudo rm -rf ./node_modules'
# Command boundaries come from the shared splitter (lib/shell_quotes.py simple_commands).
run 2 $'cd /tmp\nrm -rf x/__pycache__'           # a newline ends the cd
run 2 $'cd /tmp && rm -rf \\\nx/__pycache__'     # backslash-newline continues the rm
run 2 "bash -c 'rm -rf node_modules'"
run 2 $'cat <<\'EOF\' | bash\nrm -rf node_modules\nEOF'
run 0 $'echo "cd /tmp\nrm -rf x/__pycache__"'   # a quoted newline is text, not a boundary
run 0 $'cat > notes.md <<\'EOF\'\nrm -rf node_modules\nEOF'  # heredoc data, not a command
run 2 "${BIGDOC}rm -rf node_modules"              # a command past 128 KiB
run 0 "${BIGDOC}ls node_modules"
# Runner prefixes come off with their option values (lib/shell_quotes.py unwrap_runners).
run 2 'env rm -rf node_modules'
run 2 'nice -n 5 rm -rf node_modules'
run 2 'sudo -u root rm -rf node_modules'
run 2 'timeout 60 rm -rf node_modules'
run 2 'find . -name node_modules -exec env rm -rf {} +'
run 2 'find . -name node_modules -print0 | xargs -0 -n 1 rm -rf'
run 2 'find . -name node_modules | xargs --max-args 1 rm -rf'
# xargs stdin is a cache only when a cache find feeds THAT pipeline.
run 0 'find . -name node_modules -prune; ls ~ | xargs -n 1 rm -rf'
# Every name in the shared cache list gets past the bash prefilter above the python.
names=$(cd "$(dirname "$HOOK")/lib" && PYTHONDONTWRITEBYTECODE=1 python3 -c 'from delete_commands import CACHES; print(*sorted(CACHES))')
[ "$(wc -w <<<"$names")" -ge 8 ] || { echo "FAIL could not read CACHES from lib/delete_commands.py: '$names'"; fail=1; }
for name in $names; do
  run 2 "rm -rf sub/$name"
done
# Allowed.
run 0 'safe-clean node_modules'
run 0 'safe-clean --find __pycache__ .'
run 0 'rm -rf build/tmp-output'
run 0 'rm node_modules.txt'
run 0 'rm .coverage'
run 0 'git rm -r --cached node_modules'
run 0 'ls node_modules | head'
run 0 'find . -name __pycache__ -type d'
run 0 'SYG_ALLOW_CACHE_RM=1 rm -rf node_modules'
run 0 'echo "rm -rf node_modules is risky"'
run 0 ''
# A blocked delete targeting a .claude/worktrees path also names safe-worktree-clean; others don't.
hint() { # $1 want "yes" or "no", $2 command
  local msg got=no
  msg=$(jq -nc --arg c "$2" '{tool_input: {command: $c}}' | bash "$HOOK" 2>&1 >/dev/null)
  case "$msg" in
    CACHE-RM*) ;;
    *) echo "FAIL not blocked: $2"; fail=1; return ;;
  esac
  case "$msg" in
    *'  agent worktrees: safe-worktree-clean --repo <repo> [--apply] (it judges the seven SAFE criteria first)'*) got=yes ;;
    *safe-worktree-clean*) got=garbled ;;
  esac
  if [ "$got" = "$1" ]; then echo "ok   hint $1: $2"; else echo "FAIL hint $got want $1: $2"; fail=1; fi
}
hint yes 'rm -rf .claude/worktrees/agent-x/node_modules'
hint yes 'find /srv/repo/.claude/worktrees/agent-x -name __pycache__ -exec rm -rf {} +'
hint no 'rm -rf node_modules'
hint no 'cd .claude/worktrees/agent-x && rm -rf node_modules'
exit $fail
