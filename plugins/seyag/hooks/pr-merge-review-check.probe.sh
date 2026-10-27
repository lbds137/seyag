#!/usr/bin/env bash
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

# Leak guard: the live ack state must be byte-identical afterwards. Captured
# before the first invocation so a HOME that silently failed to take effect
# is caught, rather than quietly acking real PRs. "absent" is a real state,
# not a failure: the live state may simply not exist yet.
REAL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/seyag/pr-merge-review-check/ack"
# `md5sum` missing would make BOTH checksums fall through to the same
# sentinel, so the guard would compare "absent" to "absent" and report PASS
# having verified nothing — the vacuous pass this file refuses everywhere
# else. Checked once, up front, and fatal: a leak guard that cannot run is
# worse than none, because it reads as proof.
if ! command -v md5sum >/dev/null 2>&1; then
  printf 'FATAL: md5sum not found — the leak guard could not verify that the live\n' >&2
  printf 'ack state is untouched, and a guard that cannot run must not report a pass.\n' >&2
  exit 1
fi
REAL_STATE_BEFORE=$(md5sum "$REAL_STATE" 2>/dev/null | cut -d' ' -f1 || echo "absent")

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
    # The hook pipes gh's output to a REAL jq, so the fixture must be the
    # RAW shape --slurp produces: an outer array of PAGES, each page an
    # array of comments. The fixture is one comment object, so the shim
    # wraps it twice (one page holding that comment). Pagination itself
    # (many pages) is a live-API property, pinned only as the flags'
    # presence in the logged argv.
    printf '[[%s]]' "${SHIM_REVIEW_JSON:-}"
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
# 1. Command match — the hook must not fire on anything that is not an actual
#    `gh pr merge`. Each of these would be a spurious block if it regressed.
# ===========================================================================
printf '\n--- command match (no block, no fetch) ---\n'

SHIM_REVIEW_JSON="$LGTM"

new_case
printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | env \
  -u XDG_STATE_HOME -u CLAUDE_PROJECT_DIR HOME="$CASE_HOME" PATH="$WORK/bin:$PATH" SHIM_API_LOG="$API_LOG" \
  bash "$HOOK" >"$STDOUT_FILE" 2>"$STDERR_FILE"
LAST_EXIT=$?
assert_exit "non-Bash tool: allowed" 0
assert_no_fetch "non-Bash tool: no fetch"

new_case; invoke 'pnpm test'
assert_exit "unrelated command: allowed" 0
assert_no_fetch "unrelated command: no fetch"

# Both sides of the boundary. The trailing one is the case the hook's own
# comment calls out (`merge-queue`); the leading one is the half that is easy
# to drop when the regex is edited.
new_case; invoke 'gh pr merge-queue 2002'
assert_exit "trailing boundary: gh pr merge-queue is not gh pr merge" 0
assert_no_fetch "trailing boundary: no fetch"

new_case; invoke 'xgh pr merge 2002'
assert_exit "leading boundary: xgh pr merge is not gh pr merge" 0
assert_no_fetch "leading boundary: no fetch"

# `gh pr merge` with no number at all: the numberless arm. With the branch-PR
# lookup failing (SHIM_NUMBER_EXIT), the gate fails open — same observable as
# the source hook, which had no numberless arm at all. The arm's positive
# cases live in section 2d.
new_case; invoke 'gh pr merge --rebase'
assert_exit "bare gh pr merge, branch PR unresolvable: allowed" 0
assert_no_fetch "bare gh pr merge, unresolvable: no fetch"

# A digit that is part of a flag token, not a standalone argument. This is the
# distinction the whole-token digit test exists for; numberless applies the
# same way as the bare form above.
new_case; invoke 'gh pr merge --retries=5 --rebase'
assert_exit "flag-value digit is not a PR number: allowed" 0
assert_no_fetch "flag-value digit: no fetch"

# ===========================================================================
# 2. PR-number extraction — asserted on the fetched URL, never on the exit code
# ===========================================================================
printf '\n--- PR-number extraction ---\n'

new_case; invoke 'gh pr merge 2002 --rebase'
assert_pr "number first" 2002

new_case; invoke 'gh pr merge --rebase 2002'
assert_pr "flags first" 2002

new_case; invoke 'gh  pr   merge  2002'
assert_pr "extra whitespace between words" 2002

# Every separator the leading boundary allows.
new_case; invoke 'pnpm test && gh pr merge 2002'
assert_pr "separator: &&" 2002
new_case; invoke 'echo done; gh pr merge 2002'
assert_pr "separator: ;" 2002
new_case; invoke 'true | gh pr merge 2002'
assert_pr "separator: pipe" 2002
new_case; invoke "$(printf 'pnpm test\ngh pr merge 2002')"
assert_pr "separator: newline" 2002

# The two-part precondition for the old extraction defect, kept as a group
# because the differences between these cases are what document the boundary.
new_case; invoke 'echo "gh pr merge 1" && gh pr merge 2002'
assert_pr "quoted decoy: no misfire" 2002

new_case; invoke 'echo gh pr merge now && gh pr merge 2002'
assert_pr "leading decoy with no digit at all: no misfire" 2002

new_case; invoke 'gh pr merge 2002 && echo gh pr merge 1'
assert_pr "decoy AFTER the real invocation: no misfire" 2002

# WAS A PINNED DEFECT. The old text scan stripped to the FIRST occurrence of
# the phrase, so the decoy's bare digit won over the real invocation and the
# gate fetched the decoy's number. Command-position matching is what fixes it: `echo` holds
# the command position, so its arguments can never be a merge invocation.
new_case; invoke 'echo gh pr merge 1 && gh pr merge 2002'
assert_pr "unquoted leading decoy does not beat the real PR" 2002

# WAS A PINNED DEFECT, and the widest of the three. The old match tested the
# whole command TEXT, so the subcommand actually invoked was irrelevant: any
# command carrying the phrase plus a bare digit armed the gate. Both shapes
# below fired in production. Arg-vector parsing fixes them — a quoted --body
# is ONE argument, so prose inside it can never hold the command position.
new_case; invoke 'gh pr comment 2006 --body "the hook matches gh pr merge 1 in prose"'
assert_no_fetch "gh pr comment whose BODY quotes the phrase does not arm the gate"

new_case; invoke 'gh issue create --body "run gh pr merge 42 when ready"'
assert_no_fetch "command text carrying the phrase does not arm the gate"

# An assignment prefix does not consume the command position. Missing this in
# the prototype made the gate silently skip the shape — a fail-OPEN miss, the
# same class the rewrite exists to close, so it is pinned rather than assumed.
new_case; invoke 'GH_TOKEN=x gh pr merge 2002'
assert_pr "an env-assignment prefix still reaches the merge invocation" 2002

# The command word is matched by basename, so a
# path-qualified gh (`/usr/bin/gh`, a mise shim path) is a real invocation.
new_case; SHIM_REVIEW_JSON="$LGTM"
invoke '/usr/bin/gh pr merge 2002'
assert_pr "a path-qualified gh still arms the gate" 2002
assert_exit "…and blocks under a review fixture" 2

# The cheap reject must not eat shapes the tokenizer
# would have parsed — a quoted command word and a backslash continuation are
# real invocations. (The bare-`merge` substring also costs this section a
# python spawn on `gh pr merge-queue` above; that is the accepted prefilter
# trade.)
new_case; invoke '"gh" pr merge 2002'
assert_pr 'a quoted command word still arms the gate' 2002

new_case; invoke "$(printf 'gh pr \\\nmerge 2002')"
assert_pr 'a line continuation between pr and merge still arms the gate' 2002

# A value token after a value-taking flag is not a PR
# number. `-s -t 2026` leaves no bare number, so the NUMBERLESS arm fires
# (fake gh serves 4242); `-b 9 7` and `--subject 2024 2002` skip the flag's
# value and arm the bare number.
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242
invoke 'gh pr merge -s -t 2026'
assert_pr 'a flag value is not the PR number — the numberless arm fires' 4242
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

new_case; invoke 'gh pr merge -b 9 7'
assert_pr '…the digit after a short value flag is skipped, the bare one arms' 7

new_case; invoke 'gh pr merge --subject 2024 2002'
assert_pr '…same for a long value flag (--subject)' 2002

# -R scopes every lookup to the named repo. The shim's
# repo view is made to FAIL here, so the review fetch can only carry
# other-x through the -R threading itself — the sharpest form of the assert.
new_case; SHIM_REPO_EXIT=1
invoke 'gh pr merge 2002 -R other-x'
assert_pr "a -R-scoped merge still resolves and gates the PR" 2002
assert_api_has "…and the review fetch URL is scoped to the -R repo" 'repos/other-x/issues/2002/comments'
SHIM_REPO_EXIT=0

