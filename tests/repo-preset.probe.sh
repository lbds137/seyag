#!/bin/bash
# Fixture check for plugins/seyag/bin/repo-preset — run after ANY edit to it.
#
# Never touches GitHub: a fake `gh` is put first on PATH. It serves repo-settings
# and branch-protection fixtures for the read calls and RECORDS every write
# call's argv to a log file, so the offline cases can pin not just exit codes
# but the exact flags `apply` sends — in particular that every boolean/null
# value goes out with -F (gh's magic type conversion) and never -f (which
# ships strings; the bug this probe pins against, 2026-10-01).
#
# `jq` is the real thing, not stubbed: it only parses the fixtures here,
# offline and deterministic, and a hand-rolled fake jq would test THIS probe's
# parser instead of the script's. The dependency-guard cases prove the
# script still demands both tools from a PATH that lacks one of them.
#
# Usage: tests/repo-preset.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="$SCRIPT_DIR/../plugins/seyag/bin/repo-preset"
[ -f "$BIN" ] || BIN="$SCRIPT_DIR/repo-preset"  # scratch-copy layout (probe + bin side by side)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"

# --- the gh shim ---------------------------------------------------------------
# Driven entirely by env vars the cases set:
#   FAKE_SETTINGS_FILE    stdout for `gh api repos/<owner/repo>`
#   FAKE_PROTECTION_FILE  stdout for `gh api repos/.../protection`;
#                         unset/empty -> exit 1 (the 404 shape: protection absent)
#   FAKE_PROTECTION_ERROR set -> the protection read fails with a NON-404
#                         error (the 500 shape: api error, not absence)
#   FAKE_GH_LOG           every write call's argv appended here, one line per call
#   FAKE_GH_FAIL_WRITE    set -> every write call is logged but FAILS (exit 1):
#                         the gh-write-failure shape
cat > "$FAKE_BIN/gh" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = api ]; then
  if [ "${2:-}" = "--method" ]; then
    printf '%s\n' "$*" >> "${FAKE_GH_LOG:?FAKE_GH_LOG unset}"
    if [ -n "${FAKE_GH_FAIL_WRITE:-}" ]; then
      echo "gh: api error (500) on write" >&2
      exit 1
    fi
    echo '{}'
    exit 0
  fi
  case "${2:-}" in
    */protection)
      if [ -n "${FAKE_PROTECTION_ERROR:-}" ]; then
        echo "gh: api error (500)" >&2
        exit 1
      fi
      if [ -n "${FAKE_PROTECTION_FILE:-}" ] && [ -s "$FAKE_PROTECTION_FILE" ]; then
        cat "$FAKE_PROTECTION_FILE"
        exit 0
      fi
      echo "gh: Not Found (404)" >&2
      exit 1 ;;
    *)
      cat "${FAKE_SETTINGS_FILE:?FAKE_SETTINGS_FILE unset}"
      exit 0 ;;
  esac
fi
echo "fake-gh: unhandled: $*" >&2
exit 1
SHIM
chmod +x "$FAKE_BIN/gh"

# minimal bin dirs for the dependency-guard cases: exactly one of the two tools
JQ_PATH=$(command -v jq)
MINBIN_NO_GH="$WORK/minbin-no-gh"; mkdir -p "$MINBIN_NO_GH"; ln -s "$JQ_PATH" "$MINBIN_NO_GH/jq"
MINBIN_NO_JQ="$WORK/minbin-no-jq"; mkdir -p "$MINBIN_NO_JQ"; ln -s "$FAKE_BIN/gh" "$MINBIN_NO_JQ/gh"

