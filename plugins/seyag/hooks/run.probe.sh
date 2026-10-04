#!/bin/bash
# Fixture check for run.sh (the seyag hook dispatcher).
#   1. a project-local .claude/hooks/<name>.sh exists → silent exit 0 (yield)
#   2. no project copy → the plugin hook runs; exit 2 + stderr pass through
#   3. stdin reaches the hook; stdout passes through
#   4. PYTHONDONTWRITEBYTECODE is exported to the hook
#   5. sdk-* entrypoints skip the turn-shape hooks; a background session a person
#      drives (entrypoint cli, SESSION_ATTENDED=0) keeps them
# Uses a throwaway fake hook placed next to run.sh in a temp copy, so the real
# hooks are never involved.
#
# Usage: hooks/run.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/plugin/hooks" "$TMP/proj-with/.claude/hooks" "$TMP/proj-without"
cp "$SCRIPT_DIR/run.sh" "$TMP/plugin/hooks/run.sh"
RUN="$TMP/plugin/hooks/run.sh"
# Every run.sh call starts without the caller's entrypoint/attended env, so a probe
# run inside an sdk-* or background session cannot flip the cases below. A case
# sets them itself with leading NAME=value arguments.
runsh() {
  local -a set=()
  while [[ "${1:-}" == *=* ]]; do set+=("$1"); shift; done
  env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ATTENDED "${set[@]+"${set[@]}"}" bash "$RUN" "$@"
}

cat > "$TMP/plugin/hooks/fake-guard.sh" <<'EOF'
#!/bin/bash
IN=$(cat)
echo "stdout:$IN:${PYTHONDONTWRITEBYTECODE:-unset}"
echo "BLOCKED by fake-guard" >&2
exit 2
EOF
echo '#!/bin/bash' > "$TMP/proj-with/.claude/hooks/fake-guard.sh"

fail=0
check() { # $1 label, $2 want-rc, $3 got-rc, $4 want-stdout, $5 got-stdout, $6 want-stderr, $7 got-stderr
  if [ "$3" = "$2" ] && [ "$5" = "$4" ] && [ "$7" = "$6" ]; then
    echo "ok   [$3]: $1"
  else
    echo "FAIL [rc $3 want $2 | stdout '$5' want '$4' | stderr '$7' want '$6']: $1"
    fail=1
  fi
}

# --- 1. project copy exists → yield silently ----------------------------------
OUT=$(printf 'payload' | CLAUDE_PROJECT_DIR="$TMP/proj-with" runsh fake-guard 2>"$TMP/err")
RC=$?
check "project copy present → silent exit 0" 0 "$RC" "" "$OUT" "" "$(cat "$TMP/err")"

# --- 1b. CLAUDE_PROJECT_DIR unset → falls back to PWD --------------------------
OUT=$(cd "$TMP/proj-with" && printf 'payload' | (unset CLAUDE_PROJECT_DIR; runsh fake-guard) 2>"$TMP/err")
RC=$?
check "no CLAUDE_PROJECT_DIR, project copy in PWD → yield" 0 "$RC" "" "$OUT" "" "$(cat "$TMP/err")"

# --- 2. no project copy → passthrough of rc 2, stdout, stderr ------------------
OUT=$(printf 'payload' | CLAUDE_PROJECT_DIR="$TMP/proj-without" PYTHONDONTWRITEBYTECODE='' runsh fake-guard 2>"$TMP/err")
RC=$?
check "no project copy → exit 2, stdin/stdout/stderr pass through, PYTHONDONTWRITEBYTECODE=1" \
  2 "$RC" "stdout:payload:1" "$OUT" "BLOCKED by fake-guard" "$(cat "$TMP/err")"

# --- 3. unknown / unsafe hook names fail open ----------------------------------
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh no-such-hook >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: unknown hook name fails open" || { echo "FAIL [$RC]: unknown hook name"; fail=1; }
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh ../fake-guard >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: path-traversal name refused" || { echo "FAIL [$RC]: path-traversal name"; fail=1; }

# --- 4. a hook with a syntax error fails open instead of exiting 2 -------------
printf '#!/bin/bash\nif then fi (\n' > "$TMP/plugin/hooks/broken-guard.sh"
printf '' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh broken-guard >/dev/null 2>"$TMP/err"
RC=$?
[ "$RC" = 0 ] && grep -q "syntax error" "$TMP/err" && echo "ok   [0]: syntax error fails open with a note" \
  || { echo "FAIL [$RC]: syntax error should fail open"; fail=1; }

# --- 5. headless (sdk-*) runs skip turn-shape hooks but keep shell guards -------
# Leading NAME=value args to runsh are set after the base unset, so each case
# controls the entrypoint/attended env itself.
cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/turn-end-shape-gate.sh"
cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/promise-ledger-check.sh"
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-cli run skips a turn-shape hook" || { echo "FAIL [$RC]: sdk-cli turn-shape hook should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli promise-ledger-check >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-cli run skips promise-ledger-check" || { echo "FAIL [$RC]: sdk-cli promise-ledger-check should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli fake-guard >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: sdk-cli run still runs a shell guard" || { echo "FAIL [$RC]: sdk-cli shell guard should still run"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-ts turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && echo "ok   [0]: sdk-ts run skips a turn-shape hook" || { echo "FAIL [$RC]: sdk-ts turn-shape hook should be skipped"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ATTENDED=0 turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: background session a person drives (cli, ATTENDED=0) keeps turn-shape hooks" || { echo "FAIL [$RC]: background session (cli, ATTENDED=0) turn-shape hook should run"; fail=1; }
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh turn-end-shape-gate >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: entrypoint unset keeps turn-shape hooks" || { echo "FAIL [$RC]: unset entrypoint turn-shape hook should run"; fail=1; }

cp "$TMP/plugin/hooks/fake-guard.sh" "$TMP/plugin/hooks/route-check.sh"
printf 'x' | CLAUDE_PROJECT_DIR="$TMP/proj-without" runsh CLAUDE_CODE_ENTRYPOINT=sdk-cli route-check >/dev/null 2>&1
RC=$?
[ "$RC" = 2 ] && echo "ok   [2]: route-check is not on the sdk skip list (a headless run on the wrong route is still wrong)" || { echo "FAIL [$RC]: route-check must run under sdk-cli"; fail=1; }

exit $fail
