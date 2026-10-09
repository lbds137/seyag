#!/bin/bash
# PreToolUse:Bash hook (seyag plugin): redirect hand-rolled cache deletion to safe-clean.
#
# Blocks (exit 2) a Bash command that
#   - runs `rm` with a recursive flag on a path named like a regenerable cache
#     (__pycache__, node_modules, .pytest_cache, ...), or
#   - runs `find ... -name <cache> ... -delete` or `-exec rm`, or
#   - pipes `find ... -name <cache>` straight into `xargs rm -r...`,
# and names the safe-clean command to use instead. safe-clean checks each target is inside a git
# repo, isn't a symlink, and holds no tracked file; improvised `rm -rf` checks none of that.
# When a flagged delete's target is a .claude/worktrees path, the message also names
# safe-worktree-clean.
#
# Bypass: put SYG_ALLOW_CACHE_RM=1 in the command (the owner approved this
# specific rm).
# The analysis (commands, newlines included; runner prefixes; the cache names) is
# lib/delete_commands.py, shared with recursive-rm-guard, which defers to exactly what it flags.
# Fail-open: no python3/jq, unparsable input or command, lib import failure → exit 0.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0
case "$CMD" in *SYG_ALLOW_CACHE_RM=1*) exit 0 ;; esac
# Cheap prefilter: nothing to do unless a cache name appears at all.
case "$CMD" in
  *__pycache__* | *node_modules* | *.pytest_cache* | *.ruff_cache* | *.mypy_cache* | *.turbo* | *htmlcov* | *.coverage*) ;;
  *) exit 0 ;;
esac

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# The command goes to python on fd 3, never through the environment: Linux caps one env string
# at 128 KiB (MAX_ARG_STRLEN), and python failing to exec would fail open.
# Exit 11 (not 0) means a flagged delete's rm target or find root is in a .claude/worktrees path.
HITS=$(HOOK_LIB="$HOOK_LIB" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF'
import os, sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from delete_commands import analyze, cache_lines, worktree_target

# The analysis is shared with recursive-rm-guard, which defers only on what cache_lines flags.
hits, _, _ = analyze(os.fsdecode(open(3, "rb").read()).removesuffix("\n"))
print("\n".join(cache_lines(hits)))
sys.exit(11 if worktree_target([h for h in hits if cache_lines([h])]) else 0)
PYEOF
)
PY_RC=$?
[ "$PY_RC" = 0 ] || [ "$PY_RC" = 11 ] || exit 0

[ -n "$HITS" ] || exit 0

WORKTREE_HINT=""
[ "$PY_RC" = 11 ] && WORKTREE_HINT=$'\n'"  agent worktrees: safe-worktree-clean --repo <repo> [--apply] (it judges the seven SAFE criteria first)."

cat >&2 <<EOF
CACHE-RM REDIRECT — use safe-clean for regenerable caches

This command deletes cache folders by hand:
$(printf '%s\n' "$HITS" | sed 's/^/  - /')

Use the checked command instead. It refuses symlinks, anything outside a git repo, and any
folder holding git-tracked files, and it can't touch gitignored data:
  safe-clean <path>...             # e.g. safe-clean node_modules .pytest_cache
  safe-clean --find __pycache__ .  # every __pycache__ under a folder
  safe-clean --dry-run ...         # show what would go${WORKTREE_HINT}
If the owner approved this exact rm, prefix the command with SYG_ALLOW_CACHE_RM=1.
EOF
exit 2
