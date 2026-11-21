#!/bin/bash
# Fixture check for worktree-branch-guard.sh — run after ANY edit to the hook.
# Builds a hermetic throwaway git repo with one commit and an existing local
# branch `foo` / `existing-branch`, feeds PreToolUse JSON payloads on stdin,
# and pins deny (exit 2 + stderr message), pass (exit 0 + empty stdout), warn
# on invalid SYG_WORKTREE_BRANCH_RE (exit 0 + additionalContext JSON on stdout),
# and default-pattern parity across safe-worktree-clean, worktree-transfer,
# worktree-branch-guard.sh, and knobs.tsv.
#
# Usage: hooks/worktree-branch-guard.probe.sh   (from anywhere)

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
unset SYG_WORKTREE_BRANCH_RE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HOOK="$SCRIPT_DIR/worktree-branch-guard.sh"

TMP=$(mktemp -d) || { echo "FAIL [setup]: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
OTHER="$TMP/other"
mkdir -p "$REPO" "$OTHER"

git -C "$REPO" init -q -b main >/dev/null 2>&1 || {
  git -C "$REPO" init -q >/dev/null 2>&1
  git -C "$REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
}
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$REPO" branch existing-branch

fail=0
count=0
LAST_ERR=""
LAST_OUT=""

# run_hook <expected-exit> <label> <payload-json> [branch-re-override]
run_hook() {
  local expected="$1" label="$2" payload="$3" has_re="${4+1}" re_val="${4-}" got first_line out rc
  if [ -n "$has_re" ]; then
    {
      IFS= read -r -d '' LAST_ERR
      IFS= read -r -d '' got
      IFS= read -r -d '' LAST_OUT
    } < <(
      {
        out=$(printf '%s' "$payload" | SYG_WORKTREE_BRANCH_RE="$re_val" \
          bash "$HOOK" 2>&3)
        rc=$?
        printf '\0%s\0%s\0' "$rc" "$out"
      } 3>&1
    )
  else
    {
      IFS= read -r -d '' LAST_ERR
      IFS= read -r -d '' got
      IFS= read -r -d '' LAST_OUT
    } < <(
      {
        out=$(printf '%s' "$payload" | env -u SYG_WORKTREE_BRANCH_RE \
          bash "$HOOK" 2>&3)
        rc=$?
        printf '\0%s\0%s\0' "$rc" "$out"
      } 3>&1
    )
  fi
  count=$((count + 1))

  if [ "$got" != "$expected" ]; then
    echo "FAIL [$got≠$expected]: $label (stderr: $LAST_ERR)"
    fail=1
    return
  fi
  if [ "$expected" = 2 ]; then
    if [ -n "$LAST_OUT" ]; then
      echo "FAIL [stdout non-empty on deny]: $label (stdout: $LAST_OUT)"
      fail=1
      return
    fi
    first_line=$(printf '%s\n' "$LAST_ERR" | sed -n '1p')
    case "$first_line" in
      "WORKTREE-BRANCH GUARD — blocked: "?*)
        echo "ok   [2]: $label"
        ;;
      *)
        echo "FAIL [bad first stderr line '$first_line']: $label"
        fail=1
        ;;
    esac
  else
    echo "ok   [$got]: $label"
  fi
}

# check_deny <label> <command> <cwd> <expected-needle1> <expected-needle2> [branch-re-override]
check_deny() {
  local label="$1" cmd="$2" cwd="$3" needle1="$4" needle2="$5" payload
  shift 5
  payload=$(printf '%s\0%s' "$cmd" "$cwd" | jq -Rsc 'split("\u0000") | {tool_name:"Bash",tool_input:{command:.[0]},cwd:.[1]}')
  run_hook 2 "$label" "$payload" "$@"
  count=$((count + 1))
  if grep -qF -- "$needle1" <<<"$LAST_ERR" && grep -qF -- "$needle2" <<<"$LAST_ERR"; then
    echo "ok   [msg]: $label ($needle1; $needle2)"
  else
    echo "FAIL [msg]: $label missing '$needle1' or '$needle2' in stderr: $LAST_ERR"
    fail=1
  fi
}