FAILURES=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# --- fixtures ------------------------------------------------------------------
FIXTURES="$WORK/fixtures"; mkdir -p "$FIXTURES"
# repo settings already matching the house preset
SETTINGS_MATCHING="$FIXTURES/settings-matching.json"
cat > "$SETTINGS_MATCHING" <<'JSON'
{"default_branch":"main","allow_rebase_merge":true,"allow_squash_merge":false,"allow_merge_commit":false,"allow_update_branch":true,"has_wiki":false}
JSON
# repo settings off-preset: squash merges on, wiki on
SETTINGS_DIFFERS="$FIXTURES/settings-differs.json"
cat > "$SETTINGS_DIFFERS" <<'JSON'
{"default_branch":"main","allow_rebase_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_update_branch":true,"has_wiki":true}
JSON
# protection matching the preset: everything minimal, no reviews, no checks.
# enforce_admins nests in the GET response ({"url":...,"enabled":<bool>}),
# unlike allow_force_pushes/allow_deletions which only wrap their flag in
# {"enabled":...} — the flat boolean these fixtures used to carry is a shape
# the API never returns (fixed 2026-10-01, CI review round 2).
PROTECTION_PRESET="$FIXTURES/protection-preset.json"
cat > "$PROTECTION_PRESET" <<'JSON'
{"url":"https://api.github.com/repos/example/one/branches/main/protection","enforce_admins":{"url":"https://api.github.com/repos/example/one/branches/main/protection/enforce_admins","enabled":false},"allow_force_pushes":{"url":"https://api.github.com/repos/example/one/branches/main/protection/allow_force_pushes","enabled":false},"allow_deletions":{"url":"https://api.github.com/repos/example/one/branches/main/protection/allow_deletions","enabled":false},"required_pull_request_reviews":null,"required_status_checks":null,"restrictions":null}
JSON
# protection carrying a required_status_checks object (non-strict repo)
PROTECTION_WITH_CHECKS="$FIXTURES/protection-with-checks.json"
cat > "$PROTECTION_WITH_CHECKS" <<'JSON'
{"url":"https://api.github.com/repos/example/one/branches/main/protection","enforce_admins":{"url":"https://api.github.com/repos/example/one/branches/main/protection/enforce_admins","enabled":false},"allow_force_pushes":{"url":"https://api.github.com/repos/example/one/branches/main/protection/allow_force_pushes","enabled":false},"allow_deletions":{"url":"https://api.github.com/repos/example/one/branches/main/protection/allow_deletions","enabled":false},"required_pull_request_reviews":null,"required_status_checks":{"url":"https://api.github.com/repos/example/one/branches/main/protection/required_status_checks","strict":false,"contexts":["ci"]},"restrictions":null}
JSON

# run <label> <expected-rc> [script args...] — with RUN_PATH overriding PATH
# (default: the fake bin first, the real tools behind it) and the FAKE_* vars
# handed through explicitly, since env -i clears everything else.
run() {
  local label="$1" expected_rc="$2"; shift 2
  OUT=$(timeout 15 env -i \
    PATH="${RUN_PATH:-$FAKE_BIN:$PATH}" HOME="$HOME" \
    FAKE_SETTINGS_FILE="${FAKE_SETTINGS_FILE:-}" \
    FAKE_PROTECTION_FILE="${FAKE_PROTECTION_FILE:-}" \
    FAKE_PROTECTION_ERROR="${FAKE_PROTECTION_ERROR:-}" \
    FAKE_GH_LOG="${FAKE_GH_LOG:-}" \
    FAKE_GH_FAIL_WRITE="${FAKE_GH_FAIL_WRITE:-}" \
    "$BIN" "$@" 2>&1)
  RC=$?
  if [ "$RC" -eq "$expected_rc" ]; then
    pass "$label (exit $RC)"
  else
    fail "$label (exit $RC, expected $expected_rc)"
    printf '%s\n' "$OUT" | sed 's/^/      /'
  fi
}

# --- 1-2. --help prints usage, exit 0 ------------------------------------------
run "--help exits 0" 0 --help
[[ "$OUT" == *"Usage:"* && "$OUT" == *"apply REPLACES the default branch's entire protection"* \
   && "$OUT" == *"--strict additionally requires the 'probes' check"* ]] \
  && pass "--help: usage names the replace warning and the --strict flag" \
  || fail "--help: usage names the replace warning and the --strict flag"

# --- 3-5. usage errors: no args, bad subcommand, non-slash repo -----------------
run "no args exits 1" 1
run "bad subcommand exits 1" 1 frobnicate o/r
run "non-slash repo arg dies" 1 show norepo
[[ "$OUT" == *"is not owner/repo"* ]] && pass "non-slash repo: message names the requirement" \
  || fail "non-slash repo: message names the requirement"

# --- 6-7. dependency guards -----------------------------------------------------
RUN_PATH="$MINBIN_NO_GH" run "PATH without gh -> 'gh required'" 1 show o/r
[[ "$OUT" == *"gh required"* ]] && pass "gh guard: message names the tool" \
  || fail "gh guard: message names the tool"
