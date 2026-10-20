#!/bin/bash
# Fixture check for bin/agy-extract against synthetic Antigravity conversation DBs
# (built here with a tiny protobuf encoder; invented names and ids only).
# Usage: tests/agy-extract.probe.sh   (from anywhere)

set -uo pipefail
AE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/agy-extract"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

cat > "$T/build.py" <<'EOF'
# build.py MODE DB [AGY_EXTRACT OUTDIR]
#   plain     WAL-mode DB closed cleanly (no sidecars left)
#   nomodel   like plain, but gen_metadata names no model at the known fields
#   badts     like plain, but one step carries an absurd timestamp
#   bytests   like plain, but one step's timestamp seconds are length-delimited, not a varint
#   since     only two steps: one stamped exactly at CUT (a minute boundary), one a second later
#   nostamp   only a stamped prompt and two steps with no timestamp field
#   nomsg     only one type-17 step with no sub-message at all
#   emptyts   a stamped prompt and one step whose timestamp field is present but empty
#   walcopy   like live, but copies db + -wal (no -shm) to a new dir ARG3 instead of running the tool
#   live      like plain, then a writer stays open (sidecars present, no checkpoint) holding one
#             uncheckpointed step while agy-extract runs against the DB
import sqlite3, subprocess, sys

def vint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)

def v(f, n): return vint(f << 3) + vint(n)
def m(f, *parts):
    body = b"".join(parts)
    return vint(f << 3 | 2) + vint(len(body)) + body
def s(f, t): return m(f, t.encode())

def step(stype, ts, *body):
    return stype, v(1, stype) + m(5, m(1, v(1, ts[0]) + v(2, ts[1]))) + b"".join(body)

# Epoch seconds for the fixture steps: OLD falls before the probe's --since cutoff, NEW after it.
OLD, NEW = 1788220800, 1790211600
CUT = 1789884000  # the --since minute boundary used by the since mode
mode, db = sys.argv[1], sys.argv[2]
steps = [
    step(14, (OLD, 0), m(19, s(2, "old prompt"))),
    step(14, (NEW, 123_000_000), m(19, s(2, "please fix the widget"))),
    step(15, (NEW + 1, 500_000_000), m(20,
        s(1, "On it."), s(3, "secret reasoning about widgets"),
        m(7, s(1, "c1"), s(2, "run_command"), s(3, '{"CommandLine": "ls -la /srv/widgets", "Cwd": "/x"}')),
        m(7, s(1, "c2"), s(2, "odd_tool"), s(3, "not json at all")))),
    step(132, (NEW + 2, 0), m(31, s(2, "sandbox said no"))),
    step(132, (NEW + 3, 0)),
    step(101, (NEW + 4, 0), m(114, s(1, "[Message] Task widget finished"))),
    step(23, (NEW + 5, 0), m(30, s(5, "<summary>widgets so far</summary>"))),
    step(17, (NEW + 6, 0), m(24, m(3, s(2, "blocked by content safety filters")))),
]
if mode == "badts":
    steps.append(step(14, (1 << 62, 0), m(19, s(2, "bad clock"))))
if mode == "bytests":
    steps.append((14, v(1, 14) + m(5, m(1, s(1, "x") + s(2, "y"))) + m(19, s(2, "bytes clock"))))
if mode == "since":
    steps = [step(14, (CUT, 0), m(19, s(2, "at cutoff"))), step(14, (CUT + 1, 0), m(19, s(2, "one second later")))]
if mode == "nostamp":
    steps = [step(14, (NEW, 0), m(19, s(2, "stamped prompt"))), (14, v(1, 14) + m(19, s(2, "unstamped one"))),
             (101, v(1, 101) + m(114, s(1, "unstamped two")))]
if mode == "nomsg":
    steps = [step(17, (NEW + 7, 0))]
