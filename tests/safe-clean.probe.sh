#!/bin/bash
# Fixture check for bin/safe-clean against throwaway git repos.
# Usage: tests/safe-clean.probe.sh   (from anywhere)

set -uo pipefail
SC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/safe-clean"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

R="$T/repo"; mkdir -p "$R" && git -C "$R" init -q
mkdir -p "$R/a/__pycache__" "$R/b/__pycache__" "$R/node_modules/x" "$R/tracked/__pycache__" "$R/secrets"
echo x > "$R/a/__pycache__/m.pyc"; echo x > "$R/b/__pycache__/n.pyc"; echo x > "$R/node_modules/x/i.js"
echo x > "$R/tracked/__pycache__/keep.pyc"; echo KEY=1 > "$R/secrets/.env"; echo c > "$R/.coverage"
git -C "$R" add -f tracked/__pycache__/keep.pyc && git -C "$R" -c user.email=t@t -c user.name=t commit -qm t
ln -s "$R/a/__pycache__" "$R/linked__pycache__"; ln -s "$R/b" "$R/c"
mkdir -p "$T/outside/__pycache__"

_pipe_out=$("$SC" --dry-run "$R/node_modules") && grep -q "would remove" <<<"$_pipe_out" && [ -d "$R/node_modules" ] && ok "dry-run lists and keeps" || bad "dry-run"
"$SC" "$R/node_modules" >/dev/null && [ ! -e "$R/node_modules" ] && ok "removes node_modules" || bad "remove node_modules"
"$SC" "$R/.coverage" >/dev/null && [ ! -e "$R/.coverage" ] && ok "removes the .coverage file" || bad ".coverage"
"$SC" "$R/secrets" 2>/dev/null; [ $? = 1 ] && [ -f "$R/secrets/.env" ] && ok "refuses a non-cache name" || bad "non-cache name"
"$SC" "$R/tracked/__pycache__" 2>/dev/null; [ $? = 1 ] && [ -f "$R/tracked/__pycache__/keep.pyc" ] && ok "refuses a cache holding tracked files" || bad "tracked"
mkdir -p "$R/x"; ln -s "$R/a/__pycache__" "$R/x/__pycache__"
"$SC" "$R/x/__pycache__" 2>/dev/null; [ $? = 1 ] && [ -d "$R/a/__pycache__" ] && ok "refuses a symlink" || bad "symlink"
"$SC" "$T/outside/__pycache__" 2>/dev/null; [ $? = 1 ] && [ -d "$T/outside/__pycache__" ] && ok "refuses outside a git repo" || bad "outside repo"
"$SC" "$R/c/__pycache__" 2>/dev/null; [ $? = 0 ] && ok "follows a symlinked parent that stays inside the repo" || bad "symlinked parent inside repo"
mkdir -p "$R/d/__pycache__"; echo x > "$R/d/__pycache__/o.pyc"
(cd "$R" && "$SC" --find __pycache__ . >/dev/null 2>&1); rc=$?
[ ! -e "$R/d/__pycache__" ] && [ -f "$R/tracked/__pycache__/keep.pyc" ] && [ $rc = 1 ] \
  && ok "--find removes untracked matches, refuses the tracked one, exits 1" || bad "--find (rc $rc)"
"$SC" --find .env "$R" 2>/dev/null; [ $? = 1 ] && [ -f "$R/secrets/.env" ] && ok "--find refuses a non-cache name" || bad "--find non-cache"
"$SC" "$R/nope/__pycache__" 2>/dev/null; [ $? = 1 ] && ok "refuses a missing path" || bad "missing"
mkdir -p "$R/e/__pycache__"
out=$("$SC" --help "$R/e/__pycache__" 2>&1); [ $? = 0 ] && grep -q "Usage:" <<< "$out" && [ -d "$R/e/__pycache__" ] \
  && ok "--help prints usage, exits 0, removes nothing it was given" || bad "--help"
exit $fail
