#!/bin/bash
# Fixture check for hooks/long-job-chain-guard.sh: PreToolUse JSON in, the
# hook's exit code and stderr out, run hermetically (temp cache and project
# dir, no config file). The last two cases run through run.sh to pin the
# long-job-chain component toggle (SYG_DISABLE).
# Usage: hooks/long-job-chain-guard.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOKS/long-job-chain-guard.sh"
# A missing hook is a loud failure, never a vacuous pass.
if [ ! -f "$HOOK" ]; then
  echo "FAIL hook script missing: $HOOK"
  exit 1
fi
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/xdg-cache" # run.sh syntax-ok stamps off the real cache
export CLAUDE_PROJECT_DIR="$TMP/proj"  # a project-local hook override would shadow this one
mkdir -p "$TMP/proj"
unset SYG_PROFILE SYG_ENABLE SYG_DISABLE SYG_LONG_JOB_CMD

payload() { jq -nc --arg c "$1" '{tool_input: {command: $c}}'; }

# run WANT-RC COMMAND [VAR=VAL ...]: payload on stdin, hook's exit code out,
# its stderr left in ERR for the message checks below.
ERR=""
run() {
  local want=$1 cmd=$2 shown=$2 rc
  shift 2
  ERR=$(payload "$cmd" | env "$@" bash "$HOOK" 2>&1 >/dev/null; exit "${PIPESTATUS[1]}")
  rc=$?
  if [ ${#shown} -gt 120 ]; then shown="${shown:0:40}...[${#cmd} bytes]...${shown: -30}"; fi
  if [ "$rc" = "$want" ]; then
    echo "ok   [$rc]: $shown"
  else
    echo "FAIL [$rc want $want]: $shown"
    [ -n "$ERR" ] && printf '     stderr: %s\n' "$ERR"
    fail=1
  fi
}

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Quote-split runner name passes the fast path (bash runs it as long-job).
run 2 "lo''ng-job run N -- a && b"
# Refuse: exit 2, the refusal names the runner and the fix.
run 2 'long-job run N -- a && b'
if grep -q "^long-job: refusing:" <<<"$ERR" && grep -q "Put the chain inside the job: long-job run " <<<"$ERR"; then
  ok "refusal stderr names 'long-job: refusing:' and the fix"
else
  bad "refusal stderr missing/incorrect: $ERR"
fi
# Clean: exit 0, nothing on stderr.
run 0 "long-job run N -- bash -c 'a && b'"
[ -z "$ERR" ] && ok "clean command is silent" || bad "clean command wrote stderr: $ERR"
# Fast path: text naming no runner exits 0 without a verdict.
run 0 'echo hello && pwd -P'
[ -z "$ERR" ] && ok "text without long-job is silent" || bad "unrelated text wrote stderr: $ERR"
# Runner alias: the first word of SYG_LONG_JOB_CMD is refused like long-job.
run 2 'jobrun run x -- true && echo y' SYG_LONG_JOB_CMD='jobrun run'
if grep -q "^jobrun: refusing:" <<<"$ERR"; then
  ok "alias refusal stderr names 'jobrun: refusing:'"
else
  bad "alias refusal stderr missing: $ERR"
fi
# The alias also opens the fast path for text without the literal long-job token.
run 0 'echo hello && pwd -P' SYG_LONG_JOB_CMD='jobrun run'
[ -z "$ERR" ] && ok "alias set, unrelated text still silent" || bad "alias fast path wrote stderr: $ERR"
# A heredoc body quoting a chain is data, not a chain.
run 0 "$(printf 'cat <<'"'"'EOF'"'"'\nlong-job run x -- a && b\nEOF\n')"
[ -z "$ERR" ] && ok "heredoc body is clean" || bad "heredoc body wrote stderr: $ERR"
# Unparsable payload fails open.
if printf 'this is not json' | bash "$HOOK" >/dev/null 2>"$TMP/err"; then
  [ -s "$TMP/err" ] && bad "non-JSON stdin wrote stderr: $(cat "$TMP/err")" || ok "non-JSON stdin exits 0 silently"
else
  echo "FAIL [want 0]: non-JSON stdin"
  fail=1
fi

# Fail open: python's own rc 2 (missing checker, bad cache arg) never blocks a call.
mkdir -p "$TMP/iso/hooks"
cp "$HOOK" "$TMP/iso/hooks/long-job-chain-guard.sh"
ERR=$(payload 'long-job run N -- a && b' | bash "$TMP/iso/hooks/long-job-chain-guard.sh" 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$ERR" ] && ok "missing checker script exits 0 silently" || bad "missing checker: rc $rc: $ERR"
run 0 'long-job run N -- a && b' SYG_PY_CACHE_ARG=--bogus
[ -z "$ERR" ] && ok "bad SYG_PY_CACHE_ARG is silent" || bad "bad SYG_PY_CACHE_ARG wrote stderr: $ERR"

# Component toggle, through run.sh like hooks.json wires it.
runsh() {
  local want=$1 cmd=$2 shown=$2 rc
  shift 2
  ERR=$(payload "$cmd" | env -u SYG_PROFILE -u SYG_ENABLE "$@" bash "$HOOKS/run.sh" long-job-chain-guard 2>&1 >/dev/null; exit "${PIPESTATUS[1]}")
  rc=$?
  if [ ${#shown} -gt 120 ]; then shown="${shown:0:40}...[${#cmd} bytes]...${shown: -30}"; fi
  if [ "$rc" = "$want" ]; then
    echo "ok   [$rc via run.sh]: $shown"
  else
    echo "FAIL [$rc want $want via run.sh]: $shown"
    [ -n "$ERR" ] && printf '     stderr: %s\n' "$ERR"
    fail=1
  fi
}
runsh 2 'long-job run N -- a && b'
runsh 0 'long-job run N -- a && b' SYG_DISABLE=long-job-chain
[ -z "$ERR" ] && ok "SYG_DISABLE=long-job-chain is silent" || bad "disabled component wrote stderr: $ERR"

exit $fail