if mode == "emptyts":
    steps = [step(14, (NEW, 0), m(19, s(2, "real prompt"))),
             (14, v(1, 14) + m(5, m(1, b"")) + m(19, s(2, "empty clock")))]
con = sqlite3.connect(db)
con.execute("pragma journal_mode=wal")
con.execute("create table steps(idx integer primary key, step_type integer, step_payload blob)")
con.execute("create table gen_metadata(idx integer primary key, data blob)")
con.execute("create table trajectory_metadata_blob(id integer primary key, data blob)")
for i, (st, b) in enumerate(steps):
    con.execute("insert into steps values(?,?,?)", (i, st, b))
if mode == "nomodel":
    con.execute("insert into gen_metadata values(0, ?)", (m(1, s(5, "gemini-9.9-test")),))
else:
    con.execute("insert into gen_metadata values(0, ?)", (m(1, s(19, "gemini-9.9-test"), s(5, "claude-usage prose")),))
    con.execute("insert into gen_metadata values(1, ?)", (m(3, s(28, "gemini-9.9-test-high")) + s(9, "see claude-usage"),))
con.execute("insert into trajectory_metadata_blob values(0, ?)", (m(1, s(1, "file:///srv/widgets-ws")),))
con.commit()
con.close()
if mode in ("live", "walcopy"):
    w = sqlite3.connect(db)
    w.execute("pragma wal_autocheckpoint=0")
    st, b = step(14, (NEW + 20, 0), m(19, s(2, "wal-only prompt")))
    w.execute("insert into steps values(?,?,?)", (99, st, b))
    w.commit()
    # premise: the step sits only in the WAL, not in the main DB file
    assert b"wal-only prompt" not in open(db, "rb").read(), "step reached the main DB file"
    assert b"wal-only prompt" in open(db + "-wal", "rb").read(), "step missing from the WAL"
    if mode == "live":
        subprocess.run([sys.argv[3], sys.argv[4], db], check=True, stdout=subprocess.DEVNULL)
    else:  # db + -wal copied aside while the writer holds the WAL: no -shm
        import os, shutil
        os.mkdir(sys.argv[3])
        shutil.copyfile(db, os.path.join(sys.argv[3], os.path.basename(db)))
        shutil.copyfile(db + "-wal", os.path.join(sys.argv[3], os.path.basename(db) + "-wal"))
    w.close()
EOF

ID=aaaabbbb-0000-4000-8000-000000000001
mkdir "$T/conv"
DB="$T/conv/$ID.db"
python3 -I "$T/build.py" plain "$DB"
sum_before=$(sha256sum "$DB" | cut -d' ' -f1)
[ "$(od -An -tu1 -j18 -N2 "$DB" | tr -s ' ')" = " 2 2" ] && ok "fixture is a WAL-mode DB" || bad "fixture is not WAL mode"
sidecars() { ls "$1"-wal "$1"-shm "$1"-journal 2>/dev/null | wc -l; }
[ "$(sidecars "$DB")" = 0 ] && ok "fixture starts without sidecars" || bad "fixture left sidecars"

"$AE" --since 2026-09-20T00:00 "$T/out" "$DB" > "$T/log"; rc=$?
O="$T/out/$ID.txt"; A="${O%.txt}.agent.txt"
[ $rc = 0 ] && ok "exits 0" || bad "exit $rc"
[ "$(sidecars "$DB")" = 0 ] && ok "no -wal, -shm or -journal file created next to a WAL DB" || bad "sidecars created: $(ls "$T/conv")"
[ "$(sha256sum "$DB" | cut -d' ' -f1)" = "$sum_before" ] && ok "DB unchanged after extraction" || bad "DB was modified"
grep -q '^=== 2026-09-24T01:00:00.123Z ===$' "$O" && grep -q '^please fix the widget$' "$O" && ok "type 14 prompt block with ms timestamp" || bad "prompt block"
grep -q "old prompt" "$O" && bad "--since let an old step through" || ok "--since drops the old step"
grep -q '^=== 2026-09-24T01:00:04.000Z \[mid-turn\] ===$' "$O" && grep -q 'Task widget finished' "$O" && ok "type 101 mid-turn block" || bad "mid-turn"
grep -q '^=== 2026-09-24T01:00:05.000Z \[summary\] ===$' "$O" && grep -q '<summary>widgets so far</summary>' "$O" && ok "type 23 summary block" || bad "summary"
grep -q '^# agy conversation aaaabbbb models: gemini-9.9-test, gemini-9.9-test-high workspace: file:///srv/widgets-ws$' "$O" \
  && grep -q '^# agy conversation aaaabbbb models:' "$A" && ok "header names models and workspace, in both files" || bad "header: $(head -1 "$O")"
