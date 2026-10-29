#!/bin/bash
# Fixture check for plugins/seyag/hooks/lib/commit_location.sh: sources the
# resolver in a set -uo pipefail subshell (the caller environment its header
# documents) against throwaway git fixtures under mktemp -d — no network, no
# real repositories. Pins the subtle paths: sibling detection with both
# require_top spellings, the dedupe of repeated locations, CL_MULTI on
# several distinct checkouts, CL_UNTRUSTED on a non-inert segment, and the
# non-resolving-location-counts-as-start logic.
# Usage: tests/commit-location.probe.sh   (from anywhere)

# shellcheck disable=SC1090  # the resolver is sourced REPO-relative by design; the path is dynamic
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CL="$REPO/plugins/seyag/hooks/lib/commit_location.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid

git init -q "$T/proj" && git -C "$T/proj" commit -q --allow-empty -m init
git -C "$T/proj" worktree add -q -b sib "$T/sib"
git init -q "$T/other" && git -C "$T/other" commit -q --allow-empty -m init
mkdir -p "$T/plain"

PROJ="$T/proj" SIB="$T/sib" OTHER="$T/other" PLAIN="$T/plain"
PROJ_COMMON=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
PROJ_TOP=$(git -C "$PROJ" rev-parse --show-toplevel)
SIB_TOP=$(git -C "$SIB" rev-parse --show-toplevel)

# Each check is a function whose body is a subshell: it sources the resolver
# under set -uo pipefail, runs the functions under test, and prints "pass" or
# a short got-it line.
start_falls_back_to_project_dir() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "" ""
  [ "$CL_START_DIR" = "$PROJ" ] || { echo "start=$CL_START_DIR"; return; }
  [ -z "$CL_START_FOREIGN" ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  echo pass
)

start_cwd_wins_over_project_dir() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$SIB" ""
  [ "$CL_START_DIR" = "$SIB" ] || { echo "start=$CL_START_DIR"; return; }
  echo pass
)

start_in_project_is_not_foreign() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  [ -z "$CL_START_FOREIGN" ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  [ "$CL_START_TOP" = "$PROJ_TOP" ] || { echo "top=$CL_START_TOP"; return; }
  echo pass
)

# require_top empty spelling: only a differing common dir makes the start
# foreign, so another repository qualifies ...
start_other_repo_is_foreign_without_require_top() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$OTHER" ""
  [ "$CL_START_FOREIGN" = 1 ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  echo pass
)

# ... but a directory inside the project's git dir (matching common dir, no
# toplevel) does not.
start_topless_matching_common_stays_local_without_require_top() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ/.git" ""
  [ -z "$CL_START_FOREIGN" ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  [ -z "$CL_START_TOP" ] || { echo "top=$CL_START_TOP"; return; }
  echo pass
)

# require_top set spelling: the same topless start counts as foreign.
start_topless_matching_common_is_foreign_with_require_top() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ/.git" "require-top"
  [ "$CL_START_FOREIGN" = 1 ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  echo pass
)

start_outside_any_repo_is_foreign() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PLAIN" ""
  [ "$CL_START_FOREIGN" = 1 ] || { echo "foreign=$CL_START_FOREIGN"; return; }
  [ -z "$CL_START_TOP" ] || { echo "top=$CL_START_TOP"; return; }
  echo pass
)

resolve_dedupes_repeated_locations() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "$PROJ"$'\t'"$PROJ/" ""
  [ -z "$CL_MULTI" ] || { echo "multi=$CL_MULTI"; return; }
  [ "$CL_REP" = "$PROJ" ] || { echo "rep=$CL_REP"; return; }
  [ -z "$CL_ACTION" ] || { echo "action=$CL_ACTION"; return; }
  echo pass
)

resolve_multi_on_several_distinct_checkouts() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "$PROJ"$'\t'"$OTHER" ""
  [ "$CL_MULTI" = 1 ] || { echo "multi=$CL_MULTI"; return; }
  echo pass
)

# A location that does not resolve to a toplevel counts as the start, so it
# neither widens the checkout set nor invents an action.
resolve_unresolvable_location_counts_as_start() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "<start>"$'\t'"/no/such/dir" ""
  [ -z "$CL_MULTI" ] || { echo "multi=$CL_MULTI"; return; }
  [ -z "$CL_ACTION" ] || { echo "action=$CL_ACTION"; return; }
  echo pass
)

