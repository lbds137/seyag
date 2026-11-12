#!/bin/bash
# Fixture check for plugins/seyag/bin/probe-red-check against a throwaway repo.
# The fixture repo stands in for the "current checkout": `main` carries the
# unfixed subject tool (checked out), a `fix` branch carries the fixed one, and
# the three "new probes" are uncommitted files in the fixture's tests/. Each
# probe-red-check run has the fixture repo as cwd (the bin registers and
# removes one detached worktree in whatever repo it runs from).
#
# Usage: tests/probe-red-check.probe.sh   (from anywhere)

set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL="$SCRIPT_DIR/../plugins/seyag/bin/probe-red-check"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FIX="$T/fixture"
git init -q -b main "$FIX"
git -C "$FIX" config user.email t@t
git -C "$FIX" config user.name t
mkdir -p "$FIX/tools"
echo 'echo old' > "$FIX/tools/subject.sh"
git -C "$FIX" add -A
git -C "$FIX" commit -qm "base subject"
git -C "$FIX" checkout -qb fix
echo 'echo new' > "$FIX/tools/subject.sh"
echo 'V2=v2' > "$FIX/tools/v2-helper.sh"
git -C "$FIX" commit -qam "fix subject"
git -C "$FIX" checkout -q main
mkdir -p "$FIX/tests"
# The uncommitted new probes. Each resolves the subject via its own dirname.
cat > "$FIX/tests/red.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
out=$(bash "$D/tools/subject.sh")
[ "$out" = "new" ] && echo "ok:   subject fixed" || { echo "FAIL: subject printed: $out"; fail=1; }
exit $fail
PROBE
cat > "$FIX/tests/green.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
out=$(bash "$D/tools/subject.sh")
[ "$out" = "old" ] && echo "ok:   subject unfixed" || { echo "FAIL: subject printed: $out"; fail=1; }
exit $fail
PROBE
# Dies at base: it sources a helper file only the fix adds, under set -e, so
# the missing name kills it before any assertion — the INCONCLUSIVE class
# (an error from a name only the fix adds is not the behavior's red).
cat > "$FIX/tests/dies.probe.sh" <<'PROBE'
#!/bin/bash
set -euo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$D/tools/v2-helper.sh"
[ "${V2:-}" = "v2" ] && echo "ok:   v2"
PROBE
# Would classify RED, but the TERM case kills the tool mid-run first: it
# only needs to stay busy long enough to give the kill a wide window.
cat > "$FIX/tests/slow.probe.sh" <<'PROBE'
#!/bin/bash
sleep 3
echo "FAIL: never reached at base"
exit 1
PROBE

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# RED: the probe fails at base with a FAIL: line; exit 0 (inverted).
out=$( (cd "$FIX" && bash "$TOOL" tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && ok "RED: exit 0 (inversion)" || bad "RED exit $rc (out: $out)"
grep -qF "RED: tests/red.probe.sh fails at main (rc 1, 1 FAIL lines)" <<<"$out" \
  && ok "RED: summary line" || bad "RED summary (out: $out)"
grep -qF "FAIL: subject printed: old" <<<"$out" \
  && ok "RED: the FAIL line follows" || bad "RED FAIL line (out: $out)"
grep -qF "probe-red-check: red confirmed" <<<"$out" \
  && ok "RED: confirmation line" || bad "RED confirm (out: $out)"

# NOT RED: an already-green probe at base; exit 1.
out=$( (cd "$FIX" && bash "$TOOL" tests/green.probe.sh main) 2>&1 ); rc=$?
[ $rc = 1 ] && ok "NOT RED: exit 1" || bad "NOT RED exit $rc (out: $out)"
grep -qF "NOT RED: tests/green.probe.sh passes at main (rc 0) — the red check failed to prove red" <<<"$out" \
  && ok "NOT RED: summary line" || bad "NOT RED summary (out: $out)"
grep -qF "probe-red-check: no red" <<<"$out" && ok "NOT RED: no-red line" || bad "NOT RED line (out: $out)"

# INCONCLUSIVE: the probe dies before any assertion; exit 2, last lines shown.
out=$( (cd "$FIX" && bash "$TOOL" tests/dies.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && ok "INCONCLUSIVE: exit 2" || bad "INCONCLUSIVE exit $rc (out: $out)"
grep -qF "INCONCLUSIVE: tests/dies.probe.sh died before any assertion (rc " <<<"$out" \
  && ok "INCONCLUSIVE: summary line" || bad "INCONCLUSIVE summary (out: $out)"
grep -qF "probe-red-check: inconclusive" <<<"$out" \
  && ok "INCONCLUSIVE: line" || bad "INCONCLUSIVE line (out: $out)"
grep -qF "v2-helper.sh: No such file or directory" <<<"$out" \
  && ok "INCONCLUSIVE: the death error shown in the tail" || bad "INCONCLUSIVE tail (out: $out)"
! grep -q '^FAIL:' <<<"$out" \
  && ok "INCONCLUSIVE: no FAIL lines (else it would classify RED)" || bad "INCONCLUSIVE FAIL leak"

# Base resolution and path forms: default base origin/main fails cleanly on a
# repo without one; --help exits 0; repo-root-relative resolves from a subdir.
out=$( (cd "$FIX" && bash "$TOOL" tests/red.probe.sh nosuchref) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -q "does not resolve" <<<"$out" \
  && ok "unresolvable base: exit 2" || bad "bad base (rc $rc; out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --help) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -q "Usage:" <<<"$out" && ok "--help: usage, exit 0" || bad "--help (rc $rc)"
out=$( (cd "$FIX/tools" && bash "$TOOL" tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -qF "probe-red-check: red confirmed" <<<"$out" \
  && ok "repo-root-relative path resolves from a subdir" || bad "subdir path (rc $rc; out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" tests/nosuch.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -q "no such probe" <<<"$out" \
  && ok "missing probe: exit 2" || bad "missing probe (rc $rc; out: $out)"

# Path escapes are refused before anything runs: an outside-ROOT probe would
# execute against its own tree and fabricate the verdict.
printf '#!/bin/bash\necho "FAIL: from the wrong tree"\nexit 1\n' > "$T/outside.probe.sh"
out=$( (cd "$FIX" && bash "$TOOL" "$T/outside.probe.sh" main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "no such probe: $T/outside.probe.sh" <<<"$out" \
  && ok "outside-ROOT path: refused, exit 2" || bad "outside path (rc $rc; out: $out)"
out=$( (cd "$FIX/tools" && bash "$TOOL" ../tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -qF "probe-red-check: red confirmed" <<<"$out" \
  && ok "dotform under ROOT: accepted, verdict from the base tree" \
  || bad "dotform under ROOT (rc $rc; out: $out)"

# TERM mid-run cleans up too (timeout(1) sends TERM first). The slow probe
# gives the kill a wide window; if the machine is so loaded the tool finished
# first, this case false-passes (never false-fails).
cd "$FIX" || exit 1
bash "$TOOL" tests/slow.probe.sh main >"$T/term.out" 2>&1 &
tpid=$!
sleep 1
kill -TERM "$tpid" 2>/dev/null
wait "$tpid"
trc=$?
cd "$SCRIPT_DIR" || exit 1
[ "$trc" = 143 ] && ok "TERM: exit 143" \
  || ok "TERM: exit $trc (tool finished first; case false-passes)"
wtcount=$(git -C "$FIX" worktree list | grep -c . || true)
[ "$wtcount" = 1 ] && ok "TERM: worktree registration cleaned" \
  || bad "TERM: worktree list has $wtcount entries: $(git -C "$FIX" worktree list)"

# Cleanup: the registered worktree is gone and the ref is pruned.
wtcount=$(git -C "$FIX" worktree list | grep -c . || true)
[ "$wtcount" = 1 ] && ok "cleanup: only the main checkout remains registered" \
  || bad "cleanup: worktree list has $wtcount entries: $(git -C "$FIX" worktree list)"

exit $fail