grep -q 'claude-usage' "$O" && bad "model attribution picked up prose" || ok "model attribution ignores prose"
grep -q '^=== 2026-09-24T01:00:01.500Z \[agent\] ===$' "$A" && grep -q '^On it\.$' "$A" && ok "type 15 visible text as an agent block" || bad "agent block"
grep -q '^--- 2026-09-24T01:00:01.500Z tool run_command: ls -la /srv/widgets$' "$A" && ok "tool stub takes CommandLine from the args JSON" || bad "tool stub"
grep -q '^--- 2026-09-24T01:00:01.500Z tool odd_tool: not json at all$' "$A" && ok "tool stub falls back to the raw args" || bad "raw-args stub"
grep -q '^--- 2026-09-24T01:00:02.000Z tool-error: sandbox said no$' "$A" && ok "type 132 error line" || bad "tool-error"
[ "$(grep -c 'tool-error: sandbox' "$A")" = 1 ] && [ "$(grep -c '^--- .* tool-error:' "$A")" = 2 ] && ok "an error-free type 132 step emits nothing" || bad "error count in agent file"
grep -q '^--- 2026-09-24T01:00:06.000Z tool-error: \[safety-block\] blocked by content safety filters$' "$A" && ok "type 17 safety-block line" || bad "safety block"
grep -q "secret reasoning" "$A" && bad "thinking present by default" || ok "thinking dropped by default"
grep -q '^aaaabbbb…: 1 user blocks, 1 mid-turn, 1 agent blocks, 2 tool calls, 2 tool errors, models gemini-9.9-test,gemini-9.9-test-high, workspace file:///srv/widgets-ws$' "$T/log" \
  && ok "count line" || bad "count line: $(cat "$T/log")"

"$AE" --thinking "$T/out2" "$DB" > /dev/null
grep -q '^=== 2026-09-24T01:00:01.500Z \[thinking\] ===$' "$T/out2/$ID.agent.txt" \
  && grep -q "secret reasoning about widgets" "$T/out2/$ID.agent.txt" \
  && grep -q "old prompt" "$T/out2/$ID.txt" && ok "--thinking adds the thinking block; no --since keeps old steps" || bad "--thinking"

SYG_AGY_CONVERSATIONS_DIR="$T/conv" "$AE" "$T/out3" > "$T/log3"
grep -q '^aaaabbbb…: 2 user blocks' "$T/log3" && [ -f "$T/out3/$ID.txt" ] \
  && ok "no DB args reads SYG_AGY_CONVERSATIONS_DIR" || bad "default dir: $(cat "$T/log3")"

# A path with # and ? must stay read-only on the right file: no stray file, no sidecars.
mkdir "$T/we#ird?dir"
cp "$DB" "$T/we#ird?dir/$ID.db"
"$AE" "$T/out6" "$T/we#ird?dir/$ID.db" > "$T/log6" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^aaaabbbb…: 2 user blocks' "$T/log6" && [ ! -e "$T/we" ] && [ ! -e "$T/we#ird" ] \
  && [ "$(ls "$T/we#ird?dir" | wc -l)" = 1 ] && ok "a # and ? in the path: right file read, nothing created" || bad "special path: rc=$rc $(cat "$T/log6"); $(ls "$T")"

