#!/bin/bash
# Hermetic fixture check for plugins/seyag/bin/mutation-canary against a throwaway git repo.
# Cases:
#  1. caught (probe asserts output old; mutation old->new) -> rc 0, new label echoed
#  2. survived (probe checks something else) -> rc 1
#  3. inconclusive (probe exits nonzero without a FAIL line under the mutation) -> rc 2
#  4. baseline red -> rc 2, subject never mutated, no journal
#  5. old absent -> rc 2, untouched, no journal
#  6. old non-unique (including overlapping aa in aaa) -> rc 2, untouched, no journal
#  7. old == new (and old empty) -> rc 2, untouched, no journal
#  8. symlink target -> rc 2, untouched, no journal
#  9. path outside repo -> rc 2, untouched, no journal
# 10. --old-file/--new-file with a multi-line old text ending in a newline -> caught, restored
# 11. --fail-pattern '^not ok' with a TAP-style probe -> caught
# 12. baseline label filtering (one FAIL: at baseline exit 0, a second under mutation) -> caught K=1
# 13. --no-baseline with a red-at-baseline probe -> no baseline line, verdict from mutant run
# 14. timeout: --timeout 1 with a mutant-only sleep 30 -> rc 2, restored, fast
# 15. TERM mid-run: kill -TERM tool PID once journal exists -> rc 143, restored, no journal, child gone
# 16. leftover journal: SIGKILL mid-probe -> new run refused rc 2; --restore -> rc 0; --restore again -> no journal rc 0
# 17. concurrent edit: probe rewrites subject -> rc 3, changed message, subject kept as probe wrote, .orig intact
# 18. patch mode: unified diff modification -> caught, restored; patch creating a new file -> refused rc 2
# 19. --help -> rc 0, usage on stdout; no args -> rc 2
# 20. --timeout 0 grandchild cleanup -> TERM mid-run exits 143, grandchild gone within 6 s, subject intact
# 21. mutant-only exit 137 with FAIL: line under default timeout -> CAUGHT, exit 0, no TIMEOUT line
# 22. NUL byte in probe output under mutation -> CAUGHT, exit 0
# 23. --restore with journal holding 0.path and 0.orig but no 0.mutant, subject mutated -> rc 3, left no mutant snapshot, subject still mutated, journal kept
# 24. --restore while journal pid is alive -> refused exit 2, another mutation-canary run is live
# 25. multi-file patch modifying tools/subject.sh and a second tracked file -> CAUGHT on second file, both files byte-identical
# 26. probe restores subject itself (git checkout) and exits 0 under mutation -> SURVIVED exit 1, no changed line
# 27. double signal during cleanup (stubborn probe ignores TERM, two TERMs 0.5 s apart) -> exit 143, restored, child gone
# 28. --timeout 08 -> rc 2, without leading zeros, subject intact
# 29. --timeout 1234567890 -> rc 2, without leading zeros, subject intact
# 30. apply-time recount (probe appends second old on first run) -> rc 2, occurs 2 times at apply time, journal gone, post-baseline subject kept
# 31. no-op patch (- and + of the same existing subject line) -> rc 2, did not change, subject intact, journal gone
# 32. manual --restore with fabricated journal where subject differs from both .orig and .mutant -> rc 3, subject left as is, journal kept
# 33. HUP mid-run: kill -HUP tool PID once journal exists -> rc 129, restored, no journal, child gone
# 34. --restore --force with journal holding 0.path and 0.orig but no 0.mutant, subject mutated -> rc 0, restored, no journal
# 35. --restore --force with fabricated journal where subject differs from both .orig and .mutant -> rc 0, restored, no journal
# 36. --force without --restore -> rc 2, subject intact
# 37. --restore with journal pid of a live non-mutation-canary process (sleep) -> rc 0, pid treated as stale, restored
# 38. --restore with journal dir holding 0.path, 0.orig, 0.mutant but no pid file -> rc 0 after >=900 ms retry window, restored
# 39. --restore with journal dir holding 0.path, 0.orig, 0.mutant and a live pid written during the retry window -> refused exit 2, subject still mutated, journal kept
# 40. default --fail-pattern with a two-space "FAIL  " probe line (tests/twosp.probe.sh) -> caught, exit 0, subject intact
# 41. the same probe with the opt-out --fail-pattern '^FAIL:' -> INCONCLUSIVE, exit 2, subject intact
# 42. mtime restore over a Makefile fixture -> restored src.txt is newer than out.txt (make -q exits 1), rebuild output holds no mutant token
# 43. mtime restore on the already-restored path: CMD rebuilds mutant output then restores the original with cp -p (stale mtime, bytes equal) -> make -q exits 1, rebuild holds the original token only
#
# Usage: tests/mutation-canary.probe.sh   (from anywhere)

set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL="$SCRIPT_DIR/../plugins/seyag/bin/mutation-canary"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FIX="$T/fixture"
git init -q -b main "$FIX"
git -C "$FIX" config user.email t@t
git -C "$FIX" config user.name t
mkdir -p "$FIX/tools" "$FIX/tests"

# Subject script: exec bit set (755), NO trailing newline, prints "old".
# Line 2 holds "aaa" for the overlapping non-unique check (case 6).
printf '#!/bin/bash\n# overlap-seed: aaa\nMSG=old\necho "$MSG"' >"$FIX/tools/subject.sh"
chmod 755 "$FIX/tools/subject.sh"
cp -p "$FIX/tools/subject.sh" "$T/subject.orig"
printf 'SECOND=before\n' >"$FIX/tools/second.txt"
cp -p "$FIX/tools/second.txt" "$T/second.orig"

git -C "$FIX" add -A
git -C "$FIX" commit -qm "base subject"

# --absolute-git-dir: a bare --git-dir prints the relative ".git", which would
# resolve against this probe's cwd and make every no-journal check vacuous.
JDIR="$(git -C "$FIX" rev-parse --absolute-git-dir)/mutation-canary"

cat >"$FIX/tests/caught.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  echo "ok:   subject prints old"
  exit 0
fi
echo "FAIL: subject printed $out instead of old"
exit 1
PROBE

cat >"$FIX/tests/survived.probe.sh" <<'PROBE'
#!/bin/bash
echo "ok:   unrelated check passes"
exit 0
PROBE

