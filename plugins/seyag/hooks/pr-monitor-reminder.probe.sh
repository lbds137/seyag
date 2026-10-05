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
# substitution's own `git rev-parse HEAD`. Only the SHA's `$(...)` stays
# unresolved.
check_contains "cd '$REPO_ROOT' && pr-ci-wait 7 --sha \$(git rev-parse HEAD)"
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

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