# check_pass <label> <command> <cwd> [branch-re-override]
check_pass() {
  local label="$1" cmd="$2" cwd="$3" payload
  shift 3
  payload=$(printf '%s\0%s' "$cmd" "$cwd" | jq -Rsc 'split("\u0000") | {tool_name:"Bash",tool_input:{command:.[0]},cwd:.[1]}')
  run_hook 0 "$label" "$payload" "$@"
  if [ -n "$LAST_OUT" ]; then
    echo "FAIL [stdout non-empty on pass]: $label (stdout: $LAST_OUT)"
    fail=1
  fi
}

# --- 1. Deny cases ------------------------------------------------------------
check_deny "explicit -b bad under .claude/worktrees/ denies" \
  "git worktree add -b bad .claude/worktrees/x HEAD" "$REPO" \
  "does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "Fix: name the branch worktree-agent-x: git worktree add -b worktree-agent-x $REPO/.claude/worktrees/x <base>"

check_deny "attached -bbad denies" \
  "git worktree add -bbad .claude/worktrees/x HEAD" "$REPO" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

check_deny "uppercase -B bad denies" \
  "git worktree add -B bad .claude/worktrees/x HEAD" "$REPO" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

check_deny "clustered -qb bad denies" \
  "git worktree add -qb bad .claude/worktrees/x HEAD" "$REPO" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

check_deny "git -C <repo> worktree add -b bad from another cwd denies" \
  "git -C $REPO worktree add -b bad .claude/worktrees/x HEAD" "$OTHER" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

check_deny "cd <repo> && git worktree add -b bad from another cwd denies" \
  "cd $REPO && git worktree add -b bad .claude/worktrees/x HEAD" "$OTHER" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

check_deny "two bad adds in one command lists both" \
  "git worktree add -b bad1 .claude/worktrees/one HEAD && git worktree add -b bad2 .claude/worktrees/two HEAD" "$REPO" \
  "branch bad1 for $REPO/.claude/worktrees/one" \
  "branch bad2 for $REPO/.claude/worktrees/two"

check_deny "implied branch with no existing local branch foo denies with implied prefix" \
  "git worktree add .claude/worktrees/foo" "$REPO" \
  "without -b, git names the new branch after the directory (foo); name the branch worktree-agent-foo: git worktree add -b worktree-agent-foo $REPO/.claude/worktrees/foo <base>" \
  "does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)"

check_deny "custom knob ^feat- with -b worktree-agent-x falls back to matching pattern message" \
  "git worktree add -b worktree-agent-x .claude/worktrees/x HEAD" "$REPO" \
  "does not match SYG_WORKTREE_BRANCH_RE (^feat-)" \
  "Fix: use a branch name matching ^feat-" \
  '^feat-'

check_deny "tracked variable B=bad in -b \"\$B\" expands and denies naming bad" \
  "B=bad; git worktree add -b \"\$B\" .claude/worktrees/x HEAD" "$REPO" \
  "branch bad for $REPO/.claude/worktrees/x does not match SYG_WORKTREE_BRANCH_RE (^worktree-agent-)" \
  "name the branch worktree-agent-x"

# --- 2. Pass cases ------------------------------------------------------------
check_pass "matching -b worktree-agent-x passes" \
  "git worktree add -b worktree-agent-x .claude/worktrees/x HEAD" "$REPO"

check_pass "custom knob ^feat- with -b feat-x passes" \
  "git worktree add -b feat-x .claude/worktrees/x HEAD" "$REPO" \
  '^feat-'

check_pass "commitish given without -b passes (existing-branch)" \
  "git worktree add .claude/worktrees/y existing-branch" "$REPO"

git -C "$REPO" branch foo
check_pass "implied branch where local branch foo already exists passes" \
  "git worktree add .claude/worktrees/foo" "$REPO"

check_pass "--detach passes" \
  "git worktree add --detach .claude/worktrees/d" "$REPO"

check_pass "-d passes" \
  "git worktree add -d .claude/worktrees/d" "$REPO"

check_pass "path outside .claude/worktrees/ with bad -b passes" \
  "git worktree add -b bad $TMP/outside-wt HEAD" "$REPO"