# Two-part owner/repo and three-part HOST/OWNER/REPO -R forms when `gh repo
# view` fails: the fetch fallback strips a leading host component so the REST
# path is `repos/<owner>/<repo>/...` rather than a 404 `repos/github.com/...`,
# while leaving a plain two-part `owner/repo` intact.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 -R other-x/repo-x --rebase'
assert_pr "plain two-part -R with repo view failing still resolves PR" 2002
assert_api_has "…and the fallback fetch URL keeps owner/repo intact" 'repos/other-x/repo-x/issues/2002/comments'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 -R github.com/other-x/repo-x --rebase'
assert_pr "host-form -R with repo view failing still resolves PR" 2002
assert_api_has "…and the fallback fetch URL strips the leading host" 'repos/other-x/repo-x/issues/2002/comments'
assert_api_lacks "…so github.com does not reach the REST path" 'github.com'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

# A multi-line --repo value is a quoted blob, not an owner/repo: it assigns
# nothing (the lookups scope to the cwd repo) and must not shift the
# line-oriented extraction — every line after the repo line would read the
# wrong value.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf 'gh pr merge 2002 --repo "line one\nline two"')"
assert_pr "a multi-line --repo value assigns nothing; the gate arms the command's PR" 2002
assert_api_has "…and the fetch scopes to the cwd repo, not an -R-invented one" 'repos/acme-widgets/cli/issues/2002/comments'
assert_exit "…and blocks normally" 2
# The discriminator for a leaked multi-line value: with the repo view
# failing, a leaked value would fall through to the fetch URL itself.
# Guarded, the hook has no repo to fetch from and fails open.
new_case; SHIM_REPO_EXIT=1
invoke "$(printf 'gh pr merge 2002 --repo "line one\nline two"')"
assert_exit "repo view failing: fail open" 0
assert_no_fetch "…no fetch ran — no -R-invented repo reached one"
assert_api_lacks "…and the multi-line value reached no lookup" 'line one'
SHIM_REPO_EXIT=0

# GH_REPO= scopes gh exactly like -R; the hook reads it off the command's
# assignment prefix (env-prefixed form included). Repo view fails here so
# the fetch can only carry the assignment through the scoping itself.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'GH_REPO=other-x gh pr merge 2002 --rebase'
assert_api_has "an inline GH_REPO scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and the gate blocks on that repo's review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'env GH_REPO=other-x gh pr merge 2002 --rebase'
assert_api_has "the env-prefixed GH_REPO form scopes the fetch too" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks" 2

# -R wins over GH_REPO (gh's own precedence): the flag's repo reaches the
# fetch, the assignment's does not.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'GH_REPO=other-x gh pr merge 2002 -R second-x --rebase'
assert_api_has "-R beats GH_REPO: the flag's repo scopes the fetch" 'repos/second-x/issues/2002/comments'
assert_api_lacks "…and the assignment's repo reaches nothing" 'other-x'
SHIM_REPO_EXIT=0

# An assignment in an EARLIER simple command — `export GH_REPO=…` — exports
# the variable for the rest of the shell, so it scopes a later merge exactly
# like the prefix form. Same constraints: single-line value, -R wins, and it
# only applies while it PRECEDES the armed invocation in the command.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "an earlier export GH_REPO scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and the gate blocks on that repo's review" 2
SHIM_REPO_EXIT=0

# The ordering half of the same rule: an export AFTER the merge runs too late
# to scope it, so the lookups stay on the cwd repo (repo view resolves it
# here, and its fetch is the one that gates the merge).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase && export GH_REPO=other-x'
assert_api_has "an export AFTER the merge scopes nothing: the cwd repo's review gates it" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the assignment's repo reaches no fetch" 'repos/other-x'

# A STANDALONE assignment (`GH_REPO=x;`) sets a shell VARIABLE, not an
# exported one — bash exports nothing, so a later gh still reads the cwd
# repo. Capturing it gated the merge on another repo's review. Repo view
# fails here so the discriminator is sharp: a capture would reach the fetch
# URL; the correct behavior is fail-open with no fetch at all.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'GH_REPO=other-x; gh pr merge 2002 --rebase'
assert_exit "a standalone GH_REPO= assignment exports nothing: fail open" 0
assert_no_fetch "…no fetch ran — nothing scoped the lookups"
assert_api_lacks "…and the assignment's repo reaches no fetch" 'other-x'
SHIM_REPO_EXIT=0

# The behavior half of the same rule under a healthy repo view: the cwd
# repo's review is what gates the merge.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'GH_REPO=other-x; gh pr merge 2002 --rebase'
assert_api_has "a standalone assignment scopes nothing: the cwd repo's review gates the merge" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the assignment's repo reaches no fetch" 'other-x'

# `export -n` UN-exports: a flag-carrying export must never capture.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export -n GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_exit "export -n un-exports: nothing scopes the lookups, fail open" 0
assert_no_fetch "…no fetch ran"
assert_api_lacks "…and the un-exported repo reaches no fetch" 'other-x'
SHIM_REPO_EXIT=0

# `export -- GH_REPO=…` exports THROUGH the `--` separator (verified on
# this machine): a bare `--` is not a disqualifying flag — only -n, -u and
# -p change export's meaning.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export -- GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "export -- GH_REPO still captures: other-x scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and the gate blocks on that repo's review" 2
SHIM_REPO_EXIT=0

# Child-context exports ignored (measured, bash 5.3, `env -i`: subshell
# `(...)`, `$(...)`, and backtick exports die with the child shell and do not
# reach the parent's later `gh pr merge`).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '(export GH_REPO=other-x) && gh pr merge 2002 --rebase'
assert_api_has "subshell export dies with the child: fetch scopes to the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the subshell's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '$(export GH_REPO=other-x) && gh pr merge 2002 --rebase'
assert_api_has "command-substitution export dies with the child: fetch scopes to the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the substitution's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '`export GH_REPO=other-x` && gh pr merge 2002 --rebase'
assert_api_has "backtick export dies with the child: fetch scopes to the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the backtick's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

# Control: a wrapper shell (`bash -c '…'`) runs its commands in one inner
# shell, so its `export GH_REPO=…` DOES reach the merge inside it (no
# child-context filter on wrapper interiors).
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "bash -c 'export GH_REPO=other-x; gh pr merge 2002 --rebase'"
assert_api_has "control: export inside bash -c scopes the merge in that same wrapper shell" 'repos/other-x/issues/2002/comments'
assert_exit "…and the gate blocks on that repo's review" 2
SHIM_REPO_EXIT=0

# `declare`/`typeset`/`readonly` capture (measured, bash 5.3, `env -i`: `-x`
# before the assignment word exports; last x-flag before the word wins; flags
# after the word are inert for the export attribute).
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'declare -x GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "declare -x GH_REPO scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'typeset -x GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "typeset -x GH_REPO scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'readonly -x GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "readonly -x GH_REPO scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'declare GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "declare without -x does not export: fetch stays on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and other-x reaches no fetch" 'repos/other-x'
assert_exit "…and blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'declare -x +x GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "declare -x +x (last x-flag wins, +x clears export): fetch stays on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and other-x reaches no fetch" 'repos/other-x'
assert_exit "…and blocks on the cwd repo's review" 2

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'declare +x -x GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_api_has "declare +x -x (last x-flag wins, -x exports): fetch scopes to other-x" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks on that repo's review" 2
SHIM_REPO_EXIT=0

# Bare-assignment state (measured, bash 5.3, `env -i`: reassigning an
# exported var updates children's view; `GH_REPO=x; export GH_REPO` exports x).
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export GH_REPO=first-x && GH_REPO=second-x && gh pr merge 2002 --rebase'
assert_api_has "reassigning an exported GH_REPO updates the scope to second-x" 'repos/second-x/issues/2002/comments'
assert_api_lacks "…and the overwritten first-x value reaches no fetch" 'first-x'
assert_exit "…and blocks on second-x's review" 2
SHIM_REPO_EXIT=0

new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'GH_REPO=second-x && export GH_REPO && gh pr merge 2002 --rebase'
assert_api_has "bare assignment promoted by a later export GH_REPO scopes to second-x" 'repos/second-x/issues/2002/comments'
assert_exit "…and blocks on second-x's review" 2
SHIM_REPO_EXIT=0