# Live writer: sidecars present and a step only in the WAL; it must be read, not missed.
mkdir "$T/live"
python3 -I "$T/build.py" live "$T/live/$ID.db" "$AE" "$T/out7" \
  && ok "premise: the live-WAL step is not in the main DB file" || bad "live-WAL premise"
grep -q '^wal-only prompt$' "$T/out7/$ID.txt" && ok "a step held only in a live WAL is extracted" || bad "WAL content missed"

# db + -wal but no -shm (copied aside while a writer held the WAL): WAL replayed in a temp copy,
# nothing created next to the fixture.
mkdir "$T/nosh-src"
python3 -I "$T/build.py" walcopy "$T/nosh-src/$ID.db" "$T/nosh" \
  && ok "premise: the aside copy has the step only in its -wal" || bad "walcopy premise"
nosh_before=$(ls -A "$T/nosh" | tr '\n' ' '); nosh_sum=$(sha256sum "$T/nosh/$ID.db" "$T/nosh/$ID.db-wal" | cut -d' ' -f1 | tr '\n' ' ')
"$AE" "$T/out10" "$T/nosh/$ID.db" > "$T/log10" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^wal-only prompt$' "$T/out10/$ID.txt" \
  && [ "$(ls -A "$T/nosh" | tr '\n' ' ')" = "$nosh_before" ] \
  && [ "$(sha256sum "$T/nosh/$ID.db" "$T/nosh/$ID.db-wal" | cut -d' ' -f1 | tr '\n' ' ')" = "$nosh_sum" ] \
  && ok "db + -wal without -shm: WAL-only step extracted, nothing created or changed beside it" || bad "no-shm case: rc=$rc $(cat "$T/log10"); $(ls -A "$T/nosh")"

# Model attribution going silent is reported, not hidden.
mkdir "$T/nomodel"
python3 -I "$T/build.py" nomodel "$T/nomodel/$ID.db"
"$AE" "$T/out8" "$T/nomodel/$ID.db" > "$T/log8" 2> "$T/err8"
grep -q "^agy-extract: aaaabbbb…: no model names at the known fields (schema drift?)$" "$T/err8" \
  && grep -q 'models ?,' "$T/log8" && grep -q 'models: ? workspace' "$T/out8/$ID.txt" \
  && ok "no model at the known fields: stderr note, ? on count line and header" || bad "model drift: $(cat "$T/err8" "$T/log8")"

# A bad timestamp fails its own DB only.
mkdir "$T/badts"
ID2=aaaabbbb-0000-4000-8000-000000000002
python3 -I "$T/build.py" badts "$T/badts/$ID2.db"
"$AE" "$T/out9" "$T/badts/$ID2.db" "$DB" > "$T/log9" 2>/dev/null; rc=$?
[ $rc = 1 ] && [ -f "$T/out9/$ID.txt" ] && [ ! -e "$T/out9/$ID2.txt" ] && grep -q '^aaaabbbb…: 2 user blocks' "$T/log9" \
  && ok "a DB with an absurd timestamp fails alone (exit 1); the next DB is still extracted" || bad "bad timestamp: rc=$rc $(cat "$T/log9"); $(ls "$T/out9")"

# A bytes-typed timestamp field is schema drift: it fails its own DB with a ValueError, and the next DB still runs.
ID3=ccccdddd-0000-4000-8000-000000000003
mkdir "$T/bytests"
python3 -I "$T/build.py" bytests "$T/bytests/$ID3.db"
"$AE" "$T/out11" "$T/bytests/$ID3.db" "$DB" > "$T/log11" 2> "$T/err11"; rc=$?
[ $rc = 1 ] && [ -f "$T/out11/$ID.txt" ] && [ ! -e "$T/out11/$ID3.txt" ] \
  && grep -q '^agy-extract: ccccdddd…: failed: timestamp field is not an integer$' "$T/err11" && grep -q '^aaaabbbb…: 2 user blocks' "$T/log11" \
  && ok "a bytes-typed timestamp fails alone with the ValueError text (exit 1); the next DB is still extracted" \
  || bad "bytes timestamp: rc=$rc $(cat "$T/err11" "$T/log11"); $(ls "$T/out11")"