check_pass "git worktree list passes" \
  "git worktree list" "$REPO"

check_pass "git worktree add -h passes" \
  "git worktree add -h -b bad .claude/worktrees/x" "$REPO"

check_pass "path with unexpanded \$VAR passes" \
  "git worktree add -b bad .claude/worktrees/\$UNSET_X HEAD" "$REPO"

check_pass "tracked variable B=worktree-agent-x in -b \"\$B\" expands and passes" \
  "B=worktree-agent-x; git worktree add -b \"\$B\" .claude/worktrees/x HEAD" "$REPO"

check_pass "command substitution in -b \"\$(echo worktree-agent-x)\" is unresolvable and passes" \
  "git worktree add -b \"\$(echo worktree-agent-x)\" .claude/worktrees/x HEAD" "$REPO"

check_pass "for-loop variable in -b \$b is unresolvable and passes" \
  "for b in a c; do git worktree add -b \$b .claude/worktrees/\$b HEAD; done" "$REPO"

run_hook 0 "non-Bash tool passes" \
  "$(printf '%s' "$REPO" | jq -Rsc '{tool_name:"Read",tool_input:{file_path:"git worktree add -b bad .claude/worktrees/x"},cwd:.}')"
if [ -n "$LAST_OUT" ]; then
  echo "FAIL [non-Bash stdout non-empty]: $LAST_OUT"
  fail=1
fi

run_hook 0 "malformed JSON fails open" "{not valid json"
if [ -n "$LAST_OUT" ]; then
  echo "FAIL [malformed JSON stdout non-empty]: $LAST_OUT"
  fail=1
fi

check_pass "empty command passes" "" "$REPO"

# --- 3. Warn case (invalid regex) ---------------------------------------------
WARN_PAYLOAD=$(printf '%s' "$REPO" | jq -Rsc '{tool_name:"Bash",tool_input:{command:"git worktree add -b bad .claude/worktrees/x HEAD"},cwd:.}')
run_hook 0 "invalid regex knob '(' exits 0 with additionalContext JSON" "$WARN_PAYLOAD" '('
WANT_CTX="worktree-branch-guard: SYG_WORKTREE_BRANCH_RE is not a valid extended regex ((); safe-worktree-clean will HOLD every tree as branch-name until it is fixed"
GOT_CTX=$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$LAST_OUT" 2>/dev/null || echo "")
GOT_EV=$(jq -r '.hookSpecificOutput.hookEventName // empty' <<<"$LAST_OUT" 2>/dev/null || echo "")
count=$((count + 1))
if [ "$GOT_EV" = "PreToolUse" ] && [ "$GOT_CTX" = "$WANT_CTX" ] && [ -z "$LAST_ERR" ]; then
  echo "ok   [warn]: invalid regex emits exact additionalContext JSON and empty stderr"
else
  echo "FAIL [warn]: ev='$GOT_EV' ctx='$GOT_CTX' (want '$WANT_CTX') err='$LAST_ERR'"
  fail=1
fi

# --- 4. Drift check: default ^worktree-agent- matches across all 4 surfaces ---
count=$((count + 1))
KNOB_DEF=$(awk -F'\t' '$1=="SYG_WORKTREE_BRANCH_RE"{print $4}' "$REPO_ROOT/plugins/seyag/config/knobs.tsv")
if [ "$KNOB_DEF" = "^worktree-agent-" ] \
  && grep -qF "BRANCH_RE='^worktree-agent-'" "$REPO_ROOT/plugins/seyag/bin/safe-worktree-clean" \
  && grep -qF "BRANCH_RE='^worktree-agent-'" "$REPO_ROOT/plugins/seyag/bin/worktree-transfer" \
  && grep -qF "RE='^worktree-agent-'" "$HOOK"; then
  echo "ok   [drift]: default ^worktree-agent- matches across knobs.tsv, safe-worktree-clean, worktree-transfer, and worktree-branch-guard.sh"
else
  echo "FAIL [drift]: default pattern mismatch (knobs.tsv='$KNOB_DEF')"
  fail=1
fi

echo "---"
echo "$count cases"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
