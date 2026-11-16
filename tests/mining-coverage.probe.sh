#!/bin/bash
# Fixture check for plugins/seyag/bin/mining-coverage: full coverage across reports passes; a hole at the start,
# middle or end is named with exit 1; an extract with no ledger line is a whole-file hole; a range
# past the end or an unlisted file exits 2.
# Usage: tests/mining-coverage.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MC="$REPO/plugins/seyag/bin/mining-coverage"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
seq 1 10 > "$tmp/a.txt"
seq 1 4 > "$tmp/b.txt"
printf '%s\n' "$tmp/a.txt" "$tmp/b.txt" > "$tmp/list"
cov() { printf 'findings\nCOVERED %s %s\n' "$1" "$2" >> "$3"; }
run() { out=$("$MC" --extracts "$tmp/list" "$@" 2>&1); rc=$?; }

cov "$tmp/a.txt" 1-6 "$tmp/r1"; cov "$tmp/a.txt" 5-10 "$tmp/r2"; cov "$tmp/b.txt" 1-4 "$tmp/r2"
run "$tmp/r1" "$tmp/r2"
[ $rc = 0 ] && grep -q '2 extracts, 0 holes' <<< "$out" && ok "full, overlapping coverage across reports passes" || bad "full: rc $rc $out"

cov "$tmp/a.txt" 3-4 "$tmp/r3"; cov "$tmp/a.txt" 7-8 "$tmp/r3"; cov "$tmp/b.txt" 1-4 "$tmp/r3"
run "$tmp/r3"
[ $rc = 1 ] && grep -qx "HOLE $tmp/a.txt 1-2" <<< "$out" && grep -qx "HOLE $tmp/a.txt 5-6" <<< "$out" && grep -qx "HOLE $tmp/a.txt 9-10" <<< "$out" \
  && ok "holes at the start, middle and end are each named, exit 1" || bad "holes: rc $rc $out"

cov "$tmp/a.txt" 1-10 "$tmp/r4"
run "$tmp/r4"
[ $rc = 1 ] && grep -qx "HOLE $tmp/b.txt 1-4" <<< "$out" && ok "an extract with no ledger line is a whole-file hole" || bad "no ledger: rc $rc $out"

cov "$tmp/a.txt" 1-11 "$tmp/r5"
run "$tmp/r5"
[ $rc = 2 ] && grep -q 'bad range 1-11' <<< "$out" && ok "a range past the end exits 2" || bad "past end: rc $rc $out"

cov "$tmp/other.txt" 1-1 "$tmp/r6"
run "$tmp/r6"
[ $rc = 2 ] && grep -q 'not in the list' <<< "$out" && ok "an unlisted file exits 2" || bad "unlisted: rc $rc $out"

: > "$tmp/empty-list"
out=$("$MC" --extracts "$tmp/empty-list" "$tmp/r1" 2>&1); rc=$?
[ $rc = 2 ] && grep -q 'names no extracts' <<< "$out" && ok "an empty list exits 2, never a vacuous pass" || bad "empty list: rc $rc $out"

exit $fail
