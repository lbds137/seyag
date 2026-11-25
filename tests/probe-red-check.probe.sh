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
cat > "$FIX/tests/red2sp.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
out=$(bash "$D/tools/subject.sh")
[ "$out" = "new" ] && echo "ok:   subject fixed" || { echo "FAIL  subject printed: $out"; fail=1; }
exit $fail
PROBE
cat > "$FIX/tests/notfail.probe.sh" <<'PROBE'
#!/bin/bash
echo "  FAIL: indented colon form"
echo "FAILED not a fail line"
echo "FAIL one-space form"
exit 1
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

# RED with the two-space FAIL form ("FAIL  x", no colon; 32 probes print it).
out=$( (cd "$FIX" && bash "$TOOL" tests/red2sp.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && ok "RED two-space FAIL: exit 0" || bad "RED two-space exit $rc (out: $out)"
grep -qF "RED: tests/red2sp.probe.sh fails at main (rc 1, 1 FAIL lines)" <<<"$out" \
  && ok "RED two-space FAIL: summary line counts the line" || bad "RED two-space summary (out: $out)"
grep -qF "FAIL  subject printed: old" <<<"$out" \
  && ok "RED two-space FAIL: the FAIL line is echoed" || bad "RED two-space FAIL line (out: $out)"

# --expect matches a two-space FAIL line: exit 0.
out=$( (cd "$FIX" && bash "$TOOL" --expect 'subject printed' tests/red2sp.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -qF "probe-red-check: red confirmed (expected text found)" <<<"$out" \
  && ok "--expect on two-space FAIL line: exit 0" \
  || bad "--expect two-space match (rc $rc; out: $out)"

# --expect missing from the two-space FAIL line: exit 3 (WRONG REASON).
out=$( (cd "$FIX" && bash "$TOOL" --expect 'no such text' tests/red2sp.probe.sh main) 2>&1 ); rc=$?
[ $rc = 3 ] && grep -qF "WRONG REASON: tests/red2sp.probe.sh fails at main" <<<"$out" \
  && ok "--expect miss on two-space FAIL line: exit 3" \
  || bad "--expect miss two-space (rc $rc; out: $out)"

# Not FAIL lines: indented, FAILED, one space; rc 1 without a FAIL line is INCONCLUSIVE.
out=$( (cd "$FIX" && bash "$TOOL" tests/notfail.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "INCONCLUSIVE: tests/notfail.probe.sh" <<<"$out" \
  && ok "non-FAIL lines (indented, FAILED, one space): exit 2 INCONCLUSIVE" \
  || bad "non-FAIL lines (rc $rc; out: $out)"

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

# 1. --expect matching a FAIL line: exit 0, confirmation names expected text found.
out=$( (cd "$FIX" && bash "$TOOL" --expect 'subject printed: old' tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -qF "probe-red-check: red confirmed (expected text found)" <<<"$out" \
  && ok "--expect match: exit 0 and expected-text confirmation" \
  || bad "--expect match (rc $rc; out: $out)"

# 2. --expect missing from FAIL lines: exit 3, WRONG REASON summary and footer.
out=$( (cd "$FIX" && bash "$TOOL" --expect 'no such text' tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 3 ] \
  && grep -qF "WRONG REASON: tests/red.probe.sh fails at main" <<<"$out" \
  && grep -qF "probe-red-check: red for the wrong reason" <<<"$out" \
  && ok "--expect miss: exit 3, WRONG REASON summary and footer" \
  || bad "--expect miss (rc $rc; out: $out)"

# 3. --expect text present only on an ok: line does not count: exit 3.
cat > "$FIX/tests/okline.probe.sh" <<'PROBE'
#!/bin/bash
echo "ok:   marker-text here"
echo "FAIL: something else"
exit 1
PROBE
out=$( (cd "$FIX" && bash "$TOOL" --expect marker-text tests/okline.probe.sh main) 2>&1 ); rc=$?
[ $rc = 3 ] && grep -qF "probe-red-check: red for the wrong reason" <<<"$out" \
  && ok "--expect ignores ok: lines: exit 3" \
  || bad "--expect okline (rc $rc; out: $out)"

# 4. --expect on dies.probe.sh: exit 2, INCONCLUSIVE summary (TEXT not consulted).
out=$( (cd "$FIX" && bash "$TOOL" --expect anything tests/dies.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "INCONCLUSIVE: tests/dies.probe.sh died before any assertion" <<<"$out" \
  && ok "--expect on INCONCLUSIVE probe: exit 2, INCONCLUSIVE summary" \
  || bad "--expect dies (rc $rc; out: $out)"

# 5. Usage refusals, each exit 2.
out=$( (cd "$FIX" && bash "$TOOL" --expect '' tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "must not be empty" <<<"$out" && ok "usage refusal: --expect '' exits 2" || bad "--expect '' (rc $rc; out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --expect a --expect b tests/red.probe.sh main) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "given more than once" <<<"$out" && ok "usage refusal: --expect given twice exits 2" || bad "--expect twice (rc $rc; out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --base main tests/red.probe.sh) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "valid only with --both" <<<"$out" && ok "usage refusal: --base without --both exits 2" || bad "--base without --both (rc $rc; out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --both) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qF "requires at least one probe" <<<"$out" && ok "usage refusal: --both with no probe exits 2" || bad "--both no probe (rc $rc; out: $out)"

# 6. --help mentions --expect and --both.
out=$( (cd "$FIX" && bash "$TOOL" --help) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -q -- '--expect' <<<"$out" && grep -q -- '--both' <<<"$out" \
  && ok "--help mentions --expect and --both" \
  || bad "--help content (rc $rc; out: $out)"

# 7. --both on fix branch: red+green exits 1; red alone exits 0.
git -C "$FIX" checkout -q fix
both_rg_out=$( (cd "$FIX" && bash "$TOOL" --both --base main tests/red.probe.sh tests/green.probe.sh) 2>&1 ); rc=$?
[ $rc = 1 ] \
  && grep -qxF "tests/red.probe.sh: base main RED | here PASS" <<<"$both_rg_out" \
  && grep -q '^tests/green\.probe\.sh: base main NOT RED | here FAIL' <<<"$both_rg_out" \
  && ok "--both red+green on fix: exit 1 with RED|PASS and NOT RED|FAIL lines" \
  || bad "--both red+green (rc $rc; out: $both_rg_out)"
out=$( (cd "$FIX" && bash "$TOOL" --both --base main tests/red.probe.sh) 2>&1 ); rc=$?
[ $rc = 0 ] && grep -qxF "tests/red.probe.sh: base main RED | here PASS" <<<"$out" \
  && ok "--both red alone on fix: exit 0" \
  || bad "--both red alone (rc $rc; out: $out)"

# 8. --both --base main tests/dies.probe.sh on fix branch: base INCONCLUSIVE, here PASS, exit 2.
both_dies_out=$( (cd "$FIX" && bash "$TOOL" --both --base main tests/dies.probe.sh) 2>&1 ); rc=$?
[ $rc = 2 ] && grep -qxF "tests/dies.probe.sh: base main INCONCLUSIVE | here PASS" <<<"$both_dies_out" \
  && ok "--both dies on fix: base INCONCLUSIVE, here PASS, exit 2" \
  || bad "--both dies (rc $rc; out: $both_dies_out)"
git -C "$FIX" checkout -q main

# 9. Verdict parity: --both base verdict word equals single-mode verdict for red, green, dies.
s_red=$( (cd "$FIX" && bash "$TOOL" tests/red.probe.sh main) 2>&1 ); s_red=${s_red%%:*}
s_green=$( (cd "$FIX" && bash "$TOOL" tests/green.probe.sh main) 2>&1 ); s_green=${s_green%%:*}
s_dies=$( (cd "$FIX" && bash "$TOOL" tests/dies.probe.sh main) 2>&1 ); s_dies=${s_dies%%:*}
b_red=$(sed -n 's/^tests\/red\.probe\.sh: base main \(.*\) | here .*/\1/p' <<<"$both_rg_out")
b_green=$(sed -n 's/^tests\/green\.probe\.sh: base main \(.*\) | here .*/\1/p' <<<"$both_rg_out")
b_dies=$(sed -n 's/^tests\/dies\.probe\.sh: base main \(.*\) | here .*/\1/p' <<<"$both_dies_out")
[ "$b_red" = "RED" ] && [ "$b_red" = "$s_red" ] \
  && [ "$b_green" = "NOT RED" ] && [ "$b_green" = "$s_green" ] \
  && [ "$b_dies" = "INCONCLUSIVE" ] && [ "$b_dies" = "$s_dies" ] \
  && ok "verdict parity: --both base verdicts equal single-mode (RED / NOT RED / INCONCLUSIVE)" \
  || bad "verdict parity (single: $s_red/$s_green/$s_dies vs both: $b_red/$b_green/$b_dies)"

# 10. Isolation: fresh base worktree per probe in --both mode.
cat > "$FIX/tests/writer.probe.sh" <<'PROBE'
#!/bin/bash
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: > "$D/leftover"
echo "FAIL: wrote leftover"
exit 1
PROBE
cat > "$FIX/tests/reader.probe.sh" <<'PROBE'
#!/bin/bash
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -e "$D/leftover" ] && exit 0
echo "FAIL: no leftover"
exit 1
PROBE
out=$( (cd "$FIX" && bash "$TOOL" --both --base main tests/writer.probe.sh tests/reader.probe.sh) 2>&1 ); rc=$?
rm -f "$FIX/leftover"
grep -q '^tests/reader\.probe\.sh:.*base main RED' <<<"$out" \
  && ok "isolation: reader sees fresh base tree without writer leftover" \
  || bad "isolation (rc $rc; out: $out)"

# 11. After all --both cases, worktree list shows only the main checkout.
wtcount=$(git -C "$FIX" worktree list | grep -c . || true)
[ "$wtcount" = 1 ] && ok "--both cleanup: only the main checkout remains registered" \
  || bad "--both cleanup: worktree list has $wtcount entries: $(git -C "$FIX" worktree list)"

# 12. --both mode TERM cleans up worktree registration.
cd "$FIX" || exit 1
bash "$TOOL" --both --base main tests/slow.probe.sh >"$T/term-both.out" 2>&1 &
tpid=$!
sleep 1
kill -TERM "$tpid" 2>/dev/null
wait "$tpid"
trc=$?
cd "$SCRIPT_DIR" || exit 1
[ "$trc" = 143 ] && ok "--both TERM: exit 143" \
  || ok "--both TERM: exit $trc (tool finished first; case false-passes)"
wtcount=$(git -C "$FIX" worktree list | grep -c . || true)
[ "$wtcount" = 1 ] && ok "--both TERM: worktree registration cleaned" \
  || bad "--both TERM: worktree list has $wtcount entries: $(git -C "$FIX" worktree list)"

exit $fail