# Unparseable input must fall back to the permissive scan, never to silence.
# Over-arming is recoverable (the agent sees an unrelated review and retries);
# under-arming just lets the merge through.
new_case; invoke 'gh pr merge 2002 --body "unbalanced'
assert_pr "unbalanced quotes fall back to the legacy scan rather than arming nothing" 2002

# A broken shell_quotes IMPORT must take the same legacy
# fallback, not silently disarm the gate. Simulated by pointing the import's
# lib dir at an empty directory via the SYG_PR_MERGE_LIB_DIR knob — the hook
# tree itself stays intact.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
LIB_DIR_OVERRIDE="$WORK/emptylib.$CASE_N"; mkdir -p "$LIB_DIR_OVERRIDE"
invoke 'gh pr merge 2002'
assert_pr "a broken lib import falls back to the legacy scan, not to silence" 2002
assert_exit "…and the over-arm still blocks on the review it fetched" 2
LIB_DIR_OVERRIDE=''

# A real invocation inside a command substitution is still a real invocation.
new_case; invoke 'out=$(gh pr merge 2002)'
assert_pr "command substitution around the invocation still arms the gate" 2002

# A shell with flags before its own `-c`. Scoping the check to the token
# immediately preceding `-c` missed this; the owner is the command word.
new_case; invoke 'bash -x -c "gh pr merge 2002"'
assert_pr "flags between the shell and its -c do not hide the invocation" 2002

# The QUOTED eval form is one opaque token, so wrapper detection alone cannot
# see it — it needs the recursion that the unquoted form does not.
new_case; invoke 'eval "gh pr merge 2002"'
assert_pr "a quoted eval argument still arms the gate" 2002

# A decoy BEFORE a wrapper-run invocation.
new_case; invoke 'echo gh pr merge 1 && eval gh pr merge 2002'
assert_pr "a decoy before a wrapper-run invocation does not win" 2002

# The `-c` shell check must belong to the token that owns the flag. A shell
# named anywhere earlier in a compound command previously made an unrelated
# tool's `-c` argument get scanned as if it were a shell string.
new_case; invoke 'bash --version; grep -c "gh pr merge 42 mentioned" notes.txt'
assert_no_fetch "an earlier shell name does not make grep -c a shell string"

new_case; invoke 'eval gh pr merge 2002'
assert_pr "an unquoted eval joins its arguments into a real command" 2002

new_case; invoke 'gh pr comment 2006 --body "the hook matches gh pr merge 1 in prose"'
assert_no_fetch "quoted prose never looks like a merge invocation, so no fallback fires"

# Utilities that RUN the following command do not consume the command
# position. `env FOO=bar gh pr merge N` extracted nothing at all — an under-arm.
new_case; invoke 'env GH_TOKEN=x gh pr merge 2002'
assert_pr "a wrapper utility does not consume the command position" 2002

new_case; invoke 'nohup gh pr merge 2002'
assert_pr "same for nohup" 2002

# The `-c` recursion must belong to a SHELL. Many tools take `-c`, and one
# whose argument merely quotes the phrase would otherwise arm the gate on it.
new_case; invoke 'grep -c "gh pr merge 2002" notes.txt'
assert_no_fetch "a non-shell -c argument is not scanned as a command"

# An empty-quoted ARGUMENT between `merge` and the PR number. An empty
# argument must not end the digit scan before reaching the number.
new_case; invoke "gh pr merge '' 2002"
assert_pr "an empty argument does not end the PR-number scan" 2002

# Two REAL, differently-numbered invocations joined by a semicolon. A semicolon
# runs both sides unconditionally and in order, so the FIRST is the one that
# executes first and the one whose review must be surfaced.
new_case; invoke 'gh pr merge 1; gh pr merge 2002'
assert_stderr_has "…the banner names the FIRST invocation as the armed one" '1 2002'
assert_stderr_has "…and the SECOND one is why the compound is refused" 'ONE MERGE PER COMMAND'

# ===========================================================================
# 2c. Compound merges — arming on the first is correct and not sufficient
#
# Observed in production: `gh pr merge A && gh pr merge B` armed the gate on A
# and B merged with no ack cycle of its own. The gate is attention-independent
# by design, so a shape that silently halves its coverage is a hole.
#
# The refusal is deliberately NOT ackable — a retry of the same command would
# reproduce the same hole — so the only way past it is one merge per command.
# It counts only invocations the precise arg-vector scan resolved, for the
# same reason the delete-branch guard does: the fallback paths exist to
# over-arm, and hanging a non-ackable refusal off an over-arm has no way out.
#
# Upstream gates held inert: base `develop` (no reminder), no
# `--delete-branch` (no worktree guard), and a review present (so the gate
# reaches the injection path at all).
# ===========================================================================
printf '\n--- compound merges ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

new_case; invoke 'gh pr merge 2197 && gh pr merge 2198'
assert_exit "two real merges in one command: refused" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the first PR" '2197'
assert_stderr_has "…and the second" '2198'
# The refusal runs BEFORE any network call (it needs only the local
# extraction), so a refused compound costs no review round trip.
assert_no_fetch "…and no review fetch ran first — the refusal needs nothing from the network"
assert_ack_lacks "…and nothing is acked, so the same command refuses again" '2197:777:2026-08-08T12:00:00Z'

# The discriminator. A decoy is not a second invocation, and counting it would
# reintroduce the over-arm the extraction was rewritten to remove — against a
# refusal that cannot be acked past.
new_case; invoke 'echo gh pr merge 1 && gh pr merge 2002'
assert_stderr_lacks "a decoy alongside one real merge is not a compound" 'ONE MERGE PER COMMAND'
assert_pr "…and the real PR is still the armed one" 2002

new_case; invoke 'gh pr merge 2002 --rebase'
assert_stderr_lacks "a single merge does not trip the compound refusal" 'ONE MERGE PER COMMAND'
assert_pr "…and gates normally" 2002

# A merge wrapped in a shell string is a real invocation too, so a wrapped one
# beside a plain one is a compound. Without this the refusal is bypassable by
# spelling one half `bash -c`.
new_case; invoke 'bash -c "gh pr merge 2001" && gh pr merge 2002'
assert_stderr_has "a wrapped merge beside a plain one is a compound" 'ONE MERGE PER COMMAND'
# The banner names the resolved PRs in LIST order: the shared splitter surfaces
# wrapper-interior commands AFTER the top-level ones, so list order — not
# execution order — picks the armed PR here. Both merges are real and the
# refusal blocks the whole command either way, so no merge reaches its ack
# cycle ungated. Pinned so the delta is a decision, not a drift.
assert_stderr_has "…armed on the top-level invocation (list order; the refusal blocks both)" '2002 2001'

# Both merges inside ONE nested shell string — the count has to survive the
# wrapper recursion, not just the top level.
new_case; invoke 'bash -c "gh pr merge 2001 && gh pr merge 2002"'
assert_stderr_has "two merges inside one -c string are still a compound" 'ONE MERGE PER COMMAND'

SHIM_REVIEW_JSON=''

new_case; invoke 'gh pr merge 2002;'
assert_pr "a trailing semicolon does not glue to the PR number" 2002

# An empty-quoted argument is a legitimate EMPTY-STRING argument, not end of
# input. Treating it as nothing truncated the scan and dropped every command
# after it — an under-arm.
new_case; invoke "echo '' && gh pr merge 2002"
assert_pr "an empty-string token does not truncate the scan" 2002

# A `-c` argument is a command in its own right, and arrives as ONE quoted
# token. Without recursion this is invisible — and the naive text scan this
# replaced DID catch it, so missing it would be a regression, not a gap.
new_case; invoke 'bash -c "gh pr merge 2002"'
assert_pr "a merge inside a -c string argument still arms the gate" 2002

# THE RECURSION DEPTH CAP, both sides of it. The shared splitter stops
# unwrapping wrappers past its own cap, so a merge nested four shells deep
# would vanish — the under-arm direction the whole file refuses. The hook
# over-arms on the abandoned strings textually instead.
#
# Built by wrapping rather than by hand, so the nesting depth is the loop count
# and not a hand-counted run of backslashes that is easy to get wrong by one.
#
# SINGLE-QUOTE wrapping specifically, not `printf %q`. %q escapes the SPACES
# (`gh\ pr\ merge`), and the hook's bash pre-filter requires the three words to
# be separated by real whitespace — so a %q-built fixture exits at the
# pre-filter and measures nothing, whichever way the depth cap behaves.
sq() { # <text> -> the text as one single-quoted shell word
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}
nest_shells() { # <levels>
  local nested='gh pr merge 2002' i
  for ((i = 0; i < $1; i++)); do nested="bash -c $(sq "$nested")"; done
  printf '%s' "$nested"
}
new_case; invoke "$(nest_shells 3)"
assert_pr "three levels of shell nesting resolve the real PR" 2002