cat >"$FIX/tests/inconclusive.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  echo "ok:   baseline passes"
  exit 0
fi
echo "fatal: died before any assertion" >&2
exit 1
PROBE

cat >"$FIX/tests/base-red.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
echo "FAIL: already broken at baseline (subject=$out)"
exit 1
PROBE

cat >"$FIX/tests/tap.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  echo "ok 1 - subject output is old"
  exit 0
fi
echo "not ok 1 - subject output is $out"
exit 1
PROBE

cat >"$FIX/tests/twosp.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  echo "ok:   subject prints old"
  exit 0
fi
echo "FAIL  subject printed $out instead of old"
exit 1
PROBE

cat >"$FIX/tests/filter.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
echo "FAIL: pre-existing non-fatal noise"
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  exit 0
fi
echo "FAIL: new failure under mutation ($out)"
exit 1
PROBE

cat >"$FIX/tests/timeout.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  exit 0
fi
sleep 30
exit 1
PROBE

cat >"$FIX/tests/slow.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
sleep 30 &
spid=$!
if [ -n "${SLOW_CHILD_PID_FILE:-}" ]; then
  echo "$spid" >"$SLOW_CHILD_PID_FILE"
fi
wait "$spid"
echo "FAIL: slow probe finished"
exit 1
PROBE

cat >"$FIX/tests/meddle.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf 'rewritten by concurrent edit' >"$D/tools/subject.sh"
echo "FAIL: probe meddled with subject"
exit 1
PROBE

cat >"$FIX/tests/grandchild.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
bash -c 'sleep 30 & echo $! > "$GRANDCHILD_PID_FILE"; wait'
PROBE

cat >"$FIX/tests/exit137.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  exit 0
fi
echo "FAIL: died hard"
exit 137
PROBE

cat >"$FIX/tests/nul.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$D/tools/subject.sh")
if [ "$out" = "old" ]; then
  exit 0
fi
printf 'FAIL: nul\0here\n'
exit 1
PROBE

cat >"$FIX/tests/self-restore.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
git -C "$D" checkout -- tools/subject.sh
exit 0
PROBE

cat >"$FIX/tests/second.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -n "${SUBJECT_SNAPSHOT:-}" ] && cp "$D/tools/subject.sh" "$SUBJECT_SNAPSHOT"
if [ "$(cat "$D/tools/second.txt")" = "SECOND=before" ]; then
  echo "ok:   second unchanged"
  exit 0
fi
echo "FAIL: second changed"
exit 1
PROBE

cat >"$FIX/tests/stubborn.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
trap '' TERM
if [ -n "${STUBBORN_PID_FILE:-}" ]; then
  echo "$$" >"$STUBBORN_PID_FILE"
fi
sleep 20
exit 1
PROBE

cat >"$FIX/tests/recount.probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
D=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ -n "${RECOUNT_MARKER:-}" ] && [ ! -e "$RECOUNT_MARKER" ]; then
  : >"$RECOUNT_MARKER"
  printf '\nold\n' >>"$D/tools/subject.sh"
fi
exit 0
PROBE

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

check_intact() {
  local label=$1
  local mode
  mode=$(stat -c %a "$FIX/tools/subject.sh" 2>/dev/null || true)
  if cmp -s "$FIX/tools/subject.sh" "$T/subject.orig" && [ "$mode" = "755" ] && [ ! -e "$JDIR" ]; then
    ok "$label: subject byte-identical, mode 755, no journal"
  else
    bad "$label: intact check failed (mode=$mode, journal_exists=$([ -e "$JDIR" ] && echo y || echo n))"
  fi
}

# 1. caught
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "1. caught: exit 0" || bad "1. caught: exit $rc (out: $out)"
grep -qF "baseline: green" <<<"$out" && ok "1. caught: baseline green" || bad "1. caught: baseline line (out: $out)"
grep -qF "CAUGHT: bash tests/caught.probe.sh fails under the mutation (rc 1, 1 new failing lines)" <<<"$out" \
  && ok "1. caught: verdict line" || bad "1. caught: verdict line (out: $out)"
grep -qF "FAIL: subject printed new instead of old" <<<"$out" \
  && ok "1. caught: new label echoed" || bad "1. caught: label (out: $out)"
grep -qF "restore: byte-identical " <<<"$out" \
  && ok "1. caught: restore line" || bad "1. caught: restore line (out: $out)"
grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "1. caught: final line" || bad "1. caught: final line (out: $out)"
check_intact "1. caught"

# 2. survived
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/survived.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && ok "2. survived: exit 1" || bad "2. survived: exit $rc (out: $out)"
grep -qF "SURVIVED: bash tests/survived.probe.sh passes under the mutation; a vacuous canary: the mutated code is not on the path bash tests/survived.probe.sh runs, or no assertion covers it" <<<"$out" \
  && ok "2. survived: verdict line" || bad "2. survived: verdict line (out: $out)"
grep -q '^mutation-canary: survived$' <<<"$out" \
  && ok "2. survived: final line" || bad "2. survived: final line (out: $out)"
check_intact "2. survived"

# 3. inconclusive
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/inconclusive.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && ok "3. inconclusive: exit 2" || bad "3. inconclusive: exit $rc (out: $out)"
grep -qF "INCONCLUSIVE: bash tests/inconclusive.probe.sh failed (rc 1) with no new line matching ^FAIL(:|  ); it may have died before any assertion" <<<"$out" \
  && ok "3. inconclusive: verdict line" || bad "3. inconclusive: verdict line (out: $out)"
grep -qF "fatal: died before any assertion" <<<"$out" \
  && ok "3. inconclusive: tail shown" || bad "3. inconclusive: tail (out: $out)"
grep -q '^mutation-canary: inconclusive$' <<<"$out" \
  && ok "3. inconclusive: final line" || bad "3. inconclusive: final line (out: $out)"
check_intact "3. inconclusive"

# 4. baseline red
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/base-red.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && ok "4. baseline red: exit 2" || bad "4. baseline red: exit $rc (out: $out)"
grep -qF "BASELINE RED: bash tests/base-red.probe.sh fails unmutated (rc 1); a canary needs a green baseline" <<<"$out" \
  && ok "4. baseline red: verdict line" || bad "4. baseline red: verdict line (out: $out)"
