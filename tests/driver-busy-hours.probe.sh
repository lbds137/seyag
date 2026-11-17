#!/bin/bash
# Fixture check for bin/driver-busy-hours: gap counting, the time window, replies per model,
# subagent files left out, and the --slug resolution and usage errors.
# Usage: tests/driver-busy-hours.probe.sh   (from anywhere)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/plugins/seyag/bin/driver-busy-hours"
[ -x "$BIN" ] || { echo "FAIL: $BIN is not executable (chmod +x it)"; exit 1; }
export SYG_CONFIG=0
unset CLAUDE_CONFIG_DIR
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_PROJECTS_DIR="$tmp/projects"
proj="$CLAUDE_PROJECTS_DIR/-home-user-Projects-demo"
mkdir -p "$proj/s1/subagents" "$CLAUDE_PROJECTS_DIR/-home-user-Projects-demo-two" "$CLAUDE_PROJECTS_DIR/-home-x-two"

line() { # line <type> <utc time> [model]
    jq -cn --arg t "$1" --arg ts "$2" --arg m "${3:-}" \
        '{type: $t, timestamp: $ts} + (if $m == "" then {} else {message: {model: $m}} end)'
}
# s1: 10:00 → 10:02 (120 s) → 10:04 (120 s) busy; 10:30 is a 26-minute gap (idle); 10:31 (60 s);
# a line at 23:00 the day before sits outside the window; one untimed and one unparsable line.
{ line user 2026-10-25T23:00:00Z
  line user 2026-10-26T10:00:00Z
  line assistant 2026-10-26T10:02:00Z claude-sonnet-5-5
  line assistant 2026-10-26T10:04:00Z claude-opus-5-5
  line user 2026-10-26T10:30:00Z
  line assistant 2026-10-26T10:31:00Z claude-sonnet-5-5
  line assistant 2026-10-26T10:31:30Z '<synthetic>'
  echo '{"type":"custom-title","timestamp":null}'
  echo '{"type":"api-request-blob","timestamp":"2026-10-26T10:03:00Z","message":{"id":"mblob","model":"claude-opus-5-5"}}'
  echo '{not json'; } > "$proj/s1.jsonl"
line assistant 2026-10-26T10:00:30Z claude-haiku-5-5 > "$proj/s1/subagents/agent-a.jsonl"
line user 2026-10-24T09:00:00Z > "$proj/s2.jsonl"

out=$("$BIN" --slug=-home-user-Projects-demo --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 330 ] && ok "busy = gaps of 300 s or less (120+120+60+30)" || bad "busy_seconds: $(jq -c . <<< "$out")"
[ "$(jq -r '.sessions | length' <<< "$out")" = 1 ] && ok "a session with no events in the window is left out" || bad "sessions: $(jq -c .sessions <<< "$out")"
[ "$(jq -r '.sessions[0].events' <<< "$out")" = 6 ] && ok "only timed lines inside the window count as events" || bad "events: $(jq -c .sessions <<< "$out")"
[ "$(jq -c '.sessions[0].replies_by_model' <<< "$out")" = '{"claude-sonnet-5-5":2,"claude-opus-5-5":1}' ] \
    && ok "replies per model, <synthetic> and subagent files left out" || bad "models: $(jq -c .sessions <<< "$out")"

out=$("$BIN" --slug=-home-user-Projects-demo --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --gap 1800 --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 1890 ] && ok "--gap widens what counts as busy" || bad "gap 1800: $(jq -r .busy_seconds <<< "$out")"

out=$("$BIN" --slug demo --since 2026-10-26T10:03Z --until 2026-10-26T10:31:10Z --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 60 ] && ok "a tail slug resolves; the window clips events" || bad "window: $(jq -c . <<< "$out")"

"$BIN" --slug two --since 2026-10-26 --until 2026-10-26 > /dev/null 2> "$tmp/err"; rc=$?
[ $rc = 2 ] && grep -q '2 folders' "$tmp/err" && ok "an ambiguous tail exits 2 and names the matches" || bad "ambiguous: rc=$rc $(cat "$tmp/err")"
"$BIN" --slug nope --since 2026-10-26 --until 2026-10-26 > /dev/null 2> "$tmp/err"; rc=$?
[ $rc = 2 ] && grep -q 'no folder' "$tmp/err" && ok "an unknown slug exits 2" || bad "unknown: rc=$rc $(cat "$tmp/err")"
"$BIN" --slug demo --since 10/26 --until 2026-10-26 > /dev/null 2> "$tmp/err"; rc=$?
[ $rc = 2 ] && grep -q 'bad time' "$tmp/err" && ok "a bad time is refused" || bad "bad time: rc=$rc $(cat "$tmp/err")"
"$BIN" --slug demo > /dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "missing --since/--until exits 2" || bad "missing args: rc=$rc"
help=$("$BIN" --help)   # captured first: under pipefail, grep -q exiting early would SIGPIPE the producer
grep -q 'Busy time is the sum' <<< "$help" && ok "--help prints the docstring" || bad "--help"
"$BIN" --slug demo --since 2026-10-27 --until 2026-10-26 > /dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "--since after --until exits 2" || bad "reversed window: rc=$rc"
CLAUDE_PROJECTS_DIR="$tmp/none" "$BIN" --slug demo --since 2026-10-26 --until 2026-10-26 > /dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "a missing projects root exits 2" || bad "missing root: rc=$rc"