# --since is strictly after its minute: a step stamped exactly at the cutoff is dropped, one a second later is kept.
ID4=ddddeeee-0000-4000-8000-000000000004
mkdir "$T/bound"
python3 -I "$T/build.py" since "$T/bound/$ID4.db"
"$AE" --since 2026-09-20T06:00 "$T/out12" "$T/bound/$ID4.db" > "$T/log12" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^one second later$' "$T/out12/$ID4.txt" && ! grep -q '^at cutoff$' "$T/out12/$ID4.txt" \
  && ok "--since 2026-09-20T06:00: the step at the cutoff is dropped, one a second later is kept" \
  || bad "since boundary: rc=$rc $(cat "$T/log12")"

# The shorter accepted shapes pad to the same cutoff; a bare date is midnight, so both steps are after it.
pad_ok=1; i=0
for since in 2026-09-20T06:00Z 2026-09-20T06:00:00 2026-09-20T06:00:00.000 2026-09-20T06:00:00.000Z; do
  i=$((i + 1))
  "$AE" --since "$since" "$T/pad$i" "$T/bound/$ID4.db" > /dev/null 2>&1 || pad_ok=0
  { grep -q '^one second later$' "$T/pad$i/$ID4.txt" && ! grep -q '^at cutoff$' "$T/pad$i/$ID4.txt"; } 2>/dev/null || pad_ok=0
done
"$AE" --since 2026-09-20 "$T/bare" "$T/bound/$ID4.db" > /dev/null 2>&1 || pad_ok=0
{ grep -q '^at cutoff$' "$T/bare/$ID4.txt" && grep -q '^one second later$' "$T/bare/$ID4.txt"; } 2>/dev/null || pad_ok=0
[ $pad_ok = 1 ] && ok "--since shapes HH:MM, HH:MM:SS, .000 and Z pad to the cutoff; a bare date is midnight" \
  || bad "--since padding"

# Malformed --since (a space for the T, an impossible date, a fraction without seconds) is a usage error, exit 2.
malformed_ok=1
for since in "2026-09-20 06:00" "2026-02-30T00:00" "2026-09-20T06:00.000" "2026-09-20T24:00" "2026-09-20T06:00ZZ"; do
  "$AE" --since "$since" "$T/o14" "$DB" > /dev/null 2>&1; [ $? = 2 ] || malformed_ok=0
done
"$AE" --since 2> "$T/errmv" >/dev/null; [ $? = 2 ] && grep -q "needs a timestamp" "$T/errmv" || malformed_ok=0
"$AE" --since "2026-09-20 06:00" "$T/o14" "$DB" 2> "$T/errmi" >/dev/null; [ $? = 2 ] && grep -q "wants UTC YYYY-MM-DD" "$T/errmi" || malformed_ok=0
[ $malformed_ok = 1 ] && ok "malformed --since (space for T, impossible date, .fff without seconds, 24:00, double Z, missing value) exits 2, with the usage text" || bad "malformed --since accepted"

# A step with no timestamp is skipped under --since with one stderr note; no note without --since or when every step is stamped.
ID5=eeeeffff-0000-4000-8000-000000000005
mkdir "$T/nostamp"
python3 -I "$T/build.py" nostamp "$T/nostamp/$ID5.db"
"$AE" --since 2026-09-20T00:00 "$T/out15" "$T/nostamp/$ID5.db" > "$T/log15" 2> "$T/err15"; rc=$?
[ $rc = 0 ] && [ "$(cat "$T/err15")" = "agy-extract: eeeeffff…: 2 step(s) without a timestamp skipped under --since" ] \
  && grep -q '^stamped prompt$' "$T/out15/$ID5.txt" && ! grep -q 'unstamped' "$T/out15/$ID5.txt" \
  && ok "steps without a timestamp are skipped under --since, with one stderr note per DB" \
  || bad "missing-stamp note: rc=$rc $(cat "$T/err15")"
