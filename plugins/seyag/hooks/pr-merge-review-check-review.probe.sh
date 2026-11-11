#!/usr/bin/env bash
# pr-merge-review-check-review - second half of the pr-merge-review-check probe split.
# Same hook, two probe files (perf13a): this one holds sections 4-11 (the review
# surface, scans, ack anomalies, delete-branch, toggle, audit holes, self-check);
# pr-merge-review-check.probe.sh holds the command-match and merge-form sections.
# Probe for pr-merge-review-check.sh — run after ANY edit to the hook.
#
# This is a high-stakes hook: it is the structural backstop behind "read the
# review before merging", and its silent failure mode is a merge proceeding
# UNREVIEWED. So the assertions here are on all three observable channels —
# the EXIT CODE (2 blocks the merge, 0 allows it), the injected stderr BLOCK
# (what the agent actually reads), and the ACK STATE FILE (what makes the
# next attempt proceed).
#
# The assertion that matters most is none of those on its own: it is WHICH PR
# the hook decided to fetch. A wrong PR number whose review happens to be
# absent exits 0 and the merge lands unreviewed — an outcome indistinguishable
# from "correct PR, no review" if you only read the exit code. Every
# extraction case below therefore reads the PR number back out of the shimmed
# `gh api` call log rather than inferring it.
#
# Everything runs offline, with no production change to the hook:
#
#   * `gh` is shimmed onto the front of PATH — the PR-number fallback, the
#     base-branch lookup, the repo/default-branch lookup, the review fetch
#     and the diff fetch are all driven from fixtures, and the review fetch
#     is logged so the extracted PR number is readable.
#   * `git` is shimmed too (worktree questions), with an EMPTY worktree list
#     as the default so the delete-branch cases never read this machine's
#     real tree.
#   * The ack state lives under HOME, so each case gets its own fresh HOME:
#     no ack state can leak between cases, and none can touch the real one.
#     The real state file is checksummed before and after and asserted
#     unchanged, so a HOME that failed to take effect is reported rather than
#     silently polluting the live gate.
#
# --- what this probe does NOT pin -------------------------------------------
#
#   1. The `--jq` output-shape contract on the `pr view`/`repo view` calls:
#      the shim dispatches on the command text and returns fixtures already
#      in post-`--jq` shape; it never runs those filters. The REVIEW fetch
#      is different: gh there pipes its slurped pages to a real jq inside
#      the hook, so the api fixtures are raw single-page comment shapes (the
#      shim wraps them) and that filter really runs under the probe.
#   2. That `--paginate` actually walks every page — live-API behavior. The
#      probe pins that the invocation carries both flags (log-assert below)
#      and that the slurped shape parses; the page-walking itself stays
#      unpinned.
#   3. Whether stderr from a blocking PreToolUse hook actually reaches the
#      agent's context. That is a Claude Code runtime property; the probe can
#      only assert the hook wrote it.
#
# Two cases in section 2 were PINNED DEFECTS until the extraction was
# rewritten: the old match tested the whole command TEXT, so any command
# carrying the phrase `gh pr merge` plus a bare all-digit token armed the
# gate on the WRONG PR — a decoy before the real invocation, a `--body`
# argument, or prose in an unrelated subcommand. They now assert the correct
# behaviour, which is what pinning them was for: the fix flipped known cases
# instead of discovering them.

set -uo pipefail
# Never leave __pycache__ in the hooks lib when run standalone (run-probes.sh
# exports this too; this probe is also runnable directly).
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/pr-merge-review-check.sh"
RUNNER="$SCRIPT_DIR/run.sh"

FAILURES=0

if [ ! -f "$HOOK" ]; then
  printf 'FATAL: %s not found\n' "$HOOK" >&2
  exit 1
fi

WORK=$(mktemp -d)
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

# Leak guard: capture the live ack lines before the first invocation so a
# HOME that silently failed to take effect is caught at the end by checking
# whether any new live line matches a fixture ack, without reddening when
# another session merges an unrelated PR concurrently.
REAL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/pr-merge-review-check/ack"
cp "$REAL_STATE" "$WORK/live-before" 2>/dev/null || : >"$WORK/live-before"

mkdir -p "$WORK/bin"

# --- the gh shim -----------------------------------------------------------
# The calls to serve, all driven by env vars the cases set:
#   `gh pr view <n> --json number -q .number`              -> the branch's PR
#   `gh pr view <n> --json baseRefName,headRefName --jq …` -> base + head refs
#   `gh pr view <n> --json author,files --jq …`            -> author + workflow edit
#   `gh repo view --json nameWithOwner,defaultBranchRef …` -> repo + default branch
#   `gh api repos/…/issues/<n>/comments…`                  -> the newest claude review
#   `gh pr diff …`                                         -> the claim-scan diff
# The `pr view` calls are told apart by their `--json` field list, and each
# fails independently: SHIM_BASE_EXIT the refs, SHIM_AUTHOR_FILES_EXIT the
# author/files facts, SHIM_NUMBER_EXIT the branch-PR fallback. Modelling
# failure per FIELD (not per arm) is what lets the refs-survive-a-files-
# failure case go red against a hook that folds both lookups into one call.
# The api call is LOGGED, because its URL carries the extracted PR number and
# that is the value the extraction cases assert on; the `pr view` calls are
# logged too (SHIM_VIEW_LOG), because which SELECTOR the hook resolved a
# selector-bearing invocation with is only visible in that argv. Anything
# unrecognised exits 64 rather than succeeding silently — a shim that answers
# a call the hook does not make is how a probe ends up testing a path that no
# longer exists.
cat >"$WORK/bin/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  "pr view "*"--json "*)
    printf '%s\n' "$*" >>"${SHIM_VIEW_LOG:-/dev/null}"
    fields=$(printf '%s\n' "$*" | sed -n 's/.*--json \([^ ]*\).*/\1/p')
    case "$fields" in
      number)
        [ "${SHIM_NUMBER_EXIT:-1}" = "0" ] || exit "${SHIM_NUMBER_EXIT}" ;;
      baseRefName,headRefName)
        [ "${SHIM_BASE_EXIT:-0}" = "0" ] || exit "${SHIM_BASE_EXIT}" ;;
      author,files)
        [ "${SHIM_AUTHOR_FILES_EXIT:-0}" = "0" ] || exit "${SHIM_AUTHOR_FILES_EXIT}" ;;
      *)
        echo "gh shim: unexpected --json field list: $fields" >&2
        exit 64 ;;
    esac
    # Post-`--jq` shapes: one value per line. A missing value is an EMPTY
    # line, not an absent one — that is what the hook's `sed -n Np` reads.
    case "$fields" in
      number) printf '%s\n' "${SHIM_PR_NUMBER:-}" ;;
      baseRefName,headRefName)
        printf '%s\n%s\n' "${SHIM_PR_BASE:-}" "${SHIM_PR_HEAD:-}" ;;
      author,files)
        # `(.author.login // ""), (<files include the review workflow> | tostring)`
        printf '%s\n%s\n' "${SHIM_PR_AUTHOR:-}" "${SHIM_PR_EDITS_WORKFLOW-false}" ;;
    esac
    ;;
  "repo view "*"--json "*)
    [ "${SHIM_REPO_EXIT:-0}" = "0" ] || exit "${SHIM_REPO_EXIT}"
    printf '%s\n%s\n' "${SHIM_REPO:-}" "${SHIM_DEFAULT_BRANCH:-}"
    ;;
  *"/issues/"*"/comments"*)
    printf '%s\n' "$*" >>"${SHIM_API_LOG:-/dev/null}"
    [ "${SHIM_API_EXIT:-0}" = "0" ] || exit "${SHIM_API_EXIT}"
    # The hook pipes gh's output to a REAL jq, so the fixture must be the
    # RAW shape --slurp produces: an outer array of PAGES, each page an
    # array of comments. The fixture is one comment object, so the shim
    # wraps it twice (one page holding that comment). Pagination itself
    # (many pages) is a live-API property, pinned only as the flags'
    # presence in the logged argv. SHIM_API_EMPTY=1 prints nothing (empty
    # gh stdout); non-comment payloads (no "user" field and not empty/"[]")
    # print raw so filter failures on {"message":"x"} or [1] are reachable.
    if [ "${SHIM_API_EMPTY:-0}" = "1" ]; then
      :
    elif [ -z "${SHIM_REVIEW_JSON:-}" ] || [ "${SHIM_REVIEW_JSON:-}" = "[]" ]; then
      printf '[[]]'
    elif [[ "${SHIM_REVIEW_JSON}" == *'"user"'* ]]; then
      printf '[[%s]]' "${SHIM_REVIEW_JSON}"
    else
      printf '%s' "${SHIM_REVIEW_JSON}"
    fi
    ;;
  "pr diff "*)
    # The added-comment claim scan's input. SHIM_DIFF_EXIT non-zero with no
    # output is the fail-open case: the hook must degrade to "no scan", never
    # to a warning or a block.
    [ "${SHIM_DIFF_EXIT:-0}" = "0" ] || exit "${SHIM_DIFF_EXIT}"
    printf '%s' "${SHIM_PR_DIFF:-}"
    ;;
  *)
    echo "gh shim: unexpected invocation: $*" >&2
    exit 64
    ;;
esac
SHIM
chmod +x "$WORK/bin/gh"

# --- the git shim ----------------------------------------------------------
# The delete-branch guard asks git two questions: which worktree am I in, and
# which worktrees hold which branches. Both are shimmed so the cases can pose
# a worktree layout that does not exist on this machine.
#
# The DEFAULT is an empty worktree list, not the real repo's. A probe that
# fell through to real git would answer from whatever branches happen to be
# checked out while it runs — so it would pass on this machine and fail on
# the next one, and the fixture cases would silently depend on the runner's
# tree.
#
# `SHIM_GIT_EXIT` makes both queries fail, which is how the fail-open case
# proves the guard degrades to "allow" rather than "cannot merge".
cat >"$WORK/bin/git" <<'SHIM'
#!/bin/bash
[ "${SHIM_GIT_EXIT:-0}" = "0" ] || exit "${SHIM_GIT_EXIT}"
# Separate knob so `worktree list` can fail while `rev-parse` succeeds. The
# combined SHIM_GIT_EXIT short-circuits on the empty-CURRENT_TREE check and
# never reaches the worktree query, so it cannot cover that asymmetry.
case "$*" in
  "worktree list --porcelain")
    [ "${SHIM_WORKTREE_EXIT:-0}" = "0" ] || exit "${SHIM_WORKTREE_EXIT}" ;;
esac
case "$*" in
  # `${VAR-default}`, NOT `${VAR:-default}`: the colon form substitutes on an
  # EMPTY value too, so a case setting SHIM_CURRENT_TREE='' to simulate a failed
  # `rev-parse` would silently get `/repo` back and test nothing.
  "rev-parse --show-toplevel") printf '%s\n' "${SHIM_CURRENT_TREE-/repo}" ;;
  # The cwd-repo slug the delete-branch guard compares a -R against. Derived
  # from SHIM_REPO so a row that changes the served repo changes the remote
  # with it; an unrecognised remote question still exits 64 (the unparseable
  # → same-repo → guard-stays-on path).
  "remote get-url origin") printf 'https://github.com/%s.git\n' "${SHIM_REPO:-acme-widgets/cli}" ;;
  "worktree list --porcelain") printf '%s' "${SHIM_WORKTREES:-}" ;;
  *) echo "git shim: unexpected invocation: $*" >&2; exit 64 ;;
esac
SHIM
chmod +x "$WORK/bin/git"

# --- driver ----------------------------------------------------------------
CASE_N=0
STDOUT_FILE=''
STDERR_FILE=''
API_LOG=''
VIEW_LOG=''
ACK_FILE=''
CASE_HOME=''
LAST_EXIT=0