RUN_PATH="$MINBIN_NO_JQ" run "PATH without jq -> 'jq required'" 1 show o/r
[[ "$OUT" == *"jq required"* ]] && pass "jq guard: message names the tool" \
  || fail "jq guard: message names the tool"
unset RUN_PATH

# show_line <key-substring> — the single show-output line carrying <key-substring>
show_line() { printf '%s\n' "$OUT" | grep -F -- "$1"; }

# --- 8. show against a fully matching (protected) repo: every line ok -----------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  run "show, matching protected repo: exits 0" 0 show o/r
for key in allow_rebase_merge allow_squash_merge allow_merge_commit allow_update_branch has_wiki \
           "protection.allow_force_pushes" "protection.allow_deletions" "protection.enforce_admins" \
           "protection.required_pull_request_reviews" "protection.required_status_checks" \
           "protection.restrictions"; do
  L=$(show_line "$key")
  [[ "$L" == *" ok "* ]] && pass "show matching: $key reads ok" \
    || { fail "show matching: $key reads ok"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
done
CHECKS_L=$(show_line "protection.required_status_checks")
REVIEWS_L=$(show_line "protection.required_pull_request_reviews")
ENFORCE_L=$(show_line "protection.enforce_admins")
RESTRICT_L=$(show_line "protection.restrictions")
[[ "$CHECKS_L" == *"preset=absent"* && "$REVIEWS_L" == *"preset=absent"* \
   && "$ENFORCE_L" == *"preset=false"* && "$RESTRICT_L" == *"preset=absent"* ]] \
  && pass "show matching: new protection lines say preset=absent / enforce_admins=false" \
  || { fail "show matching: new protection lines say preset=absent / enforce_admins=false"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
[[ "$OUT" == *"default branch: main"* ]] && pass "show matching: names the default branch" \
  || fail "show matching: names the default branch"

# --- 9. show against an off-preset UNPROTECTED repo: differs where it should ----
FAKE_SETTINGS_FILE="$SETTINGS_DIFFERS" FAKE_PROTECTION_FILE='' \
  run "show, off-preset unprotected repo: exits 0" 0 show o/r
SQUASH_L=$(show_line "allow_squash_merge"); WIKI_L=$(show_line "has_wiki")
[[ "$SQUASH_L" == *"differs"* && "$WIKI_L" == *"differs"* ]] \
  && pass "show unprotected: squash and wiki read differs" \
  || fail "show unprotected: squash and wiki read differs"
CHECKS_L=$(show_line "protection.required_status_checks")
REVIEWS_L=$(show_line "protection.required_pull_request_reviews")
[[ "$CHECKS_L" == *" ok "* && "$CHECKS_L" == *"preset=absent"* ]] \
  && pass "show unprotected: absent protection still previews checks as absent" \
  || fail "show unprotected: absent protection still previews checks as absent"
[[ "$REVIEWS_L" == *" ok "* && "$REVIEWS_L" == *"preset=absent"* ]] \
  && pass "show unprotected: absent protection previews reviews as absent" \
  || fail "show unprotected: absent protection previews reviews as absent"
# no protection rule means force pushes and deletions are UNRESTRICTED — the two
# keys must NOT read ok against the preset's false (the inverted-signal bug the
# false-on-absent default used to ship, fixed 2026-10-01)
FP_L=$(show_line "protection.allow_force_pushes")
DEL_L=$(show_line "protection.allow_deletions")
[[ "$FP_L" == *"differs"* && "$DEL_L" == *"differs"* \
   && "$FP_L" != *" ok "* && "$DEL_L" != *" ok "* ]] \
  && pass "show unprotected: force_pushes and deletions read differs, never ok" \
  || { fail "show unprotected: force_pushes and deletions read differs, never ok"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
[[ "$OUT" == *"branch has NO protection rule — force pushes and deletions are unrestricted"* ]] \
  && pass "show unprotected: names the no-protection-rule state" \
  || { fail "show unprotected: names the no-protection-rule state"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
RESTRICT_L=$(show_line "protection.restrictions")
[[ "$RESTRICT_L" == *" ok "* && "$RESTRICT_L" == *"preset=absent"* ]] \
  && pass "show unprotected: restrictions previews as absent (no rule, no restriction)" \
  || fail "show unprotected: restrictions previews as absent (no rule, no restriction)"

# --- 10. show where a checks object already exists: differs, preset=absent ------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_WITH_CHECKS" \
  run "show, protected repo with existing checks: exits 0" 0 show o/r
CHECKS_L=$(show_line "protection.required_status_checks")
[[ "$CHECKS_L" == *"differs"* && "$CHECKS_L" == *"preset=absent"* ]] \
  && pass "show with-checks: required_status_checks reads differs vs absent" \
  || { fail "show with-checks: required_status_checks reads differs vs absent"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- 11. apply (preset): -F for every boolean/null in BOTH calls, never -f ------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  FAKE_GH_LOG="$WORK/apply.log" \
  run "apply, preset repo: exits 0" 0 apply o/r
[[ "$OUT" == *"applied: o/r now matches the house preset"* ]] \
  && pass "apply: success line names the repo" \
  || fail "apply: success line names the repo"
PATCH_LINE=$(grep -F -- '--method PATCH' "$WORK/apply.log")
PUT_LINE=$(grep -F -- '--method PUT' "$WORK/apply.log")
[ -n "$PATCH_LINE" ] && [ -n "$PUT_LINE" ] \
  && pass "apply: log holds one PATCH and one PUT call" \
  || fail "apply: log holds one PATCH and one PUT call"
[[ "$PATCH_LINE" == *'--method PATCH repos/o/r'* ]] \
  && pass "apply: PATCH targets repos/o/r" \
  || fail "apply: PATCH targets repos/o/r"
[[ "$PUT_LINE" == *'--method PUT repos/o/r/branches/main/protection'* ]] \
  && pass "apply: PUT targets the default branch's protection" \
  || fail "apply: PUT targets the default branch's protection"
for flag in '-F allow_rebase_merge=true' '-F allow_squash_merge=false' '-F allow_merge_commit=false' \
            '-F allow_update_branch=true' '-F has_wiki=false'; do
  [[ "$PATCH_LINE" == *"$flag"* ]] && pass "apply PATCH: $flag" \
    || fail "apply PATCH: $flag"
done
for flag in '-F required_status_checks=null' '-F required_pull_request_reviews=null' \
            '-F restrictions=null' '-F enforce_admins=false' \
            '-F allow_force_pushes=false' '-F allow_deletions=false'; do
  [[ "$PUT_LINE" == *"$flag"* ]] && pass "apply PUT: $flag" \
    || fail "apply PUT: $flag"
done
if grep -qE '(^| )-f( |$)' "$WORK/apply.log"; then
  fail "apply: no -f (raw string) flag appears anywhere in the recorded calls"
  grep -nE '(^| )-f( |$)' "$WORK/apply.log" | sed 's/^/      /'
else
  pass "apply: no -f (raw string) flag appears anywhere in the recorded calls"
fi

# --- 12. apply --strict: the probes check replaces the null ---------------------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  FAKE_GH_LOG="$WORK/apply-strict.log" \
  run "apply --strict: exits 0" 0 apply --strict o/r
STRICT_PUT=$(grep -F -- '--method PUT' "$WORK/apply-strict.log")
[[ "$STRICT_PUT" == *'-F required_status_checks[strict]=true'* ]] \
  && pass "apply --strict: PUT carries required_status_checks[strict]=true" \
  || fail "apply --strict: PUT carries required_status_checks[strict]=true"
[[ "$STRICT_PUT" == *'-F required_status_checks[contexts][]=probes'* ]] \
  && pass "apply --strict: PUT carries required_status_checks[contexts][]=probes" \
  || fail "apply --strict: PUT carries required_status_checks[contexts][]=probes"
grep -qF 'required_status_checks=null' "$WORK/apply-strict.log" \
  && fail "apply --strict: the null checks flag is gone" \
  || pass "apply --strict: the null checks flag is gone"
[[ "$OUT" == *"applied: o/r now matches the house preset"* && "$OUT" == *"strict:"*"probes"* ]] \
  && pass "apply --strict: success line notes the strict requirement" \
  || fail "apply --strict: success line notes the strict requirement"
if grep -qE '(^| )-f( |$)' "$WORK/apply-strict.log"; then
  fail "apply --strict: still no -f flag anywhere"
else
  pass "apply --strict: still no -f flag anywhere"
fi

# --- 13. a trailing --strict AFTER the repo arg is a usage error, not a drop ---
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  FAKE_GH_LOG="$WORK/trailing-strict.log" \
  run "apply o/r --strict (flag after repo): exits 1" 1 apply o/r --strict
[[ "$OUT" == *"--strict must come before <owner/repo>"* ]] \
  && pass "trailing --strict: error names the problem" \
  || { fail "trailing --strict: error names the problem"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
[ ! -s "$WORK/trailing-strict.log" ] \
  && pass "trailing --strict: NO gh write recorded" \
  || { fail "trailing --strict: NO gh write recorded"; sed 's/^/      /' "$WORK/trailing-strict.log"; }

# --- 14. --strict on show: the die path -----------------------------------------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  run "show --strict o/r: exits 1" 1 show --strict o/r
[[ "$OUT" == *"--strict applies only to apply"* ]] \
  && pass "show --strict: die message names the rule" \
  || { fail "show --strict: die message names the rule"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- 15. other argument shapes: stray positional, unknown flag, missing repo ----
run "stray extra positional: exits 1" 1 show o/r extra
[[ "$OUT" == *"expected exactly one <owner/repo> argument, got 2"* ]] \
  && pass "stray positional: error counts the args" \
  || { fail "stray positional: error counts the args"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
run "unknown flag: exits 1" 1 apply o/r --frobnicate
[[ "$OUT" == *"unknown option: --frobnicate"* ]] \
  && pass "unknown flag: error names the flag" \
  || { fail "unknown flag: error names the flag"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
run "subcommand without a repo: exits 1" 1 show
[[ "$OUT" == *"expected exactly one <owner/repo> argument, got 0"* ]] \
  && pass "missing repo: error counts the args" \
  || { fail "missing repo: error counts the args"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

# --- 16. gh write failure: nonzero exit + die message, no second write ----------
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_FILE="$PROTECTION_PRESET" \
  FAKE_GH_FAIL_WRITE=1 FAKE_GH_LOG="$WORK/write-fail.log" \
  run "apply with failing gh write: exits nonzero" 1 apply o/r
[[ "$OUT" == *"repo settings api call failed for o/r"* ]] \
  && pass "write failure: die message names the call and the repo" \
  || { fail "write failure: die message names the call and the repo"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
[ ! -e "$WORK/write-fail.log" ] \
  || { grep -q -- '--method PUT' "$WORK/write-fail.log" \
        && fail "write failure: the protection PUT must not run after the PATCH dies" \
        || pass "write failure: the protection PUT must not run after the PATCH dies"; }
grep -q -- '--method PATCH' "$WORK/write-fail.log" \
  && pass "write failure: the failing PATCH itself is still recorded" \
  || fail "write failure: the failing PATCH itself is still recorded"

# --- 17. protection read fails NON-404: unknown (api error), never a false negative
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_ERROR=1 \
  run "show, protection api error: exits 1" 1 show o/r
[[ "$OUT" == *"protection.allow_force_pushes"*"unknown (api error)"* \
   && "$OUT" == *"protection.required_status_checks"*"unknown (api error)"* ]] \
  && pass "protection api error: the protection keys read unknown (api error)" \
  || { fail "protection api error: the protection keys read unknown (api error)"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
[[ "$OUT" == *"could not read branch protection of o/r"* ]] \
  && pass "protection api error: the die line names the repo" \
  || { fail "protection api error: the die line names the repo"; printf '%s\n' "$OUT" | sed 's/^/      /'; }
# apply must not read protection at all: an erroring protection read cannot fail it
FAKE_SETTINGS_FILE="$SETTINGS_MATCHING" FAKE_PROTECTION_ERROR=1 \
  FAKE_GH_LOG="$WORK/no-protection-fetch.log" \
  run "apply ignores protection reads entirely: exits 0" 0 apply o/r
[[ "$OUT" == *"applied: o/r now matches the house preset"* ]] \
  && pass "apply: succeeds even when the protection read would error" \
  || { fail "apply: succeeds even when the protection read would error"; printf '%s\n' "$OUT" | sed 's/^/      /'; }

echo "---"
echo "$FAILURES failed"
[ "$FAILURES" -eq 0 ]