new_case; invoke "$(nest_shells 4)"
assert_pr "four levels hit the depth cap and still arm rather than exiting clean" 2002

# Five-plus levels leave a `bash -c '…'` wrap still on the text when the cap
# fires, so a token scan (which only sees the outermost layer) would find
# nothing and the under-arm would return one level deeper. The cap runs a raw
# textual regex that reads through every wrap and tolerates the closing quote
# abutting the number, so a merge arms at ANY nesting depth.
new_case; invoke "$(nest_shells 5)"
assert_pr "five levels past the cap still arm via the textual scan" 2002

new_case; invoke "$(nest_shells 7)"
assert_pr "seven levels still arm — depth-independent at the cap" 2002

# ORDERING, list-order side. The shared splitter surfaces wrapper interiors
# after every top-level command, so a plain merge that genuinely comes first
# still wins over a later wrapped one — visible in the refusal banner's PR
# list, since a compound is refused before any fetch runs.
new_case; invoke 'gh pr merge 2001 && bash -c "gh pr merge 2002"'
assert_stderr_has "a plain merge before a wrapped one still wins" '2001 2002'

# Bash keywords that open a command position. `if`/`while`/`until` are the
# easy half to drop; `then`/`do` the other.
new_case; invoke 'if gh pr merge 2002; then echo ok; fi'
# SINGLE-quoted labels here and below: a backticked word inside a DOUBLE-quoted
# label is command substitution, and bash prints a syntax error to stderr for
# each one. The assertions still passed, so the only cost was noise that reads
# as a failing probe to anyone scanning stderr.
assert_pr 'a merge directly after `if` is at a command position' 2002

new_case; invoke 'while gh pr merge 2002; do echo retry; done'
assert_pr 'same after `while`' 2002

# A bare merge chained beside a real one used to arm
# the numbered PR and let the bare half infer its own PR and run ungated;
# under the compound rule the numberless invocation counts toward
# one-merge-per-command, so this is a REFUSAL, and the refusal wins over the
# fallback.
new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge && gh pr merge 2002'
assert_exit "a bare merge beside a real one is refused as a compound" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the numberless invocation as one of the merges" 'a numberless merge (gh infers the PR from the current branch)'
assert_ack_lacks "…and nothing is acked, so the refusal is not ackable past" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge; gh pr merge 2002'
assert_exit "same across a semicolon separator: refused as a compound" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the numberless invocation as one of the merges" 'a numberless merge (gh infers the PR from the current branch)'
assert_ack_lacks "…and nothing is acked" '2002:777:2026-08-08T12:00:00Z'

# Glued punctuation still opens a command position (a subshell).
new_case; invoke 'pnpm test &&( gh pr merge 2002 )'
assert_pr "glued punctuation still opens a command position" 2002

# Bash keywords open a command position too.
new_case; invoke 'if true; then gh pr merge 2002; fi'
assert_pr 'a merge after `then` is still at a command position' 2002

# Heredoc bodies are DATA, never commands — bash will not execute a word in
# one however shell-like it looks. The splitter strips them, so any example
# command quoted in a PR body, commit message or issue text cannot arm the
# gate on the digit after it.
new_case; invoke "$(printf 'gh pr create --body "$(cat <<%sEOF%s\nrun gh pr merge 42 when ready\nEOF\n)"' "'" "'")"
assert_no_fetch "a merge quoted inside a heredoc body does not arm the gate"

# The complement: stripping the body must not swallow a REAL invocation that
# follows the heredoc's terminator.
new_case; invoke "$(printf 'gh pr comment 7 --body "$(cat <<%sEOF%s\nsee gh pr merge 1\nEOF\n)" && gh pr merge 2002' "'" "'")"
assert_pr "a real merge after the heredoc terminator still arms the gate" 2002