SHIM_PR_BASE='develop'
SHIM_PR_HEAD='feat/example'
SHIM_PR_AUTHOR='octo-user'
SHIM_PR_EDITS_WORKFLOW='false'
SHIM_BASE_EXIT=0
SHIM_AUTHOR_FILES_EXIT=0
SHIM_NUMBER_EXIT=1
SHIM_PR_NUMBER=''
SHIM_REPO='acme-widgets/cli'
SHIM_DEFAULT_BRANCH='main'
SHIM_REPO_EXIT=0
SHIM_API_EXIT=0
SHIM_API_EMPTY=0
SHIM_REVIEW_JSON=''
SHIM_CURRENT_TREE='/repo'
SHIM_WORKTREES=''
SHIM_GIT_EXIT=0
SHIM_WORKTREE_EXIT=0
SHIM_PR_DIFF=''
SHIM_DIFF_EXIT=0
REMINDER_OVERRIDE=''
# Same pattern for the two configurable identities: an empty override means
# the hook's defaults apply (claude[bot], the claude-code-review workflow).
LOGIN_OVERRIDE=''
WORKFLOW_OVERRIDE=''
# SYG_PR_MERGE_LIB_DIR knob: pointing the hook's shell_quotes import at
# an empty dir simulates a broken lib without touching the hook tree.
LIB_DIR_OVERRIDE=''

# new_case — a fresh HOME (and so a fresh ack state), api log, and output
# captures. The ack state is the hook's only cross-invocation state, so a
# stale one leaking between groups would silently convert a "blocks" case
# into an "already acked" one.
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_HOME="$WORK/home.$CASE_N"
  mkdir -p "$CASE_HOME"
  ACK_FILE="$CASE_HOME/.local/state/seyag/pr-merge-review-check/ack"
  API_LOG="$WORK/api.$CASE_N"
  VIEW_LOG="$WORK/view.$CASE_N"
  STDOUT_FILE="$WORK/out.$CASE_N"
  STDERR_FILE="$WORK/err.$CASE_N"
  : >"$API_LOG"
  : >"$VIEW_LOG"
}

payload() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# invoke <command-string> — run the hook with the current shim env. XDG_STATE_HOME
# is stripped so the state lands under the case HOME (the default path), and
# CLAUDE_PROJECT_DIR is stripped so a project-local hook copy cannot stand the
# hook down differently between cases.
invoke() {
  printf '%s' "$(payload "$1")" | env \
    -u XDG_STATE_HOME -u CLAUDE_PROJECT_DIR \
    HOME="$CASE_HOME" \
    PATH="$WORK/bin:$PATH" \
    SHIM_API_LOG="$API_LOG" \
    SHIM_VIEW_LOG="$VIEW_LOG" \
    SHIM_PR_BASE="$SHIM_PR_BASE" \
    SHIM_PR_HEAD="$SHIM_PR_HEAD" \
    SHIM_PR_AUTHOR="$SHIM_PR_AUTHOR" \
    SHIM_PR_EDITS_WORKFLOW="$SHIM_PR_EDITS_WORKFLOW" \
    SHIM_BASE_EXIT="$SHIM_BASE_EXIT" \
    SHIM_AUTHOR_FILES_EXIT="$SHIM_AUTHOR_FILES_EXIT" \
    SHIM_NUMBER_EXIT="$SHIM_NUMBER_EXIT" \
    SHIM_PR_NUMBER="$SHIM_PR_NUMBER" \
    SHIM_REPO="$SHIM_REPO" \
    SHIM_DEFAULT_BRANCH="$SHIM_DEFAULT_BRANCH" \
    SHIM_REPO_EXIT="$SHIM_REPO_EXIT" \
    SHIM_API_EXIT="$SHIM_API_EXIT" \
    SHIM_API_EMPTY="$SHIM_API_EMPTY" \
    SHIM_REVIEW_JSON="$SHIM_REVIEW_JSON" \
    SHIM_CURRENT_TREE="$SHIM_CURRENT_TREE" \
    SHIM_WORKTREES="$SHIM_WORKTREES" \
    SHIM_GIT_EXIT="$SHIM_GIT_EXIT" \
    SHIM_WORKTREE_EXIT="$SHIM_WORKTREE_EXIT" \
    SHIM_PR_DIFF="$SHIM_PR_DIFF" \
    SHIM_DIFF_EXIT="$SHIM_DIFF_EXIT" \
    SYG_MERGE_REVIEW_RELEASE_REMINDER="${REMINDER_OVERRIDE:-}" \
    SYG_MERGE_REVIEW_LOGIN="${LOGIN_OVERRIDE:-}" \
    SYG_MERGE_REVIEW_WORKFLOW="${WORKFLOW_OVERRIDE:-}" \
    SYG_PR_MERGE_LIB_DIR="${LIB_DIR_OVERRIDE:-}" \
    bash "$HOOK" >"$STDOUT_FILE" 2>"$STDERR_FILE"
  LAST_EXIT=$?
}

# invoke_via_runner <disable> <command-string> — same, but through run.sh (the
# wiring the plugin actually uses), so component toggles can be exercised.
# Component selection reads the real components.tsv next to run.sh.
invoke_via_runner() {
  local disable="${1:-}" cmd="${2:-}"
  printf '%s' "$(payload "$cmd")" | env \
    -u XDG_STATE_HOME -u CLAUDE_PROJECT_DIR \
    HOME="$CASE_HOME" \
    PATH="$WORK/bin:$PATH" \
    SYG_DISABLE="$disable" \
    SHIM_API_LOG="$API_LOG" \
    SHIM_VIEW_LOG="$VIEW_LOG" \
    SHIM_PR_BASE="$SHIM_PR_BASE" \
    SHIM_PR_HEAD="$SHIM_PR_HEAD" \
    SHIM_PR_AUTHOR="$SHIM_PR_AUTHOR" \
    SHIM_PR_EDITS_WORKFLOW="$SHIM_PR_EDITS_WORKFLOW" \
    SHIM_BASE_EXIT="$SHIM_BASE_EXIT" \
    SHIM_AUTHOR_FILES_EXIT="$SHIM_AUTHOR_FILES_EXIT" \
    SHIM_NUMBER_EXIT="$SHIM_NUMBER_EXIT" \
    SHIM_PR_NUMBER="$SHIM_PR_NUMBER" \
    SHIM_REPO="$SHIM_REPO" \
    SHIM_DEFAULT_BRANCH="$SHIM_DEFAULT_BRANCH" \
    SHIM_REPO_EXIT="$SHIM_REPO_EXIT" \
    SHIM_API_EXIT="$SHIM_API_EXIT" \
    SHIM_API_EMPTY="$SHIM_API_EMPTY" \
    SHIM_REVIEW_JSON="$SHIM_REVIEW_JSON" \
    SHIM_CURRENT_TREE="$SHIM_CURRENT_TREE" \
    SHIM_WORKTREES="$SHIM_WORKTREES" \
    SHIM_GIT_EXIT="$SHIM_GIT_EXIT" \
    SHIM_WORKTREE_EXIT="$SHIM_WORKTREE_EXIT" \
    SHIM_PR_DIFF="$SHIM_PR_DIFF" \
    SHIM_DIFF_EXIT="$SHIM_DIFF_EXIT" \
    SYG_MERGE_REVIEW_RELEASE_REMINDER="${REMINDER_OVERRIDE:-}" \
    SYG_MERGE_REVIEW_LOGIN="${LOGIN_OVERRIDE:-}" \
    SYG_MERGE_REVIEW_WORKFLOW="${WORKFLOW_OVERRIDE:-}" \
    SYG_PR_MERGE_LIB_DIR="${LIB_DIR_OVERRIDE:-}" \
    bash "$RUNNER" pr-merge-review-check >"$STDOUT_FILE" 2>"$STDERR_FILE"
  LAST_EXIT=$?
}

# invoke_in <dir> <command-string> — same as invoke, with cwd redirected. Used
# only by the globbing case: the glob hazard is about the CWD's contents, so
# the only way to prove it is to run somewhere that has a digit-named file.
invoke_in() {
  local dir=$1
  (
    cd "$dir" || exit 1
    printf '%s' "$(payload "$2")" | env \
      -u XDG_STATE_HOME -u CLAUDE_PROJECT_DIR \
      HOME="$CASE_HOME" \
      PATH="$WORK/bin:$PATH" \
      SHIM_API_LOG="$API_LOG" \
      SHIM_VIEW_LOG="$VIEW_LOG" \
      SHIM_PR_BASE="$SHIM_PR_BASE" \
      SHIM_PR_HEAD="$SHIM_PR_HEAD" \
      SHIM_PR_AUTHOR="$SHIM_PR_AUTHOR" \
      SHIM_PR_EDITS_WORKFLOW="$SHIM_PR_EDITS_WORKFLOW" \
      SHIM_BASE_EXIT="$SHIM_BASE_EXIT" \
      SHIM_AUTHOR_FILES_EXIT="$SHIM_AUTHOR_FILES_EXIT" \
      SHIM_NUMBER_EXIT="$SHIM_NUMBER_EXIT" \
      SHIM_PR_NUMBER="$SHIM_PR_NUMBER" \
      SHIM_REPO="$SHIM_REPO" \
      SHIM_DEFAULT_BRANCH="$SHIM_DEFAULT_BRANCH" \
      SHIM_REPO_EXIT="$SHIM_REPO_EXIT" \
      SHIM_API_EXIT="$SHIM_API_EXIT" \
      SHIM_API_EMPTY="$SHIM_API_EMPTY" \
      SHIM_REVIEW_JSON="$SHIM_REVIEW_JSON" \
      SHIM_CURRENT_TREE="$SHIM_CURRENT_TREE" \
      SHIM_WORKTREES="$SHIM_WORKTREES" \
      SHIM_GIT_EXIT="$SHIM_GIT_EXIT" \
      SHIM_WORKTREE_EXIT="$SHIM_WORKTREE_EXIT" \
      SHIM_PR_DIFF="$SHIM_PR_DIFF" \
      SHIM_DIFF_EXIT="$SHIM_DIFF_EXIT" \
      SYG_MERGE_REVIEW_RELEASE_REMINDER="${REMINDER_OVERRIDE:-}" \
      SYG_MERGE_REVIEW_LOGIN="${LOGIN_OVERRIDE:-}" \
      SYG_MERGE_REVIEW_WORKFLOW="${WORKFLOW_OVERRIDE:-}" \
      SYG_PR_MERGE_LIB_DIR="${LIB_DIR_OVERRIDE:-}" \
      bash "$HOOK"
  ) >"$STDOUT_FILE" 2>"$STDERR_FILE"
  LAST_EXIT=$?
}

# review_json <id> <body> [updated_at] [login] — a fixture in RAW comment
# shape: the shim wraps it into the slurped single-page array and the hook's
# real jq filters it, so the fields must be the real ones (user.login
# included). updated_at defaults to created_at (a different value models a
# review that EDITED its comment in place); login defaults to the hook's
# default reviewer.
review_json() {
  jq -nc --arg i "$1" --arg b "$2" --arg u "${3:-2026-08-08T12:00:00Z}" \
    --arg l "${4:-claude[bot]}" \
    '{id:($i|tonumber),user:{login:$l},created_at:"2026-08-08T12:00:00Z",updated_at:$u,body:$b}'
}

