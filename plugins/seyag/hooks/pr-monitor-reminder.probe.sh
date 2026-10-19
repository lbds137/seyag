#!/bin/bash
# Fixture check for pr-monitor-reminder.sh — run after ANY edit to the hook.
#
# The hook exits 0 on every path (fail-open), so exit code carries no
# information: every case asserts on OUTPUT. `gh` is shimmed onto the front
# of PATH for PR-number resolution; `git` stays real (branch/HEAD lookups the
# repo already answers), except the dedup-by-SHA case, which needs a HEAD
# that MOVES and runs inside a disposable throwaway repo under $WORK so the
# real checkout's HEAD is never touched.
#
# What this probe does NOT pin: whether real `gh pr create`/`gh pr list`
# still emit the exact fields this hook reads (`.tool_response.stdout` for
# the PostToolUse Bash shape, `--jq '.[0].number'` for the list) — see
# pr-monitor-reminder.sh's own header for that field's doc citation. It also
# does not re-verify that `additionalContext` is the channel that reaches
# Claude for PostToolUse; that is cited from the hooks reference in the
# script's header, and case 8 below only pins the JSON SHAPE the hook emits.
#
# Usage: plugins/seyag/hooks/pr-monitor-reminder.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
HOOK="$SCRIPT_DIR/pr-monitor-reminder.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Hermetic: an ambient SYG_PR_MONITOR_SEEN_FILE would beat every per-case
# seen-file fixture below.
unset SYG_PR_MONITOR_SEEN_FILE
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"

# --- the gh shim -------------------------------------------------------------
# FAKE_GH_PR_LIST_NUM   stdout for `pr list --head <branch> --state open ...`
#                       (default: empty -> no open PR)
# FAKE_GH_LOG           if set, every call's cwd ($PWD) + argv is appended,
#                       so a case can assert WHICH directory `gh` actually
#                       ran from (proving the resolved effective directory,
#                       not just that some `gh pr list` answered).
# FAKE_GH_PR_LIST_SLEEP seconds to sleep before answering `pr list` (default
#                       0) — simulates a hung/slow `gh`, to prove the hook's
#                       own 2s bound kills it rather than waiting it out.
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
if [ -n "${FAKE_GH_LOG:-}" ]; then
  printf '%s\t%s\n' "$PWD" "$*" >> "$FAKE_GH_LOG"
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  sleep "${FAKE_GH_PR_LIST_SLEEP:-0}"
  echo "${FAKE_GH_PR_LIST_NUM:-}"
  exit 0
fi
echo "fake-gh: unhandled: $*" >&2
exit 1
SHIM
chmod +x "$FAKE_BIN/gh"

FAILURES=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# run <tool_name> <command> [env overrides...]
#   -> sets OUT (hook stdout+stderr). No `.cwd` in the payload — the hook
#   falls back to its own process cwd (priority 4), matching whatever the
#   caller `cd`'d to (or not) before invoking run_hook.
run_hook() {
  local tool="$1" command="$2"; shift 2
  local payload
  # The command reaches jq on stdin, not argv, so a case past 128 KiB is not capped by exec.
  payload=$(printf '%s' "$command" | jq -Rs --arg t "$tool" '{tool_name:$t, tool_input:{command:.}}')
  printf '%s' "$payload" | env PATH="$FAKE_BIN:$PATH" "$@" "$HOOK" 2>&1
}

# run_hook_cwd <tool_name> <command> <payload .cwd> [env overrides...]
#   -> same, but with an explicit `.cwd` field (priority 3), independent of
#   wherever the calling shell actually is.
run_hook_cwd() {
  local tool="$1" command="$2" cwd="$3"; shift 3
  local payload
  payload=$(jq -n --arg t "$tool" --arg c "$command" --arg cwd "$cwd" \
    '{tool_name:$t, tool_input:{command:$c}, cwd:$cwd}')
  printf '%s' "$payload" | env PATH="$FAKE_BIN:$PATH" "$@" "$HOOK" 2>&1
}

cd "$REPO_ROOT" || exit 1
SEEN1="$WORK/seen1"
SEEN2="$WORK/seen2"