# An UNTERMINATED heredoc inside a command substitution leaves the quote
# unbalanced, so the splitter cannot classify the span and extract() falls to
# the legacy textual scan — the deliberate over-arm for input it cannot parse
# (the direction the hook's header pins: over-arm, never arm-nothing). Real
# bash warns and runs the partial command, so no merge executes here; the cost
# is one unrelated review injection, recovered by the ack-retry. Pinned as the
# contract, with the exit asserted so the fallback's block is part of it.
new_case; SHIM_REVIEW_JSON="$LGTM"; SHIM_PR_BASE='develop'
invoke "$(printf 'gh pr create --body "$(cat <<%sEOF%s\nrun gh pr merge 42 when ready' "'" "'")"
assert_pr "an unterminated heredoc inside a substitution over-arms via the legacy scan" 42
assert_exit "…and blocks on the review it fetched (the over-arm's cost)" 2

# The bypass that over-stripping used to cause, pinned so it cannot come back:
# a quoted string that merely LOOKS like a heredoc opener, with a real merge
# after it. Stripping to end-of-text here removed the real invocation entirely
# and the merge proceeded with no gate at all.
new_case; invoke 'gh pr comment 5 --body "see the <<EOF heredoc marker" && gh pr merge 2002'
assert_pr "a false heredoc opener inside quotes must not swallow the real merge" 2002

# `<<<` is a here-string, not a heredoc.
new_case; invoke 'cat <<<marker && gh pr merge 2002'
assert_pr "a here-string is not read as a heredoc opener" 2002

# The tokenizer must not expand a glob against the cwd, so a digit-named file
# cannot become a PR number.
GLOBDIR="$WORK/globdir"
mkdir -p "$GLOBDIR"
: >"$GLOBDIR/7"
new_case; invoke_in "$GLOBDIR" 'gh pr merge * 2002'
assert_pr "a glob token does not expand into a digit-named file" 2002

# ===========================================================================
# 2d. Numberless merges — `gh pr merge` with no number arms the branch's PR
#
# gh infers the PR from the checked-out branch when no number is given, so
# the hook resolves it the same way (`gh pr view --json number`) in its own
# cwd. Lookup failure fails open. The arm is reachable ONLY through a real
# invocation whose arguments carry no number token: a phrase that merely
# mentions the merge — in a quoted body or another command's argument list —
# must stay a no-op.
# ===========================================================================
printf '\n--- numberless merges (branch-PR fallback) ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

# Fake gh serving a number: the numberless invocation arms THAT PR.
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242
invoke 'gh pr merge --rebase'
assert_pr "numberless merge arms the branch's PR (fake gh serves 4242)" 4242
assert_exit "…and blocks to surface its review" 2
assert_stderr_has "…naming the resolved PR" 'PR #4242'
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# gh failing (not a PR branch, gh missing/unauthenticated): fail open.
new_case; SHIM_NUMBER_EXIT=1
invoke 'gh pr merge --rebase'
assert_exit "numberless merge with a failing lookup: allowed" 0
assert_no_fetch "failing lookup: no fetch"

# A bare merge beside a numbered one is a compound
# refusal, not a silent arming: the bare half infers its own PR and would
# merge ungated, which the one-merge-per-command rule refuses; the refusal
# wins over the fallback.
new_case; invoke 'gh pr merge && gh pr merge 2002'
assert_exit "a bare merge beside a numbered one is a compound refusal" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the numberless invocation as one of the merges" 'a numberless merge (gh infers the PR from the current branch)'
assert_ack_lacks "…and nothing is acked, so the same command refuses again" '2002:777:2026-08-08T12:00:00Z'

# Mention-only shapes: a quoted body, and an unquoted echo argument. Neither
# is an invocation, so no fallback may fire — this is the discriminator that
# keeps the numberless arm from re-opening the wrong-PR class the arg-vector
# parse exists to close.
new_case; invoke 'echo gh pr merge 7'
assert_exit "a phrase as another command's argument stays a no-op" 0
assert_no_fetch "echo mention: no fetch"

new_case; invoke 'gh pr comment 2006 --body "merge it with gh pr merge 7 please"'
assert_exit "a phrase inside a quoted body stays a no-op" 0
assert_no_fetch "quoted-body mention: no fetch"

# ===========================================================================
# 2e. Selector merges — `gh pr merge <branch|url|#N>` names its own PR
#
# gh accepts `number | url | branch` as the merge argument (a leading `#` is
# stripped), so a positional non-flag argument is a selector, not a
# numberless invocation: treating it as numberless resolved the CWD branch's
# PR instead — from main the lookup failed and the merge ran ungated; from
# another PR's branch the gate surfaced and acked the WRONG PR's review. The
# hook resolves the selector with `gh pr view <selector>`, fail-open on
# lookup failure, exactly like the numberless arm. The served number alone
# cannot tell the two apart, so these rows assert the view argv too
# (assert_view_has): the selector must be the argument the hook passed.
# ===========================================================================
printf '\n--- selector merges (branch / URL / #N) ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

# A branch selector from a non-PR branch: fake gh resolves feature-x → 4242
# and the gate arms THAT PR (the numberless cwd lookup would have failed and
# stood down here).
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242
invoke 'gh pr merge feature-x --rebase'
assert_view_has "a branch selector is passed to gh pr view" 'feature-x'
assert_pr "…and arms the PR it names" 4242
assert_exit "…and blocks to surface its review" 2
assert_stderr_has "…naming the resolved PR" 'PR #4242'
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# A URL selector naming a DIFFERENT PR than the cwd branch would resolve: the
# gate must arm the URL's PR, and the selector — not a branch inference —
# must be the argument gh pr view saw.
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=7
invoke 'gh pr merge https://github.com/acme-widgets/cli/pull/7 --rebase'
assert_view_has "a URL selector is passed to gh pr view" 'https://github.com/acme-widgets/cli/pull/7'
assert_pr "…and arms the URL's PR" 7
assert_exit "…and blocks to surface its review" 2
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# A URL selector carries its OWN repository, and gh resolves the PR there
# even beside a -R — so every hook lookup must scope to the URL's repo, not
# the cwd's or the -R's. Fetching the cwd repo's same-numbered PR would
# surface and ack the WRONG review (or none, and an ungated merge). The
# shim's repo view is made to FAIL here so the fetch can only carry the
# URL's repo through the SELECTOR_REPO threading (same trick as the -R row).
new_case; SHIM_REPO_EXIT=1; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=9500
invoke 'gh pr merge https://github.com/cli/cli/pull/9500 --rebase'
assert_view_has "the URL selector is passed to gh pr view" 'https://github.com/cli/cli/pull/9500'
assert_pr "…and arms the URL's PR" 9500
assert_api_has "…and the review fetch is scoped to the URL's OWN repo" 'repos/cli/cli/issues/9500/comments'
SHIM_REPO_EXIT=0; SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# The URL's repo wins over an explicit -R on the same command — gh resolves
# it that way, and the -R must not leak into any lookup.
new_case; SHIM_REPO_EXIT=1; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=9500
invoke 'gh pr merge https://github.com/cli/cli/pull/9500 --rebase -R other-x'
assert_api_has "…URL beside -R: the fetch still scopes to the URL's repo" 'repos/cli/cli/issues/9500/comments'
assert_api_lacks "…and the -R repo never reaches a lookup" 'other-x'
SHIM_REPO_EXIT=0; SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# A `#N` selector (quoted — bare, # opens a comment): gh strips the # and
# arms N.
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=7
invoke 'gh pr merge "#7" --rebase'
assert_view_has "a #N selector is passed through for gh to strip" '#7'
assert_pr "…and arms N" 7
assert_exit "…and blocks to surface its review" 2
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# Selector resolution fails (unknown branch, gh blip): fail open, same as
# the numberless fallback.
new_case; SHIM_NUMBER_EXIT=1
invoke 'gh pr merge feature-x --rebase'
assert_exit "selector merge with a failing lookup: allowed" 0
assert_no_fetch "failing selector lookup: no fetch"

# Selector invocations are compounds too: a selector beside a numbered merge
# used to arm only the numbered PR while the selector merge resolved its own
# PR and ran ungated. Refused now — and the refusal PRECEDES the selector
# resolution (a network call), so nothing is resolved and nothing fetched.
new_case; invoke 'gh pr merge feature-x && gh pr merge 2002'
assert_exit "a selector merge beside a numbered one: refused as a compound" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the selector invocation generically" '+ a merge naming its PR by branch or URL'
assert_no_fetch "…no review fetch ran — the refusal precedes every network call"
assert_view_empty "…and no selector was resolved — the refusal precedes the resolution too"

# Two selector merges: same refusal, both named generically.
new_case; invoke 'gh pr merge feature-a && gh pr merge feature-b'
assert_exit "two selector merges in one command: refused" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming both selector invocations" \
  '+ a merge naming its PR by branch or URL + a merge naming its PR by branch or URL'
assert_stderr_has "…with the count naming both invocations" 'one review out of 2'
assert_no_fetch "…nothing fetched"
assert_view_empty "…nothing resolved"

# Selector + bare numberless (no numbered merge at all): still a compound —
# each half would resolve a different PR with no ack cycle of its own.
new_case; invoke 'gh pr merge feature-x && gh pr merge'
assert_exit "a selector merge beside a bare numberless one: refused" 2
assert_stderr_has "…with the one-merge-per-command banner" 'ONE MERGE PER COMMAND'
assert_stderr_has "…naming the numberless half" 'a numberless merge (gh infers the PR from the current branch)'
assert_stderr_has "…and the selector half" '+ a merge naming its PR by branch or URL'
assert_no_fetch "…nothing fetched"
assert_view_empty "…nothing resolved"

# The honest breakdown for a mixed triple: two bare merges beside one
# selector merge names TWO numberless invocations and ONE selector
# invocation, and the total is three — one clause per real invocation, not
# one per kind.
new_case; invoke 'gh pr merge && gh pr merge && gh pr merge feature-x'
assert_exit "two bare merges beside a selector merge: refused" 2
assert_stderr_has "…naming BOTH numberless invocations and the selector one" \
  '+ a numberless merge (gh infers the PR from the current branch) + a numberless merge (gh infers the PR from the current branch) + a merge naming its PR by branch or URL'
assert_stderr_has "…with the honest total" 'one review out of 3'
assert_no_fetch "…nothing fetched"
assert_view_empty "…nothing resolved"

# The boundary the selector clause must NOT cross: two BARE numberless
# merges stay unrefused — both resolve the same cwd-branch PR, so one ack
# cycle covers both. (The view log is non-empty here: the resolution ran.)
new_case; SHIM_NUMBER_EXIT=0; SHIM_PR_NUMBER=4242
invoke 'gh pr merge && gh pr merge'
assert_stderr_lacks "two bare numberless merges are not a compound" 'ONE MERGE PER COMMAND'
assert_pr "…the shared branch PR arms normally" 4242
SHIM_NUMBER_EXIT=1; SHIM_PR_NUMBER=''

# ===========================================================================
# 2f. Scope-moved merges — a directory change before the merge in the same
#     command. The hook's cwd is then not the merge's cwd, so resolving
#     here fetches the WRONG repo's PR (or none → ungated). Non-ackable
#     refusal, before any network call; the escape is to run the merge from
#     the target directory or with -R naming that repo.
# ===========================================================================
printf '\n--- scope-moved merges (cd before the merge) ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

new_case; invoke 'cd ../other-repo && gh pr merge 7'
assert_exit "a cd before a numbered merge: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_stderr_has "…naming the -R escape" 'gh pr merge <PR> -R <owner>/<repo>'
assert_no_fetch "…no fetch ran"
assert_view_empty "…and nothing was resolved"

# The numberless worktree-cd shape: the branch lookup would run against the
# hook's cwd and fail open — an ungated merge.
new_case; invoke 'cd .claude/worktrees/x && gh pr merge'
assert_exit "a cd before a numberless merge: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"
assert_view_empty "…no branch lookup ran either"

# A chdir RUNNER wrapping the merge itself is the same shape.
new_case; invoke 'env -C /tmp gh pr merge 2002'
assert_exit "env -C wrapping the merge: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'

# Separators GLUED into words (`status;`, `repo;gh`, a `{` group) and a
# path-qualified or quoted gh word would hide real cds from the confirm
# scan's command-position model, so the refinement would clear the refusal
# on commands whose merge really runs from another directory. The per-word
# separator split, the reserved-word command positions and the
# basename/quote-aware gh match close them.
new_case; invoke 'git status; cd ../other-repo && gh pr merge 7'
assert_exit "glued trailing separator, cd back at command position: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke '{ cd ../other-repo; gh pr merge 7; }'
assert_exit "brace group, cd in command position: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke 'cd ../other-repo;gh pr merge 7'
assert_exit "glueless separator between cd and gh: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke 'cd ../other-repo && /usr/bin/gh pr merge 7'
assert_exit "path-qualified gh is still a merge the cd affects: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke 'cd ../other-repo && "gh" pr merge 7'
assert_exit "a quoted gh word is still the merge command: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# The merge inside a wrapper string INHERITS the directory the top-level cd
# moved to; neither shell level shows both events on its own, so the
# refinement must refuse rather than clear across levels.
new_case; invoke 'cd ../other-repo && bash -c "gh pr merge 2002"'
assert_exit "cd at top level, merge inside bash -c: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# The merge can also sit where this scan's levels have no eyes: a cd at
# wrapper level 1 with the merge at level 2, or a heredoc BODY fed to a
# stdin shell (bodies are stripped as data at every level, so no scanned
# level shows the merge the caller's walk armed on). Blind means refuse.
new_case; invoke "bash -c 'cd ../x && bash -c \"gh pr merge 2002\"'"
assert_exit "cd at wrapper level 1, merge at level 2: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke "$(printf "cd ../x && bash <<'EOF'\ngh pr merge 2002\nEOF")"
assert_exit "merge in a heredoc body fed to a shell: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke "$(printf "cd ../x && cat <<'EOF' | bash\ngh pr merge 2002\nEOF")"
assert_exit "merge heredoc-piped into bash: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# A here-string word (`<<<`) is all strip-chars: the leading-char strip used
# to spin forever once the part emptied (the membership test stayed True),
# hanging the hook into the harness timeout — a silent stand-down, the
# worst failure mode. The `part and` terminator closes it; the refusal
# rides the wrapper rule (a here-string IS a wrapper string, and the
# top-level cd moves the shell it feeds).
new_case; invoke "cd ../other-repo && bash <<< 'gh pr merge 2002'"
assert_exit "cd before a here-string shell merge: refused (and does not hang)" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# Depth is one-directional: a cd at depth D affects every later merge at
# depth >= D — a subshell or command substitution INHERITS the moved
# directory, so the merge inside it runs from the cd'd directory even
# though the depths differ. Same-depth equality cleared both of these.
new_case; invoke 'cd ../other-repo && (gh pr merge 2002 --rebase)'
assert_exit "cd before a merge inside a subshell: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

new_case; invoke 'cd ../other-repo && echo $(gh pr merge 2002 --rebase)'
assert_exit "cd before a merge inside a command substitution: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# Controls. A cd AFTER the merge is the merge's own business — the merge
# runs first, in this cwd.
new_case; invoke 'gh pr merge 2002 --rebase && cd ..'
assert_stderr_lacks "a cd AFTER the merge does not refuse" 'MERGE SCOPE MOVED'
assert_pr "…and the merge gates normally" 2002

# A cd inside a QUOTED string is data, not a directory change.
new_case; invoke 'echo "cd /tmp" && gh pr merge 2002 --rebase'
assert_stderr_lacks "a cd inside quotes does not refuse" 'MERGE SCOPE MOVED'
assert_pr "…and the merge gates normally" 2002

# A cd inside a SUBSHELL cannot move the parent's directory, so the merge's
# scope is unchanged.
new_case; invoke '(cd /tmp && ls) && gh pr merge 2002 --rebase'
assert_stderr_lacks "a subshell cd does not refuse" 'MERGE SCOPE MOVED'
assert_pr "…and the merge gates normally" 2002

# A pinned repository is immune to a cd by construction — resolving a named
# repo gives the same answer from any directory. The refusal's own -R advice
# is exactly this escape, already taken.
new_case; invoke 'cd ../other-repo && gh pr merge 7 -R acme-widgets/cli'
assert_stderr_lacks "a cd beside an -R pin does not refuse" 'MERGE SCOPE MOVED'
assert_pr "…and the merge gates on the pinned repo" 7
assert_api_has "…scoped by the -R, not the cwd" 'repos/acme-widgets/cli/issues/7/comments'

# ===========================================================================
# 2g. Fan-out merges — `gh pr merge` under xargs/parallel runs once per
#     input; no ack cycle covers the second and later runs. Non-ackable
#     refusal, one merge per command.
# ===========================================================================
printf '\n--- fan-out merges (xargs / parallel) ---\n'

new_case; invoke 'echo 7 8 | xargs -n1 gh pr merge'
assert_exit "a merge under xargs: refused" 2
assert_stderr_has "…with the fan-out banner" 'FAN-OUT MERGE REFUSED'
assert_stderr_has "…naming the recovery" 'one merge per review cycle'
assert_no_fetch "…no fetch ran"

# The control: fan-out around a NON-merge command refuses nothing.
new_case; invoke 'echo 7 8 | xargs -n1 echo'
assert_exit "xargs without a merge: allowed" 0
assert_silent "…and silent"

# ===========================================================================
# 2h. Unresolvable-scope merges — a bare `export GH_REPO` / `declare -x
#     GH_REPO` with no prior assignment in this command (measured, bash 5.3,
#     `env -i`: exports whatever inherited value the shell had, unknown to
#     this hook) or a dynamic `-R`/`--repo`/`GH_REPO=` value (`$(...)`,
#     backticks, `<(...)`, `$VAR`). Non-ackable refusal, exit 2, before any
#     network call.
# ===========================================================================
printf '\n--- unresolvable-scope merges (dynamic / bare-export repo scope) ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

new_case; invoke 'export GH_REPO && gh pr merge 2002 --rebase'
assert_exit "bare export GH_REPO with no prior assignment: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; invoke 'declare -x GH_REPO && gh pr merge 2002 --rebase'
assert_exit "bare declare -x GH_REPO with no prior assignment: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; invoke 'GH_REPO=$(calc) gh pr merge 2002 --rebase'
assert_exit "non-literal GH_REPO=\$(calc) prefix: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; invoke "gh pr merge 2002 -R '\$(calc)' --rebase"
assert_exit "non-literal -R '\$(calc)': refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

# Precedence control: a literal -R shadows a dynamic GH_REPO= prefix (gh's
# own precedence), so the winning scope is literal and the merge is NOT
# refused. Empty review fixture on develop so a non-refused merge exits 0
# (distinguishable from the exit-2 refusal).
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON=''
invoke 'GH_REPO=$(calc) gh pr merge 2002 -R other-x --rebase'
assert_stderr_lacks "literal -R shadows dynamic GH_REPO: no unresolvable refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and the fetch scopes to the literal -R repo" 'repos/other-x/issues/2002/comments'
assert_exit "…and exits 0 per the empty-review fixture (not 2)" 0
SHIM_REPO_EXIT=0; SHIM_REVIEW_JSON="$LGTM"

# ===========================================================================
# 2i. Fix-round pins — position-scoped split-sub prefix check, sibling
#     child-context export + merge refusal, declare +x assignment linkage,
#     and fold-in dynamic/process-substitution shapes (measured, bash 5.3,
#     `env -i`; reviewer-run inputs).
# ===========================================================================
printf '\n--- fix-round pins (split-sub scope, child-sibling export, +x linkage, fold-in shapes) ---\n'

SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON="$LGTM"

# Fix 1 (reviewer-run failing inputs): a `# ... GH_REPO=$(pick) for CI`
# comment or a quoted `--body 'see GH_REPO=$(x) docs'` argument beside a
# standalone `GH_REPO=$(pick);` must not flip the standalone bare assignment
# into a prefix assignment on `gh pr merge` (measured, bash 5.3, `env -i`:
# bare `GH_REPO=$(pick);` before `;` stays unexported, so the merge scopes
# to the cwd repo).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "$(printf '# export the repo dynamically: GH_REPO=$(pick) for CI\nGH_REPO=$(pick); gh pr merge 2002 --rebase')"
assert_stderr_lacks "comment mentioning GH_REPO=\$(pick) before a bare GH_REPO=\$(pick); does not refuse" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_exit "…and blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke "GH_REPO=\$(pick); gh pr merge 2002 --body 'see GH_REPO=\$(x) docs' --rebase"
assert_stderr_lacks "quoted --body mentioning GH_REPO=\$(x) after a bare GH_REPO=\$(pick); does not refuse" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_exit "…and blocks on the cwd repo's review" 2

# Fix 2 (reviewer-run failing inputs): an `export GH_REPO=...` and `gh pr merge`
# inside the SAME child construct (subshell `(...)` or backtick span) scopes
# the merge to that exported repo in bash (measured, bash 5.3, `env -i`), so
# ignoring the child export would silently gate the cwd repo while merging
# the other repo's PR. Refused as unresolvable.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '(export GH_REPO=other-x; gh pr merge 2002 --rebase)'
assert_exit "sibling export GH_REPO + gh pr merge inside one subshell: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '`export GH_REPO=other-x; gh pr merge 2002 --rebase`'
assert_exit "sibling export GH_REPO + gh pr merge inside one backtick span: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

# Known over-approximation (accepted direction): `(export GH_REPO=a);
# (gh pr merge N)` across two separate child constructs — where bash 5.3
# scopes nothing — also refuses, because `simple_commands_context`'s flat
# list does not distinguish construct boundaries; the escape (drop the
# parens or pass literal -R) costs one command.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '(export GH_REPO=other-x); (gh pr merge 2002 --rebase)'
assert_exit "child export followed by a separate child merge (accepted over-approximation): refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

# Fix 3 (reviewer-run failing input): `declare +x GH_REPO=other-x` clears
# the export attribute but still assigns the variable (measured, bash 5.3,
# `env -i`), so a later bare `export GH_REPO` promotes `other-x` and scopes
# the merge rather than hitting the unresolvable refusal.
new_case; SHIM_REPO_EXIT=1; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'declare +x GH_REPO=other-x && export GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "declare +x GH_REPO=other-x promoted by export GH_REPO: no unresolvable refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…and the fetch scopes to other-x" 'repos/other-x/issues/2002/comments'
assert_exit "…and blocks on other-x's review" 2
SHIM_REPO_EXIT=0

# Fold-in pins (review follow-up 1 + 5): `-R $VAR` refusal, unquoted
# backtick `-R` refusal, `<(...)`/`>(...)` -R refusal shapes, and
# `<(...)`/`>(...)` child-context export-ignore rows (measured, bash 5.3,
# `env -i`; verified live by the reviewer).
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 -R $VAR --rebase'
assert_exit "non-literal -R \$VAR: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 -R `calc` --rebase'
assert_exit "non-literal unquoted backtick -R \`calc\`: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# The SPACED value is the shape that carries a real value in bash: a GLUED
# `-R<(calc)` parses as the flag `-R` PLUS a stdin redirection, so gh gets no
# -R argument at all and the merge cannot run — nothing to pin there.
invoke 'gh pr merge 2002 -R $(calc) --rebase'
assert_exit "non-literal spaced -R \$(calc): refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# A process substitution as an ASSIGNMENT VALUE assigns a /dev/fd path —
# a literal string the hook cannot resolve a repository from, and a merge
# that would fail in gh anyway; refusing it early is the honest direction.
invoke 'GH_REPO=<(calc) gh pr merge 2002 --rebase'
assert_exit "non-literal proc-subst assignment value GH_REPO=<(calc): refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…no repos/ lookup in the api log" 'repos/'
assert_ack_lacks "…and no ack line written" '2002:777:2026-08-08T12:00:00Z'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '<(export GH_REPO=other-x) && gh pr merge 2002 --rebase'
assert_stderr_lacks "input process-substitution <(export GH_REPO=...) does not refuse a top-level merge" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…process-substitution <(export GH_REPO=...) dies with the child: fetch scopes to the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the process substitution's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke '>(export GH_REPO=other-x) && gh pr merge 2002 --rebase'
assert_stderr_lacks "output process-substitution >(export GH_REPO=...) does not refuse a top-level merge" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…process-substitution >(export GH_REPO=...) dies with the child: fetch scopes to the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…and the process substitution's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# The same glue artifact on a `cd`: a backtick-span interior's cd arrives as
# argv[0] = `cd, and the merge inside the substitution really does run from
# the moved directory — the scope-moved refusal applies to it.
invoke '`cd ../other-repo && gh pr merge 2002 --rebase`'
assert_exit "backtick-glued cd before a merge: refused" 2
assert_stderr_has "…with the scope-moved banner" 'MERGE SCOPE MOVED'
assert_no_fetch "…no fetch ran"

# --- un-export arms (unset / export -n) -------------------------------------
# bash 5.3 measured (`env -i`): `unset GH_REPO` removes the variable entirely
# (a later bare `export GH_REPO` exports nothing); `export -n GH_REPO`
# un-exports but the shell variable survives (a later bare `export GH_REPO`
# re-exports it). bash parses a GLUED `-R<(calc)` as the flag plus a stdin
# redirection — gh receives no -R value and the merge cannot run — so the
# value-shaped rows use spaced/quoted forms.

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export GH_REPO=other-x && unset GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "unset GH_REPO clears the captured scope: no unresolvable refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo (nothing exported)" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…other-x reaches no fetch" 'repos/other-x'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export GH_REPO=other-x && export -n GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "export -n GH_REPO un-exports: no unresolvable refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…other-x reaches no fetch" 'repos/other-x'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Accepted fail-safe over-approximation: after `unset GH_REPO` a bare
# `export GH_REPO` exports nothing, so bash would gate the merge unscoped —
# the hook refuses instead (the value-less-export arm cannot tell the
# variable was unset). Escape: drop the no-op export. Pinned as the
# documented direction.
invoke 'unset GH_REPO && export GH_REPO && gh pr merge 2002 --rebase'
assert_exit "export GH_REPO after unset: refused (accepted fail-safe)" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# `export -n GH_REPO=x` is not covered (ambiguous assign-and-unexport); the
# hook captures nothing, which matches bash (nothing reaches children).
invoke 'export -n GH_REPO=other-x && gh pr merge 2002 --rebase'
assert_stderr_lacks "export -n GH_REPO=x stays not-covered: no refusal, no capture" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…other-x reaches no fetch" 'repos/other-x'

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Fix 1a: `export GH_REPO=other-x | true; gh pr merge 2002 --rebase` runs each
# element of a multi-command pipeline in a subshell — the export does not
# reach the merge.
invoke 'export GH_REPO=other-x | true; gh pr merge 2002 --rebase'
assert_stderr_lacks "pipelined export GH_REPO=other-x | true does not capture into later merge" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…the pipeline's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Fix 1b: `export GH_REPO=other-x & gh pr merge 2002 --rebase` runs the
# `&`-terminated command in a background subshell — the export does not
# reach the foreground merge.
invoke 'export GH_REPO=other-x & gh pr merge 2002 --rebase'
assert_stderr_lacks "backgrounded export GH_REPO=other-x & does not capture into foreground merge" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…the backgrounded export's repo reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Fix 2: `declare +x GH_REPO` (bare, no value) un-exports GH_REPO while
# keeping the shell variable — mirrors `export -n GH_REPO`.
invoke 'export GH_REPO=other-x && declare +x GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "declare +x GH_REPO un-exports: no unresolvable refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_api_lacks "…other-x reaches no fetch" 'repos/other-x'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Fix 3: a child-context bare reassignment when GH_REPO is already exported
# (`export GH_REPO=other-a && (GH_REPO=other-b; gh pr merge 2002 --rebase)`)
# updates the exported value inside the subshell — the in-child merge refuses
# instead of gating the stale parent repo.
invoke 'export GH_REPO=other-a && (GH_REPO=other-b; gh pr merge 2002 --rebase)'
assert_exit "child bare GH_REPO= reassignment over exported GH_REPO with in-child merge: refused" 2
assert_stderr_has "…with the unresolvable-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_no_fetch "…no fetch ran"
assert_api_lacks "…neither parent nor child repo reaches a fetch" 'repos/'
assert_lacks_ack "…no ack written"

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
# Fix 4: `unset GH_REPO` and `export -n GH_REPO` clear `gh_repo_unresolvable`
# after a value-less `export GH_REPO` — bash exports nothing by merge time.
invoke 'export GH_REPO && unset GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "unset GH_REPO after bare export GH_REPO clears unresolvable: no refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'export GH_REPO && export -n GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "export -n GH_REPO after bare export GH_REPO clears unresolvable: no refusal" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the merge gates on the cwd repo" 'repos/acme-widgets/cli/issues/2002/comments'
assert_exit "…and the gate blocks on the cwd repo's review" 2

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"; SHIM_REPO_EXIT=1
# Fix 5: `unset -f GH_REPO` removes a shell function, not the variable — the
# exported GH_REPO scope stands.
invoke 'export GH_REPO=other-x && unset -f GH_REPO && gh pr merge 2002 --rebase'
assert_stderr_lacks "unset -f GH_REPO keeps the exported variable scope" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…other-x still scopes the fetch" 'repos/other-x/issues/2002/comments'
assert_exit "…and the gate blocks on other-x's review" 2
SHIM_REPO_EXIT=0

# --- backtick-glue strip on captured values ----------------------------------
# A backtick-span interior keeps its closing delimiter glued to the last
# word: `-R a/b` at the end of a span arrives as `a/b\``. The strip is
# parser-artifact correction — bash's own value has no backtick.

new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"; SHIM_REPO='other-x/repo-x'
# Backtick glue stripped from the -R value: a command-position span's last
# word arrives as `other-x/repo-x` (closing delimiter glued), and bash's own
# value has no backtick — the literal slug must scope the fetch.
invoke '`gh pr merge 2002 -R other-x/repo-x`'
assert_stderr_lacks "backtick glue is stripped from the -R value: no spurious dynamic-scope banner" 'MERGE SCOPE UNRESOLVABLE'
assert_api_has "…the literal slug scopes the fetch" 'repos/other-x/repo-x/issues/2002/comments'
assert_exit "…and the gate blocks on that repo's review" 2
# SHIM_REPO is a script-global the harness passes per case: restore the
# default so later cases resolve against acme-widgets/cli again.
SHIM_REPO='acme-widgets/cli'

# ===========================================================================
# 3. The review gate — block once per (PR, review-id), allow on retry
# ===========================================================================
printf '\n--- review gate: block, ack, retry ---\n'

SHIM_PR_BASE='develop'
new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase'
assert_exit "first call on a feature PR with a review: BLOCKS" 2
assert_stderr_has "block names the PR" 'PR MERGE GATE — latest claude[bot] review for PR #2002'
assert_stderr_has "block carries the review body" 'LGTM. No actionable findings.'
assert_stderr_has "block carries both timestamps (posted + updated)" 'Posted: 2026-08-08T12:00:00Z (updated 2026-08-08T12:00:00Z)'
assert_stderr_has "block warns against editing the ack state" 'Do NOT bypass this gate by editing the ack state'
assert_ack_has "ack holds PR:review-id:updated_at" '2002:777:2026-08-08T12:00:00Z'
# `stat -c` is GNU syntax, so on a platform without it the mode is unreadable.
# That FAILS rather than skips, deliberately: an assertion that did not run must
# never report as one that passed, and this one covers the permissions of a
# file the merge gate trusts. The failure is the probe's own gap, not the
# hook's — the message says so, because the two send a reader at different
# files.
MODE=$(stat -c '%a' "$ACK_FILE" 2>/dev/null || echo '')
if [ -z "$MODE" ]; then
  bad "PROBE GAP (not a hook defect): could not read the ack file's mode — GNU \`stat -c\` unavailable? Failing rather than passing an assertion that never ran"
elif [ "$MODE" = "600" ]; then
  ok "ack file is mode 600"
else
  bad "ack file mode is $MODE, expected 600"
fi
STATE_DIR_MODE=$(stat -c '%a' "$CASE_HOME/.local/state/seyag/pr-merge-review-check" 2>/dev/null || echo '')
if [ "$STATE_DIR_MODE" = "700" ]; then
  ok "ack state directory is mode 700"
else
  bad "ack state directory mode is '${STATE_DIR_MODE:-unreadable}', expected 700"
fi

invoke 'gh pr merge 2002 --rebase'
assert_exit "retry with the same review: ALLOWS" 0
assert_silent "retry is silent"

# Both halves of the ack key, varied independently. Same ack state throughout —
# that is the point: a key that dropped either half would let one of these
# through.
invoke 'gh pr merge 2003 --rebase'
assert_exit "different PR, same review-id: BLOCKS (PR half of the key)" 2
assert_pr "…and it fetched the other PR" 2003

# The fetch must reach the NEWEST review on a busy PR: this endpoint ignores
# sort/direction, so walking every page is the whole fix. The shim cannot
# model pagination, but the hook's REAL jq runs on the wrapped fixture — a
# dropped --paginate/--slurp or a broken pipe shows up as a missing review.
new_case; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase'
assert_api_has "…the review fetch walks every page (paginate + slurp)" '--paginate --slurp'
assert_pr "…and the piped jq still yields the newest matching comment" 2002

# Configurable reviewer identity: SYG_MERGE_REVIEW_LOGIN. The fetch filter
# and the banner carry the override; the fixture's comment is posted by the
# override login, so the row proves the FILTER threading too — with the
# default login wired in, the comment would be filtered out and no review
# would surface.
new_case; SHIM_PR_BASE='develop'
SHIM_REVIEW_JSON=$(review_json 777 'LGTM from the release bot.' '2026-08-08T12:00:00Z' 'release-bot[bot]')
LOGIN_OVERRIDE='release-bot[bot]'
invoke 'gh pr merge 2002 --rebase'
assert_stderr_has "…the banner names the configured login, not the default bot" 'latest release-bot[bot] review for PR #2002'
assert_stderr_has "…and the override login's review is the one surfaced" 'LGTM from the release bot.'
assert_exit "…and the gate still blocks" 2
LOGIN_OVERRIDE=''

SHIM_REVIEW_JSON=$(review_json 888 'Round 2: one finding.')
invoke 'gh pr merge 2002 --rebase'
assert_exit "same PR, NEW review-id: BLOCKS again (review half of the key)" 2
assert_stderr_has "…carrying the new review body" 'Round 2: one finding.'
assert_ack_has "ack now holds the new key too" '2002:888:2026-08-08T12:00:00Z'
assert_ack_has "…and still holds the old one" '2002:777:2026-08-08T12:00:00Z'

# The third half of the key. Sticky and edit-in-place review modes UPDATE one
# comment: the id stays, updated_at moves. Keying on the id alone read the
# edit as already acked and let the merge through carrying the OLD body.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase'
assert_exit "first call blocks" 2
invoke 'gh pr merge 2002 --rebase'
assert_exit "retry after ack: ALLOWS" 0
SHIM_REVIEW_JSON=$(review_json 777 'Edited in place: the finding is sharper now.' '2026-08-08T15:30:00Z')
invoke 'gh pr merge 2002 --rebase'
assert_exit "same PR, same review-id, EDITED comment (moved updated_at): BLOCKS again" 2
assert_stderr_has "…carrying the edited body" 'Edited in place: the finding is sharper now.'
assert_stderr_has "…and the moved updated timestamp beside the original" 'Posted: 2026-08-08T12:00:00Z (updated 2026-08-08T15:30:00Z)'
assert_ack_has "…ack holds the edited key" '2002:777:2026-08-08T15:30:00Z'
assert_ack_has "…and the pre-edit key" '2002:777:2026-08-08T12:00:00Z'

# Ack lookups are EXACT-line matches, and that is load-bearing rather than
# stylistic: relaxed to a substring match, a key that is a SUBSTRING of one
# already in the file reads as "already acked" and the merge proceeds with no
# review injected — the exact outcome this hook exists to prevent. The ack
# state accumulates across every PR the session touches, so a collision only
# needs two PR numbers where one is a suffix of the other: with the same
# review id and timestamp, the shorter key becomes a substring of the longer
# one, and only exact-line matching tells the two merges apart.
new_case; SHIM_PR_BASE='develop'; SHIM_REVIEW_JSON="$LGTM"
invoke 'gh pr merge 2002 --rebase'
assert_ack_has "ack holds the PR-2002 key" '2002:777:2026-08-08T12:00:00Z'
invoke 'gh pr merge 2 --rebase'
assert_exit "a PR whose key is a SUBSTRING of an acked key still BLOCKS" 2
assert_stderr_has "…and injects its own review" 'LGTM. No actionable findings.'
assert_ack_has "…and acks under its own key" '2:777:2026-08-08T12:00:00Z'

# Same property on the release key, which has its own lookup — now scoped by
# repo identity, so the same PR number in another repository cannot ack this
# one's reminder.
new_case; SHIM_PR_BASE='main'; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 20100 --rebase'
assert_ack_has "release key acked for the longer PR number" 'RELEASE:acme-widgets/cli:20100'
invoke 'gh pr merge 2010 --rebase'
assert_exit "release PR whose key is a prefix of an acked one: still BLOCKS" 2
assert_stderr_has "…and still gets the reminder" 'DEFAULT-BRANCH MERGE'

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

# Fail-open on an unreadable repo/default-branch, the same way.
new_case; SHIM_REPO_EXIT=1; SHIM_REVIEW_JSON=''
invoke 'gh pr merge 2010 --rebase'
assert_exit "gh repo view fails: no reminder, merge allowed" 0
assert_silent "unreadable default branch is silent, not a block"
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
# 11. Leak guard — the live ack state must be untouched
# ===========================================================================
printf '\n--- leak guard ---\n'

REAL_STATE_AFTER=$(md5sum "$REAL_STATE" 2>/dev/null | cut -d' ' -f1 || echo "absent")
if [ "$REAL_STATE_BEFORE" = "$REAL_STATE_AFTER" ]; then
  ok "the live ack state is unchanged ($REAL_STATE_BEFORE)"
else
  bad "the live ack state CHANGED ($REAL_STATE_BEFORE -> $REAL_STATE_AFTER) — the HOME redirect did not hold"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d probe(s) FAILED\n' "$FAILURES" >&2
  exit 1
fi
printf '\nAll probes passed\n'