ok() { printf 'PASS  %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

assert_exit() { # <label> <expected>
  if [ "$LAST_EXIT" = "$2" ]; then ok "$1"; else
    bad "$1 (exit $LAST_EXIT, expected $2)"
  fi
}

# assert_pr <label> <expected> — the load-bearing one. Reads the PR number back
# out of the URL the hook actually fetched, so "right PR" and "wrong PR that
# happened to exit the same way" are distinguishable.
extracted_pr() {
  sed -n 's#.*/issues/\([0-9][0-9]*\)/comments.*#\1#p' "$API_LOG" | tail -1
}
assert_pr() {
  local got
  got=$(extracted_pr)
  if [ "$got" = "$2" ]; then ok "$1"; else
    bad "$1 (fetched PR '${got:-<none>}', expected $2)"
  fi
}
assert_no_fetch() { # <label> — the hook exited before deciding on a PR at all
  if [ ! -s "$API_LOG" ]; then ok "$1"; else
    bad "$1 (expected no review fetch, got: $(tr '\n' ';' <"$API_LOG"))"
  fi
}

assert_silent() { # <label> — a clean no-op: nothing on either stream
  if [ -s "$STDERR_FILE" ]; then
    bad "$1 (expected silence, stderr: $(head -c 200 "$STDERR_FILE" | tr '\n' ';'))"
  elif [ -s "$STDOUT_FILE" ]; then
    bad "$1 (expected silence, stdout: $(head -c 200 "$STDOUT_FILE" | tr '\n' ';'))"
  else
    ok "$1"
  fi
}

assert_stderr_has() { # <label> <fixed-string>
  if grep -qF "$2" "$STDERR_FILE"; then ok "$1"; else
    bad "$1 (block missing: $2)"
  fi
}
assert_stderr_lacks() {
  if grep -qF "$2" "$STDERR_FILE"; then
    bad "$1 (block should NOT contain: $2)"
  else ok "$1"; fi
}
assert_ack_has() { # <label> <exact-line>
  if grep -qxF "$2" "$ACK_FILE" 2>/dev/null; then ok "$1"; else
    bad "$1 (ack missing line '$2'; holds: $(tr '\n' ';' <"$ACK_FILE" 2>/dev/null))"
  fi
}
assert_ack_lacks() {
  if grep -qxF "$2" "$ACK_FILE" 2>/dev/null; then
    bad "$1 (ack should not hold '$2')"
  else ok "$1"; fi
}
assert_no_ack() { # <label>
  if [ ! -s "$ACK_FILE" ]; then ok "$1"; else
    bad "$1 (expected no ack, got: $(tr '\n' ';' <"$ACK_FILE" 2>/dev/null))"
  fi
}
# assert_api_has <label> <fixed-string> — pin the REVIEW FETCH URL itself
# (the api log line), beyond just the PR number assert_pr extracts from it.
# Used by the -R scoping row and the paginate row. The `--` separator keeps a
# flag-shaped fixed string (e.g. `--paginate --slurp`) a pattern, not an
# option.
assert_api_has() {
  if grep -qF -- "$2" "$API_LOG"; then ok "$1"; else
    bad "$1 (api log missing: $2)"
  fi
}
# assert_view_has <label> <fixed-string> — pin the argv of a `gh pr view`
# call. The selector rows need it: which argument the hook resolved the PR
# with is only visible there, and the served number alone cannot tell a
# selector resolution from the numberless branch lookup.
assert_view_has() {
  if grep -qF -- "$2" "$VIEW_LOG"; then ok "$1"; else
    bad "$1 (view log missing: $2)"
  fi
}
# assert_view_empty <label> — no `gh pr view` ran at all: the selector
# resolution is a network call, and a compound refusal must precede it.
assert_view_empty() {
  if [ ! -s "$VIEW_LOG" ]; then ok "$1"; else
    bad "$1 (view log non-empty: $(tr '\n' ';' <"$VIEW_LOG"))"
  fi
}
# assert_api_lacks <label> <fixed-string> — the negative half of
# assert_api_has: a repository (or flag) that must NOT appear in the fetch.
assert_api_lacks() {
  if grep -qF -- "$2" "$API_LOG"; then
    bad "$1 (api log should NOT contain: $2)"
  else ok "$1"; fi
}

LGTM=$(review_json 777 'LGTM. No actionable findings.')

# ===========================================================================
# 4. No usable review — the gate has nothing to surface, so it allows
# ===========================================================================
printf '\n--- no usable review (feature PR) ---\n'

SHIM_PR_BASE='develop'

new_case; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2002 --rebase'
assert_exit "no review comment: allowed" 0
assert_silent "no review: silent on a feature PR"

new_case; SHIM_REVIEW_JSON='[]'
invoke 'gh pr merge 2002 --rebase'
assert_exit "jq returned the literal null: allowed" 0
assert_silent "literal null: silent"

new_case; SHIM_REVIEW_JSON=$(review_json 777 '')
invoke 'gh pr merge 2002 --rebase'
assert_exit "review comment with an empty body: allowed" 0
assert_silent "unparseable review: silent"

new_case; SHIM_REVIEW_JSON='{"user":{"login":"claude[bot]"},"created_at":"2026-08-08T12:00:00Z","updated_at":"2026-08-08T12:00:00Z","body":"has a body but no id"}'
invoke 'gh pr merge 2002 --rebase'
assert_exit "review comment with no id: allowed" 0
assert_silent "missing id: silent"

# ===========================================================================
# 5. The default-branch reminder — base equals the repo's default branch, and
#    reachable WITHOUT a review
# ===========================================================================
printf '\n--- default-branch reminder (base = default branch) ---\n'

SHIM_PR_BASE='main'
SHIM_DEFAULT_BRANCH='main'

new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2010 --rebase'
assert_exit "default-branch PR with a review: BLOCKS" 2
assert_stderr_has "reminder banner present" 'DEFAULT-BRANCH MERGE'
assert_stderr_has "…naming the default branch" 'default branch (main)'
assert_stderr_has "default reminder text shown (one neutral sentence)" "run this project's post-merge steps"
assert_ack_has "release key acked" 'RELEASE:acme-widgets/cli:2010'
assert_ack_has "review key acked too" '2010:777:2026-08-08T12:00:00Z'

# The reminder text is the project's own: the env var replaces the default
# sentence entirely — the default must NOT also print.
new_case; SHIM_REVIEW_JSON="$LGTM"; REMINDER_OVERRIDE='Cut a release tag and bump the changelog before anything else.'
invoke 'gh pr merge 2011 --rebase'
assert_exit "reminder override: still BLOCKS" 2
assert_stderr_has "…and shows the override text" 'Cut a release tag and bump the changelog before anything else.'
assert_stderr_lacks "…and not the default sentence beside it" "run this project's post-merge steps"
REMINDER_OVERRIDE=''

# A default-branch PR whose review posted NOTHING must still get the reminder.
# The review gate has nothing to say, but stderr only reaches the agent on the
# blocking path, so the hook exits 2 once anyway. This is the case that would
# silently regress if the reminder were moved back below the review-existence
# early-exits — which is where it used to sit.
new_case; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2010 --rebase'
assert_exit "default-branch PR with NO review: still BLOCKS for the reminder" 2
assert_stderr_has "…and the reminder is there" 'DEFAULT-BRANCH MERGE'
assert_stderr_has "…with the reason line naming the absent review" 'no review comment found'
assert_ack_has "release key acked on the no-review path" 'RELEASE:acme-widgets/cli:2010'
invoke 'gh pr merge 2010 --rebase'
assert_exit "retry after the no-review reminder: allowed" 0
assert_silent "…and silent"

# The literal-null guard, which is invisible on a feature PR: without it the
# string "null" falls through to jq, produces an empty id, and lands on the
# OTHER no-usable-review exit — same exit code, same silence, different reason
# line. Only a default-branch PR, where a reason line actually prints, can tell
# the two apart.
new_case; SHIM_REVIEW_JSON='[]'
invoke 'gh pr merge 2010 --rebase'
assert_exit "default-branch PR, jq returned literal null: BLOCKS for the reminder" 2
assert_stderr_has "…reported as an ABSENT review, not an unparseable one" 'no review comment found'
assert_stderr_lacks "…and not as a parse failure" 'did not parse'

# The two no-usable-review exits are NOT the same state, and the hook says
# which. A single shared wording would be a banner asserting something untrue.
new_case; SHIM_REVIEW_JSON=$(review_json 777 '')
invoke 'gh pr merge 2010 --rebase'
assert_exit "default-branch PR with an unparseable review: BLOCKS" 2
assert_stderr_has "…with its own distinct reason line" 'did not parse'

# The reminder is once per PR, not once per review round.
new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2010 --rebase'
assert_stderr_has "first block on the default-branch PR carries the reminder" 'DEFAULT-BRANCH MERGE'
SHIM_REVIEW_JSON=$(review_json 888 'Round 2 on the default-branch PR.')
invoke 'gh pr merge 2010 --rebase'
assert_exit "a fresh review re-arms the review gate" 2
assert_stderr_has "…and injects the new review" 'Round 2 on the default-branch PR.'
assert_stderr_lacks "…but does NOT repeat the reminder" 'DEFAULT-BRANCH MERGE'

# Fail-open on an unreadable base: no reminder, never a hard block.
new_case; SHIM_PR_BASE=''; SHIM_BASE_EXIT=1; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2010 --rebase'
assert_exit "gh pr view fails: no reminder, merge allowed" 0
assert_silent "unreadable base is silent, not a block"
SHIM_BASE_EXIT=0

# Unreadable repo with no -R refuses (MERGE REVIEW UNREADABLE) before the
# reminder path is reached.
new_case; SHIM_REPO_EXIT=1; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2010 --rebase'
assert_exit "gh repo view fails: refuses" 2
assert_stderr_has "unreadable repo/default branch refuses with MERGE REVIEW UNREADABLE" 'MERGE REVIEW UNREADABLE'
SHIM_REPO_EXIT=0

# A feature PR (base ≠ default) never gets the reminder, review or not.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase'
assert_stderr_lacks "feature PR gets no default-branch block" 'DEFAULT-BRANCH MERGE'
assert_ack_lacks "…and no release ack key" 'RELEASE:acme-widgets/cli:2002'

# A repo whose default branch is NOT "main": the reminder follows the resolved
# default, not the name.
new_case; SHIM_PR_BASE='develop'; SHIM_DEFAULT_BRANCH='develop'; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2030 --rebase'
assert_exit "base equals a non-main default branch: reminder fires" 2
assert_stderr_has "…naming the repo's own default" 'default branch (develop)'
assert_ack_has "…and acks under it" 'RELEASE:acme-widgets/cli:2030'
SHIM_DEFAULT_BRANCH='main'

# RETARGET: the acked-retry path must re-evaluate the reminder obligation.
#
# The gap this pins: the ack fast path used to `exit 0` before the base was
# ever consulted, on the reasoning that a prior blocking call had already
# delivered any reminder. Retargeting between two attempts on the SAME review
# comment left the ack matching and the reminder never fired — the same
# staleness class as a base cache, through another door.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2011 --rebase'
assert_exit "round 1 on a feature-based PR: review block" 2
assert_stderr_lacks "…no reminder while based off the default branch" 'DEFAULT-BRANCH MERGE'
SHIM_PR_BASE='main'
invoke 'gh pr merge 2011 --rebase'
assert_exit "retargeted to the default branch on the SAME review: blocks for the reminder" 2
assert_stderr_has "…and the reminder finally fires" 'DEFAULT-BRANCH MERGE'
assert_ack_has "…and the release key is acked" 'RELEASE:acme-widgets/cli:2011'
invoke 'gh pr merge 2011 --rebase'
assert_exit "third attempt: both obligations acked, merge proceeds" 0

# REVERSE retarget: default -> feature AFTER the reminder already fired.
# Correct by inspection (the reminder check reads the RELEASE ack before it
# ever looks at the base, so a fired reminder cannot re-fire), and pinned
# anyway — every gap this file has had was found by a case that was not there.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2014 --rebase'
assert_exit "default-branch PR round 1 blocks with the reminder" 2
assert_stderr_has "…reminder fired while based on the default branch" 'DEFAULT-BRANCH MERGE'
SHIM_PR_BASE='develop'
invoke 'gh pr merge 2014 --rebase'
assert_exit "retargeted BACK off the default branch: merge proceeds" 0
assert_silent "…and the fired reminder does not re-fire"

# FAIL-OPEN on the acked path. The acked retry is the highest-traffic path in
# this hook, and it resolves the base — so a `gh` blip there must degrade to
# "no reminder", never to "cannot merge".
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2013 --rebase'
assert_exit "round 1 blocks to surface the review" 2
SHIM_BASE_EXIT=1; SHIM_PR_BASE=''
invoke 'gh pr merge 2013 --rebase'
assert_exit "acked retry with a FAILING base lookup still allows the merge" 0
assert_silent "…and says nothing, rather than blocking on a gh blip"
SHIM_BASE_EXIT=0

# The acked path stays free of a SECOND block once the release key exists —
# the reminder is once per PR, not once per retry.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2012 --rebase'
assert_exit "default-branch PR round 1 blocks" 2
invoke 'gh pr merge 2012 --rebase'
assert_exit "acked retry on a default-branch PR proceeds" 0
assert_silent "…silently — no repeated reminder"

# SANCTIONED NO-REVIEW CASES. When the reminder block prints on the no-review
# path, it names why there is no review if the reason is one a review workflow
# produces by design, so the agent does not chase a rerun that cannot post
# anything. Both facts come from no_review_reason's OWN `gh pr view --json
# author,files` call, separate from the refs call the reminder needs.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_PR_EDITS_WORKFLOW='true'
invoke 'gh pr merge 2020 --rebase'
assert_exit "no review on a PR that edits the review workflow: BLOCKS for the reminder" 2
assert_stderr_has "…the header names the likely workflow self-skip" \
  'no review comment (most likely skipped itself)'
assert_stderr_has "…the detail names the edited workflow file" \
  'This PR changes .github/workflows/claude-code-review.yml'
assert_stderr_has "…and the reminder is still there" 'DEFAULT-BRANCH MERGE'
SHIM_PR_EDITS_WORKFLOW='false'

# Configurable workflow path: SYG_MERGE_REVIEW_WORKFLOW. The self-skip detail
# names the CONFIGURED file, not the default spelling.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_PR_EDITS_WORKFLOW='true'
WORKFLOW_OVERRIDE='.github/workflows/other-review.yml'
invoke 'gh pr merge 2031 --rebase'
assert_exit "workflow-path override: BLOCKS for the reminder" 2
assert_stderr_has "…the detail names the configured workflow path" 'This PR changes .github/workflows/other-review.yml'
assert_stderr_lacks "…not the default spelling" 'claude-code-review.yml'
WORKFLOW_OVERRIDE=''
SHIM_PR_EDITS_WORKFLOW='false'

new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_PR_AUTHOR='app/dependabot'
invoke 'gh pr merge 2021 --rebase'
assert_exit "no review on a dependabot PR: BLOCKS for the reminder" 2
assert_stderr_has "…the header names dependabot" 'dependabot PRs are typically skipped'
assert_stderr_lacks "…and not the workflow self-skip" 'skipped itself'
# The webhook spelling of the same author, as a workflow `if:` writes it.
new_case; SHIM_PR_AUTHOR='dependabot[bot]'
invoke 'gh pr merge 2022 --rebase'
assert_stderr_has "dependabot[bot] spelling is recognised too" 'dependabot PRs are typically skipped'
SHIM_PR_AUTHOR='octo-user'

# Both at once: the workflow self-skip is checked first.
new_case; SHIM_PR_AUTHOR='app/dependabot'; SHIM_PR_EDITS_WORKFLOW='true'
invoke 'gh pr merge 2023 --rebase'
assert_stderr_has "workflow edit + dependabot: the self-skip wins" 'skipped itself'
SHIM_PR_AUTHOR='octo-user'; SHIM_PR_EDITS_WORKFLOW='false'

# An ordinary author with no workflow edit keeps the plain wording.
new_case; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2024 --rebase'
assert_stderr_has "ordinary no-review PR keeps the plain reason line" 'no review comment found'
assert_stderr_lacks "…with no sanctioned-case wording" 'skipped itself'
assert_stderr_lacks "…and no dependabot wording" 'dependabot'

# An UNREADABLE author and/or files line (empty, as the shim's `printf` writes a
# missing value) is neither sanctioned case: the plain wording and the reminder
# both still print.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_PR_AUTHOR=''; SHIM_PR_EDITS_WORKFLOW=''
invoke 'gh pr merge 2026 --rebase'
assert_exit "no review, empty author AND files lines: BLOCKS for the reminder" 2
assert_stderr_has "…plain no-review wording" 'no review comment found'
assert_stderr_lacks "…no dependabot wording" 'dependabot'
assert_stderr_lacks "…no workflow self-skip wording" 'skipped itself'
assert_stderr_has "…and the reminder block still prints" 'DEFAULT-BRANCH MERGE'
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_PR_AUTHOR=''; SHIM_PR_EDITS_WORKFLOW='false'
invoke 'gh pr merge 2027 --rebase'
assert_exit "no review, empty author + non-workflow files line: BLOCKS for the reminder" 2
assert_stderr_has "…plain no-review wording" 'no review comment found'
assert_stderr_lacks "…no dependabot wording" 'dependabot'
assert_stderr_has "…and the reminder block still prints" 'DEFAULT-BRANCH MERGE'
SHIM_PR_AUTHOR='octo-user'; SHIM_PR_EDITS_WORKFLOW='false'

# The author/files lookup FAILS while the refs lookup succeeds. The reminder
# depends only on the base, so it must still print — with the plain wording,
# since neither sanctioned fact could be read. The fixture would otherwise
# answer with BOTH sanctioned reasons, so any sanctioned wording here means the
# failed call's output leaked through. A hook that folds author/files into the
# refs call loses the base with them and goes silent (exit 0) on this row.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''; SHIM_AUTHOR_FILES_EXIT=1
SHIM_PR_AUTHOR='app/dependabot'; SHIM_PR_EDITS_WORKFLOW='true'
invoke 'gh pr merge 2028 --rebase'
assert_exit "author/files lookup fails, refs succeed: BLOCKS for the reminder" 2
assert_stderr_has "…the reminder block still prints" 'DEFAULT-BRANCH MERGE'
assert_stderr_has "…with the plain no-review wording" 'no review comment found'
assert_stderr_lacks "…no workflow self-skip wording" 'skipped itself'
assert_stderr_lacks "…no dependabot wording" 'dependabot'
SHIM_AUTHOR_FILES_EXIT=0; SHIM_PR_AUTHOR='octo-user'; SHIM_PR_EDITS_WORKFLOW='false'

# A NON-default PR stays silent on the no-review path even when the reason is a
# sanctioned one — the reminder block prints nothing for a non-default base.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON=''; SHIM_PR_EDITS_WORKFLOW='true'
invoke 'gh pr merge 2025 --rebase'
assert_exit "non-default PR editing the review workflow, no review: allowed" 0
assert_silent "…and silent"
SHIM_PR_EDITS_WORKFLOW='false'; SHIM_PR_BASE='main'

# ===========================================================================
# 6. Origin-language scan
# ===========================================================================
printf '\n--- origin-language scan ---\n'

SHIM_PR_BASE='develop'

new_case; SHIM_REVIEW_JSON=$(review_json 777 'This is pre-existing and not a regression.')
invoke 'gh pr merge 2002 --rebase'
assert_stderr_has "origin language fires" 'ORIGIN-LANGUAGE DETECTED'
assert_stderr_has "…and demands a merits disposition" 'merits disposition'

# The count is reported, not just the boolean — the warning says how much of it
# there is, so a regression to a plain flag would still print the banner.
new_case; SHIM_REVIEW_JSON=$(review_json 777 "$(printf 'line one predates the change\nline two is consistent with existing code\n')")
invoke 'gh pr merge 2002 --rebase'
assert_stderr_has "origin count is per-line" 'DETECTED (2 matching line(s))'

new_case; SHIM_REVIEW_JSON=$(review_json 777 'Two real findings, both introduced here.')
invoke 'gh pr merge 2002 --rebase'
assert_stderr_lacks "clean review: no origin warning" 'ORIGIN-LANGUAGE DETECTED'

# ===========================================================================
# 6a. Added-comment claim scan
#
# The scan reads the PR DIFF, not the review, so its fixtures are independent
# of SHIM_REVIEW_JSON — but the review still has to be present, because the
# paragraph rides the review-gate block and never prints on its own. Every
# upstream gate is held inert: base `develop` (no reminder) and no
# `--delete-branch` (no worktree guard), so a failure here is the scan's.
# ===========================================================================
printf '\n--- added-comment claim scan ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

# One added comment carrying two of the three vocabulary classes (certainty
# and provenance), beside an added code line that must not itself match.
DIFF_CLAIM=$(printf 'diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1,2 +1,4 @@\n const a = 1;\n+  // this value always comes from the catalog\n+const b = resolve(a);\n')

# The negative fixture. A STANDALONE `always` token sits in a CODE line — it
# must be standalone, not `alwaysOn`, because the anchored vocabulary cannot
# match inside a longer identifier and the fixture would then pass vacuously.
# As written, a regression that dropped the comment-shape filter lights this
# case up: the code line matches the vocabulary and only the shape filter
# keeps it out of the banner.
DIFF_CLEAN=$(printf 'diff --git a/src/y.ts b/src/y.ts\n--- a/src/y.ts\n+++ b/src/y.ts\n@@ -1,2 +1,4 @@\n+// helper for the parser\n+if (always) { return; }\n+const parsed = parse(input);\n')

# The substring fixture: an added COMMENT line whose only claim vocabulary is
# buried inside longer words — "whenever" carries `never`, "spread from"
# carries `read from`. This is the case the anchors exist for, and it goes red
# the moment any of them is dropped.
DIFF_SUBSTRING=$(printf 'diff --git a/src/z.ts b/src/z.ts\n--- a/src/z.ts\n+++ b/src/z.ts\n@@ -1,2 +1,3 @@\n+// call this whenever the flag changes; values spread from config\n+const z = 1;\n')

# Thirteen claim-shaped comment lines — one past the 12-line display cap, so
# the banner has to say it is truncating rather than report the cap as the
# total.
DIFF_MANY=$(printf 'diff --git a/src/m.ts b/src/m.ts\n--- a/src/m.ts\n+++ b/src/m.ts\n@@ -1,2 +1,15 @@\n')
for claim_i in $(seq 1 13); do
  DIFF_MANY="${DIFF_MANY}"$'\n'"+// claim ${claim_i}: this can never be null"
done

new_case; SHIM_PR_DIFF="$DIFF_CLAIM"
invoke 'gh pr merge 2002 --rebase'
assert_exit "claim-shaped comment: still blocks to surface the review" 2
assert_stderr_has "…and the review is still injected" 'LGTM. No actionable findings.'
assert_stderr_has "claim scan fires" 'CLAIM-SHAPED ADDED COMMENTS'
assert_stderr_has "…and quotes the matched line" 'this value always comes from the catalog'
assert_stderr_has "…and says what to do about it" 'hedge it'
# The verification instruction fires at the one moment the code it names is
# most likely to be on a branch the shell is not standing on, so it has to name
# the ref. The shim's headRefName is `feat/example`, so the concrete form is
# assertable — an abstract "use the PR's ref" would pass a substring check
# without ever having resolved anything.
assert_stderr_has "…and names the branch hazard" 'not the working tree'
assert_stderr_has "…with the PR's own head ref, resolved" 'origin/feat/example'

new_case; SHIM_PR_DIFF="$DIFF_CLEAN"
invoke 'gh pr merge 2002 --rebase'
assert_exit "no claim-shaped comment: still blocks to surface the review" 2
assert_stderr_lacks "neutral diff: no claim paragraph" 'CLAIM-SHAPED'
# The branch-hazard line rides the claim paragraph and must not print on its
# own — otherwise every merge carries an instruction with nothing to apply it
# to, and the assertion above would pass on a hook that printed it always.
assert_stderr_lacks "neutral diff: no branch-hazard line either" 'not the working tree'

new_case; SHIM_PR_DIFF="$DIFF_SUBSTRING"
invoke 'gh pr merge 2002 --rebase'
assert_exit "substring-only comment: still blocks to surface the review" 2
assert_stderr_has "…review still injected" 'LGTM. No actionable findings.'
assert_stderr_lacks "…and 'whenever'/'spread from' do not light the banner" 'CLAIM-SHAPED'

new_case; SHIM_PR_DIFF="$DIFF_MANY"
invoke 'gh pr merge 2002 --rebase'
assert_exit "13 claim lines: still blocks to surface the review" 2
assert_stderr_has "…and the banner names the truncation" 'showing first 12 of 13'
assert_stderr_lacks "…rather than reporting the cap as the total" 'ADDED COMMENTS (12 line(s))'
assert_stderr_has "…the 12th line is shown" 'claim 12:'
assert_stderr_lacks "…and the 13th is the one held back" 'claim 13:'

# Fail-open. A diff fetch that cannot run must leave the gate exactly as it was
# — no paragraph, no warning about the fetch, and the review still surfaced.
new_case; SHIM_PR_DIFF="$DIFF_CLAIM"; SHIM_DIFF_EXIT=1
invoke 'gh pr merge 2002 --rebase'
assert_exit "diff fetch fails: gate unchanged, still blocks on the review" 2
assert_stderr_has "…review still injected" 'LGTM. No actionable findings.'
assert_stderr_lacks "…and no claim paragraph" 'CLAIM-SHAPED'
SHIM_DIFF_EXIT=0
SHIM_PR_DIFF=''

# ===========================================================================
# 7. Body fidelity — the printf-not-heredoc decision
# ===========================================================================
printf '\n--- injected body fidelity ---\n'

# A review quoting a heredoc would truncate the injection under an unquoted
# heredoc; printf has no delimiter semantics. The tail line proves nothing was
# cut, which a leading-line assertion could not.
new_case; SHIM_REVIEW_JSON=$(review_json 777 "$(printf 'before the delimiter\nEOF\nafter the delimiter')")
invoke 'gh pr merge 2002 --rebase'
assert_stderr_has "body containing a bare EOF line: head survives" 'before the delimiter'
assert_stderr_has "…and the tail past it survives too" 'after the delimiter'

# ===========================================================================
# 8. Ack-state anomalies (fail closed). Write failures split by which ack:
#    the REVIEW-ack write fails closed with the escape named (an allow would
#    print a review to a stream nobody sees); the REMINDER-ack write fails
#    open — its banner already printed on a blocking exit, best-effort by
#    construction, so the cost is at most a duplicate reminder.
# ===========================================================================
printf '\n--- ack state ---\n'

# A SYMLINK planted at the state file: the state reads as NOT acked, the gate
# blocks, and the victim's bytes are untouched — never write through it.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$CASE_HOME/.local/state/seyag/pr-merge-review-check"
VICTIM="$WORK/victim.$CASE_N"
printf 'victim bytes\n' >"$VICTIM"
VICTIM_BEFORE=$(md5sum "$VICTIM" | cut -d' ' -f1)
ln -s "$VICTIM" "$ACK_FILE"
invoke 'gh pr merge 2002 --rebase'
assert_exit "symlink at the state file: BLOCKS (fail closed)" 2
assert_stderr_has "…and says the state is unusable" 'ack state is unusable'
assert_stderr_has "…naming the symlink" 'symlink'
assert_stderr_has "…and the review is still injected" 'LGTM. No actionable findings.'
if [ "$(md5sum "$VICTIM" | cut -d' ' -f1)" = "$VICTIM_BEFORE" ]; then
  ok "the symlink's victim file is byte-identical"
else
  bad "the hook wrote through the symlink (victim bytes changed)"
fi
assert_ack_lacks "…and no ack line was written" '2002:777:2026-08-08T12:00:00Z'
# The retry blocks again — the anomaly is not ackable past.
invoke 'gh pr merge 2002 --rebase'
assert_exit "retry with the symlink still planted: blocks again" 2
assert_stderr_has "…with the same warning" 'ack state is unusable'
rm -f "$ACK_FILE"

# A non-regular file at the state path: same fail-closed treatment.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$ACK_FILE"
invoke 'gh pr merge 2002 --rebase'
assert_exit "directory at the state path: BLOCKS (fail closed)" 2
assert_stderr_has "…and says the state is unusable" 'ack state is unusable'
rm -rf "$ACK_FILE"

# Same on the reminder path: the reminder prints, nothing is written through
# the anomaly, and the merge stays blocked.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''
mkdir -p "$ACK_FILE"
invoke 'gh pr merge 2010 --rebase'
assert_exit "reminder path with a directory at the state path: BLOCKS" 2
assert_stderr_has "…the reminder still prints" 'DEFAULT-BRANCH MERGE'
assert_stderr_has "…and the state warning says so" 'ack state is unusable'
rm -rf "$ACK_FILE"

# A symlink at the state DIRECTORY is the same
# write-through class as one at the file — the ack would land in whatever
# the link points at. Fail closed, name the dir, leave the victim untouched.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$CASE_HOME/.local/state/seyag"
VICTIM_DIR="$WORK/victimdir.$CASE_N"; mkdir -p "$VICTIM_DIR"
ln -s "$VICTIM_DIR" "$CASE_HOME/.local/state/seyag/pr-merge-review-check"
invoke 'gh pr merge 2002 --rebase'
assert_exit "symlink at the state DIR: BLOCKS (fail closed)" 2
assert_stderr_has "…and names it as the state directory symlink" 'the state directory)'
assert_stderr_has "…with the unusable-state warning" 'ack state is unusable'
if [ ! -e "$VICTIM_DIR/ack" ]; then
  ok "the dir symlink's victim is untouched"
else
  bad "the hook wrote through the dir symlink (victim gained an ack file)"
fi

# Same at the seyag-level parent directory.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$CASE_HOME/.local/state"
VICTIM_DIR="$WORK/victimdir.$CASE_N"; mkdir -p "$VICTIM_DIR"
ln -s "$VICTIM_DIR" "$CASE_HOME/.local/state/seyag"
invoke 'gh pr merge 2002 --rebase'
assert_exit "symlink at the seyag state dir: BLOCKS (fail closed)" 2
assert_stderr_has "…and names it as the seyag state directory symlink" 'the seyag state directory)'
if [ ! -e "$VICTIM_DIR/pr-merge-review-check/ack" ]; then
  ok "the seyag-dir symlink's victim is untouched"
else
  bad "the hook wrote through the seyag-dir symlink"
fi

# A regular file where the state DIRECTORY belongs is a
# NAMED fault, not a generic write failure (which fails open).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$CASE_HOME/.local/state/seyag"
: >"$CASE_HOME/.local/state/seyag/pr-merge-review-check"
invoke 'gh pr merge 2002 --rebase'
assert_exit "regular file where the state dir belongs: BLOCKS (fail closed)" 2
assert_stderr_has "…naming the fault" 'exists and is not a directory'
assert_ack_lacks "…and nothing was written anywhere" '2002:777:2026-08-08T12:00:00Z'

# A pre-existing wide state dir self-heals to 700 on the
# next blocking write (-m only applies at creation).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
WIDE_DIR="$CASE_HOME/.local/state/seyag/pr-merge-review-check"
mkdir -p "$WIDE_DIR"; chmod 755 "$WIDE_DIR"; : >"$ACK_FILE"
invoke 'gh pr merge 2002 --rebase'
assert_exit "wide state dir: still blocks normally" 2
assert_ack_has "…and the ack write happened" '2002:777:2026-08-08T12:00:00Z'
if [ "$(stat -c '%a' "$WIDE_DIR")" = "700" ]; then
  ok "the wide state dir self-healed to 700"
else
  bad "the state dir mode is $(stat -c '%a' "$WIDE_DIR"), expected 700"
fi

# A HEALTHY state file whose write fails (read-only): fail CLOSED, with the
# escape named. An allow here would print the review to a stream nobody
# sees (stderr reaches the agent only on the blocking path) and silently
# no-op the gate for as long as the fault lasts. SYG_DISABLE=guards-pr is
# the way out of the block while the state path is fixed.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
mkdir -p "$CASE_HOME/.local/state/seyag/pr-merge-review-check"
: >"$ACK_FILE"
chmod 444 "$ACK_FILE"
invoke 'gh pr merge 2002 --rebase'
assert_exit "review path, healthy-but-unwritable ack: BLOCKS with the escape named" 2
assert_stderr_has "…and says why" 'ack write failed'
assert_stderr_has "…naming the escape" 'SYG_DISABLE=guards-pr'
assert_stderr_has "…and that it lives in the SESSION environment, not this shell" 'SESSION'
assert_stderr_has "…after injecting the review" 'LGTM. No actionable findings.'
rm -f "$ACK_FILE"

# The REMINDER path's failed write is the mirror image: the reminder banner
# already printed, the write is best-effort, so the hook fails OPEN (exit 0)
# rather than block forever. That exit-0 path is exactly where stderr
# reaches nobody (the header's rule), so the dropped-warning contract is
# silence about the write: no WARNING line may claim the agent was told.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''
mkdir -p "$CASE_HOME/.local/state/seyag/pr-merge-review-check"
: >"$ACK_FILE"
chmod 444 "$ACK_FILE"
invoke 'gh pr merge 2010 --rebase'
assert_exit "reminder ack write failing on a healthy state: fails open" 0
assert_stderr_lacks "…and no warning line claims the agent was told" 'WARNING: default-branch reminder ack write failed'
assert_ack_lacks "…and nothing was acked through the read-only file" 'RELEASE:acme-widgets/cli:2010'
rm -f "$ACK_FILE"

# ===========================================================================
# 9. The --delete-branch precondition
#
# Scope note, because it is the whole design and a future edit will be tempted
# to widen it: the guard fires on a worktree OTHER than the current one. gh
# switches the CURRENT worktree off the head branch before deleting it, so that
# case works and blocking it would block the ordinary "merge my feature
# branch" invocation. The case below pins exactly that, and it is the case
# most likely to be broken by someone implementing the rule from its one-line
# description.
# ===========================================================================
printf '\n--- delete-branch precondition ---\n'

# Two worktrees: the current one on develop, another holding the head branch.
OTHER_TREE='/repo/../wt-a'
WT_CONFLICT=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/develop\n\nworktree %s\nHEAD bbb\nbranch refs/heads/feat/example\n' "$OTHER_TREE")
# The same two trees, except the head branch is held by the CURRENT one.
WT_CURRENT_ONLY=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/feat/example\n\nworktree %s\nHEAD bbb\nbranch refs/heads/other\n' "$OTHER_TREE")
# Nobody holds it, and one worktree is detached (no `branch` line at all).
WT_CLEAN=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/develop\n\nworktree %s\nHEAD bbb\ndetached\n' "$OTHER_TREE")

SHIM_PR_BASE='develop'
SHIM_PR_HEAD='feat/example'
SHIM_CURRENT_TREE='/repo'
SHIM_REVIEW_JSON="$LGTM"

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_exit "another worktree holds the head branch: blocked" 2
assert_stderr_has "…names the branch" 'feat/example'
assert_stderr_has "…names the offending worktree path" "$OTHER_TREE"
assert_stderr_has "…and gives a fix" 'git worktree remove'
# Ordering: the guard runs BEFORE the review fetch, so a blocked merge costs no
# review round trip and the agent reads the precondition alone rather than
# hunting for it under an injected review.
assert_no_fetch "…without fetching the review first"
assert_ack_lacks "…and writes no review ack" '2002:777:2026-08-08T12:00:00Z'

# Not ackable, and this pair is what says so. The review gate's whole contract
# is "block once, then allow"; inheriting that here would make the guard
# decorative — the second attempt would delete the branch anyway.
#
# It runs with NO review fixture on a develop-based PR, which is the only
# arrangement that can detect the failure. Under the LGTM fixture above, an
# ackable guard falls through to the review gate, which blocks with the SAME
# exit 2. With no review to fall through to, an acked second call exits 0 and
# the mutation is caught.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_exit "no-review fixture: first attempt blocked by the precondition" 2
assert_stderr_has "…with the precondition banner" 'PR MERGE BLOCKED'
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_exit "retrying the same command is blocked again (no ack path)" 2
assert_stderr_has "…still the precondition, not a spent gate" 'PR MERGE BLOCKED'
SHIM_REVIEW_JSON="$LGTM"

# THE REFINEMENT. gh switches the current worktree off the head branch and then
# deletes it, so this is the ordinary merge and must pass straight through to
# the review gate.
new_case; SHIM_WORKTREES="$WT_CURRENT_ONLY"
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "current worktree on the head branch: not the guard's case" 'PR MERGE BLOCKED'
assert_pr "…and control reaches the review gate normally" 2002

new_case; SHIM_WORKTREES="$WT_CLEAN"
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "branch checked out nowhere: passes through" 'PR MERGE BLOCKED'
assert_pr "…and reaches the review gate" 2002

# Short forms. `-d` is the documented shorthand and pflag clusters booleans, so
# `-rd` is a real invocation shape — matching only the long flag would leave a
# silent hole that looks exactly like a correct pass.
#
# Both assert the BANNER, not just exit 2. Exit 2 alone was measured to pass
# with the short-flag pattern deleted from the hook, because the review gate
# blocks with the same code — a test that reported coverage while verifying
# nothing about the flag it was named for.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase -d'
assert_exit "short flag -d is the same flag: blocked" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 -rd'
assert_exit "clustered short flags -rd: blocked" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'

# The negative half of the cluster pattern. A regex loose enough to match any
# flag containing a `d` would block every merge on a repo with worktrees, which
# would read as "the guard works" right up until someone merges without -d.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --admin'
assert_stderr_lacks "no delete flag: guard does not fire" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# The flag must belong to the MERGE, not merely to the command line. Both of
# these were live false positives under a raw whole-command match: the guard is
# not ackable, so a false block told the agent to tear down a worktree that had
# nothing to do with the command, under a banner explaining a flag that was
# never passed.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase && git branch -d old-feature'
assert_stderr_lacks "a chained unrelated -d does not arm the guard" 'PR MERGE BLOCKED'
assert_pr "…and the merge still reaches the review gate" 2002

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase && find . -delete'
assert_stderr_lacks "a chained --delete-shaped flag does not arm the guard" 'PR MERGE BLOCKED'
assert_pr "…and the merge still reaches the review gate" 2002

# Quoted prose is ONE argument, so an anchored full-token match cannot see a
# flag inside it — the same property that keeps a quoted --body from arming
# the PR-number extraction, now relied on by the flag check too.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --body "remove the -d flag from the config script"'
assert_stderr_lacks "a -d inside a quoted --body does not arm the guard" 'PR MERGE BLOCKED'
assert_pr "…and the merge still reaches the review gate" 2002

# The other half of the same property: cross-attribution between two REAL merge
# invocations. The gate arms on the first, so the second's flag is not its flag.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2001 --rebase && gh pr merge 2002 -d'
assert_stderr_lacks "a LATER merge's flag is not attributed to the armed one" 'PR MERGE BLOCKED'
assert_stderr_has "…it is still refused as a compound (the refusal precedes every network call)" 'ONE MERGE PER COMMAND'

# …and the converse, so the case above cannot pass by the flag check simply
# being broken: when the ARMED invocation is the one carrying the flag, it fires.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 -d && echo done'
assert_exit "the armed invocation's own flag still fires" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# pflag accepts `--flag=value` for BOOLEANS — `--delete-branch=true` is a real
# shape, and anchoring the token match on `$` alone silently let it through:
# an UNDER-arm, where the merge proceeds and deletes the branch.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --delete-branch=true'
assert_exit "explicit --delete-branch=true is the same flag: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# pflag's `--flag=value` form for booleans: `=false` is an explicit opt-out
# and must NOT arm the guard — blocking on it is a false block the reader
# has to dismiss. `=true` (the row above this one) does arm it.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --delete-branch=false'
assert_stderr_lacks "--delete-branch=false is an explicit opt-out: guard does not fire" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# A flag-shaped token consumed as a VALUE is not the flag: `--body -d` passes
# "-d" as the body. The delete check runs inside the value-aware walk, so
# the token is skipped exactly the way the PR-number walk skips it.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --body -d'
assert_stderr_lacks "a -d consumed as a flag's value is not the delete flag" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase -t -d'
assert_stderr_lacks "same for a short value flag (-t -d)" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# The asymmetric git failure: rev-parse fails, worktree list succeeds. Without
# an explicit empty-CURRENT_TREE check the comparison is `path != ""`, true for
# EVERY worktree, so a single failed command flips the guard from fail-open to
# block-everything. The SHIM_GIT_EXIT case cannot see this — it fails both.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_CURRENT_TREE=''
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "unresolvable current worktree: fails open, not closed" 'PR MERGE BLOCKED'
assert_pr "…and the review gate still runs" 2002
SHIM_CURRENT_TREE='/repo'

# The flag has to survive the WRAPPER RECURSION, not just the top-level scan.
# `bash -c` and quoted `eval` arguments are one opaque token, so the invocation
# inside is found by re-entering the parse — and the flag rides back out of
# that alongside the PR number. Nothing else pins the flag half of that
# return, so a future edit to the recursive branch could drop it and stay
# green: the PR number would still resolve, the gate would still arm, and only
# the delete-branch guard would silently stop firing.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'bash -c "gh pr merge 2002 --rebase --delete-branch"'
assert_exit "flag propagates out of a bash -c recursion: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'eval "gh pr merge 2002 --rebase -d"'
assert_exit "…and out of a quoted eval recursion" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# The negative half: recursion must not INVENT a flag either. Same nesting, no
# delete flag — without this, a recursive branch hardcoding a flag would pass
# both cases above.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'bash -c "gh pr merge 2002 --rebase"'
assert_stderr_lacks "recursion does not invent a flag that was not passed" 'PR MERGE BLOCKED'
assert_pr "…and the gate still arms on the nested invocation" 2002

# A redirection does not end a command's argument list in bash, and the
# splitter drops redirection words WITH their targets — so a flag after
# `2>&1` or `> out.log` is still seen.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase 2>&1 --delete-branch'
assert_exit "a flag after a 2>&1 redirection is still seen: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase > out.log --delete-branch'
assert_exit "…and after a plain > redirection" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# The PR-NUMBER walk must stay strict about redirection TARGETS while the flag
# walk is loosened. An all-digit redirection TARGET is not a PR number; the
# redirect word and its target never become arguments. This is a numberless
# invocation now (gh infers the branch PR), and with the fallback failing the
# gate stands down — the same observable the source hook had, by a different
# mechanism; the fallback's positive case is in section 2d.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge --rebase > 2'
assert_no_fetch "an all-digit redirection TARGET is not read as a PR number"

# A real separator still ends the walk, so dropping redirections did not
# quietly re-open the chained-command false positive.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase > out.log && git branch -d old-feature'
assert_stderr_lacks "a chained -d past a redirection still does not arm" 'PR MERGE BLOCKED'
assert_pr "…and the merge still reaches the review gate" 2002

# A bare NEWLINE separates statements in bash — a -d on the NEXT line belongs
# to a different command and must not arm the guard.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge 2002 --rebase\ngit branch -d old-feature')"
assert_stderr_lacks "a -d on the NEXT line does not arm the guard" 'PR MERGE BLOCKED'
assert_pr "…and the merge still reaches the review gate" 2002

# The same boundary, on the PR-NUMBER walk: a bare digit belonging to a later
# statement must not become the resolved PR. This is the wrong-PR failure the
# arg-vector parse exists to prevent, reached through the newline. No delete
# flag here, so the guard cannot mask the result; the invocation is numberless
# and the fallback fails, so nothing arms.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge --rebase\necho 5')"
assert_no_fetch "a digit on the NEXT line is not read as the PR number"

# The exception that makes the boundary a continuation test rather than a
# line test: a backslash-continued invocation is ONE command, and a flag past
# the continuation is still seen. Measured, not assumed.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge 2002 --rebase \\\n  --delete-branch')"
assert_exit "a flag past a backslash-continuation is still seen: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# A `\`-CONTINUATION is not a command break, and treating it as one made a
# decoy read as a real invocation. Real bash runs the command below as ONE
# `echo` — `gh` never executes. The source hook still over-armed the review
# gate here (its token backstop read echo's arguments); the shared splitter
# classifies the whole thing as echo's argument list, and the
# mention-in-argument rule keeps it a no-op. Pinned as the new contract.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'echo decoy \\\n  gh pr merge 2002 --delete-branch')"
assert_stderr_lacks "a backslash-continued decoy does not block" 'PR MERGE BLOCKED'
assert_exit "…and arms nothing at all (one echo runs; no merge to gate)" 0
assert_no_fetch "…no fetch either"

# A PR number placed AFTER a redirection: the source hook's strict walk never
# collected it (its own documented under-arm — "the number virtually always
# follows merge directly"). The shared splitter drops only the redirect word
# and its target, so the number resolves now. Pinned as the fix.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge --rebase > out.log 2002'
assert_pr "a PR number after a redirection resolves (was the source hook's documented under-arm)" 2002

# A redirection TARGET is never a flag, however it is spelled.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase > -d'
assert_stderr_lacks "a redirection target named -d is not the flag" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase > --delete-branch'
assert_stderr_lacks "…nor is a target named --delete-branch" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# The converse, so consuming the target cannot quietly swallow a REAL flag that
# follows it — which would be an under-arm, the worse direction.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase > -d --delete-branch'
assert_exit "…while a real flag AFTER that target is still seen: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# A MULTI-LINE QUOTED ARGUMENT sits inside one invocation, and the boundary
# must not read it as a statement break. Both severities are pinned because
# they are different failures. With the value before the FLAG the guard
# silently does not fire (an under-arm — the branch is deleted despite the
# conflict). With it before the NUMBER nothing resolves at all, which disarms
# the review gate and the reminder too, not just this guard.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge 2002 --rebase --title "line one\nline two" --delete-branch')"
assert_exit "a flag past a multi-line quoted value is still seen: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CLEAN"
invoke "$(printf 'gh pr merge --title "line one\nline two" 2002 --rebase')"
assert_pr "a PR number past a multi-line quoted value still resolves" 2002

# The REPO value carries the same hazard one line earlier: a quoted multi-line
# --repo value emitted raw would shift every extraction line after the fifth
# (the protocol reads the scope off line 5), and a truthy corrupted scope
# would silently SKIP the delete-branch precondition below — a block becoming
# an unblock. The capture refuses multi-line values: repo stays empty, the
# lookups scope to the cwd repo, and the extraction is unshifted.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'gh pr merge 2002 --repo "line one\nline two" --rebase --delete-branch')"
assert_stderr_has "a multi-line --repo value assigns nothing, so the precondition still runs" 'PR MERGE BLOCKED'
assert_api_lacks "…and no corrupted value reached any fetch" 'line one'

# The control that keeps the pair honest: the same command with a single-line
# value behaved correctly even while the multi-line form was broken, so a
# fixture without the embedded newline proves nothing about this boundary.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --title "one line" --delete-branch'
assert_exit "control: single-line value, same command shape" 2

# A `\`-continuation between a redirection operator and its target is not the
# target — the splice makes `> --delete-branch` operator-plus-target, so the
# flag is the target and must not fire.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge 2002 --rebase > \\\n  --delete-branch')"
assert_stderr_lacks "a continuation before a redirection target is not the flag" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# The converse: consuming the target across a continuation must not swallow a
# REAL flag that follows it, which would be an under-arm.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke "$(printf 'gh pr merge 2002 --rebase > \\\n  out.log --delete-branch')"
assert_exit "…while a real flag after that target is still seen: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# `git worktree list` failing ALONE, with `rev-parse` succeeding. The combined
# SHIM_GIT_EXIT case cannot reach this: the empty-CURRENT_TREE check short-
# circuits first, so the worktree query never runs. The script sets `pipefail`
# but not `errexit`, so the failed pipeline yields an empty result rather than
# aborting — which is the fail-open guarantee, pinned rather than assumed.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_WORKTREE_EXIT=128
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "worktree list failing alone: fails open" 'PR MERGE BLOCKED'
assert_pr "…and the review gate still runs" 2002
SHIM_WORKTREE_EXIT=0

# A SHELL WRAPPER spelled any way bash accepts. Exact equality on both the
# shell name and the `-c` flag missed two ordinary shapes, and each disarmed
# EVERY gate — no review injected, no precondition, no reminder — because the
# merge sits inside one opaque quoted token.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'bash -lc "gh pr merge 2002 --rebase --delete-branch"'
assert_exit "clustered shell flag (-lc) still recurses: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke '/bin/bash -c "gh pr merge 2002 --rebase --delete-branch"'
assert_exit "path-qualified shell still recurses: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# The gate half, not just the guard half: without the flag the review gate must
# still arm on the nested PR, which is what "disarmed EVERY gate" meant.
new_case; SHIM_WORKTREES="$WT_CLEAN"
invoke '/usr/bin/env bash -lc "gh pr merge 2002 --rebase"'
assert_pr "…and the review gate arms on the nested PR" 2002

# The negative: a non-shell with a -c flag must NOT recurse, or `grep -c` and
# friends start arming the gate on whatever digit follows.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'grep -c "gh pr merge 1 --delete-branch" file.txt'
assert_no_fetch "a non-shell -c does not recurse into its argument"

# `eval` as a bare ARGUMENT to something else is not an eval invocation. Real
# bash runs the command below as `echo` and nothing more.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'echo eval "gh pr merge 2002 --delete-branch"'
assert_stderr_lacks "eval as another command's argument does not block" 'PR MERGE BLOCKED'
assert_no_fetch "…and resolves no PR at all"

# The converse, so gating eval did not simply disable it: the real quoted form
# still recurses and still arms.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'eval "gh pr merge 2002 --rebase --delete-branch"'
assert_exit "a genuine quoted eval still recurses: blocked" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'

# pflag GLUES a value onto a short flag — `gh pr list -L2` behaves identically
# to `-L 2` — so in a cluster everything after the first value-taking letter
# is that value. `-bd` is a body of "d", not a delete flag, and reading it as
# one produced a false block on a merge that would never delete anything.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase -bd'
assert_stderr_lacks "-bd is a body value, not the delete flag" 'PR MERGE BLOCKED'
assert_pr "…and the merge reaches the review gate" 2002

# The two neighbours that keep that rule from being a blanket exemption: a
# boolean before the `d` still carries it, and a `d` BEFORE the value-taker
# does too.
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 -rd'
assert_exit "-rd: a boolean before d still carries the flag" 2
new_case; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 -db some-body'
assert_exit "-db: d precedes the value-taker, so it carries" 2

# A numberless merge carrying the delete flag: the source hook exited before
# EITHER gate (its own documented gap); the numberless arm resolves the branch
# PR, so BOTH gates now run. This row closes that gap.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242; SHIM_REVIEW_JSON=''
invoke 'gh pr merge --rebase --delete-branch'
assert_exit "numberless merge with --delete-branch: precondition fires (gap closed)" 2
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'
assert_stderr_has "…for the branch-resolved PR" 'PR #4242'
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''; SHIM_REVIEW_JSON="$LGTM"

# The release-PR shape: base default, no flag. This is why the guard needs no
# special-casing for release-style merges.
new_case; SHIM_PR_BASE='main'; SHIM_PR_HEAD='develop'
SHIM_CURRENT_TREE='/repo'
SHIM_WORKTREES=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/develop\n')
SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2010 --rebase'
assert_stderr_lacks "default-branch merge without the flag: guard silent" 'PR MERGE BLOCKED'
assert_stderr_has "…and the reminder still fires" 'DEFAULT-BRANCH MERGE'

# The inverse, and the highest-value case the guard can catch: a default-branch
# merge that DOES carry the flag, with its head branch held by another worktree.
new_case; SHIM_PR_BASE='main'; SHIM_PR_HEAD='develop'
SHIM_CURRENT_TREE='/repo/../wt-a'
SHIM_WORKTREES=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/develop\n')
invoke 'gh pr merge 2010 --rebase --delete-branch'
assert_exit "default-branch merge carrying --delete-branch: blocked" 2
# Again the banner rather than the exit code: with no review fixture in play a
# default-branch PR already exits 2 to deliver its reminder, and that reminder
# mentions the branch too — so both weaker assertions would pass with the guard
# removed entirely.
assert_stderr_has "…by the precondition" 'PR MERGE BLOCKED'
assert_stderr_has "…naming the head branch at risk" 'develop'

# Fail-open, both halves. A guard that blocks when its own lookups break is
# worse than no guard: it stops merges for reasons unrelated to the merge.
SHIM_PR_BASE='develop'; SHIM_CURRENT_TREE='/repo'; SHIM_REVIEW_JSON="$LGTM"

new_case; SHIM_PR_HEAD=''; SHIM_WORKTREES="$WT_CONFLICT"
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "unresolvable head ref: fails open" 'PR MERGE BLOCKED'
assert_pr "…and the review gate still runs" 2002

new_case; SHIM_PR_HEAD='feat/example'; SHIM_GIT_EXIT=128
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_stderr_lacks "git unavailable (not a repo): fails open" 'PR MERGE BLOCKED'
assert_pr "…and the review gate still runs" 2002
SHIM_GIT_EXIT=0

# A worktree path with a space. The porcelain format is line-oriented, so the
# path must be read as the rest of the line — field-splitting would truncate it
# at the space and print a path the reader cannot act on.
new_case
SHIM_WORKTREES=$(printf 'worktree /repo\nHEAD aaa\nbranch refs/heads/develop\n\nworktree /tmp/my worktree\nHEAD bbb\nbranch refs/heads/feat/example\n')
invoke 'gh pr merge 2002 --rebase --delete-branch'
assert_exit "worktree path containing a space: blocked" 2
assert_stderr_has "…and the path is printed whole" '/tmp/my worktree'
# The path appearing is NOT enough — the message also offers two commands to
# paste, and unquoted they break on exactly the shape the detection was hardened
# for: `git worktree remove /tmp/my worktree` takes an extra positional, and
# `-C /tmp/my` leaves `worktree` parsed as the subcommand. Asserting the raw path
# alone let that through.
assert_stderr_has "…and the remove suggestion is quoted" "git worktree remove '/tmp/my worktree'"
assert_stderr_has "…as is the detach suggestion" "git -C '/tmp/my worktree' checkout --detach"

# A cross-repo merge (-R) skips the worktree check entirely: the local
# worktrees belong to THIS checkout's repo and cannot safely answer for
# another repo's head branch — a same-named local branch (feat/example, held
# by wt-a here) would be a false, non-ackable block with no recovery path.
# The review gate still runs for the -R-scoped merge.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R other-x'
assert_stderr_lacks "a cross-repo -R merge skips the local worktree check" 'PR MERGE BLOCKED'
assert_pr "…and the review gate runs normally" 2002

# The converse: -R naming THIS repo (the cwd's own owner/name, served by the
# git shim's remote) is the same merge as an unscoped one, so the worktree
# guard applies to it too.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R acme-widgets/cli'
assert_exit "-R naming the cwd repo: the precondition still fires" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'

# GitHub owner/repo is case-INSENSITIVE and gh accepts a HOST/OWNER/REPO
# spelling for -R, so both of the next rows still name THIS repo; an
# exact-string compare let them skip the local worktree check (a delete
# that strands the branch in the other worktree).
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R Acme-Widgets/CLI'
assert_exit "-R naming the cwd repo in different case: the precondition still fires" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'

new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R github.com/acme-widgets/cli'
assert_exit "-R naming the cwd repo with a host component: the precondition still fires" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'

# An unparseable cwd remote (`SHIM_REPO=weird` makes the git shim serve
# `https://github.com/weird.git`, which `cwd_repo_slug` parses to empty)
# keeps the delete-branch guard ON even when `-R` is passed — the safe
# direction, matching `cwd_repo_slug`'s contract.
new_case; SHIM_REPO='weird'; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R acme-widgets/cli'
assert_exit "unparseable cwd remote with -R acme-widgets/cli: precondition stays on and blocks" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'
assert_stderr_has "…names the branch" 'feat/example'
assert_stderr_has "…names the offending worktree path" "$OTHER_TREE"
assert_no_fetch "…without fetching the review first"

new_case; SHIM_REPO='weird'; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R other-x/repo-x'
assert_exit "unparseable cwd remote with -R other-x/repo-x: precondition also stays on (empty cwd slug)" 2
assert_stderr_has "…by the precondition, not the review gate" 'PR MERGE BLOCKED'
assert_no_fetch "…without fetching the review first"
SHIM_REPO='acme-widgets/cli'

# Control: with a parseable cwd remote and the same worktree conflict
# fixture, `-R other-x/repo-x` (a genuinely different repo) turns the guard
# off and proceeds to the review gate.
new_case; SHIM_WORKTREES="$WT_CONFLICT"; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase --delete-branch -R other-x/repo-x'
assert_stderr_lacks "control: cross-repo -R other-x/repo-x skips the local worktree check" 'PR MERGE BLOCKED'
assert_pr "…and the review gate runs normally" 2002
assert_exit "…exiting per the review fixture" 2

SHIM_WORKTREES=''

# ===========================================================================
# 10. Component toggle — SYG_DISABLE=guards-pr stands the hook down via run.sh
# ===========================================================================
printf '\n--- component toggle ---\n'

# Positive control first, through the same runner: without the disable the
# hook runs and blocks, so the toggle row cannot pass vacuously on a broken
# runner.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke_via_runner '' 'gh pr merge 2002 --rebase'
assert_exit "runner without a disable: the hook blocks as wired" 2
assert_pr "…and fetches through the runner" 2002

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke_via_runner 'guards-pr' 'gh pr merge 2002 --rebase'
assert_exit "SYG_DISABLE=guards-pr: the hook is skipped" 0
assert_no_fetch "skipped hook fetches nothing"
assert_silent "…and is silent"

# ===========================================================================
# 10b. Audit holes D2, D3, D5, D6, D13
# ===========================================================================
printf '\n--- audit holes (D2, D3, D5, D6, D13) ---\n'

# D2: gh accepts -R/--repo before `pr` and between `pr` and `merge`.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R o/r pr merge 7'
assert_api_has "D2: gh -R o/r pr merge 7 arms and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh --repo o/r pr merge 7'
assert_api_has "D2: gh --repo o/r pr merge 7 arms and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh --repo=o/r pr merge 7'
assert_api_has "D2: gh --repo=o/r pr merge 7 arms and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -Ro/r pr merge 7'
assert_api_has "D2: gh -Ro/r pr merge 7 arms and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr -R o/r merge 7'
assert_api_has "D2: gh pr -R o/r merge 7 arms and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R first/r pr merge 7 -R o/r'
assert_api_has "D2: later -R on merge wins over root -R" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R=o/r pr merge 7'
assert_api_has "D2: gh -R=o/r pr merge 7 strips = and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 7 -R=o/r'
assert_api_has "D2: gh pr merge 7 -R=o/r strips = and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh --foo pr merge 7'
assert_exit "D2: unknown root flag gh --foo pr merge 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R o/r pr view 7'
assert_exit "D2: gh -R o/r pr view 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

# D3: quote-split and backslash-split `merge` words pass the cheap reject.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr m""erge 7'
assert_pr 'D3: gh pr m""erge 7 arms and fetches PR 7' 7
assert_exit "…and blocks on review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr mer\ge 7'
assert_pr 'D3: gh pr mer\ge 7 arms and fetches PR 7' 7
assert_exit "…and blocks on review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'gh pr m\\\nerge 7')"
assert_pr 'D3: line-continuation-split gh pr m\NEWLINEerge 7 arms and fetches PR 7' 7
assert_exit "…and blocks on review" 2

# D5: numberless merge after a branch switch in the same command refuses.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git switch other && gh pr merge'
assert_exit "D5: git switch other && gh pr merge refused" 2
assert_stderr_has "…with MERGE BRANCH MOVED banner" 'MERGE BRANCH MOVED — numberless merge after a branch switch refused'
assert_no_fetch "…no fetch"
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git -C . checkout other; gh pr merge'
assert_exit "D5: git -C . checkout other; gh pr merge refused" 2
assert_stderr_has "…with MERGE BRANCH MOVED banner" 'MERGE BRANCH MOVED — numberless merge after a branch switch refused'
assert_no_fetch "…no fetch"
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr checkout 9 && gh pr merge'
assert_exit "D5: gh pr checkout 9 && gh pr merge refused" 2
assert_stderr_has "…with MERGE BRANCH MOVED banner" 'MERGE BRANCH MOVED — numberless merge after a branch switch refused'
assert_no_fetch "…no fetch"
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git switch other && gh pr merge 7'
assert_stderr_lacks "D5: numbered merge after git switch does not get MERGE BRANCH MOVED" 'MERGE BRANCH MOVED'
assert_pr "…and fetches PR 7" 7

new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge; git switch main'
assert_stderr_lacks "D5: switch after gh pr merge does not get MERGE BRANCH MOVED" 'MERGE BRANCH MOVED'
assert_pr "…and resolves branch PR" 4242

new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git checkout -- f; gh pr merge'
assert_stderr_lacks "D5: path checkout (git checkout -- f) before merge does not get MERGE BRANCH MOVED" 'MERGE BRANCH MOVED'
assert_pr "…and resolves branch PR" 4242

new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git checkout HEAD -- f; gh pr merge'
assert_stderr_lacks "D5: path checkout with tree-ish (git checkout HEAD -- f) before merge does not get MERGE BRANCH MOVED" 'MERGE BRANCH MOVED'
assert_pr "…and resolves branch PR" 4242
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'git checkout file.txt; gh pr merge'
assert_exit "D5: pathspec checkout without -- (git checkout file.txt; gh pr merge) is an accepted over-refusal" 2
assert_stderr_has "…with MERGE BRANCH MOVED banner" 'MERGE BRANCH MOVED — numberless merge after a branch switch refused'
assert_stderr_has "…telling the caller to pass the PR number" 'gh pr merge <PR>'
assert_no_fetch "…no fetch"
assert_no_ack "…no ack"

# D6: a failed review fetch refuses instead of reading as no review.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"; SHIM_API_EXIT=1
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: SHIM_API_EXIT=1 refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"; SHIM_API_EXIT=124
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: SHIM_API_EXIT=124 (timeout) refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"
SHIM_API_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON='not-json{'
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: malformed non-JSON review fixture refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON='{"message":"x"}'
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: object payload {\"message\":\"x\"} (filter failure) refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON='[1]'
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: non-page array payload [1] (filter failure) refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON=''; SHIM_API_EMPTY=1
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: empty gh output (shim prints nothing) refuses" 2
assert_stderr_has "…with MERGE REVIEW UNREADABLE banner" 'MERGE REVIEW UNREADABLE — the review could not be read'
assert_no_ack "…no ack"
SHIM_API_EMPTY=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON=$(review_json 777 'other bot' '2026-08-08T12:00:00Z' 'other[bot]')
invoke 'gh pr merge 2002 --rebase'
assert_exit "D6: exit 0 with no matching comment still takes the no-review path" 0
assert_stderr_lacks "…not MERGE REVIEW UNREADABLE" 'MERGE REVIEW UNREADABLE'
assert_silent "…and stays silent on a feature PR"

# D13: heredoc-fed split substitution prefix sets unresolvable.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf "GH_REPO=\$(bash <<'E'\ncat r\nE\n) gh pr merge 7")"
assert_exit "D13: heredoc-fed split sub prefix refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf "GH_REPO=\$(cat <<'E'\no/r\nE\n) gh pr merge 7")"
assert_exit "D13: data heredoc split sub prefix refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "GH_REPO=\$(bash <<<'cat r') gh pr merge 7"
assert_exit "D13: here-string split sub prefix refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf "GH_REPO=\$(cat <<'E'\nx/y\nE\n) gh pr merge 7 -R o/r")"
assert_stderr_lacks "D13: shadowed heredoc sub prefix with -R o/r does not get MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and fetches repos/o/r/issues/7/comments" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf "GH_REPO=\$(cat <<E\no/r\nE\n) gh pr view 1; gh pr merge 7")"
assert_exit "D13: command-wide heredoc_sub_prefix on earlier gh pr view still refuses later gh pr merge 7" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

# R4: unquoted substitution in root repo flag position refuses before any fetch.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R $(cat r) pr merge 7'
assert_exit "R4: gh -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh --repo=$(cat r) pr merge 7'
assert_exit "R4: gh --repo=\$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R `cat r` pr merge 7'
assert_exit "R4: gh -R \`cat r\` pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R o/r -R $(cat r) pr merge 7'
assert_exit "R4: double-root gh -R o/r -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'FOO=1 gh -R $(cat r) pr merge 7'
assert_exit "R4: FOO=1 gh -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'env gh -R $(cat r) pr merge 7'
assert_exit "R4: env gh -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'command gh -R $(cat r) pr merge 7'
assert_exit "R4: command gh -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr -R $(cat r) merge 7'
assert_exit "R4: gh pr -R \$(cat r) merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R $(echo $(cat r)) pr merge 7'
assert_exit "R4: gh -R \$(echo \$(cat r)) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 3; gh -R $(cat r) pr merge 7'
assert_exit "R4: gh pr merge 3; gh -R \$(cat r) pr merge 7 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf "cat <<'E'\ngh -R \$(cat r) pr merge 7\nE")"
assert_exit "R4: heredoc body gh -R \$(cat r) pr merge 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'echo "gh -R $(cat r) pr merge 7"'
assert_exit 'R4: echo "gh -R $(cat r) pr merge 7" stays silent' 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R $(cat r) pr view 7'
assert_exit "R4: gh -R \$(cat r) pr view 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh -R o/r pr merge 7'
assert_stderr_lacks "R4: gh -R o/r pr merge 7 does not get MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf '# gh -R $(cat r) pr merge 7\nls')"
assert_exit "R4: commented # gh -R \$(cat r) pr merge 7 before ls stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "gh -R '\$(cat r)' -R o/r pr merge 7 # shadowed single-quoted sub"
assert_stderr_lacks "R4: single-quoted -R '\$(cat r)' shadowed by -R o/r does not get MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and fetches o/r#7" 'repos/o/r/issues/7/comments'
assert_exit "…and blocks on review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
LONG_SUB_CMD="gh $(printf -- '-R $(a) %.0s' {1..2000})x merge"
t0=$SECONDS
invoke "$LONG_SUB_CMD"
elapsed=$((SECONDS - t0))
assert_exit "R4: 2000x -R \$(a) x merge is not killed (exits 0)" 0
assert_no_fetch "…no fetch"
if [ "$elapsed" -lt 20 ]; then
  ok "R4: 2000x -R \$(a) x merge finishes under 20s (${elapsed}s) and is not killed"
else
  bad "R4: 2000x -R \$(a) x merge took ${elapsed}s (>= 20s)"
fi

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'echo `echo a\ngh pr merge 5` `gh pr merge 5`')"
assert_exit "R4: two backtick spans with gh pr merge 5 refuses ONE MERGE PER COMMAND" 2
assert_stderr_has "…with ONE MERGE PER COMMAND" 'ONE MERGE PER COMMAND'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'bash -c '\''gh -R $(x) pr merge 5'\'''
assert_exit "R4: bash -c 'gh -R \$(x) pr merge 5' refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'eval '\''gh -R $(x) pr merge 5'\'''
assert_exit "R4: eval 'gh -R \$(x) pr merge 5' refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'bash -c "gh -R \$(x) pr merge 5"'
assert_exit 'R4: bash -c "gh -R \$(x) pr merge 5" refuses' 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'bash -c "gh -R $(x) pr merge 5"'
assert_exit 'R4: bash -c "gh -R $(x) pr merge 5" refuses' 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'x=$(gh -R $(y) pr merge 5)'
assert_exit "R4: x=\$(gh -R \$(y) pr merge 5) refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '$(gh -R $(x) pr merge 5)'
assert_exit "R4: \$(gh -R \$(x) pr merge 5) refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '`gh -R $(x) pr merge 5`'
assert_exit "R4: \`gh -R \$(x) pr merge 5\` refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'echo "$(gh -R $(y) pr merge 5)"'
assert_exit 'R4: echo "$(gh -R $(y) pr merge 5)" refuses' 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'cat <<'\''E'\''\n$(y\nE\ngh -R $(x) pr merge 5')"
assert_exit "R4: cat heredoc with unterminated \$(y before gh -R \$(x) pr merge 5 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'bash <<'\''E'\''\ngh -R $(x) pr merge 5\nE')"
assert_exit "R4: bash heredoc with gh -R \$(x) pr merge 5 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'git commit -m "$(cat <<'\''E'\''\ngh -R $(cat r) pr merge 7\nE\n)"')"
assert_exit "R4: git commit -m heredoc mentioning gh -R \$(cat r) pr merge 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'gh pr create --body "$(cat <<'\''E'\''\ngh -R $(cat r) pr merge 7\nE\n)"')"
assert_exit "R4: gh pr create --body heredoc mentioning gh -R \$(cat r) pr merge 7 stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'x=$(echo gh -R $(y) pr merge 5)'
assert_exit "R4: x=\$(echo gh -R \$(y) pr merge 5) stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'echo '\''$(gh -R $(x) pr merge 5)'\'''
assert_exit "R4: echo '\$(gh -R \$(x) pr merge 5)' stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf '# $(gh -R $(x) pr merge 5)\nls')"
assert_exit "R4: a merge span in a comment stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'cat <<'\''E'\''\n$(gh -R $(x) pr merge 5)\nE')"
assert_exit "R4: a merge span in heredoc data stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf '# x $(y)\nls')"
assert_exit "R4: # x \$(y) before ls stays silent" 0
assert_no_fetch "…no fetch"
assert_silent "…and silent"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
DEEP_SUB_CMD="$(printf '$(%.0s' {1..2000})gh -R \$(a) pr merge 5"
t0=$SECONDS
invoke "$DEEP_SUB_CMD"
elapsed=$((SECONDS - t0))
assert_exit "R4: 2000x \$( then gh -R \$(a) pr merge 5 is not killed (exits 0)" 0
assert_no_fetch "…no fetch"
if [ "$elapsed" -lt 20 ]; then
  ok "R4: 2000x \$( then gh -R \$(a) pr merge 5 finishes under 20s (${elapsed}s) and is not killed"
else
  bad "R4: 2000x \$( then gh -R \$(a) pr merge 5 took ${elapsed}s (>= 20s)"
fi

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'echo $'\''a\'\''$(y)'\''; gh -R $(x) pr merge 5'
assert_exit "R4: echo \$'a\\'\$(y)'; gh -R \$(x) pr merge 5 refuses" 2
assert_stderr_has "…with MERGE SCOPE UNRESOLVABLE" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch"

# ===========================================================================
# 11. Self-check and leak guard
# ===========================================================================
printf '\n--- self-check & leak guard ---\n'

# A1: every assert_[A-Za-z0-9_]+ word at command position in $0 must be a
# defined function.
assert_helper_check_fails() {
  local label="$1" target="$2" out rc=0
  out=$(check_assert_helpers "$target") || rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *"FAIL  "* ]]; then
    ok "$label"
  else
    bad "$label (rc=$rc, out=$out)"
  fi
}
check_assert_helpers() {
  local src="${1:-$0}" fn missing=0 count=0
  if [ ! -r "$src" ]; then
    bad "unreadable assertion source: $src"
    return 1
  fi
  for fn in $(sed -E '/^[[:space:]]*#/d; s/[;|&({]+/\n/g' "$src" \
    | sed -nE ':a; s/^[[:space:]]+//; s/^(if|while|until|then|elif|else|do|!)[[:space:]]+//; ta; s/^(assert_[A-Za-z0-9_]+)([[:space:])};|&].*|$)/\1/p' | sort -u); do
    count=$((count + 1))
    if ! declare -F "$fn" >/dev/null; then
      bad "undefined assertion helper in $(basename "$src"): $fn"
      missing=1
    fi
  done
  # Non-empty check: a broken sed pipeline yielding fewer than 10 helpers fails
  # rather than vacuously passing with missing=0.
  if [ "$count" -lt 10 ]; then
    bad "fewer than 10 assertion helpers found in $(basename "$src"): $count"
    return 1
  fi
  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  ok "all assert_* helpers in $(basename "$src") are defined"
}
check_assert_helpers "$0"
cp "$0" "$WORK/scratch-if.sh"
printf '\nif assert_undef_after_if "x"; then :; fi\n' >>"$WORK/scratch-if.sh"
assert_helper_check_fails "A1: undefined helper after if is caught" "$WORK/scratch-if.sh"
rm -f "$WORK/scratch-if.sh"