# Local-time windows: a bare date is the local day through 23:59:59.999999, in any TZ.
loc="$CLAUDE_PROJECTS_DIR/-home-user-Projects-loc"; mkdir -p "$loc"
{ line user 2026-10-26T06:58:00Z; line user 2026-10-26T07:00:00Z     # 23:58, 00:00 in Los Angeles (UTC-7)
  line user 2026-10-26T15:00:00Z; line user 2026-10-26T15:01:00Z     # 00:00, 00:01 in Tokyo (UTC+9)
  line user 2026-10-27T06:59:00Z; line user 2026-10-27T06:59:59.5Z; } > "$loc/s.jsonl"
out=$(TZ=America/Los_Angeles "$BIN" --slug loc --since 2026-10-26 --until 2026-10-26 --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 120 ] && [ "$(jq -r '.sessions[0].events' <<< "$out")" = 5 ] \
    && ok "Los Angeles day: the gap before local midnight is out, the last half-second before the next one is in" \
    || bad "LA window: $(jq -c '{busy_seconds, sessions}' <<< "$out")"
out=$(TZ=Asia/Tokyo "$BIN" --slug loc --since 2026-10-27 --until 2026-10-27 --json)
[ "$(jq -r '.sessions[0].events' <<< "$out")" = 4 ] && ok "Tokyo day starts at 15:00Z" || bad "Tokyo window: $(jq -c .sessions <<< "$out")"

# One reply spans several lines sharing a message id; naive and non-string timestamps; overlap.
odd="$CLAUDE_PROJECTS_DIR/-home-user-Projects-odd"; mkdir -p "$odd"
{ jq -cn '{type: "assistant", timestamp: "2026-10-26T10:00:00Z", message: {id: "m1", model: "claude-opus-5-5"}}'
  jq -cn '{type: "assistant", timestamp: "2026-10-26T10:00:01Z", message: {id: "m1", model: "claude-opus-5-5"}}'
  jq -cn '{type: "assistant", timestamp: "2026-10-26T10:00:02Z", message: {id: "m2", model: "claude-opus-5-5"}}'
  echo '{"type":"user","timestamp":"2026-10-26T10:02:00"}'
  echo '{"type":"user","timestamp":123}'; } > "$odd/a.jsonl"
{ line user 2026-10-26T10:01:00Z; line user 2026-10-26T10:04:00Z; } > "$odd/b.jsonl"
out=$("$BIN" --slug odd --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json 2> "$tmp/err"); rc=$?
[ $rc = 0 ] && ok "naive and non-string timestamps don't crash" || bad "odd timestamps: rc=$rc $(cat "$tmp/err")"
[ "$(jq -r '.sessions[0].replies_by_model."claude-opus-5-5"' <<< "$out")" = 2 ] && ok "replies count message ids, not lines" || bad "replies: $(jq -c .sessions <<< "$out")"
[ "$(jq -r '.sessions[0].busy_seconds' <<< "$out")" = 120 ] && ok "a naive transcript timestamp is read as UTC" || bad "naive: $(jq -c .sessions <<< "$out")"
[ "$(jq -r .busy_seconds <<< "$out")" = 240 ] && ok "the total is the union of overlapping sessions (10:00-10:04)" || bad "union: $(jq -c . <<< "$out")"
out=$("$BIN" --slug odd --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --session b --json)
[ "$(jq -r '.sessions | map(.session) | join(",")' <<< "$out")" = b ] && [ "$(jq -r .busy_seconds <<< "$out")" = 180 ] \
    && ok "--session keeps only the named sessions" || bad "--session: $(jq -c . <<< "$out")"

