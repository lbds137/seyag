#!/bin/bash
# Fixture check for bin/chrome-loss-scan: fake `claude agents --json` output plus fake transcripts
# covering each state (on, lost, off, re-added, no transcript, a non-Chrome delta), the exit code,
# and that the newest transcript copy wins. Usage: tests/chrome-loss-scan.probe.sh (from anywhere)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLS="$ROOT/plugins/seyag/bin/chrome-loss-scan"
[ -x "$CLS" ] || { echo "FAIL: $CLS is not executable (chmod +x it)"; exit 1; }
export SYG_CONFIG=0
unset CLAUDE_PROJECTS_DIR CLAUDE_CONFIG_DIR
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
P="$t/projects"
mkdir -p "$P/-a" "$P/-b"
C1=mcp__claude-in-chrome__computer C2=mcp__claude-in-chrome__navigate
delta() { # ts added removed (comma lists, may be empty)
  python3 -c 'import json,sys
ts,a,r=sys.argv[1:]
print(json.dumps({"type":"attachment","timestamp":ts,"attachment":{"type":"deferred_tools_delta",
 "addedNames":[x for x in a.split(",") if x],"removedNames":[x for x in r.split(",") if x]}}))' "$1" "$2" "$3"
}
{ delta T1 "Read,$C1,$C2" ""; } > "$P/-a/s-on.jsonl"
{ delta T1 "$C1,$C2" ""; delta T2 "" "$C1,$C2"; } > "$P/-a/s-lost.jsonl"
{ delta T1 "Read,mcp__council__ask" ""; } > "$P/-a/s-off.jsonl"
{ delta T1 "$C1,$C2" ""; delta T2 "" "$C1,$C2"; delta T3 "$C1" ""; } > "$P/-a/s-back.jsonl"
{ delta T1 "$C1,$C2" ""; delta T2 "" "$C1"; } > "$P/-a/s-partial.jsonl"
# Same id in two folders: the newer file (lost) must win over the older (on).
{ delta T1 "$C1" ""; } > "$P/-a/s-dup.jsonl"; touch -d '2020-01-01' "$P/-a/s-dup.jsonl"
{ delta T1 "$C1" ""; delta T9 "" "$C1"; } > "$P/-b/s-dup.jsonl"

agents() { python3 -c 'import json,sys; print(json.dumps([{"id":s[:8],"sessionId":s,"pid":1,"name":s,"cwd":"/x"} for s in sys.argv[1:]]+[{"id":"nopid","sessionId":"s-lost","pid":None}]))' "$@" > "$t/agents.json"; }

state_of() { python3 -c 'import json,sys; print(" ".join(r["id"]+"="+r["state"]+"@"+str(r["since"]) for r in json.load(sys.stdin)))'; }

agents s-on s-lost s-off s-back s-partial s-dup s-none
got=$("$CLS" --agents "$t/agents.json" --projects "$P" --json | state_of)
want="s-on=on@T1 s-lost=lost@T2 s-off=off@None s-back=on@T3 s-partia=on@T1 s-dup=lost@T9 s-none=no-transcript@None"
[ "$got" = "$want" ] && ok "states per transcript" || bad "states: got '$got' want '$want'"

out=$("$CLS" --agents "$t/agents.json" --projects "$P"); rc=$?
[ "$rc" = 1 ] && ok "exit 1 when a session lacks Chrome" || bad "exit $rc, want 1"
n=$(grep -c '^no Chrome' <<<"$out")
[ "$n" = 3 ] && ok "reports lost, off and dup (3 lines)" || bad "report lines $n, want 3: $out"
grep -q '^no Chrome (off): s-off .*since its start' <<<"$out" && ok "off line says since its start" || bad "off line: $out"
grep -q 'nopid' <<<"$out" && bad "a pid-less entry was scanned" || ok "pid-less entries skipped"

agents s-on s-back
out=$("$CLS" --agents "$t/agents.json" --projects "$P"); rc=$?
[ "$rc" = 0 ] && grep -q 'all have Chrome' <<<"$out" && ok "exit 0 and all-clear line when every session has Chrome" || bad "all-clear: rc $rc out '$out'"

# A session whose transcript can't be found is unknown, never an all-clear.
agents s-on s-none
out=$("$CLS" --agents "$t/agents.json" --projects "$P"); rc=$?
[ "$rc" = 1 ] && grep -q '^unknown: s-none' <<<"$out" && ! grep -q 'all have Chrome' <<<"$out" \
  && ok "missing transcript goes red, no all-clear" || bad "no-transcript: rc $rc out '$out'"

# A session list that isn't a list (changed CLI shape) or isn't JSON fails, never "0 sessions, fine".
echo '{"agents":[]}' > "$t/agents.json"
out=$("$CLS" --agents "$t/agents.json" --projects "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'expected a list' <<<"$out" && ok "non-list session list fails" || bad "non-list: rc $rc out '$out'"
echo 'not json' > "$t/agents.json"
out=$("$CLS" --agents "$t/agents.json" --projects "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "can't read the session list" <<<"$out" && ! grep -q Traceback <<<"$out" \
  && ok "non-JSON session list fails cleanly" || bad "non-json: rc $rc out '$out'"

# A line that only mentions the strings, and a malformed line, change nothing.
{ delta T1 "$C1" ""; echo '{"type":"user","note":"deferred_tools_delta removedNames mcp__claude-in-chrome__computer"}'; echo '{"deferred_tools_delta" mcp__claude-in-chrome__ broken'; } > "$P/-a/s-noise.jsonl"
agents s-noise
got=$("$CLS" --agents "$t/agents.json" --projects "$P" --json | state_of)
[ "$got" = "s-noise=on@T1" ] && ok "non-delta and malformed lines ignored" || bad "noise: got '$got'"

# Default transcript root: CLAUDE_PROJECTS_DIR, else CLAUDE_CONFIG_DIR/projects; an explicit --projects wins.
mkdir -p "$t/cfg/projects/-a" "$t/empty"
cp "$P/-a/s-on.jsonl" "$t/cfg/projects/-a/s-on.jsonl"
agents s-on
got=$(CLAUDE_CONFIG_DIR="$t/cfg" "$CLS" --agents "$t/agents.json" --json | state_of)
[ "$got" = "s-on=on@T1" ] && ok "default root is CLAUDE_CONFIG_DIR/projects" || bad "config dir root: got '$got'"
got=$(CLAUDE_CONFIG_DIR="$t/empty" CLAUDE_PROJECTS_DIR="$t/cfg/projects" "$CLS" --agents "$t/agents.json" --json | state_of)
[ "$got" = "s-on=on@T1" ] && ok "CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR" || bad "projects dir root: got '$got'"
got=$(CLAUDE_PROJECTS_DIR="$t/empty" "$CLS" --agents "$t/agents.json" --projects "$t/cfg/projects" --json | state_of)
[ "$got" = "s-on=on@T1" ] && ok "an explicit --projects wins over the environment" || bad "--projects root: got '$got'"

exit $fail