cp "$0" "$WORK/scratch-bang.sh"
printf '\n! assert_undef_after_bang "x"\n' >>"$WORK/scratch-bang.sh"
assert_helper_check_fails "A1: undefined helper after ! is caught" "$WORK/scratch-bang.sh"
rm -f "$WORK/scratch-bang.sh"

assert_helper_check_fails "A1: missing source path is caught" "$WORK/no-such-probe.sh"

printf 'assert_exit "x" 0\n' >"$WORK/scratch-few.sh"
assert_helper_check_fails "A1: helper count < 10 is caught" "$WORK/scratch-few.sh"
rm -f "$WORK/scratch-few.sh"

# A2: new live lines are those in the live file and not in live-before;
# leak_check catches a new live line equal to a fixture ack line. A leaking
# case writes nothing to its own fixture file, so the rows asserting an ack in
# the fixture HOME are what prove the redirect held.
leak_check() {
  local before="$1" after="$2"
  shift 2
  [ -s "$after" ] || return 0
  local new_lines f
  if [ -s "$before" ]; then
    new_lines=$(grep -vxFf "$before" "$after" 2>/dev/null || true)
  else
    new_lines=$(cat "$after")
  fi
  [ -n "$new_lines" ] || return 0
  for f in "$@"; do
    [ -s "$f" ] || continue
    if grep -qxFf "$f" <<<"$new_lines" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

printf 'alpha/one#1\t10\n' >"$WORK/leak-before"
printf 'alpha/one#1\t10\nbeta/two#2\t20\n' >"$WORK/leak-after-hit"
printf 'beta/two#2\t20\n' >"$WORK/leak-fixture"
if ! leak_check "$WORK/leak-before" "$WORK/leak-after-hit" "$WORK/leak-fixture"; then
  ok "leak_check: reports a leak when a fixture ack line appears in live state"
else
  bad "leak_check: missed a fixture ack line in live state"
fi

printf 'alpha/one#1\t10\ngamma/three#3\t30\n' >"$WORK/leak-after-other"
if leak_check "$WORK/leak-before" "$WORK/leak-after-other" "$WORK/leak-fixture"; then
  ok "leak_check: ignores an unrelated new live line from another session"
else
  bad "leak_check: false-positived on an unrelated new live line"
fi

if leak_check "$WORK/live-before" "$REAL_STATE" "$WORK"/home.*/.local/state/seyag/pr-merge-review-check/ack; then
  ok "the live ack state holds no leaked fixture lines"
else
  bad "the live ack state gained a fixture line — the HOME redirect did not hold"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d probe(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nAll probes passed\n'