"$AE" "$T/out16" "$T/nostamp/$ID5.db" > /dev/null 2> "$T/err16"; rc=$?
[ $rc = 0 ] && [ ! -s "$T/err16" ] && ok "no missing-stamp note without --since" || bad "note without --since: rc=$rc $(cat "$T/err16")"
"$AE" --since 2026-09-20T00:00 "$T/out17" "$DB" > /dev/null 2> "$T/err17"; rc=$?
[ $rc = 0 ] && [ ! -s "$T/err17" ] && ok "no missing-stamp note when every step is stamped" || bad "note on a fully stamped DB: rc=$rc $(cat "$T/err17")"

# A type-17 step with no message is still a safety block, and its line has no trailing space.
ID6=99998888-0000-4000-8000-000000000006
mkdir "$T/nomsg"
python3 -I "$T/build.py" nomsg "$T/nomsg/$ID6.db"
"$AE" "$T/out18" "$T/nomsg/$ID6.db" > "$T/log18" 2>&1; rc=$?
[ $rc = 0 ] && grep -q '^--- 2026-09-24T01:00:07.000Z tool-error: \[safety-block\]$' "$T/out18/$ID6.agent.txt" \
  && grep -q ', 1 tool errors, ' "$T/log18" \
  && ok "a type-17 step with no message emits [safety-block] with no trailing space" \
  || bad "empty safety block: rc=$rc $(cat "$T/out18/$ID6.agent.txt" "$T/log18")"

# A present-but-empty timestamp stamps 1970-01-01 (known gap, see stamp()): under --since the
# step is dropped silently — stamped, so no unstamped note.
ID7=77776666-0000-4000-8000-000000000007
mkdir "$T/emptyts"
python3 -I "$T/build.py" emptyts "$T/emptyts/$ID7.db"
"$AE" --since 2026-09-20T00:00 "$T/out19" "$T/emptyts/$ID7.db" > /dev/null 2> "$T/err19"; rc=$?
[ $rc = 0 ] && [ ! -s "$T/err19" ] && grep -q '^real prompt$' "$T/out19/$ID7.txt" && ! grep -q 'empty clock' "$T/out19/$ID7.txt" \
  && ok "a present-but-empty timestamp (1970) is dropped silently under --since, no unstamped note" \
  || bad "emptyts: rc=$rc $(cat "$T/err19"; ls "$T/out19")"

[ "$(sidecars "$DB")" = 0 ] && [ "$(sha256sum "$DB" | cut -d' ' -f1)" = "$sum_before" ] \
  && ok "DB still unchanged and sidecar-free after all runs" || bad "DB modified by a later run"

echo "not a database, just text" > "$T/bad.db"
"$AE" "$T/out4" "$T/bad.db" >/dev/null 2>&1; [ $? = 1 ] && ok "corrupt DB exits 1" || bad "corrupt DB"
"$AE" "$T/out4" "$T/missing.db" >/dev/null 2>&1; [ $? = 1 ] && ok "missing DB exits 1" || bad "missing DB"
"$AE" --since 2026-09-24T01:00-04:00 "$T/o5" "$DB" >/dev/null 2>&1; [ $? = 2 ] && ok "--since rejects an offset" || bad "--since offset"
"$AE" >/dev/null 2>&1; [ $? = 2 ] && ok "no arguments exits 2" || bad "no args"
out=$("$AE" --help 2>&1); [ $? = 0 ] && grep -q "Usage:" <<< "$out" && ok "--help exits 0" || bad "--help"
exit $fail