# --- 1. a Bash push with an open PR prints the banner once ------------------
OUT=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$SEEN1" FAKE_GH_PR_LIST_NUM=42)
[[ "$OUT" == *'"hookEventName": "PostToolUse"'* && "$OUT" == *"PR #42"* ]] \
  && pass "open PR -> banner prints once" \
  || { fail "open PR -> banner prints once"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- 2. a second identical call is deduped (same PR, same head SHA) --------
OUT2=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$SEEN1" FAKE_GH_PR_LIST_NUM=42)
[ -z "$OUT2" ] && pass "identical second push -> silent (dedup)" \
  || { fail "identical second push -> silent (dedup)"; printf '%s\n' "$OUT2" | sed 's/^/      /'; }

# --- 2b. the SYG_PR_MONITOR_SEEN_FILE override is honored --------------------
# The dedup on the second call proves the stamp went to (and was read back
# from) the path the override named — not the ambient default.
OUT2B=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen-syg" FAKE_GH_PR_LIST_NUM=42)
[[ "$OUT2B" == *'"hookEventName": "PostToolUse"'* && "$OUT2B" == *"PR #42"* ]] \
  && pass "SYG_PR_MONITOR_SEEN_FILE: fresh file -> banner prints" \
  || { fail "SYG_PR_MONITOR_SEEN_FILE: fresh file -> banner prints"; printf '%s\n' "$OUT2B" | sed 's/^/      /'; }
OUT2C=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen-syg" FAKE_GH_PR_LIST_NUM=42)
[ -z "$OUT2C" ] && pass "SYG_PR_MONITOR_SEEN_FILE: identical second push -> silent (dedup)" \
  || { fail "SYG_PR_MONITOR_SEEN_FILE: identical second push -> silent (dedup)"; printf '%s\n' "$OUT2C" | sed 's/^/      /'; }

# --- 3. no open PR -> silent -------------------------------------------------
OUT3=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$SEEN2" FAKE_GH_PR_LIST_NUM=)
[ -z "$OUT3" ] && pass "no open PR -> silent" \
  || { fail "no open PR -> silent"; printf '%s\n' "$OUT3" | sed 's/^/      /'; }

# --- 4. non-Bash tool -> silent ---------------------------------------------
PAYLOAD4=$(jq -n '{tool_name:"Write", tool_input:{file_path:"x", content:"git push"}}')
OUT4=$(printf '%s' "$PAYLOAD4" | env PATH="$FAKE_BIN:$PATH" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen4" "$HOOK" 2>&1)
[ -z "$OUT4" ] && pass "non-Bash tool_name -> silent" \
  || { fail "non-Bash tool_name -> silent"; printf '%s\n' "$OUT4" | sed 's/^/      /'; }

# --- 5. a command that isn't git push / gh pr create -> silent -------------
OUT5=$(run_hook "Bash" "echo hi" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen5" FAKE_GH_PR_LIST_NUM=99)
[ -z "$OUT5" ] && pass "unrelated Bash command -> silent" \
  || { fail "unrelated Bash command -> silent"; printf '%s\n' "$OUT5" | sed 's/^/      /'; }

# --- 6. a tags-only push -> silent ------------------------------------------
OUT6=$(run_hook "Bash" "git push origin --tags" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen6" FAKE_GH_PR_LIST_NUM=99)
[ -z "$OUT6" ] && pass "tags-only push -> silent" \
  || { fail "tags-only push -> silent"; printf '%s\n' "$OUT6" | sed 's/^/      /'; }

# --- 7. a project with its own .claude/hooks/pr-monitor-reminder.sh ->
#         silent via run.sh's generic yield (not this script's own logic) --
PROJ="$WORK/proj-with-copy"
mkdir -p "$PROJ/.claude/hooks"
echo '#!/bin/bash' > "$PROJ/.claude/hooks/pr-monitor-reminder.sh"
PAYLOAD7=$(jq -n '{tool_name:"Bash", tool_input:{command:"git push"}}')
OUT7=$(printf '%s' "$PAYLOAD7" | env -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$PROJ" \
  bash "$SCRIPT_DIR/run.sh" pr-monitor-reminder 2>&1)
RC7=$?
[ "$RC7" -eq 0 ] && [ -z "$OUT7" ] && pass "project-local copy present -> run.sh yields silently" \
  || { fail "project-local copy present -> run.sh yields silently (rc=$RC7)"; printf '%s\n' "$OUT7" | sed 's/^/      /'; }

# --- 8. the banner's required substrings and the unresolved substitution ---
OUT8=$(run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen8" FAKE_GH_PR_LIST_NUM=7)
CTX8=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT8" 2>/dev/null || echo "")
check_contains() {
  [[ "$CTX8" == *"$1"* ]] && pass "banner contains: $1" || fail "banner contains: $1"
}
check_contains 'select:Monitor'
check_contains 'TaskStop'
check_contains 'persistent: false'
# Dual-path banner: the reduced-toolset path (background pr-ci-wait) is
# prescribed with its own arm command, sentinel list and review endpoints.
check_contains 'PATH B'
check_contains 'run_in_background'
check_contains '10-minute cap'
check_contains 'CI_GATE_STARTUP_FAILURE'
check_contains 'CI_GATE_REVIEW_MISSING'
check_contains 'gh pr view 7 --comments'
check_contains 'gh api repos/{owner}/{repo}/pulls/7/reviews'
check_contains 'gh api repos/{owner}/{repo}/pulls/7/comments'
# The whole command `cd`s into the already-resolved, single-quoted toplevel
# (REPO_ROOT here, resolved via priority-4 fallback since this case's payload
# carries no `.cwd`) FIRST — pr-ci-wait has no -C/--cwd flag of its own, so
# every call it makes (gh api, git cat-file, review auto-detect) needs to
# already be running from the right directory, not just the --sha
# substitution's own rev-parse. Only the SHA's `$(...)` stays
# unresolved.
REPO_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)
# A detached checkout (CI checks out the PR's merge ref) prints HEAD.
if [ "$REPO_BRANCH" = HEAD ]; then REPO_REV=HEAD; else REPO_REV="refs/heads/$REPO_BRANCH"; fi
check_contains "cd '$REPO_ROOT' && pr-ci-wait 7 --sha \$(git rev-parse '$REPO_REV')"
# No 40-hex SHA anywhere in the banner: the substitution must stay unresolved.
if grep -qE '[0-9a-f]{40}' <<<"$CTX8"; then
  fail "banner: no resolved 40-hex SHA present"
else
  pass "banner: no resolved 40-hex SHA present"
fi

# --- 9. gh pr create output URL parsed for the PR number -------------------
CREATE_PAYLOAD=$(jq -n '{tool_name:"Bash", tool_input:{command:"gh pr create --fill"}, tool_response:{stdout:"https://github.com/o/r/pull/123\n"}}')
OUT9=$(printf '%s' "$CREATE_PAYLOAD" | env PATH="$FAKE_BIN:$PATH" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen9" \
  FAKE_GH_PR_LIST_NUM=999 "$HOOK" 2>&1)
[[ "$OUT9" == *"PR #123"* ]] && pass "gh pr create: PR number parsed from stdout URL" \
  || { fail "gh pr create: PR number parsed from stdout URL"; printf '%s\n' "$OUT9" | sed 's/^/      /'; }

# --- 9b. gh pr create with payload .cwd prints branch-pinned rev ------------
CREATE_REPO="$WORK/create-repo"
mkdir -p "$CREATE_REPO"
git -C "$CREATE_REPO" init -q -b feat-x
git -C "$CREATE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "create-init"
CREATE_PAYLOAD_CWD=$(jq -n --arg cwd "$CREATE_REPO" \
  '{tool_name:"Bash", tool_input:{command:"gh pr create --fill"}, cwd:$cwd, tool_response:{stdout:"https://github.com/o/r/pull/124\n"}}')
OUT9B=$(printf '%s' "$CREATE_PAYLOAD_CWD" | env PATH="$FAKE_BIN:$PATH" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen9b" \
  FAKE_GH_PR_LIST_NUM=999 "$HOOK" 2>&1)
CTX9B=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT9B" 2>/dev/null || echo "")
[[ "$CTX9B" == *"git rev-parse 'refs/heads/feat-x'"* ]] \
  && pass "gh pr create with payload .cwd: banner prints refs/heads/feat-x" \
  || { fail "gh pr create with payload .cwd: banner prints refs/heads/feat-x"; printf '%s\n' "$OUT9B" | sed 's/^/      /'; }

# --- 9c. detached-HEAD fixture prints HEAD rev ------------------------------
DETACHED_REPO="$WORK/detached-repo"
mkdir -p "$DETACHED_REPO"
git -C "$DETACHED_REPO" init -q -b feat-detached
git -C "$DETACHED_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "detached-init"
git -C "$DETACHED_REPO" checkout -q --detach HEAD
OUT9C=$(run_hook_cwd "Bash" "git push" "$DETACHED_REPO" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen9c" FAKE_GH_PR_LIST_NUM=88)
CTX9C=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT9C" 2>/dev/null || echo "")
[[ "$CTX9C" == *"git rev-parse 'HEAD'"* ]] \
  && pass "detached-HEAD fixture: banner prints HEAD" \
  || { fail "detached-HEAD fixture: banner prints HEAD"; printf '%s\n' "$OUT9C" | sed 's/^/      /'; }

# --- 10. dedup keys on (PR, head SHA): a new SHA on the same PR re-prints --
DEDUP_REPO="$WORK/dedup-repo"
mkdir -p "$DEDUP_REPO"
git -C "$DEDUP_REPO" init -q
git -C "$DEDUP_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "one"
SHA1=$(git -C "$DEDUP_REPO" rev-parse HEAD)
SEEN10="$WORK/seen10"
OUT10A=$(cd "$DEDUP_REPO" && run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$SEEN10" FAKE_GH_PR_LIST_NUM=55)
git -C "$DEDUP_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "two"
SHA2=$(git -C "$DEDUP_REPO" rev-parse HEAD)
[ "$SHA1" != "$SHA2" ] || { fail "dedup-by-sha fixture: HEAD did not move"; }
OUT10B=$(cd "$DEDUP_REPO" && run_hook "Bash" "git push" SYG_PR_MONITOR_SEEN_FILE="$SEEN10" FAKE_GH_PR_LIST_NUM=55)
[[ -n "$OUT10A" && -n "$OUT10B" ]] \
  && pass "same PR, new head SHA -> reminder prints again" \
  || { fail "same PR, new head SHA -> reminder prints again"; printf 'A:%s\nB:%s\n' "$OUT10A" "$OUT10B" | sed 's/^/      /'; }

# --- Fixture repo for the effective-directory cases (11-15) ----------------
# A distinct branch name (never "main"/whatever REPO_ROOT is on) lets each
# case prove gh was actually invoked FROM this repo, not from REPO_ROOT or
# wherever the probe process happens to sit — a same-named branch would let
# the wrong resolution pass by coincidence.
FIXTURE_WT="$WORK/fixture-wt"
mkdir -p "$FIXTURE_WT"
git -C "$FIXTURE_WT" init -q -b fixture-branch
git -C "$FIXTURE_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fixture"
FIXTURE_TOPLEVEL=$(git -C "$FIXTURE_WT" rev-parse --show-toplevel)

# gh_log_used_branch <logfile> — the branch named in the last `pr list --head
# <branch>` call the shim logged, or empty.
gh_log_used_branch() {
  grep 'pr list' "$1" 2>/dev/null | tail -1 | grep -oE -- '--head [^ ]+' | awk '{print $2}'
}

# --- 11. `git -C <fixture-wt> push` resolves the FIXTURE repo's PR, and the
#          banner names the fixture's toplevel, run from an unrelated cwd --
LOG11="$WORK/log11"
: > "$LOG11"
OUT11=$(cd "$REPO_ROOT" && run_hook "Bash" "git -C $FIXTURE_WT push" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen11" FAKE_GH_PR_LIST_NUM=201 FAKE_GH_LOG="$LOG11")
[ "$(gh_log_used_branch "$LOG11")" = "fixture-branch" ] \
  && pass "git -C <dir> push: gh ran against the fixture repo's branch" \
  || fail "git -C <dir> push: gh ran against the fixture repo's branch (got '$(gh_log_used_branch "$LOG11")')"
[[ "$OUT11" == *"$FIXTURE_TOPLEVEL"* ]] \
  && pass "git -C <dir> push: banner names the fixture toplevel" \
  || { fail "git -C <dir> push: banner names the fixture toplevel"; printf '%s\n' "$OUT11" | sed 's/^/      /'; }

# --- 12. `cd <fixture-wt> && git push` likewise -----------------------------
LOG12="$WORK/log12"
: > "$LOG12"
OUT12=$(cd "$REPO_ROOT" && run_hook "Bash" "cd $FIXTURE_WT && git push" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen12" FAKE_GH_PR_LIST_NUM=202 FAKE_GH_LOG="$LOG12")
[ "$(gh_log_used_branch "$LOG12")" = "fixture-branch" ] \
  && pass "cd <dir> && git push: gh ran against the fixture repo's branch" \
  || fail "cd <dir> && git push: gh ran against the fixture repo's branch (got '$(gh_log_used_branch "$LOG12")')"
[[ "$OUT12" == *"$FIXTURE_TOPLEVEL"* ]] \
  && pass "cd <dir> && git push: banner names the fixture toplevel" \
  || { fail "cd <dir> && git push: banner names the fixture toplevel"; printf '%s\n' "$OUT12" | sed 's/^/      /'; }

# --- 13. neither -C nor cd present -> the payload's own `.cwd` is used -----
LOG13="$WORK/log13"
: > "$LOG13"
run_hook_cwd "Bash" "git push" "$FIXTURE_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen13" FAKE_GH_PR_LIST_NUM=203 FAKE_GH_LOG="$LOG13" >/dev/null
[ "$(gh_log_used_branch "$LOG13")" = "fixture-branch" ] \
  && pass "no -C/cd: payload .cwd used for the fixture repo" \
  || fail "no -C/cd: payload .cwd used for the fixture repo (got '$(gh_log_used_branch "$LOG13")')"

# --- 14. an unresolvable `cd "$X"` is ignored, falling back to payload .cwd -
LOG14="$WORK/log14"
: > "$LOG14"
run_hook_cwd "Bash" 'cd "$SOME_VAR" && git push' "$FIXTURE_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen14" FAKE_GH_PR_LIST_NUM=204 FAKE_GH_LOG="$LOG14" >/dev/null
[ "$(gh_log_used_branch "$LOG14")" = "fixture-branch" ] \
  && pass 'cd "$VAR" (unresolvable): ignored, falls back to payload .cwd' \
  || fail 'cd "$VAR" (unresolvable): ignored, falls back to payload .cwd (got '"'$(gh_log_used_branch "$LOG14")'"')'

# --- 15. dedup key includes the toplevel: same PR number, different repo,
#          both print -----------------------------------------------------
OTHER_WT="$WORK/other-wt"
mkdir -p "$OTHER_WT"
git -C "$OTHER_WT" init -q -b other-branch
git -C "$OTHER_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "other"
SEEN15="$WORK/seen15"
OUT15A=$(run_hook_cwd "Bash" "git push" "$FIXTURE_WT" SYG_PR_MONITOR_SEEN_FILE="$SEEN15" FAKE_GH_PR_LIST_NUM=77)
OUT15B=$(run_hook_cwd "Bash" "git push" "$OTHER_WT" SYG_PR_MONITOR_SEEN_FILE="$SEEN15" FAKE_GH_PR_LIST_NUM=77)
[[ -n "$OUT15A" && -n "$OUT15B" ]] \
  && pass "dedup key includes the repo toplevel: same PR#, different repo, both print" \
  || { fail "dedup key includes the repo toplevel"; printf 'A:%s\nB:%s\n' "$OUT15A" "$OUT15B" | sed 's/^/      /'; }

# --- 16. a hung `gh pr list` (10s, well past the 2s bound) does not stall
#          the hook: it returns within ~3s, silent (no banner), with a
#          stderr note --------------------------------------------------
START16=$(date +%s%N)
OUT16=$(run_hook_cwd "Bash" "git push" "$FIXTURE_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen16" FAKE_GH_PR_LIST_SLEEP=10)
END16=$(date +%s%N)
ELAPSED_MS16=$(( (END16 - START16) / 1000000 ))
[ "$ELAPSED_MS16" -lt 3500 ] \
  && pass "hung gh pr list: hook returns within ~3s (got ${ELAPSED_MS16}ms)" \
  || fail "hung gh pr list: hook returns within ~3s (got ${ELAPSED_MS16}ms — did NOT bound the call)"
[[ "$OUT16" != *'"hookSpecificOutput"'* ]] \
  && pass "hung gh pr list: silent (no banner)" \
  || { fail "hung gh pr list: silent (no banner)"; printf '%s\n' "$OUT16" | sed 's/^/      /'; }
[[ "$OUT16" == *"timed out after 2s"* ]] \
  && pass "hung gh pr list: stderr note on timeout" \
  || { fail "hung gh pr list: stderr note on timeout"; printf '%s\n' "$OUT16" | sed 's/^/      /'; }

# --- 17. a push behind a heredoc past 128 KiB (Linux's cap on one env string)
#          still prints the banner ------------------------------------------
BIGDOC=$'git commit -F - <<\'EOF\'\n'"$(printf '%*s' 214000 '' | tr ' ' x)"$'\nEOF\n'
cd "$REPO_ROOT" || exit 1
OUT17=$(run_hook "Bash" "${BIGDOC}git push" SYG_PR_MONITOR_SEEN_FILE="$WORK/seen17" FAKE_GH_PR_LIST_NUM=42)
[[ "$OUT17" == *"PR #42"* ]] \
  && pass "a push past 128 KiB -> banner prints" \
  || { fail "a push past 128 KiB -> banner prints"; printf '%s\n' "$OUT17" | head -5 | sed 's/^/      /'; }

# --- 18. explicit push refspec names the branch (PR lookup + rev + dedup) --
PUSH_WT="$WORK/push-branch-wt"
mkdir -p "$PUSH_WT"
git -C "$PUSH_WT" init -q -b main
git -C "$PUSH_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "main-init"
MAIN_SHA=$(git -C "$PUSH_WT" rev-parse main)
git -C "$PUSH_WT" checkout -q -b feat-y
git -C "$PUSH_WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat-y-commit"
git -C "$PUSH_WT" tag v1
git -C "$PUSH_WT" -c user.email=t@t -c user.name=t tag -a v2 -m v2 feat-y
git -C "$PUSH_WT" update-ref refs/remotes/origin/feat-y feat-y
FEAT_Y_SHA=$(git -C "$PUSH_WT" rev-parse feat-y)
git -C "$PUSH_WT" checkout -q main

check_push_branch_case() {
  local id="$1" cmd="$2" exp_head="$3" exp_rev="$4"
  local log="$WORK/log18_${id}" seen="$WORK/seen18_${id}" out ctx got_head
  : > "$log"
  out=$(run_hook_cwd "Bash" "$cmd" "$PUSH_WT" \
    SYG_PR_MONITOR_SEEN_FILE="$seen" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$log")
  got_head=$(gh_log_used_branch "$log")
  [ "$got_head" = "$exp_head" ] \
    && pass "18${id} ($cmd): gh --head $exp_head" \
    || fail "18${id} ($cmd): gh --head $exp_head (got '$got_head')"
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null || echo "")
  [[ "$ctx" == *"git rev-parse '$exp_rev'"* ]] \
    && pass "18${id} ($cmd): banner rev $exp_rev" \
    || { fail "18${id} ($cmd): banner rev $exp_rev"; printf '%s\n' "$out" | sed 's/^/      /'; }
}

check_trailing_create_case() {
  local id="$1" cmd="$2" exp_num="$3" exp_head="$4" exp_rev="$5"
  local log="$WORK/log18_${id}" seen="$WORK/seen18_${id}" payload out ctx got_head
  : > "$log"
  payload=$(jq -n --arg cmd "$cmd" --arg cwd "$PUSH_WT" \
    '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd, tool_response:{stdout:"https://github.com/o/r/pull/777\n"}}')
  out=$(printf '%s' "$payload" | env PATH="$FAKE_BIN:$PATH" \
    SYG_PR_MONITOR_SEEN_FILE="$seen" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$log" "$HOOK" 2>&1)
  ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null || echo "")
  if [ "$exp_num" = "777" ]; then
    ! grep -q 'pr list' "$log" 2>/dev/null \
      && pass "18${id} ($cmd): gh pr list not called" \
      || { fail "18${id} ($cmd): gh pr list not called"; printf 'LOG:%s\n' "$(cat "$log")" | sed 's/^/      /'; }
    [[ "$ctx" == *"PR #777"* && "$ctx" == *"git rev-parse '$exp_rev'"* ]] \
      && pass "18${id} ($cmd): banner uses PR #777 and $exp_rev" \
      || { fail "18${id} ($cmd): banner uses PR #777 and $exp_rev"; printf '%s\n' "$out" | sed 's/^/      /'; }
  else
    got_head=$(gh_log_used_branch "$log")
    [ "$got_head" = "$exp_head" ] \
      && pass "18${id} ($cmd): gh --head $exp_head" \
      || fail "18${id} ($cmd): gh --head $exp_head (got '$got_head')"
    [[ "$ctx" == *"PR #${exp_num}"* && "$ctx" != *"777"* && "$ctx" == *"git rev-parse '$exp_rev'"* ]] \
      && pass "18${id} ($cmd): 777 ignored, banner uses PR #${exp_num} and $exp_rev" \
      || { fail "18${id} ($cmd): 777 ignored, banner uses PR #${exp_num} and $exp_rev"; printf '%s\n' "$out" | sed 's/^/      /'; }
  fi
}

# 18a. `git push origin feat-y` -> gh --head feat-y; banner refs/heads/feat-y
check_push_branch_case a "git push origin feat-y" "feat-y" "refs/heads/feat-y"

# 18b. `git push -u origin feat-y` -> same as a
check_push_branch_case b "git push -u origin feat-y" "feat-y" "refs/heads/feat-y"

# 18c. `git push --force-with-lease origin +feat-y` -> same as a
check_push_branch_case c "git push --force-with-lease origin +feat-y" "feat-y" "refs/heads/feat-y"

# 18d. `git push origin feat-y:feat-z` -> gh --head feat-z; banner refs/heads/feat-y
check_push_branch_case d "git push origin feat-y:feat-z" "feat-z" "refs/heads/feat-y"

# 18e. `git push origin HEAD:feat-z` -> gh --head feat-z; banner refs/heads/main
check_push_branch_case e "git push origin HEAD:feat-z" "feat-z" "refs/heads/main"

# 18f. `git push origin gone-branch` (unresolvable source) -> silent, gh never called
LOG18F="$WORK/log18_f"
: > "$LOG18F"
OUT18F=$(run_hook_cwd "Bash" "git push origin gone-branch" "$PUSH_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen18_f" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$LOG18F")
[ -z "$OUT18F" ] && [ ! -s "$LOG18F" ] \
  && pass "18f (git push origin gone-branch): unresolvable source -> silent, gh not called" \
  || { fail "18f (git push origin gone-branch): unresolvable source -> silent, gh not called"; printf 'OUT:%s\nLOG:%s\n' "$OUT18F" "$(cat "$LOG18F")" | sed 's/^/      /'; }

# 18g. `git push origin feat-y other` (two refspecs) -> gh --head main; banner refs/heads/main
check_push_branch_case g "git push origin feat-y other" "main" "refs/heads/main"

# 18h. `git push` (no args) -> gh --head main; banner refs/heads/main
check_push_branch_case h "git push" "main" "refs/heads/main"

# 18i. `git push origin :feat-y` (delete) -> gh --head main; banner refs/heads/main
check_push_branch_case i "git push origin :feat-y" "main" "refs/heads/main"
# 18i2. `git push --delete origin feat-y` is also a delete -> nothing derived
check_push_branch_case i2 "git push --delete origin feat-y" "main" "refs/heads/main"

# 18j. dedup: pushing feat-y then main from the same fixture with the same PR
#      number and seen-file prints a banner both times (different SHAs)
SEEN18J="$WORK/seen18_j"
OUT18J_A=$(run_hook_cwd "Bash" "git push origin feat-y" "$PUSH_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$SEEN18J" FAKE_GH_PR_LIST_NUM=301)
OUT18J_B=$(run_hook_cwd "Bash" "git push origin main" "$PUSH_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$SEEN18J" FAKE_GH_PR_LIST_NUM=301)
[[ -n "$OUT18J_A" && -n "$OUT18J_B" ]] \
  && pass "18j (dedup per pushed branch SHA): feat-y then main both print" \
  || { fail "18j (dedup per pushed branch SHA): feat-y then main both print"; printf 'A:%s\nB:%s\n' "$OUT18J_A" "$OUT18J_B" | sed 's/^/      /'; }

# 18k. `git push origin feat-y 2>&1` -> same as a
check_push_branch_case k "git push origin feat-y 2>&1" "feat-y" "refs/heads/feat-y"

# 18l. `git push origin feat-y > out.txt` -> same as a
check_push_branch_case l "git push origin feat-y > out.txt" "feat-y" "refs/heads/feat-y"

# 18m. `git push origin feat-y &>/dev/null` -> same as a
check_push_branch_case m "git push origin feat-y &>/dev/null" "feat-y" "refs/heads/feat-y"

# 18n. `git push -o ci.skip origin feat-y` -> same as a
check_push_branch_case n "git push -o ci.skip origin feat-y" "feat-y" "refs/heads/feat-y"

# 18o. `git push origin refs/heads/feat-y` -> same as a
check_push_branch_case o "git push origin refs/heads/feat-y" "feat-y" "refs/heads/feat-y"

# 18p. `git push origin @` -> gh --head main; banner refs/heads/main
check_push_branch_case p "git push origin @" "main" "refs/heads/main"

# 18q. `git push -fd origin feat-y` (bundled delete flag) -> gh --head main; banner refs/heads/main
check_push_branch_case q "git push -fd origin feat-y" "main" "refs/heads/main"

# 18r. `git push origin feat-y 2>&1 | tail -3` -> same as a
check_push_branch_case r "git push origin feat-y 2>&1 | tail -3" "feat-y" "refs/heads/feat-y"

# 18s. `git push origin <feat-y SHA>:feat-z` -> gh --head feat-z; banner <that SHA>
check_push_branch_case s "git push origin ${FEAT_Y_SHA}:feat-z" "feat-z" "$FEAT_Y_SHA"

# 18t. `git push origin v1:feat-z` (lightweight tag) -> gh --head feat-z; banner <feat-y SHA>
check_push_branch_case t "git push origin v1:feat-z" "feat-z" "$FEAT_Y_SHA"

# 18u. `git push --repo=origin feat-y` -> gh --head feat-y; banner refs/heads/feat-y
check_push_branch_case u "git push --repo=origin feat-y" "feat-y" "refs/heads/feat-y"

# 18v. `git -C <PUSH_WT> push origin feat-y` with payload .cwd elsewhere -> resolves in PUSH_WT
LOG18V="$WORK/log18_v"
: > "$LOG18V"
OUT18V=$(run_hook_cwd "Bash" "git -C $PUSH_WT push origin feat-y" "$FIXTURE_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen18_v" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$LOG18V")
[ "$(gh_log_used_branch "$LOG18V")" = "feat-y" ] \
  && pass "18v (git -C <PUSH_WT> push origin feat-y): gh --head feat-y" \
  || fail "18v (git -C <PUSH_WT> push origin feat-y): gh --head feat-y (got '$(gh_log_used_branch "$LOG18V")')"
CTX18V=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT18V" 2>/dev/null || echo "")
[[ "$CTX18V" == *"git rev-parse 'refs/heads/feat-y'"* ]] \
  && pass "18v (git -C <PUSH_WT> push origin feat-y): banner rev refs/heads/feat-y" \
  || { fail "18v (git -C <PUSH_WT> push origin feat-y): banner rev refs/heads/feat-y"; printf '%s\n' "$OUT18V" | sed 's/^/      /'; }

# 18w. `cd <PUSH_WT> && git push origin feat-y` with payload .cwd elsewhere -> resolves in PUSH_WT
LOG18W="$WORK/log18_w"
: > "$LOG18W"
OUT18W=$(run_hook_cwd "Bash" "cd $PUSH_WT && git push origin feat-y" "$FIXTURE_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen18_w" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$LOG18W")
[ "$(gh_log_used_branch "$LOG18W")" = "feat-y" ] \
  && pass "18w (cd <PUSH_WT> && git push origin feat-y): gh --head feat-y" \
  || fail "18w (cd <PUSH_WT> && git push origin feat-y): gh --head feat-y (got '$(gh_log_used_branch "$LOG18W")')"
CTX18W=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT18W" 2>/dev/null || echo "")
[[ "$CTX18W" == *"git rev-parse 'refs/heads/feat-y'"* ]] \
  && pass "18w (cd <PUSH_WT> && git push origin feat-y): banner rev refs/heads/feat-y" \
  || { fail "18w (cd <PUSH_WT> && git push origin feat-y): banner rev refs/heads/feat-y"; printf '%s\n' "$OUT18W" | sed 's/^/      /'; }

# 18x. Detached HEAD with explicit refspec `git push origin feat-y` -> feat-y / refs/heads/feat-y
PUSH_DETACHED_WT="$WORK/push-detached-wt"
cp -R "$PUSH_WT" "$PUSH_DETACHED_WT"
git -C "$PUSH_DETACHED_WT" checkout -q --detach HEAD
LOG18X="$WORK/log18_x"
: > "$LOG18X"
OUT18X=$(run_hook_cwd "Bash" "git push origin feat-y" "$PUSH_DETACHED_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$WORK/seen18_x" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$LOG18X")
[ "$(gh_log_used_branch "$LOG18X")" = "feat-y" ] \
  && pass "18x (detached HEAD, git push origin feat-y): gh --head feat-y" \
  || fail "18x (detached HEAD, git push origin feat-y): gh --head feat-y (got '$(gh_log_used_branch "$LOG18X")')"
CTX18X=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT18X" 2>/dev/null || echo "")
[[ "$CTX18X" == *"git rev-parse 'refs/heads/feat-y'"* ]] \
  && pass "18x (detached HEAD, git push origin feat-y): banner rev refs/heads/feat-y" \
  || { fail "18x (detached HEAD, git push origin feat-y): banner rev refs/heads/feat-y"; printf '%s\n' "$OUT18X" | sed 's/^/      /'; }

# 18y. Refspec word with embedded newline -> rejected by literal_ok; falls back to main
check_push_branch_case y $'git push origin "feat-y\nDIR=/tmp"' "main" "refs/heads/main"

# 18z. Repeat-push dedup negative: same seen-file, `git push origin feat-y` twice -> second output empty
SEEN18Z="$WORK/seen18_z"
OUT18Z_A=$(run_hook_cwd "Bash" "git push origin feat-y" "$PUSH_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$SEEN18Z" FAKE_GH_PR_LIST_NUM=302)
OUT18Z_B=$(run_hook_cwd "Bash" "git push origin feat-y" "$PUSH_WT" \
  SYG_PR_MONITOR_SEEN_FILE="$SEEN18Z" FAKE_GH_PR_LIST_NUM=302)
[[ -n "$OUT18Z_A" && -z "$OUT18Z_B" ]] \
  && pass "18z (repeat-push dedup negative): second git push origin feat-y is silent" \
  || { fail "18z (repeat-push dedup negative): second git push origin feat-y is silent"; printf 'A:%s\nB:%s\n' "$OUT18Z_A" "$OUT18Z_B" | sed 's/^/      /'; }

# 18aa. `git push origin v2:feat-z` (annotated tag) -> gh --head feat-z; banner <feat-y SHA> (commit, not tag object)
check_push_branch_case aa "git push origin v2:feat-z" "feat-z" "$FEAT_Y_SHA"

# 18ab. `git push origin main~0:feat-z` -> gh --head feat-z; banner <main SHA>
check_push_branch_case ab "git push origin main~0:feat-z" "feat-z" "$MAIN_SHA"

# 18ac. `git push origin feat-y~1:feat-z` (relative parent source) -> gh --head feat-z; banner <main SHA>
check_push_branch_case ac "git push origin feat-y~1:feat-z" "feat-z" "$MAIN_SHA"

# 18ad. `git push -odeploy origin feat-y` (attached -o value is not a delete) -> feat-y / refs/heads/feat-y
check_push_branch_case ad "git push -odeploy origin feat-y" "feat-y" "refs/heads/feat-y"

# 18ae. `git push -u origin feat-y && gh pr create --fill` -> push segment matches first; feat-y / refs/heads/feat-y
check_push_branch_case ae "git push -u origin feat-y && gh pr create --fill" "feat-y" "refs/heads/feat-y"

# 18af. `git push origin refs/remotes/origin/feat-y:feat-z` -> gh --head feat-z; banner <feat-y SHA>
check_push_branch_case af "git push origin refs/remotes/origin/feat-y:feat-z" "feat-z" "$FEAT_Y_SHA"

# 18ag. `git push origin refs/remotes/origin/feat-y:refs/heads/feat-z` -> same as af
check_push_branch_case ag "git push origin refs/remotes/origin/feat-y:refs/heads/feat-z" "feat-z" "$FEAT_Y_SHA"

# 18ah. `git push origin feat-y:HEAD` -> gh --head main; banner refs/heads/main
check_push_branch_case ah "git push origin feat-y:HEAD" "main" "refs/heads/main"

# 18ai. `git push origin feat-y:@` -> same as ah
check_push_branch_case ai "git push origin feat-y:@" "main" "refs/heads/main"

# 18aj. `git push -uo ci.skip origin feat-y` -> feat-y / refs/heads/feat-y
check_push_branch_case aj "git push -uo ci.skip origin feat-y" "feat-y" "refs/heads/feat-y"

# 18ak. `git push --repo=origin -do ci.skip feat-y` (bundled delete + -o) -> gh --head main; banner refs/heads/main
check_push_branch_case ak "git push --repo=origin -do ci.skip feat-y" "main" "refs/heads/main"

# 18al. `git push origin feat-y && gh pr create --fill` with PR URL on stdout (checked-out branch is main != feat-y) -> 777 ignored, pr list called with --head feat-y
check_trailing_create_case al "git push origin feat-y && gh pr create --fill" 300 "feat-y" "refs/heads/feat-y"

# 18am. `git push -u origin feat-y && gh pr create --fill --head other` with PR URL on stdout -> 777 ignored, pr list called with --head feat-y
check_trailing_create_case am "git push -u origin feat-y && gh pr create --fill --head other" 300 "feat-y" "refs/heads/feat-y"

# 18an. `git push origin main && gh pr create -fH other` with PR URL on stdout (bundled -H) -> 777 ignored, pr list called with --head main
check_trailing_create_case an "git push origin main && gh pr create -fH other" 300 "main" "refs/heads/main"

# 18ao. `git push origin main && gh pr create -R a/b --fill` with PR URL on stdout (-R repo option) -> 777 ignored, pr list called with --head main
check_trailing_create_case ao "git push origin main && gh pr create -R a/b --fill" 300 "main" "refs/heads/main"

# 18ap. `git push origin main && cd .. && gh pr create --fill` with PR URL on stdout (intervening cd) -> 777 ignored, pr list called with --head main
check_trailing_create_case ap "git push origin main && cd .. && gh pr create --fill" 300 "main" "refs/heads/main"

# 18aq. `git push origin main && gh pr create --fill` with PR URL on stdout (dst == checked-out branch) -> PR #777 used, gh pr list not called
check_trailing_create_case aq "git push origin main && gh pr create --fill" 777 "" "refs/heads/main"

# 18ar. `git push -u origin HEAD && gh pr create --fill` with PR URL on stdout (HEAD dst -> blank, falls back to checked-out branch) -> PR #777 used, gh pr list not called
check_trailing_create_case ar "git push -u origin HEAD && gh pr create --fill" 777 "" "refs/heads/main"

# 18as. `git push origin main && pushd .. && gh pr create --fill` with PR URL on stdout (intervening pushd; create not adjacent) -> 777 ignored, pr list called with --head main
check_trailing_create_case as "git push origin main && pushd .. && gh pr create --fill" 300 "main" "refs/heads/main"

# 18at. `git push origin main && git switch feat-y && gh pr create --fill` with PR URL on stdout (intervening git switch; create not adjacent) -> 777 ignored, pr list called with --head main
check_trailing_create_case at "git push origin main && git switch feat-y && gh pr create --fill" 300 "main" "refs/heads/main"

# 18au. `git push origin main && GH_REPO=a/b gh pr create --fill` with PR URL on stdout (env prefix on create) -> 777 ignored, pr list called with --head main
check_trailing_create_case au "git push origin main && GH_REPO=a/b gh pr create --fill" 300 "main" "refs/heads/main"

# 18av. `git push origin feat-y && git push origin main && gh pr create --fill` with PR URL on stdout (second push before create; first push is trigger) -> 777 ignored, pr list called with --head feat-y, banner rev refs/heads/feat-y
check_trailing_create_case av "git push origin feat-y && git push origin main && gh pr create --fill" 300 "feat-y" "refs/heads/feat-y"

check_standalone_create_case() {
  local id="$1" cmd="$2" exp_rev="$3"
  local log="$WORK/log18_${id}" seen="$WORK/seen18_${id}" payload out ctx
  : > "$log"
  payload=$(jq -n --arg cmd "$cmd" --arg cwd "$PUSH_WT" \
    '{tool_name:"Bash", tool_input:{command:$cmd}, cwd:$cwd, tool_response:{stdout:"https://github.com/o/r/pull/777\n"}}')
  out=$(printf '%s' "$payload" | env PATH="$FAKE_BIN:$PATH" \
    SYG_PR_MONITOR_SEEN_FILE="$seen" FAKE_GH_PR_LIST_NUM=300 FAKE_GH_LOG="$log" "$HOOK" 2>&1)
  if [ -z "$exp_rev" ]; then
    [ -z "$out" ] && [ ! -s "$log" ] \
      && pass "18${id} ($cmd): silent, gh not called" \
      || { fail "18${id} ($cmd): silent, gh not called"; printf 'OUT:%s\nLOG:%s\n' "$out" "$(cat "$log")" | sed 's/^/      /'; }
  else
    ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>/dev/null || echo "")
    [ ! -s "$log" ] \
      && pass "18${id} ($cmd): gh not called" \
      || { fail "18${id} ($cmd): gh not called"; printf 'LOG:%s\n' "$(cat "$log")" | sed 's/^/      /'; }
    [[ "$ctx" == *"PR #777"* && "$ctx" == *"git rev-parse '$exp_rev'"* ]] \
      && pass "18${id} ($cmd): banner uses PR #777 and $exp_rev" \
      || { fail "18${id} ($cmd): banner uses PR #777 and $exp_rev"; printf '%s\n' "$out" | sed 's/^/      /'; }
  fi
}

# 18aw. standalone `gh pr create --fill --head feat-y` -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case aw "gh pr create --fill --head feat-y" "refs/heads/feat-y"

# 18ax. standalone `gh pr create -fH feat-y` -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case ax "gh pr create -fH feat-y" "refs/heads/feat-y"

# 18ay. standalone `gh pr create --head=someone:feat-y --fill` -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case ay "gh pr create --head=someone:feat-y --fill" "refs/heads/feat-y"

# 18az. standalone `gh pr create --fill --head gone-branch` -> no output, gh never called
check_standalone_create_case az "gh pr create --fill --head gone-branch" ""

# 18ba. standalone `gh pr create --repo o/r --fill` -> no output, gh never called
check_standalone_create_case ba "gh pr create --repo o/r --fill" ""

# 18bb. standalone `GH_REPO=o/r gh pr create --fill` -> no output, gh never called
check_standalone_create_case bb "GH_REPO=o/r gh pr create --fill" ""

# 18bc. standalone `gh pr create --fill` (control) -> PR #777, banner rev refs/heads/main
check_standalone_create_case bc "gh pr create --fill" "refs/heads/main"

# 18bd. `git -C <PUSH_WT> push origin main && gh pr create --fill` with PR URL on stdout (push -C excluded from trailing create) -> 777 ignored, pr list called with --head main
check_trailing_create_case bd "git -C $PUSH_WT push origin main && gh pr create --fill" 300 "main" "refs/heads/main"

# 18be. `git push origin main && gh pr create --head=other --fill` with PR URL on stdout (--head= on trailing create) -> 777 ignored, pr list called with --head main
check_trailing_create_case be "git push origin main && gh pr create --head=other --fill" 300 "main" "refs/heads/main"

# 18bf. `git push origin main && gh pr create --repo=a/b --fill` with PR URL on stdout (--repo= on trailing create) -> 777 ignored, pr list called with --head main
check_trailing_create_case bf "git push origin main && gh pr create --repo=a/b --fill" 300 "main" "refs/heads/main"

# 18bg. standalone `gh pr create -tHotfix --fill` (attached -t value with H) -> PR #777, banner rev refs/heads/main
check_standalone_create_case bg "gh pr create -tHotfix --fill" "refs/heads/main"

# 18bh. standalone `gh pr create -tRelease --fill` (attached -t value with R) -> PR #777, banner rev refs/heads/main
check_standalone_create_case bh "gh pr create -tRelease --fill" "refs/heads/main"

# 18bi. standalone `gh pr create --title -H --head feat-y` (-H is --title's value) -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case bi "gh pr create --title -H --head feat-y" "refs/heads/feat-y"

# 18bj. standalone `gh pr create -H=feat-y` -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case bj "gh pr create -H=feat-y" "refs/heads/feat-y"

# 18bk. standalone `gh pr create -fH=feat-y` -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case bk "gh pr create -fH=feat-y" "refs/heads/feat-y"

# 18bl. standalone `gh pr create --head other --head feat-y` (last --head wins) -> PR #777, banner rev refs/heads/feat-y
check_standalone_create_case bl "gh pr create --head other --head feat-y" "refs/heads/feat-y"

# 18bm. standalone `gh pr create --help` -> no output, gh never called
check_standalone_create_case bm "gh pr create --help" ""

# 18bn. standalone `gh pr create --dry-run --fill` -> no output, gh never called
check_standalone_create_case bn "gh pr create --dry-run --fill" ""

# 18bo. standalone `gh pr create -w` -> no output, gh never called
check_standalone_create_case bo "gh pr create -w" ""

# 18bp. standalone `gh pr create --head ""` -> no output, gh never called
check_standalone_create_case bp 'gh pr create --head ""' ""

# 18bq. `git push origin main && gh pr create -tHotfix --fill` (attached -t value with H on trailing create) -> PR #777 used, gh pr list not called
check_trailing_create_case bq "git push origin main && gh pr create -tHotfix --fill" 777 "" "refs/heads/main"

# 18br. `git push origin main && gh pr create --title "-R x" --fill` (--title value on trailing create) -> PR #777 used, gh pr list not called
check_trailing_create_case br 'git push origin main && gh pr create --title "-R x" --fill' 777 "" "refs/heads/main"

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