grep -qF "FAIL: already broken at baseline (subject=old)" <<<"$out" \
  && ok "4. baseline red: tail shows unmutated subject" || bad "4. baseline red: tail (out: $out)"
! grep -qF "mutation-canary: journal" <<<"$out" \
  && ok "4. baseline red: no journal created" || bad "4. baseline red: journal created (out: $out)"
grep -q '^mutation-canary: baseline red$' <<<"$out" \
  && ok "4. baseline red: final line" || bad "4. baseline red: final line (out: $out)"
check_intact "4. baseline red"

# 5. old absent
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old nosuchtext --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "mutation-canary: old text not found in tools/subject.sh" <<<"$out" \
  && ok "5. old absent: refused exit 2" || bad "5. old absent: rc=$rc (out: $out)"
check_intact "5. old absent"

# 6. old non-unique (non-overlapping MSG and overlapping aa in aaa)
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old MSG --new NEWMSG -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "mutation-canary: old text occurs 2 times in tools/subject.sh; it must be unique" <<<"$out" \
  && ok "6a. old non-unique (non-overlapping): refused exit 2" || bad "6a. old non-unique: rc=$rc (out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old aa --new bb -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "mutation-canary: old text occurs 2 times in tools/subject.sh; it must be unique" <<<"$out" \
  && ok "6b. old non-unique (overlapping aa in aaa): refused exit 2" || bad "6b. overlapping non-unique: rc=$rc (out: $out)"
check_intact "6. old non-unique"

# 7. old == new (and old empty)
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new old -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "old text and new text are identical" <<<"$out" \
  && ok "7a. old == new: refused exit 2" || bad "7a. old == new: rc=$rc (out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old "" --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "old text must not be empty" <<<"$out" \
  && ok "7b. old empty: refused exit 2" || bad "7b. old empty: rc=$rc (out: $out)"
check_intact "7. old == new / empty"