# Antigravity (agy) root driver union: merges root agy transcript intervals and excludes child subagents.
agy_db="$tmp/agy.db"
agy_brain="$tmp/agy-brain"
mkdir -p "$agy_brain/agyroot1/.system_generated/logs" "$agy_brain/agychild/.system_generated/logs"
python3 -I - "$agy_db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE conversation_summaries (conversation_id text primary key, workspace_uris text, nesting_depth int, parent_conversation_id text)")
c.execute("INSERT INTO conversation_summaries VALUES ('agyroot1', '[\"file:///home/user/Projects/odd\"]', 0, '')")
c.execute("INSERT INTO conversation_summaries VALUES ('agychild', '[\"file:///home/user/Projects/odd\"]', 1, 'agyroot1')")
c.commit()
PY
cat > "$agy_brain/agyroot1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-10-26T10:10:00Z"}
{"type":"PLANNER_RESPONSE","created_at":"2026-10-26T10:12:00Z"}
EOF
cat > "$agy_brain/agychild/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-10-26T11:00:00Z"}
{"type":"PLANNER_RESPONSE","created_at":"2026-10-26T11:05:00Z"}
EOF
out_agy=$(SYG_AGY_SUMMARIES_DB="$agy_db" SYG_AGY_BRAIN_DIR="$agy_brain" "$BIN" --slug odd --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json)
# Claude union was 240s (10:00-10:04); agyroot1 adds 120s (10:10-10:12) -> 360s; agychild (300s) is excluded!
[ "$(jq -r .busy_seconds <<< "$out_agy")" = 360 ] \
  && jq -e '(.sessions | any(.session == "agyroot1" and .busy_seconds == 120 and .replies_by_model.agy == 1)) and ((.sessions | any(.session == "agychild")) | not)' <<< "$out_agy" >/dev/null \
  && ok "agy root driver intervals merge into busy_seconds while child subagents are excluded" \
  || bad "agy busy-hours union: $(jq -c . <<< "$out_agy")"

# The pre-SYG_ names are not read: with them set (and CLAUDE_PROJECTS_DIR explicit) no agy rows join.
out_old=$(AGY_SUMMARIES_DB="$agy_db" AGY_BRAIN_DIR="$agy_brain" "$BIN" --slug odd --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json)
[ "$(jq -r .busy_seconds <<< "$out_old")" = 240 ] && jq -e '.sessions | any(.session == "agyroot1") | not' <<< "$out_old" >/dev/null \
  && ok "old AGY_SUMMARIES_DB / AGY_BRAIN_DIR names are ignored" \
  || bad "old agy names honoured: $(jq -c . <<< "$out_old")"

# Project driven exclusively in agy (no folder in CLAUDE_PROJECTS_DIR): resolves via agy workspace_uris!
mkdir -p "$agy_brain/agyonly1/.system_generated/logs"
python3 -I - "$agy_db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO conversation_summaries VALUES ('agyonly1', '[\"file:///home/user/Projects/pure-agy\"]', 0, '')")
c.commit()
PY
cat > "$agy_brain/agyonly1/.system_generated/logs/transcript.jsonl" <<'EOF'
{"type":"USER_INPUT","created_at":"2026-10-26T14:00:00Z"}
{"type":"PLANNER_RESPONSE","created_at":"2026-10-26T14:03:00Z"}
EOF
out_pure=$(SYG_AGY_SUMMARIES_DB="$agy_db" SYG_AGY_BRAIN_DIR="$agy_brain" "$BIN" --slug pure-agy --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json); rc_pure=$?
[ "$rc_pure" = 0 ] && [ "$(jq -r .busy_seconds <<< "$out_pure")" = 180 ] && [ "$(jq -r .folder <<< "$out_pure")" = "-home-user-Projects-pure-agy" ] \
  && ok "agy-only project with no Claude folder resolves cleanly" \
  || bad "agy-only project: rc=$rc_pure out=$out_pure"


# Without CLAUDE_PROJECTS_DIR the root is CLAUDE_CONFIG_DIR/projects (HOME is a fixture: no real agy data).
mkdir -p "$tmp/cfg" "$tmp/nohome"; ln -s "$CLAUDE_PROJECTS_DIR" "$tmp/cfg/projects"
out=$(env -u CLAUDE_PROJECTS_DIR HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/cfg" "$BIN" --slug=-home-user-Projects-demo --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 330 ] && ok "default root is CLAUDE_CONFIG_DIR/projects" || bad "config dir root: $out"
out=$(HOME="$tmp/nohome" CLAUDE_CONFIG_DIR="$tmp/nope" "$BIN" --slug=-home-user-Projects-demo --since 2026-10-26T00:00Z --until 2026-10-26T23:59Z --json)
[ "$(jq -r .busy_seconds <<< "$out")" = 330 ] && ok "CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR" || bad "projects dir root: $out"

exit $fail