resolve_sibling_trusted_when_inert() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "$SIB" 1
  [ "$CL_ACTION" = sibling ] || { echo "action=$CL_ACTION"; return; }
  [ -z "$CL_UNTRUSTED" ] || { echo "untrusted=$CL_UNTRUSTED"; return; }
  [ "$CL_SIBLING_TOP" = "$SIB_TOP" ] || { echo "sib=$CL_SIBLING_TOP"; return; }
  echo pass
)

# The same sibling with a non-inert segment: the branch could be moved by
# whatever the segment runs, so the verdict is untrusted.
resolve_sibling_untrusted_when_not_inert() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "$SIB" 0
  [ "$CL_ACTION" = sibling ] || { echo "action=$CL_ACTION"; return; }
  [ "$CL_UNTRUSTED" = 1 ] || { echo "untrusted=$CL_UNTRUSTED"; return; }
  echo pass
)

# A different repository: silent when every other segment is inert, and no
# verdict at all when one is not (the caller keeps the live evaluation).
resolve_foreign_repo_silent_only_when_inert() (
  set -uo pipefail
  source "$CL"
  commit_location_start "$PROJ_COMMON" "$PROJ" "$PROJ" ""
  commit_location_resolve "$OTHER" 1
  [ "$CL_ACTION" = silent ] || { echo "action=$CL_ACTION"; return; }
  commit_location_resolve "$OTHER" 0
  [ -z "$CL_ACTION" ] || { echo "action=$CL_ACTION"; return; }
  [ -z "$CL_UNTRUSTED" ] || { echo "untrusted=$CL_UNTRUSTED"; return; }
  echo pass
)

out=$(start_falls_back_to_project_dir 2>&1)
[ "$out" = pass ] && ok "start: empty cwd falls back to the project dir" || bad "start: empty cwd falls back to the project dir" "$out"
out=$(start_cwd_wins_over_project_dir 2>&1)
[ "$out" = pass ] && ok "start: shell cwd wins over the project dir" || bad "start: shell cwd wins over the project dir" "$out"
out=$(start_in_project_is_not_foreign 2>&1)
[ "$out" = pass ] && ok "start: in the project checkout is not foreign (control)" || bad "start: in the project checkout is not foreign (control)" "$out"
out=$(start_other_repo_is_foreign_without_require_top 2>&1)
[ "$out" = pass ] && ok "start: another repository is foreign with require_top empty" || bad "start: another repository is foreign with require_top empty" "$out"
out=$(start_topless_matching_common_stays_local_without_require_top 2>&1)
[ "$out" = pass ] && ok "start: topless start with matching common dir stays local without require_top" || bad "start: topless start with matching common dir stays local without require_top" "$out"
out=$(start_topless_matching_common_is_foreign_with_require_top 2>&1)
[ "$out" = pass ] && ok "start: topless start with matching common dir is foreign with require_top set" || bad "start: topless start with matching common dir is foreign with require_top set" "$out"
out=$(start_outside_any_repo_is_foreign 2>&1)
[ "$out" = pass ] && ok "start: outside any repository is foreign" || bad "start: outside any repository is foreign" "$out"
out=$(resolve_dedupes_repeated_locations 2>&1)
[ "$out" = pass ] && ok "resolve: repeated locations dedupe to one checkout" || bad "resolve: repeated locations dedupe to one checkout" "$out"
out=$(resolve_multi_on_several_distinct_checkouts 2>&1)
[ "$out" = pass ] && ok "resolve: several distinct checkouts set CL_MULTI" || bad "resolve: several distinct checkouts set CL_MULTI" "$out"
out=$(resolve_unresolvable_location_counts_as_start 2>&1)
[ "$out" = pass ] && ok "resolve: a non-resolving location counts as the start" || bad "resolve: a non-resolving location counts as the start" "$out"
out=$(resolve_sibling_trusted_when_inert 2>&1)
[ "$out" = pass ] && ok "resolve: sibling worktree, inert: sibling and trusted" || bad "resolve: sibling worktree, inert: sibling and trusted" "$out"
out=$(resolve_sibling_untrusted_when_not_inert 2>&1)
[ "$out" = pass ] && ok "resolve: sibling worktree, non-inert: CL_UNTRUSTED set" || bad "resolve: sibling worktree, non-inert: CL_UNTRUSTED set" "$out"
out=$(resolve_foreign_repo_silent_only_when_inert 2>&1)
[ "$out" = pass ] && ok "resolve: foreign repo silent only when inert" || bad "resolve: foreign repo silent only when inert" "$out"

exit $fail