# 8. symlink target
ln -s subject.sh "$FIX/tools/link.sh"
out=$( (cd "$FIX" && bash "$TOOL" --file tools/link.sh --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
rm -f "$FIX/tools/link.sh"
[ "$rc" -eq 2 ] && grep -qF "target is a symlink:" <<<"$out" \
  && ok "8. symlink target: refused exit 2" || bad "8. symlink target: rc=$rc (out: $out)"
check_intact "8. symlink target"

# 9. path outside repo
printf '#!/bin/bash\necho old' >"$T/outside.sh"
out=$( (cd "$FIX" && bash "$TOOL" --file "$T/outside.sh" --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "target path is outside the repository:" <<<"$out" \
  && ok "9. path outside repo: refused exit 2" || bad "9. path outside repo: rc=$rc (out: $out)"
check_intact "9. path outside repo"

# 10. --old-file/--new-file with a multi-line old text ending in a newline
printf '# overlap-seed: aaa\nMSG=old\n' >"$T/old-multi.txt"
printf '# overlap-seed: aaa\nMSG=new\n' >"$T/new-multi.txt"
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old-file "$T/old-multi.txt" --new-file "$T/new-multi.txt" -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "10. --old-file/--new-file multi-line with trailing newline: caught exit 0" \
  || bad "10. --old-file/--new-file: rc=$rc (out: $out)"
check_intact "10. --old-file/--new-file"

# 11. --fail-pattern '^not ok' with a TAP-style probe -> caught
out=$( (cd "$FIX" && bash "$TOOL" --fail-pattern '^not ok' --file tools/subject.sh --old old --new new -- bash tests/tap.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "CAUGHT: bash tests/tap.probe.sh fails under the mutation (rc 1, 1 new failing lines)" <<<"$out" \
  && grep -qF "not ok 1 - subject output is new" <<<"$out" \
  && ok "11. --fail-pattern '^not ok': caught exit 0" || bad "11. --fail-pattern: rc=$rc (out: $out)"
check_intact "11. --fail-pattern"

# 12. baseline label filtering: one FAIL: at baseline exit 0, a second under mutation -> caught with K=1
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/filter.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "CAUGHT: bash tests/filter.probe.sh fails under the mutation (rc 1, 1 new failing lines)" <<<"$out" \
  && grep -qF "FAIL: new failure under mutation (new)" <<<"$out" \
  && ! grep -qF "FAIL: pre-existing non-fatal noise" <<<"$out" \
  && ok "12. baseline label filtering: caught with K=1 and baseline FAIL excluded" \
  || bad "12. baseline label filtering: rc=$rc (out: $out)"
check_intact "12. baseline label filtering"

# 13. --no-baseline with a red-at-baseline probe -> no baseline line, verdict from mutant run
out=$( (cd "$FIX" && bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/base-red.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && ! grep -qE '^(baseline: |BASELINE RED)' <<<"$out" \
  && grep -qF "FAIL: already broken at baseline (subject=new)" <<<"$out" \
  && grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "13. --no-baseline: no baseline line, caught verdict from mutant run" \
  || bad "13. --no-baseline: rc=$rc (out: $out)"
check_intact "13. --no-baseline"

# 14. timeout: --timeout 1 with a mutant-only sleep 30 -> rc 2, mutation-canary: timeout, restored, well under 30 s
t0=$(date +%s)
out=$( (cd "$FIX" && bash "$TOOL" --timeout 1 --file tools/subject.sh --old old --new new -- bash tests/timeout.probe.sh) 2>&1 ); rc=$?
t1=$(date +%s)
elapsed=$((t1 - t0))
[ "$rc" -eq 2 ] \
  && grep -qF "TIMEOUT: bash tests/timeout.probe.sh did not finish within 1 s under the mutation" <<<"$out" \
  && grep -q '^mutation-canary: timeout$' <<<"$out" \
  && [ "$elapsed" -lt 15 ] \
  && ok "14. timeout: exit 2 in ${elapsed}s (<15s)" \
  || bad "14. timeout: rc=$rc elapsed=${elapsed}s (out: $out)"
check_intact "14. timeout"

# 15. TERM mid-run: start in background with slow probe, wait for journal, kill -TERM -> rc 143, restored, no journal, child gone
rm -f "$T/slow-child.pid"
(
  cd "$FIX" || exit 1
  SLOW_CHILD_PID_FILE="$T/slow-child.pid" exec bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/slow.probe.sh
) >"$T/term.out" 2>&1 &
tpid=$!
w=0
while [ "$w" -lt 100 ] && { [ ! -d "$JDIR" ] || [ ! -s "$T/slow-child.pid" ]; }; do
  sleep 0.05
  w=$((w + 1))
done
spid=$(cat "$T/slow-child.pid" 2>/dev/null || true)
t_kill0=$(date +%s%N)
kill -TERM "$tpid" 2>/dev/null
wait "$tpid"
trc=$?
t_kill1=$(date +%s%N)
kill_ms=$(( (t_kill1 - t_kill0) / 1000000 ))
[ "$trc" -eq 143 ] && [ "$kill_ms" -lt 3000 ] \
  && ok "15. TERM mid-run: exit 143 in ${kill_ms}ms (<3000ms)" \
  || bad "15. TERM mid-run: exit $trc in ${kill_ms}ms (out: $(cat "$T/term.out"))"
if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
  ok "15. TERM mid-run: probe child ($spid) gone"
else
  [ -n "$spid" ] && kill -KILL "$spid" 2>/dev/null || true
  bad "15. TERM mid-run: probe child (${spid:-none}) still alive"
fi
check_intact "15. TERM mid-run"

# 16. leftover journal: SIGKILL mid-probe -> new run rc 2 with --restore message; --restore -> rc 0; --restore again -> no journal rc 0
rm -f "$T/slow-child.pid"
(
  cd "$FIX" || exit 1
  SLOW_CHILD_PID_FILE="$T/slow-child.pid" exec bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/slow.probe.sh
) >"$T/kill.out" 2>&1 &
kpid=$!
w=0
while [ "$w" -lt 100 ] && { [ ! -d "$JDIR" ] || [ ! -s "$T/slow-child.pid" ]; }; do
  sleep 0.05
  w=$((w + 1))
done
spid=$(cat "$T/slow-child.pid" 2>/dev/null || true)
kill -KILL "$kpid" 2>/dev/null
wait "$kpid" 2>/dev/null
[ -n "$spid" ] && kill -KILL "$spid" 2>/dev/null || true
[ -d "$JDIR" ] && ok "16a. leftover journal exists after SIGKILL" || bad "16a. journal missing after SIGKILL"
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "run mutation-canary --restore" <<<"$out" \
  && ok "16b. new run with leftover journal: refused exit 2 with --restore message" \
  || bad "16b. leftover journal refusal: rc=$rc (out: $out)"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "restore: byte-identical " <<<"$out" \
  && grep -q '^mutation-canary: restored$' <<<"$out" \
  && ok "16c. --restore: exit 0, restored" \
  || bad "16c. --restore: rc=$rc (out: $out)"
check_intact "16c. --restore"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && grep -q '^mutation-canary: no journal; nothing to restore$' <<<"$out" \
  && ok "16d. --restore again: no journal, exit 0" \
  || bad "16d. second --restore: rc=$rc (out: $out)"

# 17. concurrent edit: probe rewrites subject -> rc 3, changed message, subject left as probe wrote it, journal kept with .orig byte-identical
out=$( (cd "$FIX" && bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/meddle.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && ok "17. concurrent edit: exit 3" || bad "17. concurrent edit: exit $rc (out: $out)"
grep -qF "changed during the run; not restored; original kept at" <<<"$out" \
  && ok "17. concurrent edit: changed message printed" \
  || bad "17. concurrent edit: changed message missing (out: $out)"
grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "17. concurrent edit: verdict lines still printed" \
  || bad "17. concurrent edit: verdict lines missing (out: $out)"
[ "$(cat "$FIX/tools/subject.sh")" = "rewritten by concurrent edit" ] \
  && ok "17. concurrent edit: subject left as the probe wrote it" \
  || bad "17. concurrent edit: subject was overwritten"
[ -f "$JDIR/0.orig" ] && cmp -s "$JDIR/0.orig" "$T/subject.orig" \
  && ok "17. concurrent edit: journal kept with .orig byte-identical to original" \
  || bad "17. concurrent edit: journal .orig missing or mismatched"
# Clean up the meddled state via cp + --restore
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
(cd "$FIX" && bash "$TOOL" --restore) >/dev/null 2>&1
check_intact "17. post-cleanup"

# 18. patch mode: unified diff modification -> caught, restored; patch creating a new file -> refused rc 2
sed 's/MSG=old/MSG=new/' "$FIX/tools/subject.sh" >"$T/subject.mut"
cp "$T/subject.mut" "$FIX/tools/subject.sh"
git -C "$FIX" diff >"$T/mod.patch"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --patch "$T/mod.patch" -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "CAUGHT: bash tests/caught.probe.sh fails under the mutation (rc 1, 1 new failing lines)" <<<"$out" \
  && grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "18a. patch mode modification: caught exit 0" \
  || bad "18a. patch mode modification: rc=$rc (out: $out)"
check_intact "18a. patch mode modification"

printf '#!/bin/bash\necho extra\n' >"$FIX/tools/added.sh"
git -C "$FIX" add -N tools/added.sh
git -C "$FIX" diff >"$T/create.patch"
git -C "$FIX" reset -q
rm -f "$FIX/tools/added.sh"
out=$( (cd "$FIX" && bash "$TOOL" --patch "$T/create.patch" -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$FIX/tools/added.sh" ] && grep -qF "patch must only modify existing files in place" <<<"$out" \
  && ok "18b. patch creating a new file: refused exit 2" \
  || bad "18b. patch creating new file: rc=$rc (out: $out)"
check_intact "18b. patch creating new file"

# 19. --help -> rc 0, usage on stdout; no args -> rc 2
out=$(cd "$FIX" && bash "$TOOL" --help 2>"$T/help.err"); rc=$?
[ "$rc" -eq 0 ] && grep -q "Usage:" <<<"$out" && [ ! -s "$T/help.err" ] \
  && ok "19a. --help: usage on stdout, exit 0" \
  || bad "19a. --help: rc=$rc err=$(cat "$T/help.err") out=$out"
out=$( (cd "$FIX" && bash "$TOOL") 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "Usage:" <<<"$out" \
  && ok "19b. no args: usage on stderr, exit 2" \
  || bad "19b. no args: rc=$rc (out: $out)"

# 20. --timeout 0 grandchild cleanup
rm -f "$T/grandchild.pid"
(
  cd "$FIX" || exit 1
  GRANDCHILD_PID_FILE="$T/grandchild.pid" exec bash "$TOOL" --timeout 0 --no-baseline --file tools/subject.sh --old old --new new -- bash tests/grandchild.probe.sh
) >"$T/gc.out" 2>&1 &
tpid=$!
w=0
while [ "$w" -lt 100 ] && { [ ! -d "$JDIR" ] || [ ! -s "$T/grandchild.pid" ]; }; do
  sleep 0.05
  w=$((w + 1))
done
gcpid=$(cat "$T/grandchild.pid" 2>/dev/null || true)
kill -TERM "$tpid" 2>/dev/null
wait "$tpid"
trc=$?
[ "$trc" -eq 143 ] && ok "20. --timeout 0 TERM: exit 143" || bad "20. --timeout 0 TERM: exit $trc (out: $(cat "$T/gc.out"))"
gw=0
while [ "$gw" -lt 120 ] && [ -n "$gcpid" ] && kill -0 "$gcpid" 2>/dev/null; do
  sleep 0.05
  gw=$((gw + 1))
done
if [ -n "$gcpid" ] && ! kill -0 "$gcpid" 2>/dev/null; then
  ok "20. --timeout 0 TERM: grandchild ($gcpid) gone"
else
  [ -n "$gcpid" ] && kill -KILL "$gcpid" 2>/dev/null || true
  bad "20. --timeout 0 TERM: grandchild (${gcpid:-none}) still alive"
fi
check_intact "20. --timeout 0 TERM"

# 21. mutant-only probe printing FAIL: died hard and exiting 137 within a second under default timeout -> CAUGHT, exit 0, no TIMEOUT
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/exit137.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "CAUGHT: bash tests/exit137.probe.sh fails under the mutation (rc 137, 1 new failing lines)" <<<"$out" \
  && grep -qF "FAIL: died hard" <<<"$out" \
  && ! grep -q "TIMEOUT" <<<"$out" \
  && grep -q '^mutation-canary: caught$' <<<"$out" \
  && ok "21. exit 137 with FAIL line: CAUGHT exit 0, no TIMEOUT" \
  || bad "21. exit 137: rc=$rc (out: $out)"
check_intact "21. exit 137"

# 22. NUL in output: under mutation probe prints FAIL: nul\0here\n and exits 1 -> CAUGHT, exit 0
(cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/nul.probe.sh) >"$T/nul.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] \
  && grep -a -qF "CAUGHT: bash tests/nul.probe.sh fails under the mutation (rc 1, 1 new failing lines)" "$T/nul.out" \
  && grep -a -q '^mutation-canary: caught$' "$T/nul.out" \
  && ok "22. NUL in output: CAUGHT exit 0" \
  || bad "22. NUL in output: rc=$rc (out: $(tr -d '\0' <"$T/nul.out"))"
check_intact "22. NUL in output"

# 23. --restore with journal holding 0.path and 0.orig but no 0.mutant, subject mutated -> exit 3, left no mutant snapshot, subject still mutated, journal kept
SUBJECT_CANON=$(realpath -- "$FIX/tools/subject.sh")
mkdir -p "$JDIR"
printf '99999999\n' >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
printf 'new' >"$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
[ "$rc" -eq 3 ] \
  && grep -qF "left no mutant snapshot" <<<"$out" \
  && [ "$(cat "$FIX/tools/subject.sh")" = "new" ] \
  && [ -d "$JDIR" ] && [ -f "$JDIR/0.orig" ] && cmp -s "$JDIR/0.orig" "$T/subject.orig" \
  && ok "23. --restore without 0.mutant: exit 3, subject still mutated, journal kept" \
  || bad "23. --restore without 0.mutant: rc=$rc (out: $out)"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
rm -f "$JDIR/pid" "$JDIR/0.path" "$JDIR/0.orig"
rmdir "$JDIR" 2>/dev/null || true
check_intact "23. --restore without 0.mutant"

# 24. --restore while journal pid is alive -> exit 2 and another mutation-canary run is live
( exec -a mutation-canary sleep 30 ) &
live_pid=$!
mkdir -p "$JDIR"
printf '%s\n' "$live_pid" >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$T/subject.mut"
cp "$T/subject.mut" "$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
kill -KILL "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
[ "$rc" -eq 2 ] \
  && grep -qF "another mutation-canary run is live" <<<"$out" \
  && cmp -s "$FIX/tools/subject.sh" "$T/subject.mut" \
  && ok "24. --restore while journal pid alive: refused exit 2, subject still mutated" \
  || bad "24. --restore while journal pid alive: rc=$rc (out: $out)"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
rm -f "$JDIR/pid" "$JDIR/0.path" "$JDIR/0.orig"
rmdir "$JDIR" 2>/dev/null || true
check_intact "24. --restore while journal pid alive"

# 25. multi-file patch modifying tools/subject.sh and a second tracked file -> CAUGHT on second file, both files byte-identical
sed 's/# overlap-seed: aaa/# overlap-seed: aaa (patched)/' "$T/subject.orig" >"$T/subject.comment"
cp "$T/subject.comment" "$FIX/tools/subject.sh"
printf 'SECOND=after\n' >"$FIX/tools/second.txt"
git -C "$FIX" diff >"$T/multi.patch"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
cp -p "$T/second.orig" "$FIX/tools/second.txt"
out=$( (cd "$FIX" && SUBJECT_SNAPSHOT="$T/subject.seen" bash "$TOOL" --patch "$T/multi.patch" -- bash tests/second.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "FAIL: second changed" <<<"$out" \
  && grep -qF "# overlap-seed: aaa (patched)" "$T/subject.seen" \
  && grep -q '^mutation-canary: caught$' <<<"$out" \
  && cmp -s "$FIX/tools/second.txt" "$T/second.orig" \
  && ok "25. multi-file patch: CAUGHT exit 0 on second file, both files byte-identical" \
  || bad "25. multi-file patch: rc=$rc (out: $out)"
check_intact "25. multi-file patch"

# 26. probe restores subject itself (git checkout) and exits 0 under mutation -> SURVIVED exit 1 (not 3), no changed line
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/self-restore.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 1 ] \
  && grep -q '^mutation-canary: survived$' <<<"$out" \
  && ! grep -qF "changed during the run" <<<"$out" \
  && ok "26. self-restoring probe: SURVIVED exit 1 (not 3), no changed line" \
  || bad "26. self-restoring probe: rc=$rc (out: $out)"
check_intact "26. self-restoring probe"

# 27. double signal during cleanup: stubborn probe ignores TERM, tool gets TERM twice 0.5 s apart -> exit 143, restored, stubborn pid gone
rm -f "$T/stubborn.pid"
(
  cd "$FIX" || exit 1
  STUBBORN_PID_FILE="$T/stubborn.pid" exec bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/stubborn.probe.sh
) >"$T/stubborn.out" 2>&1 &
tpid=$!
w=0
while [ "$w" -lt 100 ] && { [ ! -d "$JDIR" ] || [ ! -s "$T/stubborn.pid" ]; }; do
  sleep 0.05
  w=$((w + 1))
done
stpid=$(cat "$T/stubborn.pid" 2>/dev/null || true)
kill -TERM "$tpid" 2>/dev/null
sleep 0.5
kill -TERM "$tpid" 2>/dev/null
wait "$tpid"
trc=$?
[ "$trc" -eq 143 ] && ok "27. double TERM during cleanup: exit 143" \
  || bad "27. double TERM during cleanup: exit $trc (out: $(cat "$T/stubborn.out"))"
if [ -n "$stpid" ] && ! kill -0 "$stpid" 2>/dev/null; then
  ok "27. double TERM during cleanup: stubborn probe ($stpid) gone"
else
  [ -n "$stpid" ] && kill -KILL "$stpid" 2>/dev/null || true
  bad "27. double TERM during cleanup: stubborn probe (${stpid:-none}) still alive"
fi
check_intact "27. double TERM during cleanup"

# 28. --timeout 08 -> rc 2, output contains without leading zeros, subject intact
out=$( (cd "$FIX" && bash "$TOOL" --timeout 08 --file tools/subject.sh --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "without leading zeros" <<<"$out" \
  && ok "28. --timeout 08: refused exit 2" \
  || bad "28. --timeout 08: rc=$rc (out: $out)"
check_intact "28. --timeout 08"

# 29. --timeout 1234567890 -> rc 2, same message, subject intact
out=$( (cd "$FIX" && bash "$TOOL" --timeout 1234567890 --file tools/subject.sh --old old --new new -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "without leading zeros" <<<"$out" \
  && ok "29. --timeout 1234567890: refused exit 2" \
  || bad "29. --timeout 1234567890: rc=$rc (out: $out)"
check_intact "29. --timeout 1234567890"

# 30. apply-time recount: probe appends a second line old to tools/subject.sh on its first run only and exits 0 -> rc 2, occurs 2 times at apply time, journal gone, post-baseline content preserved
rm -f "$T/recount.ran"
cp -p "$T/subject.orig" "$T/subject.post-baseline"
printf '\nold\n' >>"$T/subject.post-baseline"
out=$( (cd "$FIX" && RECOUNT_MARKER="$T/recount.ran" bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/recount.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && grep -qF "occurs 2 times" <<<"$out" \
  && grep -qF "at apply time" <<<"$out" \
  && [ ! -e "$JDIR" ] \
  && cmp -s "$FIX/tools/subject.sh" "$T/subject.post-baseline" \
  && ! cmp -s "$FIX/tools/subject.sh" "$T/subject.orig" \
  && ok "30. apply-time recount: exit 2, journal gone, post-baseline subject preserved" \
  || bad "30. apply-time recount: rc=$rc (out: $out)"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
check_intact "30. apply-time recount"

# 31. no-op patch (- and + of the same existing subject line) -> rc 2, output contains did not change, subject intact, journal gone
sed 's/^+MSG=new$/+MSG=old/' "$T/mod.patch" >"$T/noop.patch"
out=$( (cd "$FIX" && bash "$TOOL" --patch "$T/noop.patch" -- bash tests/caught.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "did not change" <<<"$out" \
  && ok "31. no-op patch: refused exit 2 with did not change" \
  || bad "31. no-op patch: rc=$rc (out: $out)"
check_intact "31. no-op patch"

# 32. manual --restore with a fabricated journal (0.path, 0.orig, 0.mutant, pid 99999999) where the subject differs from both -> rc 3, subject left as is, journal kept
mkdir -p "$JDIR"
printf '99999999\n' >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$JDIR/0.mutant"
printf 'drifted from both orig and mutant' >"$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
[ "$rc" -eq 3 ] \
  && grep -qF "changed during the run; not restored; original kept at" <<<"$out" \
  && [ "$(cat "$FIX/tools/subject.sh")" = "drifted from both orig and mutant" ] \
  && [ -d "$JDIR" ] && [ -f "$JDIR/0.orig" ] && cmp -s "$JDIR/0.orig" "$T/subject.orig" \
  && ok "32. manual --restore with drifted subject: exit 3, subject left as is, journal kept" \
  || bad "32. manual --restore with drifted subject: rc=$rc (out: $out)"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
rm -f "$JDIR/pid" "$JDIR/0.path" "$JDIR/0.orig" "$JDIR/0.mutant"
rmdir "$JDIR" 2>/dev/null || true
check_intact "32. manual --restore with drifted subject"

# 33. HUP mid-run: start in background with slow probe, wait for journal, kill -HUP -> rc 129, restored, no journal, child gone
rm -f "$T/slow-child.pid"
(
  cd "$FIX" || exit 1
  SLOW_CHILD_PID_FILE="$T/slow-child.pid" exec bash "$TOOL" --no-baseline --file tools/subject.sh --old old --new new -- bash tests/slow.probe.sh
) >"$T/hup.out" 2>&1 &
hpid=$!
w=0
while [ "$w" -lt 100 ] && { [ ! -d "$JDIR" ] || [ ! -s "$T/slow-child.pid" ]; }; do
  sleep 0.05
  w=$((w + 1))
done
spid=$(cat "$T/slow-child.pid" 2>/dev/null || true)
t_kill0=$(date +%s%N)
kill -HUP "$hpid" 2>/dev/null
wait "$hpid"
hrc=$?
t_kill1=$(date +%s%N)
kill_ms=$(( (t_kill1 - t_kill0) / 1000000 ))
[ "$hrc" -eq 129 ] && [ "$kill_ms" -lt 3000 ] \
  && ok "33. HUP mid-run: exit 129 in ${kill_ms}ms (<3000ms)" \
  || bad "33. HUP mid-run: exit $hrc in ${kill_ms}ms (out: $(cat "$T/hup.out"))"
if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then
  ok "33. HUP mid-run: probe child ($spid) gone"
else
  [ -n "$spid" ] && kill -KILL "$spid" 2>/dev/null || true
  bad "33. HUP mid-run: probe child (${spid:-none}) still alive"
fi
check_intact "33. HUP mid-run"

# 34. --restore --force with journal holding 0.path and 0.orig but no 0.mutant, subject mutated -> exit 0, restored, no journal
mkdir -p "$JDIR"
printf '99999999\n' >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
printf 'new' >"$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore --force) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -q '^mutation-canary: restored$' <<<"$out" \
  && ok "34. --restore --force without 0.mutant: exit 0, restored" \
  || bad "34. --restore --force without 0.mutant: rc=$rc (out: $out)"
check_intact "34. --restore --force without 0.mutant"

# 35. --restore --force with fabricated journal where subject differs from both .orig and .mutant -> exit 0, subject intact, no journal
mkdir -p "$JDIR"
printf '99999999\n' >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$JDIR/0.mutant"
printf 'drifted from both orig and mutant' >"$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore --force) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -q '^mutation-canary: restored$' <<<"$out" \
  && ok "35. --restore --force with drifted subject: exit 0, restored" \
  || bad "35. --restore --force with drifted subject: rc=$rc (out: $out)"
check_intact "35. --restore --force with drifted subject"

# 36. --force without --restore -> exit 2, subject intact
out=$( (cd "$FIX" && bash "$TOOL" --force --file tools/subject.sh --old old --new new -- true) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "Usage:" <<<"$out" \
  && ok "36. --force without --restore: refused exit 2" \
  || bad "36. --force without --restore: rc=$rc (out: $out)"
check_intact "36. --force without --restore"

# 37. journal pid of a live plain sleep 30 & (argv[0] sleep), subject mutated, 0.mutant present and equal to it -> --restore exits 0 and restores
sleep 30 &
stale_pid=$!
mkdir -p "$JDIR"
printf '%s\n' "$stale_pid" >"$JDIR/pid"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$T/subject.mut"
cp -p "$T/subject.mut" "$JDIR/0.mutant"
cp "$T/subject.mut" "$FIX/tools/subject.sh"
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
kill -KILL "$stale_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null || true
[ "$rc" -eq 0 ] \
  && grep -q '^mutation-canary: restored$' <<<"$out" \
  && ok "37. --restore with reused non-mutation-canary pid: exit 0, restored" \
  || bad "37. --restore with reused non-mutation-canary pid: rc=$rc (out: $out)"
check_intact "37. --restore with reused non-mutation-canary pid"

# 38. journal dir holding 0.path, 0.orig, 0.mutant but no pid file, subject mutated -> --restore exits 0, restores, and took at least 900 ms
mkdir -p "$JDIR"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$T/subject.mut"
cp -p "$T/subject.mut" "$JDIR/0.mutant"
cp "$T/subject.mut" "$FIX/tools/subject.sh"
t_nopid0=$(date +%s%N)
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
t_nopid1=$(date +%s%N)
nopid_ms=$(( (t_nopid1 - t_nopid0) / 1000000 ))
[ "$rc" -eq 0 ] \
  && [ "$nopid_ms" -ge 900 ] \
  && grep -q '^mutation-canary: restored$' <<<"$out" \
  && ok "38. --restore without pid file: exit 0 after ${nopid_ms}ms (>=900ms), restored" \
  || bad "38. --restore without pid file: rc=$rc elapsed=${nopid_ms}ms (out: $out)"
check_intact "38. --restore without pid file"

# 39. journal dir holding 0.path, 0.orig, 0.mutant and no pid file; a live mutation-canary pid appears after 0.3 s -> --restore refused exit 2, subject still mutated, journal kept
mkdir -p "$JDIR"
printf '%s\n' "$SUBJECT_CANON" >"$JDIR/0.path"
cp -p "$T/subject.orig" "$JDIR/0.orig"
sed 's/MSG=old/MSG=new/' "$T/subject.orig" >"$T/subject.mut"
cp -p "$T/subject.mut" "$JDIR/0.mutant"
cp "$T/subject.mut" "$FIX/tools/subject.sh"
( exec -a mutation-canary sleep 30 ) &
live_pid=$!
( sleep 0.3; printf '%s\n' "$live_pid" >"$JDIR/pid" ) &
writer_pid=$!
out=$( (cd "$FIX" && bash "$TOOL" --restore) 2>&1 ); rc=$?
kill -KILL "$live_pid" "$writer_pid" 2>/dev/null || true
wait "$live_pid" "$writer_pid" 2>/dev/null || true
[ "$rc" -eq 2 ] \
  && grep -qF "another mutation-canary run is live" <<<"$out" \
  && cmp -s "$FIX/tools/subject.sh" "$T/subject.mut" \
  && [ -d "$JDIR" ] && [ -f "$JDIR/0.orig" ] && cmp -s "$JDIR/0.orig" "$T/subject.orig" \
  && ok "39. --restore with pid appearing during retry window: refused exit 2, subject still mutated, journal kept" \
  || bad "39. --restore with pid appearing during retry window: rc=$rc (out: $out)"
cp -p "$T/subject.orig" "$FIX/tools/subject.sh"
rm -f "$JDIR/pid" "$JDIR/0.path" "$JDIR/0.orig" "$JDIR/0.mutant"
rmdir "$JDIR" 2>/dev/null || true
check_intact "39. --restore with pid appearing during retry window"

# 40. default --fail-pattern with a two-space "FAIL  " line -> caught
out=$( (cd "$FIX" && bash "$TOOL" --file tools/subject.sh --old old --new new -- bash tests/twosp.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && grep -qF "CAUGHT: bash tests/twosp.probe.sh fails under the mutation (rc 1, 1 new failing lines)" <<<"$out" \
  && grep -qF "FAIL  subject printed new instead of old" <<<"$out" \
  && ok "40. default --fail-pattern: two-space FAIL line caught exit 0" || bad "40. default --fail-pattern two-space: rc=$rc (out: $out)"
check_intact "40. default --fail-pattern two-space"

# 41. opt-out: --fail-pattern '^FAIL:' does not read the two-space line -> inconclusive
out=$( (cd "$FIX" && bash "$TOOL" --fail-pattern '^FAIL:' --file tools/subject.sh --old old --new new -- bash tests/twosp.probe.sh) 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -qF "INCONCLUSIVE: bash tests/twosp.probe.sh failed (rc 1) with no new line matching ^FAIL:;" <<<"$out" \
  && ok "41. --fail-pattern '^FAIL:' opt-out: two-space line inconclusive exit 2" || bad "41. opt-out: rc=$rc (out: $out)"
check_intact "41. --fail-pattern opt-out"

# 42. mtime restore: a canary run over a Makefile project must leave the restored src.txt newer than any output built during the run, so make rebuilds instead of serving mutant output
MFIX="$T/mtime-fixture"
git init -q -b main "$MFIX"
git -C "$MFIX" config user.email t@t
git -C "$MFIX" config user.name t
SRC_TOKEN="b253-source-token-original"
MUT_TOKEN="b253-source-token-mutant"
printf '%s\n' "$SRC_TOKEN" >"$MFIX/src.txt"
printf 'out.txt: src.txt\n\t@cp src.txt out.txt\n' >"$MFIX/Makefile"
git -C "$MFIX" add -A
git -C "$MFIX" commit -qm "base make fixture"
make -s -C "$MFIX"
grep -qF "$SRC_TOKEN" "$MFIX/out.txt" \
  && ok "42. mtime restore: baseline build holds the original token" \
  || bad "42. mtime restore: baseline build failed (out.txt: $(cat "$MFIX/out.txt" 2>/dev/null))"
out=$( (cd "$MFIX" && bash "$TOOL" --file src.txt --old "$SRC_TOKEN" --new "$MUT_TOKEN" -- make -s) 2>&1 ); rc=$?
grep -q '^mutation-canary: survived$' <<<"$out" \
  && ok "42. mtime restore: canary ran (survived, as expected)" \
  || bad "42. mtime restore: canary verdict rc=$rc (out: $out)"
make -q -C "$MFIX"; qrc=$?
[ "$qrc" -eq 1 ] \
  && ok "42. mtime restore: make -q exits 1 (rebuild pending after restore)" \
  || bad "42. mtime restore: make -q rc=$qrc expected 1 (rebuild pending); src mtime $(stat -c %y "$MFIX/src.txt" 2>/dev/null) vs out $(stat -c %y "$MFIX/out.txt" 2>/dev/null)"
make -s -C "$MFIX"; mrc=$?
if [ "$mrc" -eq 0 ] && grep -qF "$SRC_TOKEN" "$MFIX/out.txt" && ! grep -qF "$MUT_TOKEN" "$MFIX/out.txt"; then
  ok "42. mtime restore: make -s rc 0, rebuilt out.txt holds the original and no mutant token"
else
  bad "42. mtime restore: make -s rc=$mrc, rebuilt out.txt: $(cat "$MFIX/out.txt" 2>/dev/null)"
fi


# 43. mtime restore on the already-restored path: the probe builds mutant output, then restores the original bytes with cp -p (stale mtime, bytes and mode equal) -> the early-continue restore path must still touch the file
MFIX2="$T/mtime-fixture-cmd-restore"
git init -q -b main "$MFIX2"
git -C "$MFIX2" config user.email t@t
git -C "$MFIX2" config user.name t
SRC_TOKEN2="b253-cmd-restore-token-original"
MUT_TOKEN2="b253-cmd-restore-token-mutant"
printf '%s\n' "$SRC_TOKEN2" >"$MFIX2/src.txt"
printf 'out.txt: src.txt\n\t@cp src.txt out.txt\n' >"$MFIX2/Makefile"
cp -p "$MFIX2/src.txt" "$MFIX2/src.orig"
cat >"$MFIX2/runner.sh" <<'RUNNER'
#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
make -s
cp -p src.orig src.txt
RUNNER
git -C "$MFIX2" add -A
git -C "$MFIX2" commit -qm "base make fixture"
make -s -C "$MFIX2"
grep -qF "$SRC_TOKEN2" "$MFIX2/out.txt" \
  && ok "43. mtime restore (cmd-restore): baseline build holds the original token" \
  || bad "43. mtime restore (cmd-restore): baseline build failed (out.txt: $(cat "$MFIX2/out.txt" 2>/dev/null))"
out=$( (cd "$MFIX2" && bash "$TOOL" --file src.txt --old "$SRC_TOKEN2" --new "$MUT_TOKEN2" -- bash runner.sh) 2>&1 ); rc=$?
grep -q '^mutation-canary: survived$' <<<"$out" \
  && ok "43. mtime restore (cmd-restore): canary ran (survived, as expected)" \
  || bad "43. mtime restore (cmd-restore): canary verdict rc=$rc (out: $out)"
make -q -C "$MFIX2"; qrc=$?
[ "$qrc" -eq 1 ] \
  && ok "43. mtime restore (cmd-restore): make -q exits 1 (rebuild pending after stale-mtime restore)" \
  || bad "43. mtime restore (cmd-restore): make -q rc=$qrc expected 1 (rebuild pending); src mtime $(stat -c %y "$MFIX2/src.txt" 2>/dev/null) vs out $(stat -c %y "$MFIX2/out.txt" 2>/dev/null)"
make -s -C "$MFIX2"; mrc=$?
if [ "$mrc" -eq 0 ] && grep -qF "$SRC_TOKEN2" "$MFIX2/out.txt" && ! grep -qF "$MUT_TOKEN2" "$MFIX2/out.txt"; then
  ok "43. mtime restore (cmd-restore): make -s rc 0, rebuilt out.txt holds the original and no mutant token"
else
  bad "43. mtime restore (cmd-restore): make -s rc=$mrc, rebuilt out.txt: $(cat "$MFIX2/out.txt" 2>/dev/null)"
fi

exit "$fail"
