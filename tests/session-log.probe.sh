#!/bin/bash
# Fixture check for bin/session-log against a synthetic projects root and ledger.
# Usage: tests/session-log.probe.sh   (from anywhere)
# Fixture clock: TZ=America/New_York (EDT, UTC-4), so local 2026-09-24 starts at 04:00Z.

set -uo pipefail
SL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/session-log"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# HOME is pinned to $T so cleanup_window reads ~/.claude/settings.json under the temp root (when CLAUDE_CONFIG_DIR is unset), never the runner's real home.
export TZ=America/New_York HOME="$T" CLAUDE_PROJECTS_DIR="$T/projects" SESSION_LEDGER="$T/ledger.tsv" CLAUDE_SESSION_ARCHIVE="$T/archive" PYTHONDONTWRITEBYTECODE=1
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }
ALL="$T/all.out"   # every stdout+stderr, for the id-leak check
run() { "$SL" "$@" > "$T/out" 2> "$T/err"; rc=$?; cat "$T/out" "$T/err" >> "$ALL"; return $rc; }

A_ID=aaaaaaaa-1111-4000-8000-000000000001; B_ID=aaaaaaaa-2222-4000-8000-000000000002; C_ID=cccccccc-3333-4000-8000-000000000003
BRIDGE=cse_01AAAAAAAAAAAAAAAAAAAAAA; CLOUD=cse_01ZZZZZZZZZZZZZZZZZZZZZZ
# Two fixture uuids positioned so the grep-snippet's +-100-char window lands 1 char inside each
# (65 filler chars on either side of an 11-char match word = a boundary at offset 1 into the id):
CLIP1=11111111-2222-4000-8000-000000000111; CLIP2=99999999-8888-4000-8000-000000000222
CLIP_DOTS=$(printf '.%.0s' $(seq 1 65))
# uuids of two local mineable entries, duplicated into the archive fixture below so dedup can be checked
U1=aaaaaaaa-a111-4000-8000-0000000000a1; U2=aaaaaaaa-a222-4000-8000-0000000000a2
ARCH_CLOUD=cse_01BBBBBBBBBBBBBBBBBBBBBB   # a cloud-only archive session: no local transcript ever
ALPHA="$T/projects/-home-deck-Projects-alpha"; BETA="$T/projects/-home-deck-Projects-beta"
mkdir -p "$ALPHA/$A_ID/subagents" "$BETA"
cat > "$ALPHA/$A_ID.jsonl" <<EOF
{"type":"bridge-session","sessionId":"$A_ID","bridgeSessionId":"$BRIDGE"}
{"type":"ai-title","aiTitle":"AI Title A"}
{"type":"custom-title","customTitle":"Custom Title A"}
{"type":"user","timestamp":"2026-09-24T03:30:00Z","message":{"content":"early bird"}}
{"parentUuid":null,"type":"user","timestamp":"2026-09-24T04:30:00Z","uuid":"$U1","message":{"content":"please fix the parser"}}
{"type":"assistant","timestamp":"2026-09-24T04:31:00Z","message":{"content":[{"type":"thinking","thinking":"secret fix the parser thoughts"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"grep -r foo ~"}}]}}
{"type":"user","timestamp":"2026-09-24T04:32:00Z","message":{"content":[{"type":"tool_result","is_error":true,"content":"blocked by broad-walk-guard"},{"type":"text","text":"array-form turn"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T04:33:00Z","content":"wait, not that folder"}
{"type":"user","timestamp":"2026-09-24T04:34:00Z","message":{"content":"<system-reminder>hiddenword inside</system-reminder> visible text"}}
EOF
# The em dash is stored as the six-character JSON escape (backslash u2014), never as the character:
# printf's format collapses the doubled backslash below to one.
printf '{"type":"user","timestamp":"2026-09-24T04:35:30Z","message":{"content":"the dash \\u2014 phrase"}}\n' >> "$ALPHA/$A_ID.jsonl"
cat >> "$ALPHA/$A_ID.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-24T04:35:45Z","message":{"content":"leaked-marker cse_01AAAAAAAAAAAAAAAAAAAAAA at /tmp/x/aaaaaaaa-1111-4000-8000-000000000001/tasks/y.output done"}}
{"type":"assistant","timestamp":"2026-09-24T04:35:50Z","message":{"content":[{"type":"text","text":"${CLIP1}${CLIP_DOTS}clip-marker${CLIP_DOTS}${CLIP2}"}]}}
{"type":"user","timestamp":"2026-09-24T04:36:00Z","isMeta":true,"message":{"content":"meta noise"}}
{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"events":[{"type":"user","timestamp":"2026-09-24T09:09:00Z","data":"nested"}],"command":"echo nested"}},{"type":"text","text":"nested marker reply"}]},"type":"assistant","timestamp":"2026-09-24T04:31:30Z"}
{not json at all
EOF
D_ID=eeeeeeee-5555-4000-8000-000000000005   # only non-mineable timestamped entries: never a row
cat > "$BETA/$D_ID.jsonl" <<EOF
{"type":"custom-title","customTitle":"System only"}
{"type":"system","timestamp":"2026-09-24T07:00:00Z","content":"turn_duration"}
{"type":"attachment","timestamp":"2026-09-24T07:01:00Z","attachment":{"type":"text"}}
EOF
UNKNOWN=ffffffff-0000-4000-8000-00000000000f
cat > "$ALPHA/$A_ID/subagents/agent-0123456789abcdef0.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-24T04:40:00Z","message":{"content":"subagent only text"}}
EOF
cat > "$ALPHA/$B_ID.jsonl" <<EOF
{"type":"bridge-session","sessionId":"$B_ID","bridgeSessionId":"$BRIDGE"}
{"type":"user","timestamp":"2026-09-24T05:00:00Z","uuid":"$U2","message":{"content":"second transcript turn"}}
{"type":"assistant","timestamp":"2026-09-24T05:01:00Z","message":{"content":[{"type":"text","text":"reply two"}]}}
{"type":"user","timestamp":"2026-09-24T05:02:00Z","message":{"content":"third turn"}}
{"type":"assistant","timestamp":"2026-09-24T05:03:00Z","message":{"content":[{"type":"text","text":"reply three"}]}}
EOF
cat > "$BETA/$C_ID.jsonl" <<EOF
{"type":"custom-title","customTitle":"Session $C_ID wrap-up"}
{"type":"user","timestamp":"2026-09-24T06:00:00Z","message":{"content":"beta project turn"}}
{"type":"assistant","timestamp":"2026-09-24T06:01:00Z","message":{"content":[{"type":"text","text":"jq is nice"},{"type":"tool_use","name":"Read","input":{"file_path":"/x"}}]}}
EOF

# 1. list
run list && ok "list exits 0" || bad "list exit $rc: $(cat "$T/err")"
# The header names the zone in force NOW, so the expected abbreviation follows today's DST state.
_pipe_out=$(head -1 "$T/out") && grep -qxF "# times local ($(date +%Z))" <<<"$_pipe_out" && ok "list header names the local zone" || bad "list header: $(head -1 "$T/out")"
[ "$(tail -1 "$T/out")" = "3 transcripts (1 app sessions, 1 local-only); archive: none ($T/archive)" ] && ok "list summary groups A+B by bridge id; archive dir absent is never silent" || bad "list summary: $(tail -1 "$T/out")"
grep -q "aaaaaaaa  cse_01AAAAAAAA .*Custom Title A *early bird$" "$T/out" \
  && ok "A: later custom-title beats ai-title; first prompt" || bad "A row: $(grep aaaaaaaa "$T/out" | head -1)"
_pipe_out=$(grep "^2026-09-23 23:30  09-24 00:36" "$T/out") && grep -q "aaaaaaaa" <<<"$_pipe_out" && ok "A first/last in local time" || bad "A times: $(grep -m1 aaaaaaaa "$T/out")"
grep -q "cccccccc  local " "$T/out" && ok "C shows app=local" || bad "C row"
grep -q "aaaaaaaa  cse_01AAAAAAAA      6 " "$T/out" && ok "A turn count ignores the nested \"type\":\"user\" inside a tool input" || bad "A turns: $(grep -m1 aaaaaaaa "$T/out")"
grep -q "cccccccc.*Session cccccccc… wrap-up" "$T/out" && ok "list title masks a full uuid embedded in message-derived text" || bad "title mask: $(grep -m1 cccccccc "$T/out")"
grep -q "eeeeeeee" "$T/out" && bad "a transcript with only non-mineable entries got a list row" || ok "non-mineable-only transcript has no list row"
grep -q "aaaaaaaa: 1 unparseable lines skipped" "$T/err" && ok "malformed line warned once, not fatal" || bad "malformed warning: $(cat "$T/err")"

# 2. --since is local midnight; --project
run list --since 2026-09-24 && _pipe_out=$(grep "aaaaaaaa" "$T/out") && grep -q "^2026-09-24 00:30 .* please fix the parser" <<<"$_pipe_out" \
  && ok "--since 2026-09-24 is local midnight (03:30Z out, 04:30Z in)" || bad "--since local: $(grep -m1 aaaaaaaa "$T/out")"
run list --since 2026-09-24T00:31 && grep -q "^2026-09-24 00:31 .*aaaaaaaa" "$T/out" && ! grep -q "please fix" "$T/out" \
  && ok "--since minute precision" || bad "--since minute: $(grep -m1 aaaaaaaa "$T/out")"
run list --until 2026-09-24T01:00 && [ "$(tail -1 "$T/out")" = "2 transcripts (1 app sessions, 0 local-only); archive: none ($T/archive)" ] \
  && ok "--until rounds up through the stated minute (B's 05:00Z entry is in)" || bad "--until: $(tail -1 "$T/out")"
run list --since today && [ "$(tail -1 "$T/out")" = "0 transcripts (0 app sessions, 0 local-only); archive: none ($T/archive)" ] && ok "--since today (fixtures are dated)" || bad "--since today: rc=$rc $(tail -1 "$T/out")"
run list --since yesterday --until yesterday && [ "$(tail -1 "$T/out")" = "0 transcripts (0 app sessions, 0 local-only); archive: none ($T/archive)" ] && ok "--since yesterday --until yesterday" || bad "yesterday: rc=$rc $(tail -1 "$T/out")"
run list --project BETA && [ "$(tail -1 "$T/out")" = "1 transcripts (0 app sessions, 1 local-only); archive: none ($T/archive)" ] \
  && ok "--project substring, case-insensitive" || bad "--project: $(tail -1 "$T/out")"
run list --app cse_01AAAA && [ "$(tail -1 "$T/out")" = "2 transcripts (1 app sessions, 0 local-only); archive: none ($T/archive)" ] \
  && ok "--app prefix" || bad "--app: $(tail -1 "$T/out")"
run list --since 2026-13-01; [ $rc = 2 ] && grep -q "YYYY-MM-DD" "$T/err" && ok "bad time exits 2 naming the forms" || bad "bad time: rc=$rc $(cat "$T/err")"

# 3. grep
run grep 'fix the parser' && grep -q "^2026-09-24 00:30  Projects-alpha  aaaaaaaa  user  please fix the parser$" "$T/out" \
  && [ "$(tail -1 "$T/out")" = "1 hits in 1 transcripts" ] && ok "grep default role finds owner text" || bad "grep user: $(cat "$T/out")"
run grep hiddenword; [ $rc = 1 ] && ok "grep skips <system-reminder> text" || bad "reminder leaked: $(cat "$T/out")"
run grep --raw hiddenword && ok "grep --raw searches reminder text" || bad "--raw"
run grep 'dash — phrase' && ok "grep matches decoded text (— written as \\u2014 on disk)" || bad "decoded match: $(cat "$T/out")"
run grep 'not that folder' && grep -q "aaaaaaaa  user\[mid-turn\]  wait, not that folder" "$T/out" && ok "queue enqueue hit is user[mid-turn]" || bad "mid-turn: $(cat "$T/out")"
run grep --role agent 'On it' && ok "--role agent finds assistant text" || bad "--role agent"
run grep --role agent 'fix the parser'; [ $rc = 1 ] && ok "--role agent skips user text and thinking" || bad "--role agent leaked: $(cat "$T/out")"
run grep --role agent 'nested marker' && grep -q "^2026-09-24 00:31  Projects-alpha  aaaaaaaa  agent  nested marker reply$" "$T/out" \
  && ok "type and timestamp come from the parsed entry, not the first raw token" || bad "nested agent: $(cat "$T/out")"
run grep 'nested marker'; [ $rc = 1 ] && ok "nested \"type\":\"user\" does not make the entry a user turn" || bad "nested user: $(cat "$T/out")"
run grep --max 0 turn; [ $rc = 2 ] && ok "--max 0 exits 2" || bad "--max 0 rc=$rc"
run grep --role tool 'grep -r foo' && grep -q "  tool  Bash {\"command\": \"grep -r foo ~\"}" "$T/out" && ok "--role tool finds a Bash command" || bad "--role tool: $(cat "$T/out")"
run grep --role tool 'broad-walk-guard' && ok "--role tool finds an errored tool result" || bad "tool error"
run grep nonexistentzzz; [ $rc = 1 ] && [ "$(tail -1 "$T/out")" = "0 hits in 0 transcripts" ] && ok "no hits exits 1" || bad "no hits: rc=$rc"
run grep -i 'FIX THE PARSER' && ok "-i ignores case" || bad "-i"
run grep --max 1 'second transcript turn|third turn' && [ "$(sed -n 3p "$T/out")" = "… 1 more hits (raise --max)" ] \
  && [ "$(tail -1 "$T/out")" = "2 hits in 1 transcripts" ] && ok "--max reports the hidden remainder" || bad "--max: $(cat "$T/out")"
run grep 'subagent only'; [ $rc = 1 ] && ok "subagent files skipped by default" || bad "subagent leaked"
run grep --subagents 'subagent only' && grep -q "  Projects-alpha/sub  agent-01  user  subagent only text" "$T/out" && ok "--subagents reads them as project/sub" || bad "--subagents: $(cat "$T/out")"
run grep --subagents --app cse_01AAAA 'subagent only' && ok "subagent hits inherit the parent's bridge id for --app" || bad "--subagents --app: $(cat "$T/out")"
run grep --subagents --app cse_01ZZZZ 'subagent only'; [ $rc = 1 ] && ok "--app still filters subagent hits" || bad "--subagents --app other: $(cat "$T/out")"
run grep --role user --since 2026-09-24T01:00 'turn' && [ "$(tail -1 "$T/out")" = "3 hits in 2 transcripts" ] && ok "grep honours --since" || bad "grep --since: $(cat "$T/out")"
run grep 'leaked-marker' && grep -q "leaked-marker cse_01AAAAAAAA… at /tmp/x/aaaaaaaa…/tasks/y.output done" "$T/out" \
  && ! grep -q -e "$A_ID" -e "$BRIDGE" "$T/out" && ok "grep snippet masks a full bridge id and uuid embedded in message text" \
  || bad "snippet mask: $(grep -m1 leaked-marker "$T/out")"
# The +-100-char window around 'clip-marker' lands 1 char inside each fixture uuid on either side;
# the snippet must widen past the clip so mask() sees (and shortens) the whole id, not almost all of it.
run grep --role agent 'clip-marker' && grep -q "^2026-09-24 00:35  Projects-alpha  aaaaaaaa  agent  11111111….*clip-marker.*99999999…$" "$T/out" \
  && ! grep -qF -- "${CLIP1:8}" "$T/out" && ! grep -qF -- "${CLIP2:8}" "$T/out" \
  && ok "grep snippet widens past a window boundary that lands mid-id" || bad "clip mask: $(grep -m1 clip-marker "$T/out")"

run ledger --project alpha && grep -q "; archive: none ($T/archive)" "$T/out" \
  && ok "ledger appends archive: none too, never silent, before the archive dir exists" || bad "ledger archive none: $(tail -1 "$T/out")"

# 3b. archive: a partial row (BRIDGE, duplicating A's and B's uuids plus two extra events) and a
# cloud-only row (ARCH_CLOUD, no local transcript ever)
mkdir -p "$T/archive"
cat > "$T/archive/$BRIDGE.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-24T04:30:00Z","uuid":"$U1","message":{"content":"please fix the parser"},"_session":"$BRIDGE","_title":"Archive Title A"}
{"type":"user","timestamp":"2026-09-24T05:00:00Z","uuid":"$U2","message":{"content":"second transcript turn"},"_session":"$BRIDGE","_title":"Archive Title A"}
{"type":"user","timestamp":"2026-09-24T04:37:00Z","uuid":"aaaaaaaa-a333-4000-8000-0000000000a3","message":{"content":"extra archive user only"},"_session":"$BRIDGE","_title":"Archive Title A"}
{"type":"assistant","_created_at":"2026-09-24T04:38:00.500000Z","uuid":"aaaaaaaa-a444-4000-8000-0000000000a4","message":{"content":[{"type":"text","text":"extra archive assistant only"}]},"_session":"$BRIDGE","_title":"Archive Title A"}
EOF
cat > "$T/archive/$ARCH_CLOUD.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-24T02:00:00Z","uuid":"bbbbbbbb-b555-4000-8000-0000000000b5","message":{"content":"cloud only owner message"},"_session":"$ARCH_CLOUD","_title":"Cloud Only Session"}
{"type":"assistant","timestamp":"2026-09-24T02:01:00Z","uuid":"bbbbbbbb-b666-4000-8000-0000000000b6","message":{"content":[{"type":"text","text":"cloud only agent reply"}]},"_session":"$ARCH_CLOUD","_title":"Cloud Only Session"}
EOF
# index.tsv covers ARCH_CLOUD only, with a DIFFERENT title than its _title lines: title must always
# come from the file's own _title (spec rule 1; the index can lag a manual rename), never the index's
# title column, so the index title must NOT appear anywhere and the _title must.
printf 'id\ttitle\tevents\tfirst\tlast\n%s\tSTALE INDEX TITLE, must not appear\t2\t2026-09-24T02:00\t2026-09-24T02:01\n' "$ARCH_CLOUD" > "$T/archive/index.tsv"

run list && [ "$(tail -1 "$T/out")" = "3 transcripts (1 app sessions, 1 local-only); archive: 2 rows (1 cloud/aged-out only, 1 partial)" ] \
  && ok "list summary counts a cloud-only and a partial (deduped) archive row" || bad "list archive summary: $(tail -1 "$T/out")"
grep -q "2026-09-24 00:37  09-24 00:38  claude.ai .*cse_01AAAAAAAA  cse_01AAAAAAAA      1 " "$T/out" \
  && ok "partial archive row's entries are exactly the 2 undeduped extras" || bad "partial row: $(grep claude.ai "$T/out")"
grep -q "2026-09-23 22:00  09-23 22:01  claude.ai .*cse_01BBBBBBBB  cse_01BBBBBBBB.*Cloud Only Session " "$T/out" \
  && ok "archive row title is the file's own _title" || bad "title: $(grep cse_01BBBBBBBB "$T/out")"
grep -q "STALE INDEX TITLE" "$T/out" && bad "index.tsv's title leaked: $(grep 'STALE INDEX' "$T/out")" \
  || ok "index.tsv's title column is never shown, even though it has an entry for this cse id"

run grep 'fix the parser' && [ "$(tail -1 "$T/out")" = "1 hits in 1 transcripts" ] \
  && ok "duplicated archive event (same uuid as A's) is dropped: still 1 hit, the local one" || bad "dup dedup: $(cat "$T/out")"
run grep 'second transcript turn' && [ "$(tail -1 "$T/out")" = "1 hits in 1 transcripts" ] \
  && ok "duplicated archive event (same uuid as B's) is dropped too" || bad "dup B dedup: $(cat "$T/out")"
run grep 'extra archive user only' && grep -q "^2026-09-24 00:37  claude.ai  cse_01AAAAAAAA  user  extra archive user only$" "$T/out" \
  && [ "$(tail -1 "$T/out")" = "1 hits in 1 transcripts" ] && ok "grep finds the undeduped archive-only user event" || bad "archive user hit: $(cat "$T/out")"
run grep --role agent 'extra archive assistant only' && grep -q "^2026-09-24 00:38  claude.ai  cse_01AAAAAAAA  agent  extra archive assistant only$" "$T/out" \
  && ok "grep finds the undeduped archive-only assistant event (timestamp from _created_at)" || bad "archive agent hit: $(cat "$T/out")"
run grep --role agent --since 2026-09-24T04:37:30Z 'extra archive assistant only' && ok "an event with only _created_at passes a --since its _created_at satisfies" \
  || bad "created_at --since: rc=$rc $(cat "$T/out" "$T/err")"

run list --no-archive && [ "$(tail -1 "$T/out")" = "3 transcripts (1 app sessions, 1 local-only)" ] \
  && ok "--no-archive: no suffix at all" || bad "list --no-archive: $(tail -1 "$T/out")"
run grep --no-archive 'extra archive user only'; [ $rc = 1 ] && ok "--no-archive: grep excludes archive hits" || bad "grep --no-archive: $(cat "$T/out")"

run list --project claude && [ "$(tail -1 "$T/out")" = "0 transcripts (0 app sessions, 0 local-only); archive: 2 rows (1 cloud/aged-out only, 1 partial)" ] \
  && ok "--project claude keeps archive rows only" || bad "--project claude: $(tail -1 "$T/out")"
# The uuid dedup set must come from ALL local files, not just ones --project would keep: --project
# claude keeps zero local files, so if dedup were scoped to them the partial row would un-drop its
# 2 duplicated entries (turn count 1 -> 3, and "please fix the parser" would resurface).
run list --project claude && grep -q "cse_01AAAAAAAA      1 " "$T/out" && ! grep -q "fix the parser" "$T/out" \
  && ok "--project claude still dedups using the FULL local uuid set, not a project-filtered one" || bad "dedup scope under --project: $(grep claude.ai "$T/out")"
run list --project alpha && [ "$(tail -1 "$T/out")" = "2 transcripts (1 app sessions, 0 local-only); archive: 0 rows (0 cloud/aged-out only, 0 partial)" ] \
  && ok "--project alpha drops archive rows" || bad "--project alpha: $(tail -1 "$T/out")"

# 3c. archive index/timestamp skew: index.tsv's first/last (derived from _created_at) can sit days
# away from the file's own event timestamps (a resumed/backfilled session). The window skip must
# still find this row for a --since/--until that matches its TIMESTAMPS, not its skewed index range.
SKEW=cse_01CCCCCCCCCCCCCCCCCCCCCC
cat > "$T/archive/$SKEW.jsonl" <<EOF
{"type":"user","timestamp":"2026-09-24T15:00:00Z","uuid":"cccccccc-c777-4000-8000-0000000000c7","message":{"content":"skewed session owner turn"},"_session":"$SKEW","_title":"Skewed Session"}
EOF
# index says this session ran 10 days later than its real timestamp (comfortably inside FIRST_SLACK's
# measured-plus-margin bound, but far outside the old 1-minute slack that missed the real bug).
printf '%s\tSkewed Session\t1\t2026-10-04T15:00\t2026-10-04T15:00\n' "$SKEW" >> "$T/archive/index.tsv"
run list --since 2026-09-24 --until 2026-09-25 && grep -q "cse_01CCCCCCCC" "$T/out" \
  && ok "a window matching the real timestamp still finds a row whose index is skewed 10 days later" \
  || bad "skew not found: $(cat "$T/out")"
run list --since 2026-10-03 --until 2026-10-05; grep -q "cse_01CCCCCCCC" "$T/out" \
  && bad "skewed row wrongly shown for a window matching only its skewed index, not its real timestamp" \
  || ok "a window matching only the skewed index (not the real timestamp) correctly excludes it"

# 4. mark
run mark --lens owner aaaaaaaa 2026-09-24T00:00 2026-09-24T01:00; [ $rc = 2 ] && [ "$(grep -c "^  aaaaaaaa  Projects-alpha$" "$T/err")" = 2 ] \
  && ok "ambiguous prefix exits 2 listing candidates" || bad "ambiguous: rc=$rc $(cat "$T/err")"
[ -e "$SESSION_LEDGER" ] && bad "ambiguous mark wrote the ledger" || ok "ambiguous mark wrote nothing"
run mark --lens owner cccccccc start end && grep -q "^marked  owner  cccccccc  local  Projects-beta  2026-09-24T06:00Z → 2026-09-24T06:01Z$" "$T/out" \
  && ok "8-char prefix resolves; start/end are the first/last entries" || bad "mark start/end: $(cat "$T/out" "$T/err")"
_pipe_out=$(head -1 "$SESSION_LEDGER") && grep -q "^# marked_at_utc	lens	transcript_id	app_id	slug	from_utc	to_utc	note$" <<<"$_pipe_out" && ok "ledger created with its header" || bad "ledger header: $(head -1 "$SESSION_LEDGER")"
_pipe_out=$(cut -f2-7 "$SESSION_LEDGER") && grep -q "^owner	$C_ID	-	-home-deck-Projects-beta	2026-09-24T06:00:00Z	2026-09-24T06:01:00Z$" <<<"$_pipe_out" && ok "ledger row has full ids and ISO UTC" || bad "ledger row: $(tail -1 "$SESSION_LEDGER")"
run mark --lens owner --note "tab	and
newline" aaaaaaaa-1111 2026-09-24T00:35 2026-09-24T00:35 && ok "minute-precision mark accepted" || bad "minute mark: $(cat "$T/err")"
_pipe_out=$(tail -1 "$SESSION_LEDGER") && grep -q "	tab and newline$" <<<"$_pipe_out" && ok "note tabs/newlines become spaces" || bad "note: $(tail -1 "$SESSION_LEDGER")"
run ledger --lens owner --project alpha && grep -q "^  aaaaaaaa  2026-09-24T03:30Z → 2026-09-24T04:36Z  [0-9]*K  owner: gaps 2026-09-24T03:30Z→2026-09-24T04:34Z, 2026-09-24T04:36Z→2026-09-24T04:36Z$" "$T/out" \
  && ok "minute-precision TO covers the entry at HH:MM:30" || bad "TO round-up: $(grep aaaaaaaa "$T/out")"
grep -q "no local transcript" "$T/out" && bad "C's mark shown as an orphan although C is on disk (filtered by --project): $(grep 'no local' "$T/out")" || ok "a filtered-out on-disk transcript's mark is not an orphan"
run mark --lens owner "$UNKNOWN" start end; [ $rc = 2 ] && grep -q "no transcript matches ffffffff…" "$T/err" && ok "unknown full id exits 2 with id8 only" || bad "unknown full id: rc=$rc $(cat "$T/err")"
run mark --lens owner cse_short 2026-09-24T02:00Z 2026-09-24T03:00Z; [ $rc = 2 ] && grep -q "24 letters or digits" "$T/err" && ok "malformed cse_ id exits 2 naming the shape" || bad "cse_ shape: rc=$rc $(cat "$T/err")"
run mark --lens owner --note "$(printf 'form\ffeed')" cccccccc start end && _pipe_out=$(tail -1 "$SESSION_LEDGER") && grep -q "	form feed$" <<<"$_pipe_out" && ok "note form feed becomes a space" || bad "note \\\\f: $(tail -1 "$SESSION_LEDGER" | od -c | tail -2)"
run mark --lens owner aaaaaaaa-1111 2026-09-24T01:00 2026-09-24T00:00; [ $rc = 2 ] && ok "FROM > TO exits 2" || bad "FROM>TO rc=$rc"
run mark --lens bogus aaaaaaaa-1111 start end; [ $rc = 2 ] && ok "unknown lens exits 2" || bad "bogus lens rc=$rc"
run mark --lens owner aaaaaaaa-1111 start 2026-09-24T00:30Z; [ $rc = 2 ] && ok "mark FROM > TO catches start vs an early TO" || bad "start>TO rc=$rc"
run mark --lens owner "$CLOUD" start end; [ $rc = 2 ] && ok "start/end refused for a cse_ target" || bad "cse start rc=$rc"
run mark --lens owner zzzzzzzz-0000 start end; [ $rc = 2 ] && ok "unknown transcript exits 2" || bad "unknown rc=$rc"
n0=$(grep -vc '^#' "$SESSION_LEDGER")
run mark --lens owner,agent aaaaaaaa-2222 2026-09-24T05:00Z 2026-09-24T05:01Z && [ "$(grep -vc '^#' "$SESSION_LEDGER")" = $((n0 + 2)) ] \
  && [ "$(grep -c '^marked  ' "$T/out")" = 2 ] && ok "--lens owner,agent writes and echoes two rows" || bad "two lenses: $(cat "$T/out")"
run mark --lens procedure "$CLOUD" 2026-09-24T02:00Z 2026-09-24T03:00Z && _pipe_out=$(tail -1 "$SESSION_LEDGER" | cut -f3-5) && grep -q "^-	$CLOUD	-$" <<<"$_pipe_out" \
  && grep -q "^marked  procedure  -  cse_01ZZZZZZZZ  -  2026-09-24T02:00Z → 2026-09-24T03:00Z$" "$T/out" && ok "cse_ target records transcript -" || bad "cse mark: $(tail -1 "$SESSION_LEDGER") / $(cat "$T/out")"

# 5. ledger (fresh ledger: A fully mined for owner, B partially, an aged-out transcript, a cloud mark, a malformed line)
export SESSION_LEDGER="$T/ledger5.tsv"
run mark --lens owner aaaaaaaa-1111 start end >/dev/null || bad "mark A"
run mark --lens owner aaaaaaaa-2222 2026-09-24T05:00Z 2026-09-24T05:01Z || bad "mark B"
run mark --lens agent "$CLOUD" 2026-09-24T02:00Z 2026-09-24T03:00Z || bad "mark cloud"
run mark --lens procedure aaaaaaaa-2222 2026-09-24T05:03Z 2026-09-24T07:00Z || bad "mark B procedure (span reaches past B's entries)"
printf '2026-09-25T00:00:00Z\towner\tdddddddd-4444-4000-8000-000000000004\t-\t-home-deck-Projects-alpha\t2026-09-20T00:00:00Z\t2026-09-20T01:00:00Z\told\n' >> "$SESSION_LEDGER"
printf 'this line is not a ledger row\n' >> "$SESSION_LEDGER"
printf '2026-09-25T00:00:00Z\tprocedure\t%s\t-\t-home-deck-Projects-beta\t2026-09-24T06:00:00Z\t2026-09-24T06:00:00Z\thand\frow\n' "$C_ID" >> "$SESSION_LEDGER"
run ledger && ok "ledger exits 0" || bad "ledger rc=$rc: $(cat "$T/err")"
[ "$(head -1 "$T/out")" = "# times UTC" ] && ok "ledger header says UTC" || bad "ledger header"
grep -q "^  aaaaaaaa  2026-09-24T03:30Z → 2026-09-24T04:36Z  [0-9]*K  owner: mined$" "$T/out" && ok "A owner: mined" || bad "A owner: $(grep '  aaaaaaaa  ' "$T/out")"
grep -q "^  aaaaaaaa  2026-09-24T05:00Z → 2026-09-24T05:03Z  [0-9]*K  owner: gaps 2026-09-24T05:02Z→2026-09-24T05:03Z$" "$T/out" && ok "B owner: gaps with exact entry bounds" || bad "B owner: $(grep '05:00Z' "$T/out")"
[ "$(grep -c "  agent: unmined$" "$T/out")" = 6 ] && ok "A, B, C, and all three archive rows agent: unmined" || bad "agent unmined count: $(grep -c 'agent: unmined' "$T/out")"
grep -q "^app cse_01AAAAAAAA  project Projects-alpha,claude.ai$" "$T/out" && grep -q "^local cccccccc  project Projects-beta$" "$T/out" && ok "groups: app header and local header" || bad "group headers: $(grep -v '^  ' "$T/out")"
grep -q "^  archive cse_01AAAAAAAA  2026-09-24T04:37Z → 2026-09-24T04:38Z  [0-9]*K  owner: unmined$" "$T/out" \
  && ok "BRIDGE's archive row joins A/B's app group, deduped entries only" || bad "archive row in app group: $(grep 'archive cse_01AAAA' "$T/out")"
grep -q "^app cse_01BBBBBBBB  project claude.ai$" "$T/out" \
  && grep -q "^  archive cse_01BBBBBBBB  2026-09-24T02:00Z → 2026-09-24T02:01Z  [0-9]*K  owner: unmined$" "$T/out" \
  && ok "the cloud-only archive row gets its own app group" || bad "cloud-only group: $(grep -A3 'cse_01BBBB' "$T/out")"
grep -q "^  dddddddd  (no local transcript)  owner marked 2026-09-20T00:00Z→2026-09-20T01:00Z$" "$T/out" && ok "aged-out transcript mark shown" || bad "aged-out: $(grep dddddddd "$T/out")"
grep -q "^app cse_01ZZZZZZZZ  project -$" "$T/out" && grep -q "^  -  (no local transcript)  agent marked 2026-09-24T02:00Z→2026-09-24T03:00Z$" "$T/out" && ok "cloud mark shown under its app group" || bad "cloud: $(grep -A1 ZZZZ "$T/out")"
[ "$(grep malformed "$T/err")" = "session-log: ledger line 7 malformed, skipped" ] && ok "malformed ledger line warned, rest rendered; a form feed inside a row does not split it" || bad "malformed ledger: $(cat "$T/err")"
grep -q "^  cccccccc  2026-09-24T06:00Z → 2026-09-24T06:01Z  [0-9]*K  procedure: gaps 2026-09-24T06:01Z→2026-09-24T06:01Z$" "$T/out" && ok "the hand row with a form feed is applied" || bad "hand row: $(grep '  cccccccc  ' "$T/out")"
grep -q "eeeeeeee" "$T/out" && bad "non-mineable-only transcript got a ledger row" || ok "non-mineable-only transcript has no ledger row"
[ "$(tail -1 "$T/out")" = "4 app sessions, 3 transcripts, 3 archive rows; unmined per lens: owner 5, agent 6, procedure 6" ] && ok "ledger summary counts include archive rows (SKEW's own group too)" || bad "ledger summary: $(tail -1 "$T/out")"
run ledger --app cse_01ZZZZ && grep -q "^  -  (no local transcript)  agent marked" "$T/out" && ! grep -q -e aaaaaaaa -e dddddddd -e cccccccc "$T/out" \
  && ok "--app shows the matching cloud mark only" || bad "--app orphan: $(cat "$T/out")"
run ledger --since 2026-09-25 && ! grep -q "no local transcript" "$T/out" && [ "$(tail -1 "$T/out")" = "0 app sessions, 0 transcripts, 0 archive rows; unmined per lens: owner 0, agent 0, procedure 0" ] \
  && ok "--since hides marks that end before the window, and the archive rows too (dated before it)" || bad "--since orphan: $(cat "$T/out")"
run ledger --since 2026-09-24T01:30 && ! grep -q "no local transcript" "$T/out" && [ "$(tail -1 "$T/out")" = "1 app sessions, 1 transcripts, 1 archive rows; unmined per lens: owner 2, agent 2, procedure 2" ] \
  && ok "an on-disk transcript outside the window is not an orphan even when its mark overlaps the window (SKEW's real timestamp is inside this window too)" || bad "window orphan: $(cat "$T/out")"
run ledger --unmined --lens owner && ! grep -q "owner: mined" "$T/out" && grep -q "owner: gaps" "$T/out" && ! grep -q "agent:" "$T/out" \
  && ok "--unmined --lens owner hides A and other lenses" || bad "--unmined: $(cat "$T/out")"
run ledger --project beta && [ "$(tail -1 "$T/out")" = "0 app sessions, 1 transcripts, 0 archive rows; unmined per lens: owner 1, agent 1, procedure 1" ] && ok "ledger honours --project (archive rows excluded too)" || bad "ledger --project: $(tail -1 "$T/out")"
grep -q "aaaaaaaa" "$T/out" && bad "A/B marks shown under --project beta: $(grep aaaaaaaa "$T/out")" || ok "filtered-out on-disk transcripts' marks are not orphans"

# 5b. mark --lens owner on a cse_ id backed by an archive file: start/end resolve, and once
# marked the cse mark is applied as the archive row's coverage instead of shown as an orphan
LEDGER6="$T/ledger6.tsv"
SESSION_LEDGER="$LEDGER6" run ledger --app cse_01BBBBBBBB && grep -q "^app cse_01BBBBBBBB  project claude.ai$" "$T/out" && grep -q "owner: unmined" "$T/out" \
  && ok "cloud-only archive row starts unmined in its own app group" || bad "pre-mark cloud ledger: $(cat "$T/out")"
SESSION_LEDGER="$LEDGER6" run mark --lens owner "$ARCH_CLOUD" start end && grep -q "^marked  owner  -  cse_01BBBBBBBB  -  2026-09-24T02:00Z → 2026-09-24T02:01Z$" "$T/out" \
  && ok "start/end resolve to the archive row's first/last event (after dedup)" || bad "cse start/end mark: $(cat "$T/out" "$T/err")"
SESSION_LEDGER="$LEDGER6" run ledger --app cse_01BBBBBBBB && grep -q "owner: mined" "$T/out" && ! grep -q "no local transcript" "$T/out" \
  && ok "the cse mark is applied as coverage, not shown as an orphan" || bad "post-mark cloud ledger: $(cat "$T/out")"

# 5c. stats and list --paths-to (own projects root, so no earlier count moves)
S_ID=bbbbbbbb-5555-4000-8000-000000000005
LEAKU=deadbeef-1234-4000-8000-000000000077
STATS="$T/stats-projects"; SDIR="$STATS/-home-deck-Projects-statsproj"
mkdir -p "$SDIR/$S_ID/subagents"
U='"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":'
cat > "$SDIR/$S_ID.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-10-01T16:00:01Z","requestId":"q1","message":{"id":"msg_o1","model":"claude-opus-5-5",$U 2},"content":[{"type":"tool_use","id":"tu_h1","name":"Bash","input":{"command":"git status"}}]}}
{"type":"user","timestamp":"2026-10-01T16:00:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_h1","is_error":true,"content":"PreToolUse:Bash hook error: [bash \"/h/run.sh\" python-heredoc-edit-guard]: blocked"}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:03Z","requestId":"q2","message":{"id":"msg_o2","model":"claude-opus-5-5",$U 3},"content":[{"type":"tool_use","id":"tu_h1b","name":"Bash","input":{"command":"SYG_ALLOW_RM=1 rm x"}}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:04Z","requestId":"q3","message":{"id":"msg_g1","model":"glm-5.3-flash",$U 11},"content":[{"type":"tool_use","id":"tu_h2","name":"Edit","input":{"file_path":"a"}}]}}
EOF
cat >> "$SDIR/$S_ID.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-10-01T16:00:05Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_h2","is_error":true,"content":[{"type":"text","text":"PreToolUse:Edit hook error: [cd \"${CLAUDE_PROJECT_DIR:-.}\" && .claude/hooks/pr-body-ref-gate.sh]: no"}]}]}}
EOF
cat >> "$SDIR/$S_ID.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-10-01T16:00:06Z","requestId":"q4","message":{"id":"msg_g2","model":"glm-5.3-flash",$U 2},"content":[{"type":"tool_use","id":"tu_r","name":"Read","input":{}}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:07Z","requestId":"q5","message":{"id":"msg_o3","model":"claude-opus-5-5",$U 1},"content":[{"type":"tool_use","id":"tu_den","name":"Bash","input":{"command":"x"}},{"type":"tool_use","id":"tu_miss","name":"Edit","input":{"file_path":"b"}},{"type":"tool_use","id":"tu_den2","name":"Read","input":{"file_path":"c"}}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:08Z","requestId":"q6","message":{"id":"gen-1","model":"z-ai/glm-5.3-flash",$U 5},"content":[{"type":"text","text":"thinking"}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:09Z","requestId":"q6","message":{"id":"gen-1","model":"z-ai/glm-5.3-flash",$U 40},"content":[{"type":"tool_use","id":"tu_un","name":"Bash","input":{"command":"y"}},{"type":"tool_use","id":"tu_exit","name":"Bash","input":{"command":"z"}}]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:10Z","message":{"id":"synthetic-x","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}
{"type":"user","timestamp":"2026-10-01T16:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_den","is_error":true,"content":"Permission denied by the Claude Code auto mode classifier. Reason: [Unauthorized Persistence] more"},{"type":"tool_result","tool_use_id":"tu_un","is_error":true,"content":"classifier is temporarily unavailable"},{"type":"tool_result","tool_use_id":"tu_miss","is_error":true,"content":"String to replace not found in file"},{"type":"tool_result","tool_use_id":"tu_den2","is_error":true,"content":"Permission denied by the Claude Code auto mode classifier. Reason: [User deny rule Read(/x/$LEAKU.jsonl)] end"},{"type":"tool_result","tool_use_id":"tu_exit","is_error":true,"content":"Exit code 1\nboom"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:12Z","message":{"content":"please continue"}}
{"type":"user","timestamp":"2026-10-01T16:00:12Z","message":{"content":"<task-notification>auto</task-notification>"}}
{"type":"user","timestamp":"2026-10-01T16:00:12Z","message":{"content":"<command-name>/effort</command-name>"}}
{"type":"assistant","timestamp":"2026-10-01T16:00:13Z","requestId":"q7","message":{"id":"msg_g3","model":"glm-5.3-flash",$U 4},"content":[{"type":"text","text":"ok"}]}}
{"type":"queue-operation","timestamp":"2026-10-01T16:00:14Z","operation":"enqueue","content":"<task-notification>done</task-notification>"}
{"type":"queue-operation","timestamp":"2026-10-01T16:00:15Z","operation":"enqueue","content":"plain note"}
{"type":"assistant","timestamp":"2026-10-01T16:00:16Z","requestId":"q8","message":{"id":"msg_o4","model":"claude-opus-5-5",$U 1},"content":[{"type":"text","text":"back"}]}}
EOF
cat > "$SDIR/$S_ID/subagents/agent-1.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-10-01T16:00:20Z","requestId":"q9","message":{"id":"msg_s1","model":"glm-5.3-flash",$U 6},"content":[{"type":"text","text":"sub"}]}}
{"type":"user","isSidechain":true,"timestamp":"2026-10-01T16:00:19Z","message":{"content":"dispatch prompt from the orchestrator"}}
EOF
S2_ID=cccccccc-6666-4000-8000-000000000006
cat > "$SDIR/$S2_ID.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-09-30T10:00:00Z","requestId":"qa","message":{"id":"mx-1","model":"mystery-1",$U 1},"content":[{"type":"tool_use","id":"tu_pre","name":"Bash","input":{"command":"p"}}]}}
{"type":"assistant","timestamp":"2026-09-30T10:00:01Z","requestId":"qb","message":{"id":"msg_y1","model":"glm-5.3-flash",$U 1},"content":[{"type":"tool_use","name":"Bash","input":{"command":"noid"}}]}}
{"type":"user","timestamp":"2026-10-01T17:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_pre","is_error":true,"content":"Exit code 2"}]}}
{"type":"user","timestamp":"2026-10-01T17:00:01Z","message":"not a dict"}
{"type":"assistant","timestamp":"2026-10-01T17:00:02Z","requestId":"qc","message":{"id":"mx-2","model":"mystery-1",$U 1},"content":[{"type":"tool_use","id":"tu_w1","name":"Write","input":{}},{"type":"tool_use","id":"tu_w2","name":"Write","input":{}}]}}
{"type":"user","timestamp":"2026-10-01T17:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_w1","is_error":true,"content":"PreToolUse:Write hook error: [bash \"/h/run.sh\" x-gate]: no"}]}}
{"type":"assistant","timestamp":"2026-10-01T17:00:04Z","requestId":"qd","message":{"id":"mx-3","model":"mystery-1",$U 1},"content":[{"type":"tool_use","id":"tu_rd","name":"Read","input":{}}]}}
{"type":"user","timestamp":"2026-10-01T17:00:05Z","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom2"}]}}
{"type":"assistant","timestamp":"2026-10-05T10:00:00Z","requestId":"qe","message":{"id":"msg_y2","model":"glm-5.3-flash",$U 1},"content":[{"type":"text","text":"after the window"}]}}
EOF
srun() { CLAUDE_PROJECTS_DIR="$STATS" run "$@"; }
srun stats --since 2026-10-01 --until 2026-10-01 --json && python3 -c 'import json,sys; json.load(sys.stdin)' < "$T/out" && ok "stats --json parses" || bad "stats --json: $(head -c 300 "$T/out" "$T/err")"
jq() { python3 -c 'import json,sys; d=json.load(sys.stdin); g={"|".join(x["key"]):x for x in d["groups"]}; print(eval(sys.argv[1]))' "$1" < "$T/out"; }
[ "$(jq 'sorted(g)')" = "['anthropic:claude-opus-5-5', 'openrouter:z-ai/glm-5.3-flash', 'unknown:mystery-1', 'zai:glm-5.3-flash']" ] \
  && ok "four lanes keyed by (model, id prefix); <synthetic> and the subagent file are not groups" || bad "lanes: $(jq 'sorted(g)')"
[ "$(jq '[g[k]["replies"] for k in sorted(g)]')" = "[4, 1, 2, 3]" ] && ok "replies per lane; the split gen- reply counts once; an assistant entry after --until is not counted" || bad "replies: $(jq '[g[k]["replies"] for k in sorted(g)]')"
[ "$(jq 'g["openrouter:z-ai/glm-5.3-flash"]["output_tokens"]')" = 40 ] && ok "split reply tokens deduped by (id, requestId): out 40, not 45" || bad "dedupe: $(jq 'g["openrouter:z-ai/glm-5.3-flash"]["output_tokens"]')"
[ "$(jq '[g["openrouter:z-ai/glm-5.3-flash"][k] for k in ("input_tokens","cache_read_input_tokens")]')" = "[10, 30]" ] && ok "input and cache fields are per-key maxima, not sums" || bad "input maxima"
[ "$(jq '{k.replace(chr(8230),"~"):v for k,v in g["anthropic:claude-opus-5-5"]["error_classes"].items()}')" = "{'hook:python-heredoc-edit-guard': 1, 'classifier-denied:Unauthorized Persistence': 1, 'edit-miss': 1, 'classifier-denied:User deny rule Read(/x/deadbeef~.jsonl)': 1}" ] \
  && ok "errors follow their tool_use's driver (run.sh-form hook, classifier denial, edit-miss on opus though an openrouter reply came last); a uuid in a classifier reason is masked to 8 chars" || bad "opus classes: $(jq 'g["anthropic:claude-opus-5-5"]["error_classes"]')"
[ "$(jq 'g["openrouter:z-ai/glm-5.3-flash"]["error_classes"]')" = "{'classifier-unavailable': 1, 'exit-code': 1}" ] && ok "classifier-unavailable and Exit code land on the openrouter lane" || bad "openrouter classes: $(jq 'g["openrouter:z-ai/glm-5.3-flash"]["error_classes"]')"
[ "$(jq 'g["zai:glm-5.3-flash"]["error_classes"]')" = "{'hook:pr-body-ref-gate': 1}" ] && ok "project-hook-form block names the hook (pr-body-ref-gate) on the zai lane" || bad "zai classes: $(jq 'g["zai:glm-5.3-flash"]["error_classes"]')"
[ "$(jq 'g["unknown:mystery-1"]["error_classes"]')" = "{'exit-code': 1, 'hook:x-gate': 1, 'other': 1}" ] \
  && ok "an error whose tool_use predates --since goes to that tool_use's driver (not the zai reply before it); a result with no tool_use_id is not matched to an id-less tool_use (previous driver)" || bad "mystery classes: $(jq 'g["unknown:mystery-1"]["error_classes"]')"
[ "$(jq 'g["zai:glm-5.3-flash"]["owner_turns"]')" = 2 ] && [ "$(jq 'g["anthropic:claude-opus-5-5"]["owner_turns"]')" = 0 ] && ok "owner turns (text and a <command-name> slash command, not the <task-notification> user entry) count under the next reply's driver (glm)" || bad "owner turn attribution: $(jq 'g["zai:glm-5.3-flash"]["owner_turns"]')"
[ "$(jq '[[g["anthropic:claude-opus-5-5"][k] for k in ("midturn_tagged","midturn_plain")], g["anthropic:claude-opus-5-5"]["midturn_tags"]]')" = "[[1, 1], {'task-notification': 1}]" ] && ok "task-notification enqueue is tagged, plain enqueue is plain" || bad "mid-turn"
[ "$(jq 'g["anthropic:claude-opus-5-5"]["bypass"]')" = "{'SYG_ALLOW_RM': 1}" ] && ok "SYG_ALLOW_RM= prefix counted once under its driver" || bad "bypass: $(jq 'g["anthropic:claude-opus-5-5"]["bypass"]')"
RETRIES="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["retries"])' < "$T/out")"
[ "$RETRIES" = "{'python-heredoc-edit-guard': {'blocks': 1, 'retried': 1, 'moved_on': 0}, 'pr-body-ref-gate': {'blocks': 1, 'retried': 0, 'moved_on': 1}, 'x-gate': {'blocks': 1, 'retried': 0, 'moved_on': 1}}" ] \
  && ok "hook block then the same tool in the next reply = retried; a different tool = moved_on (a same-name sibling call in the blocked message does not count); all three keys always present" || bad "retries: $RETRIES"
srun stats --since 2026-10-01 --until 2026-10-01 --subagents --json && [ "$(jq 'sorted(g)')" = "['anthropic:claude-opus-5-5', 'openrouter:z-ai/glm-5.3-flash', 'unknown:mystery-1', 'zai:glm-5.3-flash', 'zai:glm-5.3-flash/sub']" ] \
  && ok "--subagents adds the subagent file under a /sub key" || bad "subagents: $(jq 'sorted(g)')"
[ "$(jq 'g["zai:glm-5.3-flash/sub"]["owner_turns"]')" = 0 ] && ok "a subagent file's user entries (dispatch prompts) are not owner turns" || bad "sub owner turns: $(jq 'g["zai:glm-5.3-flash/sub"]["owner_turns"]')"
srun stats --since 2026-10-01 --until 2026-10-01 && grep -q "^anthropic:claude-opus-5-5  *4  *5  *4  *80.0  *0  *1/1" "$T/out" \
  && grep -q "^classifier-denied:Unauthorized Persistence  anthropic:claude-opus-5-5=1  total=1$" "$T/out" && grep -q "^python-heredoc-edit-guard  blocks=1 retried=1 moved_on=0$" "$T/out" \
  && [ "$(tail -1 "$T/out")" = "4 groups, 2 transcripts" ] && ok "text table: opus row, a class row, a retry row and the summary" || bad "text table: $(cat "$T/out")"
srun stats --since 2026-10-01 --until 2026-10-01 --by session && grep -q "^bbbbbbbb  *anthropic:claude-opus-5-5  " "$T/out" && ! grep -q "$S_ID" "$T/out" \
  && ok "--by session shows the 8-char id, never the full id" || bad "--by session: $(cat "$T/out")"
srun stats --since 2026-10-01 --until 2026-10-01 --by slug && grep -q "^Projects-statsproj  *anthropic:claude-opus-5-5  " "$T/out" && ok "--by slug groups by project and driver" || bad "--by slug: $(cat "$T/out")"
SHORT="$T/stats-short"; mkdir -p "$SHORT/-home-deck-ab"   # project "ab": shorter than the 7-char "project" header
printf '{"type":"assistant","timestamp":"2026-10-01T16:00:01Z","requestId":"q1","message":{"id":"msg_ab","model":"claude-opus-5-5","content":[]}}\n' > "$SHORT/-home-deck-ab/$S_ID.jsonl"
CLAUDE_PROJECTS_DIR="$SHORT" run stats --since 2026-10-01 --until 2026-10-01 --by slug && hdr=$(sed -n 2p "$T/out") && row=$(sed -n 3p "$T/out") \
  && [ "${row:0:2}" = ab ] && h_pre=${hdr%%driver*} && r_pre=${row%%anthropic:*} && [ ${#h_pre} = ${#r_pre} ] \
  && ok "--by slug with a 2-char project keeps header and data aligned (min width = header word)" || bad "short-project alignment: $(cat "$T/out")"
# A plugin hook block reported as "command hook <N>" is named by its banner title in the body (rule lines skipped);
# a body with no title falls back to the index. Own projects root, so no earlier count moves.
CMDH="$T/stats-cmdhook"; mkdir -p "$CMDH/-home-deck-cmdhook"
cat > "$CMDH/-home-deck-cmdhook/$S_ID.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-10-01T16:00:01Z","requestId":"c1","message":{"id":"msg_cmd1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tc1","name":"Bash","input":{"command":"a"}},{"type":"tool_use","id":"tc2","name":"Bash","input":{"command":"b"}},{"type":"tool_use","id":"tc3","name":"Bash","input":{"command":"c"}},{"type":"tool_use","id":"tc4","name":"Bash","input":{"command":"d"}},{"type":"tool_use","id":"tc5","name":"Bash","input":{"command":"e"}},{"type":"tool_use","id":"tc6","name":"Bash","input":{"command":"f"}},{"type":"tool_use","id":"tc7","name":"Bash","input":{"command":"g"}},{"type":"tool_use","id":"tc8","name":"Bash","input":{"command":"h"}},{"type":"tool_use","id":"tc9","name":"Bash","input":{"command":"i"}},{"type":"tool_use","id":"tc10","name":"Bash","input":{"command":"j"}},{"type":"tool_use","id":"tc11","name":"Bash","input":{"command":"k"}}]}}
{"type":"user","timestamp":"2026-10-01T16:00:02Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc1","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 11]: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nCWD-DRIFT GUARD — linked-worktree command blocked (warn-once)\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc2","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 6]: \n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nLOSSY PIPE GUARD — commit/push output filtered\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:04Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc3","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 11]: CWD-DRIFT GUARD — linked-worktree command blocked"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:05Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc4","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 7]: ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:06Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc5","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 8]: PYTHON-HEREDOC EDIT GUARD — inline script rewrites a file it reads"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:07Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc6","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 9]: EDIT_LOCK: reason text"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:08Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc7","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 10]: PATH - guard body"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:09Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc8","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 12]: === T ==="}]}}
{"type":"user","timestamp":"2026-10-01T16:00:10Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc9","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 13]: A / B guard"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc10","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 14]: QWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTYUIOPQWERTY"}]}}
{"type":"user","timestamp":"2026-10-01T16:00:12Z","message":{"content":[{"type":"tool_result","tool_use_id":"tc11","is_error":true,"content":"PreToolUse:Bash hook error: [command hook 15]: +++ ---"}]}}
EOF
CLAUDE_PROJECTS_DIR="$CMDH" run stats --since 2026-10-01 --until 2026-10-01 --json \
  && [ "$(jq 'dict(sorted(g["anthropic:claude-opus-5-5"]["error_classes"].items()))')" = "{'hook:15': 1, 'hook:7': 1, 'hook:a-b-guard': 1, 'hook:cwd-drift-guard': 2, 'hook:edit-lock': 1, 'hook:lossy-pipe-guard': 1, 'hook:path': 1, 'hook:python-heredoc-edit-guard': 1, 'hook:qwertyuiopqwertyuiopqwertyuiopqwertyuiopqwertyuiopqwertyuiop': 1, 'hook:t': 1}" ] \
  && ok "command hook <N> blocks are named by banner title (rule lines skipped, em dash, colon and dash cuts, underscores to dashes); a rules-only body falls back to the index" \
  || bad "command hook names: $(jq 'dict(sorted(g["anthropic:claude-opus-5-5"]["error_classes"].items()))') $(cat "$T/out")"
[ "$(python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["retries"]))' < "$T/out")" = "['15', '7', 'a-b-guard', 'cwd-drift-guard', 'edit-lock', 'lossy-pipe-guard', 'path', 'python-heredoc-edit-guard', 'qwertyuiopqwertyuiopqwertyuiopqwertyuiopqwertyuiopqwertyuiop', 't']" ] \
  && ok "retries keys carry the same names as the error classes" || bad "command hook retries keys: $(python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)["retries"]))' < "$T/out")"
# The usage key is (gk(drv), message.id, requestId): one (id, requestId) pair under two drivers stays two entries.
DUP="$T/stats-dup"; mkdir -p "$DUP/-home-deck-dup"
cat > "$DUP/-home-deck-dup/$S_ID.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-10-01T16:00:01Z","requestId":"qdup","message":{"id":"msg_dup","model":"claude-opus-5-5",$U 7},"content":[]}}
{"type":"assistant","timestamp":"2026-10-01T16:00:02Z","requestId":"qdup","message":{"id":"msg_dup","model":"glm-5.3-flash",$U 9},"content":[]}}
EOF
CLAUDE_PROJECTS_DIR="$DUP" run stats --since 2026-10-01 --until 2026-10-01 --json \
  && [ "$(jq '[g.get(k, {}).get("output_tokens") for k in ("anthropic:claude-opus-5-5", "zai:glm-5.3-flash")]')" = "[7, 9]" ] \
  && ok "a shared (message.id, requestId) under two drivers counts each driver's output_tokens separately (7 and 9)" \
  || bad "usage key scoping: $(jq '[g.get(k, {}).get("output_tokens") for k in ("anthropic:claude-opus-5-5", "zai:glm-5.3-flash")]')"
srun stats --since 2026-09-01 --until 2026-09-02; [ $rc = 1 ] && [ "$(tail -1 "$T/out")" = "0 groups, 0 transcripts" ] && ok "an empty window exits 1 with 0 groups, 0 transcripts" || bad "empty window rc=$rc: $(cat "$T/out")"
srun list --since 2026-10-01 --until 2026-10-01 --paths-to "$T/paths.txt" --no-archive && [ "$(tail -1 "$T/out")" = "paths: 2 written to $T/paths.txt" ] && [ "$(cat "$T/paths.txt")" = "$(printf '%s\n%s' "$SDIR/$S_ID.jsonl" "$SDIR/$S2_ID.jsonl")" ] \
  && grep -q "^2 transcripts" "$T/out" && ok "list --paths-to writes the full paths, and prints the paths: line after the summary" || bad "paths-to: $(cat "$T/out" "$T/paths.txt")"
run list --paths-to "$T/paths2.txt" && n=$(grep -o "^[0-9]* transcripts" "$T/out" | cut -d' ' -f1) && [ "$(wc -l < "$T/paths2.txt")" = "$n" ] && [ "$n" -ge 1 ] \
  && [ "$(grep -c 'archive' "$T/paths2.txt")" = 0 ] && ok "paths count matches the summary's transcript count (archive rows excluded)" || bad "paths count: $n / $(wc -l < "$T/paths2.txt")"
run list --paths-to "$T/no-such-dir/p.txt"; [ $rc = 2 ] && [ "$(grep -c '^session-log: cannot write ' "$T/err")" = 1 ] && ! grep -q Traceback "$T/err" && ok "an unwritable --paths-to exits 2 with a one-line message, no traceback" || bad "unwritable paths-to rc=$rc: $(cat "$T/err")"
grep -q -e "$S_ID" -e "$S2_ID" -e "msg_o1" -e "deadbeef-" "$ALL" && bad "stats leaked a full id, a message id or a partial uuid: $(grep -m1 -e "$S_ID" -e "$S2_ID" -e msg_o1 -e deadbeef- "$ALL")" || ok "no full transcript id, message id or uuid fragment past id8 in any stats output"
grep -q "deadbeef…" "$ALL" && ok "(leak check positive control: the masked uuid does appear)" || bad "masked-uuid positive control"

# 5d. ledger --extract-due
run ledger && cp "$T/out" "$T/ledger.before" || bad "ledger baseline before extract-due"
run ledger --extract-due && [ "$(cat "$T/out")" = "# extract-due  window 30d (default)" ] \
  && ok "extract-due: default 30d window, fresh mtimes exit 0 with header only" || bad "extract-due fresh: rc=$rc $(cat "$T/out")"
touch -d "-25 days" "$BETA/$C_ID.jsonl" "$BETA/$D_ID.jsonl"
run ledger --extract-due; [ $rc = 1 ] \
  && grep -q "^Projects-beta  cccccccc  25d  due-in 5d  owner  missing$" "$T/out" \
  && grep -q "^Projects-beta  cccccccc  25d  due-in 5d  agent  missing$" "$T/out" \
  && [ "$(wc -l < "$T/out")" = 3 ] \
  && ! grep -q -e procedure -e claude.ai -e eeeeeeee -e "beta project turn" "$T/out" \
  && ok "extract-due: transcript at age >= window-7 with no extract exits 1 with owner+agent missing rows only" \
  || bad "extract-due missing: rc=$rc $(cat "$T/out")"
touch -d "-10 days" "$BETA/$C_ID.jsonl"
run ledger --extract-due && [ "$(wc -l < "$T/out")" = 1 ] \
  && ok "extract-due purpose canary: same transcript mutated to age < window-7 exits 0 printing no rows" \
  || bad "extract-due <window-7: rc=$rc $(cat "$T/out")"
run ledger --extract-due --within 20; [ $rc = 1 ] \
  && grep -q "^Projects-beta  cccccccc  10d  due-in 20d  owner  missing$" "$T/out" \
  && ok "extract-due --within N widens the edge" || bad "extract-due --within: rc=$rc $(cat "$T/out")"
run ledger --extract-due --within -1; [ $rc = 2 ] && ok "extract-due --within < 0 exits 2" || bad "extract-due --within -1: rc=$rc"
touch -d "-25 days" "$BETA/$C_ID.jsonl"
mkdir -p "$T/.claude" && printf '{"cleanupPeriodDays": 45}\n' > "$T/.claude/settings.json"
run ledger --extract-due && [ "$(cat "$T/out")" = "# extract-due  window 45d (settings)" ] \
  && ok "extract-due reads cleanupPeriodDays from settings.json (25d < 45-7 exits 0)" \
  || bad "extract-due settings 25d: rc=$rc $(cat "$T/out")"
touch -d "-40 days" "$BETA/$C_ID.jsonl"
run ledger --extract-due; [ $rc = 1 ] && _pipe_out=$(head -1 "$T/out") && grep -q "window 45d (settings)" <<<"$_pipe_out" \
  && grep -q "^Projects-beta  cccccccc  40d  due-in 5d  owner  missing$" "$T/out" \
  && ok "extract-due with settings window 45d prints row at 40d" || bad "extract-due settings 40d: rc=$rc $(cat "$T/out")"
mkdir -p "$T/cfg" && printf '{"cleanupPeriodDays": 50}\n' > "$T/cfg/settings.json"
CLAUDE_CONFIG_DIR="$T/cfg" run ledger --extract-due && [ "$(cat "$T/out")" = "# extract-due  window 50d (settings)" ] \
  && ok "extract-due honors CLAUDE_CONFIG_DIR over HOME/.claude (40d < 50-7 exits 0)" \
  || bad "extract-due CLAUDE_CONFIG_DIR: rc=$rc $(cat "$T/out")"
touch -d "-25 days" "$BETA/$C_ID.jsonl"
for bad_days in true false 0 -5; do
  printf '{"cleanupPeriodDays": %s}\n' "$bad_days" > "$T/.claude/settings.json"
  run ledger --extract-due; [ $rc = 1 ] && [ "$(head -1 "$T/out")" = "# extract-due  window 30d (default)" ] \
    && ok "extract-due cleanupPeriodDays=$bad_days falls back to window 30d (default)" \
    || bad "extract-due cleanupPeriodDays=$bad_days: rc=$rc $(cat "$T/out")"
done
rm -f "$T/.claude/settings.json"
mkdir -p "$BETA/mined-corpus/corpus"
printf '=== 2026-09-24T06:00:00Z ===\nowner turn\n' > "$BETA/mined-corpus/corpus/$C_ID.txt"
printf '=== 2026-09-22T06:01:00Z [agent] ===\nold reply\n' > "$BETA/mined-corpus/corpus/$C_ID.agent.txt"
run ledger --extract-due; [ $rc = 1 ] \
  && [ "$(sed -n 2p "$T/out")" = "Projects-beta  cccccccc  25d  due-in 5d  agent  stale by 2d" ] \
  && [ "$(wc -l < "$T/out")" = 2 ] \
  && ok "extract-due hides fresh owner (<1h gap) and reports stale agent (stale by 2d)" \
  || bad "extract-due stale: rc=$rc $(cat "$T/out")"
printf '=== 2026-09-24T01:01:00Z [agent] ===\nfive hours old\n' > "$BETA/mined-corpus/corpus/$C_ID.agent.txt"
run ledger --extract-due; [ $rc = 1 ] \
  && [ "$(sed -n 2p "$T/out")" = "Projects-beta  cccccccc  25d  due-in 5d  agent  stale by 5h" ] \
  && [ "$(wc -l < "$T/out")" = 2 ] \
  && ok "extract-due reports hours when gap is in [1h, 24h) (stale by 5h)" \
  || bad "extract-due stale hours: rc=$rc $(cat "$T/out")"
printf '=== 2026-09-24T06:01:00Z [agent] ===\nfresh reply\n' > "$BETA/mined-corpus/corpus/$C_ID.agent.txt"
run ledger --extract-due && [ "$(wc -l < "$T/out")" = 1 ] \
  && ok "extract-due exits 0 when both extracts are fresh" || bad "extract-due both fresh: rc=$rc $(cat "$T/out")"
touch -d "-26 days" "$ALPHA/$B_ID.jsonl" && rm -f "$BETA/mined-corpus/corpus/$C_ID.agent.txt"
run ledger --extract-due; [ $rc = 1 ] \
  && [ "$(sed -n 2p "$T/out")" = "Projects-alpha  aaaaaaaa  26d  due-in 4d  owner  missing" ] \
  && [ "$(sed -n 3p "$T/out")" = "Projects-alpha  aaaaaaaa  26d  due-in 4d  agent  missing" ] \
  && [ "$(sed -n 4p "$T/out")" = "Projects-beta  cccccccc  25d  due-in 5d  agent  missing" ] \
  && ok "extract-due groups rows by slug" || bad "extract-due slug order: $(cat "$T/out")"
run ledger --extract-due --lens owner; [ $rc = 1 ] && [ "$(wc -l < "$T/out")" = 2 ] && grep -q "owner  missing$" "$T/out" && ! grep -q "  agent  " "$T/out" \
  && ok "extract-due --lens owner filters to owner" || bad "extract-due --lens: $(cat "$T/out")"
run ledger --extract-due --since 1d; [ $rc = 2 ] && grep -q "does not combine with --since/--until" "$T/err" \
  && ok "extract-due --since exits 2" || bad "extract-due --since: rc=$rc $(cat "$T/err")"
run ledger --extract-due --until 2026-09-25; [ $rc = 2 ] && grep -q "does not combine with --since/--until" "$T/err" \
  && ok "extract-due --until exits 2" || bad "extract-due --until: rc=$rc $(cat "$T/err")"
run ledger --extract-due --unmined; [ $rc = 2 ] && grep -q "does not combine with --unmined" "$T/err" \
  && ok "extract-due --unmined exits 2" || bad "extract-due --unmined: rc=$rc $(cat "$T/err")"
run ledger --within 5; [ $rc = 2 ] && grep -q -- "--within requires --extract-due" "$T/err" \
  && ok "ledger --within without --extract-due exits 2" || bad "ledger --within: rc=$rc $(cat "$T/err")"
run ledger --extract-due --lens procedure; [ $rc = 2 ] && grep -q "supports lenses: owner, agent" "$T/err" \
  && ok "extract-due --lens procedure exits 2" || bad "extract-due --lens procedure: rc=$rc $(cat "$T/err")"
printf '{"type":"assistant","timestamp":"2026-09-24T06:00:00Z","message":{"content":[{"type":"text","text":"reply only"}]}}\n' > "$BETA/$UNKNOWN.jsonl"
touch -d "-25 days" "$BETA/$UNKNOWN.jsonl"
run ledger --extract-due --project beta; [ $rc = 1 ] \
  && grep -q "^Projects-beta  ffffffff  25d  due-in 5d  agent  missing$" "$T/out" \
  && ! grep -q "ffffffff.*owner" "$T/out" \
  && ok "extract-due skips owner lens when transcript holds only assistant entries" \
  || bad "extract-due assistant-only: $(cat "$T/out")"
cat > "$BETA/$UNKNOWN.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-09-24T01:00:00Z","message":{"content":"last real prompt"}}
{"type":"assistant","timestamp":"2026-09-24T01:01:00Z","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","timestamp":"2026-09-24T06:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"file.txt"}]}}
{"type":"assistant","timestamp":"2026-09-24T06:01:00Z","message":{"content":[{"type":"text","text":"agent reply after tool result"}]}}
EOF
touch -d "-25 days" "$BETA/$UNKNOWN.jsonl"
printf '=== 2026-09-24T01:00:00Z ===\nlast real prompt\n' > "$BETA/mined-corpus/corpus/$UNKNOWN.txt"
printf '=== 2026-09-24T01:01:00Z [agent] ===\nearly reply\n' > "$BETA/mined-corpus/corpus/$UNKNOWN.agent.txt"
run ledger --extract-due --project beta; [ $rc = 1 ] \
  && grep -q "^Projects-beta  ffffffff  25d  due-in 5d  agent  stale by 5h$" "$T/out" \
  && ! grep -q "ffffffff.*owner" "$T/out" \
  && ok "extract-due: trailing tool_result user entry does not make owner stale; agent evaluated per its own predicate" \
  || bad "extract-due tool_result tail: $(cat "$T/out")"
printf '{"type":"assistant","timestamp":"2026-09-24T09:00:00Z","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Bash","input":{"command":"true"}}]}}\n' >> "$BETA/$UNKNOWN.jsonl"
touch -d "-25 days" "$BETA/$UNKNOWN.jsonl"
printf '=== 2026-09-24T01:01:00Z [agent] ===\nearly reply\n--- 2026-09-24T09:00:00Z tool Bash: true\n' > "$BETA/mined-corpus/corpus/$UNKNOWN.agent.txt"
run ledger --extract-due --project beta; [ $rc = 1 ] \
  && ! grep -q "ffffffff" "$T/out" \
  && ok "extract-due: tool_use-only assistant tail with --- <ts> stub after last === keeps agent fresh" \
  || bad "extract-due tool_use stub tail: $(cat "$T/out")"
printf 'stray text with no header lines\n' > "$BETA/mined-corpus/corpus/$UNKNOWN.agent.txt"
run ledger --extract-due --project beta; [ $rc = 1 ] \
  && grep -q "^Projects-beta  ffffffff  25d  due-in 5d  agent  missing$" "$T/out" \
  && ! grep -q "ffffffff.*owner" "$T/out" \
  && ok "extract-due: extract file with no === or --- headers is still missing" \
  || bad "extract-due headerless extract: $(cat "$T/out")"
rm -f "$BETA/$UNKNOWN.jsonl" "$BETA/mined-corpus/corpus/$UNKNOWN.txt" "$BETA/mined-corpus/corpus/$UNKNOWN.agent.txt"
run ledger && cmp -s "$T/ledger.before" "$T/out" \
  && ok "claim canary: default ledger output is byte-identical" || bad "default ledger drifted"

# 5e. asks (own projects root and archive dir, so earlier counts stay untouched)
ASKS_DIR="$T/asks-projects"; ASKS_ARCH="$T/asks-archive"
A_ALPHA="$ASKS_DIR/-home-deck-Projects-alpha"; A_BETA="$ASKS_DIR/-home-deck-Projects-beta"
mkdir -p "$A_ALPHA/$A_ID/subagents" "$A_BETA" "$ASKS_ARCH"
AUQ1=aaaaaaaa-d001-4000-8000-000000000001
BANG1=aaaaaaaa-d002-4000-8000-000000000002
DENY1=aaaaaaaa-d003-4000-8000-000000000003
PROSE1=aaaaaaaa-d004-4000-8000-000000000004
PROSE2=cccccccc-d005-4000-8000-000000000005
PROSE3=cccccccc-d006-4000-8000-000000000006
AUQ2=aaaaaaaa-d007-4000-8000-000000000007
AUQ_B=aaaaaaaa-d00a-4000-8000-00000000000a
AUQ_ERR=aaaaaaaa-d011-4000-8000-000000000011
AUQ4=aaaaaaaa-d00b-4000-8000-00000000000b
AUQ6=aaaaaaaa-d010-4000-8000-000000000010
PAD620=$(printf 'x%.0s' $(seq 1 620))
PAD390=$(printf 'context %.0s' $(seq 1 50))
cat > "$A_ALPHA/$A_ID.jsonl" <<EOF
{"type":"bridge-session","sessionId":"$A_ID","bridgeSessionId":"$BRIDGE"}
{"type":"assistant","timestamp":"2026-09-24T04:30:00Z","uuid":"$AUQ1","message":{"content":[{"type":"thinking","thinking":"! rm -rf /tmp/scratch-thinking\nShould I delete thinking?"},{"type":"tool_use","id":"tu_auq1","name":"AskUserQuestion","input":{"questions":[{"question":"Deploy to production now?"},{"question":"Target railway service?"}]}}]}}
{"type":"user","timestamp":"2026-09-24T04:30:10Z","isMeta":true,"message":{"content":"meta entry"}}
{"type":"user","timestamp":"2026-09-24T04:30:20Z","message":{"content":"<task-notification>worker done</task-notification>"}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T04:30:25Z","content":"<local-command-stdout>ok</local-command-stdout>"}
{"type":"user","timestamp":"2026-09-24T04:30:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ok","content":"Permission denied by classifier in non-error result"},{"type":"tool_result","tool_use_id":"tu_err_non_deny","is_error":true,"content":"Exit code 1\nnormal failure"}]}}
{"type":"user","timestamp":"2026-09-24T04:31:00Z","message":{"content":"yes, deploy to api"}}
{"type":"assistant","timestamp":"2026-09-24T04:32:00Z","uuid":"$BANG1","message":{"content":[{"type":"text","text":"Run this command:\n\`! safe-worktree-clean --apply-hold plan-1\`\nShould I delete it?"}]}}
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T04:32:45Z","content":"ran it, all clean"}
{"type":"user","timestamp":"2026-09-24T04:35:00Z","uuid":"$DENY1","message":{"content":[{"type":"tool_result","tool_use_id":"tu_d1","is_error":true,"content":"<system-reminder>remword</system-reminder>Permission to use Bash was denied by classifier: rm -rf /tmp/scratch/$A_ID/$BRIDGE"}]}}
{"type":"user","timestamp":"2026-09-24T04:35:30Z","uuid":"aaaaaaaa-d03b-4000-8000-00000000003b","message":{"content":[{"type":"tool_result","tool_use_id":"tu_d2","is_error":true,"content":"${PAD620}Permission denied by classifier past 600 chars"}]}}
{"type":"user","timestamp":"2026-09-24T04:36:00Z","uuid":"aaaaaaaa-d00e-4000-8000-00000000000e","message":{"content":[{"type":"tool_result","tool_use_id":"tu_av","is_error":true,"content":"Permission to use Bash was denied: classifier temporarily unavailable (rate-limited), retry"}]}}
{"type":"user","timestamp":"2026-09-24T04:36:30Z","uuid":"aaaaaaaa-d00f-4000-8000-00000000000f","message":{"content":[{"type":"tool_result","tool_use_id":"tu_ec","is_error":true,"content":"Exit code 1\noutput mentioned classifier twice but no denial here"}]}}
{"type":"user","timestamp":"2026-09-25T05:35:00Z","message":{"content":"back the next day"}}
{"type":"assistant","timestamp":"2026-09-25T05:36:00Z","uuid":"$PROSE1","message":{"content":[{"type":"text","text":"Rebase complete. Shall I force-push the branch?"}]}}
{"type":"assistant","timestamp":"2026-09-25T05:37:00Z","uuid":"aaaaaaaa-d00d-4000-8000-00000000000d","message":{"content":[{"type":"text","text":"Shall I reword the paragraph?"}]}}
{"type":"assistant","timestamp":"2026-09-25T05:38:00Z","uuid":"aaaaaaaa-d00c-4000-8000-00000000000c","message":{"content":[{"type":"tool_use","id":"tu_auq5","name":"AskUserQuestion","input":{"question":"Deploy now?"}}]}}
EOF
cat > "$A_ALPHA/$A_ID/subagents/agent-sub1.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-09-24T04:40:00Z","uuid":"aaaaaaaa-d999-4000-8000-000000000999","message":{"content":[{"type":"text","text":"Can I delete the subagent worktree?"}]}}
EOF
cat > "$A_ALPHA/$B_ID.jsonl" <<EOF
{"type":"bridge-session","sessionId":"$B_ID","bridgeSessionId":"$BRIDGE"}
{"type":"assistant","timestamp":"2026-09-25T06:00:00Z","uuid":"$AUQ_B","message":{"content":[{"type":"tool_use","id":"tu_auqb","name":"AskUserQuestion","input":{"questions":[{"question":"Deploy to production now?"},{"question":"Target railway service?"}]}}]}}
{"type":"user","timestamp":"2026-09-25T06:00:40Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_auqb","content":[{"type":"text","text":"api service"}]}]}}
{"type":"user","timestamp":"2026-09-25T06:01:00Z","message":{"content":"continuing in new transcript"}}
{"type":"assistant","timestamp":"2026-09-25T06:05:00Z","uuid":"$AUQ_ERR","message":{"content":[{"type":"tool_use","id":"tu_auqe","name":"AskUserQuestion","input":{"questions":[{"question":"Proceed with the retry?"}]}}]}}
{"type":"user","timestamp":"2026-09-25T06:05:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_auqe","is_error":true,"content":"tool errored out"}]}}
EOF
cat > "$A_BETA/$C_ID.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-09-25T07:00:00Z","uuid":"$PROSE2","message":{"content":[{"type":"text","text":"${PAD390}Can I merge the docs update?"}]}}
{"type":"user","timestamp":"2026-09-25T07:02:00Z","message":{"content":"go ahead"}}
{"type":"assistant","timestamp":"2026-09-25T07:05:00Z","uuid":"$PROSE3","message":{"content":[{"type":"text","text":"History rewritten. Ok to force-push now?"}]}}
{"type":"user","timestamp":"2026-09-25T07:05:30Z","message":{"content":"yes"}}
EOF
cat > "$ASKS_ARCH/$BRIDGE.jsonl" <<EOF
{"type":"assistant","timestamp":"2026-09-24T04:32:00Z","uuid":"$BANG1","message":{"content":[{"type":"text","text":"Run this command:\n\`! safe-worktree-clean --apply-hold plan-1\`\nShould I delete it?"}]},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"assistant","_created_at":"2026-09-25T08:00:00Z","uuid":"$AUQ2","message":{"content":[{"type":"tool_use","id":"tu_auq2","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it to prod env?"}]}}]},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"user","timestamp":"2026-09-25T08:03:00Z","uuid":"aaaaaaaa-d008-4000-8000-000000000008","message":{"content":"ship it"},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"assistant","timestamp":"2026-09-25T10:00:00Z","uuid":"$AUQ6","message":{"content":[{"type":"tool_use","id":"tu_auq6","name":"AskUserQuestion","input":{"questions":[{"question":"Clean the scratch dir?"}]}}]},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"user","timestamp":"2026-09-25T10:00:30Z","uuid":"aaaaaaaa-d03b-4000-8000-00000000003b","message":{"content":"done"},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"assistant","timestamp":"2026-09-25T11:00:00Z","uuid":"$AUQ4","message":{"content":[{"type":"tool_use","id":"tu_auq4","name":"AskUserQuestion","input":{"questions":[{"question":"Deploy docs now?"}]}}]},"_session":"$BRIDGE","_title":"Archive Asks"}
{"type":"user","_created_at":"2026-09-25T11:00:30Z","message":{"content":"on it"},"_session":"$BRIDGE","_title":"Archive Asks"}
EOF
arun() { CLAUDE_PROJECTS_DIR="$ASKS_DIR" CLAUDE_SESSION_ARCHIVE="$ASKS_ARCH" run "$@"; }

arun asks && [ "$(wc -l < "$T/out")" = 12 ] && ok "asks exits 0 and emits 12 deduped rows across local + archive" || bad "asks rows: rc=$rc $(cat "$T/out" "$T/err")"
arun asks --rows && [ "$(wc -l < "$T/out")" = 12 ] && ok "asks --rows matches default row output" || bad "asks --rows: rc=$rc $(cat "$T/out")"
[ "$(sed -n 1p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-24 00:30\tauq\tprod-deploy\t60\t0\ttext\tDeploy to production now? | Target railway service?')" ] \
  && ok "asks auq row: joins questions with ' | ', classifies prod-deploy, skips non-owner entries for wait_s=60" \
  || bad "asks row 1: $(sed -n 1p "$T/out")"
[ "$(sed -n 2p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-24 00:32\tbang\tworktree-removal\t45\t0\ttext\tRun this command: `! safe-worktree-clean --apply-hold plan-1` Should I delete it?')" ] \
  && ok "asks bang row: bang takes precedence over proseask on same block, pairs with mid-turn enqueue (wait_s=45)" \
  || bad "asks row 2: $(sed -n 2p "$T/out")"
[ "$(sed -n 3p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-24 00:35\tdeny\tscratch-delete\t90000\t1\ttext\tPermission to use Bash was denied by classifier: rm -rf /tmp/scratch/aaaaaaaa…/cse_01AAAAAAAA…')" ] \
  && ok "asks deny row: strips reminder, masks ids, classifies scratch-delete, wait_s=90000 sets expired=1" \
  || bad "asks row 3: $(sed -n 3p "$T/out")"
[ "$(sed -n 4p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-25 01:36\tproseask\tforce-push\t\t1\ttext\tRebase complete. Shall I force-push the branch?')" ] \
  && ok "asks proseask row: unanswered in same transcript has empty wait_s and expired=1 (no cross-transcript pairing)" \
  || bad "asks row 4: $(sed -n 4p "$T/out")"
[ "$(sed -n 5p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-25 01:38\tauq\tprod-deploy\t\t1\ttext\tDeploy now?')" ] \
  && ok "asks auq row: input.question fallback (no questions list) emits one row with the question text" \
  || bad "asks row 5: $(sed -n 5p "$T/out")"
[ "$(sed -n 6p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-25 02:00\tauq\tprod-deploy\t40\t0\ttext\tDeploy to production now? | Target railway service?')" ] \
  && ok "asks auq row: tool_result answer with the matching tool_use id resolves at the answer (wait_s=40), not the later plain owner turn (would be 60)" \
  || bad "asks row 6: $(sed -n 6p "$T/out")"
[ "$(sed -n 7p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-25 02:05\tauq\tother\t\t1\ttext\tProceed with the retry?')" ] \
  && ok "asks auq row: ERROR tool_result for the same tool_use id does not resolve - the owner never answered (empty wait_s, expired=1)" \
  || bad "asks row 7: $(sed -n 7p "$T/out")"
_r8=$(sed -n 8p "$T/out") && _r8_pre=$(printf '%s' "$_r8" | cut -f1-8) && _r8_txt=$(printf '%s' "$_r8" | cut -f9) \
  && [ "$_r8_pre" = "$(printf 'Projects-beta\tcccccccc\t2026-09-25 03:00\tproseask\tother\t120\t0\ttext')" ] \
  && [ "${#_r8_txt}" = 400 ] && [ "${_r8_txt:399:1}" = "…" ] \
  && ok "asks other category and 400-char text cut with ellipsis" \
  || bad "asks row 8: pre=$_r8_pre len=${#_r8_txt}"
[ "$(sed -n 9p "$T/out")" = "$(printf 'Projects-beta\tcccccccc\t2026-09-25 03:05\tproseask\tforce-push\t30\t0\ttext\tHistory rewritten. Ok to force-push now?')" ] \
  && ok "asks second force-push proseask row (wait_s=30)" \
  || bad "asks row 9: $(sed -n 9p "$T/out")"
[ "$(sed -n 10p "$T/out")" = "$(printf 'claude.ai\tcse_01AAAAAAAA\t2026-09-25 04:00\tauq\tprod-deploy\t\t1\ttext\tShip it to prod env?')" ] \
  && ok "asks archive row: _created_at-only ask carries no real clock, is never paired (empty wait_s, expired=1); archive dup of a local uuid stays suppressed" \
  || bad "asks row 10: $(sed -n 10p "$T/out")"
[ "$(sed -n 11p "$T/out")" = "$(printf 'claude.ai\tcse_01AAAAAAAA\t2026-09-25 06:00\tauq\tscratch-delete\t30\t0\ttext\tClean the scratch dir?')" ] \
  && ok "asks archive row: locally-duplicated owner turn still resolves the ask (wait_s=30) while the duplicate event itself stays suppressed" \
  || bad "asks row 11: $(sed -n 11p "$T/out")"
[ "$(sed -n 12p "$T/out")" = "$(printf 'claude.ai\tcse_01AAAAAAAA\t2026-09-25 07:00\tauq\tprod-deploy\t\t1\ttext\tDeploy docs now?')" ] \
  && ok "asks archive row answered by a _created_at-only owner entry: no real clock on the answer, the ask stays pending with no later real-clock event to pair (empty wait_s, expired=1; not the clock-mixed 30)" \
  || bad "asks row 12: $(sed -n 12p "$T/out")"
! grep -q -e "scratch-thinking" -e "delete thinking" -e "past 600 chars" -e "subagent worktree" -e "non-error result" "$T/out" \
  && ok "asks ignores thinking blocks, >600-char deny tail, non-error tool_result, and subagent files" \
  || bad "asks false positive: $(cat "$T/out")"
arun asks && ! grep -q "reword the paragraph" "$T/out" \
  && ok "asks proseask needs a destructive/cleanup/merge keyword: 'Shall I reword the paragraph?' is an ordinary question and emits no row" \
  || bad "asks proseask false positive: $(grep 'reword' "$T/out")"
arun asks && ! grep -q -e "temporarily unavailable" -e "mentioned classifier" "$T/out" \
  && ok "asks deny skips classifier-availability retry noise and bare-classifier echo text" \
  || bad "asks deny false positive: $(grep -e 'unavailable' -e 'classifier twice' "$T/out")"

arun asks --raw --kinds deny && grep -q "<system-reminder>remword</system-reminder>Permission" "$T/out" \
  && ok "asks --raw keeps <system-reminder> text while still masking ids" || bad "asks --raw: $(cat "$T/out")"
arun asks --no-text && [ "$(wc -l < "$T/out")" = 12 ] \
  && [ "$(sed -n 1p "$T/out")" = "$(printf 'Projects-alpha\taaaaaaaa\t2026-09-24 00:30\tauq\tprod-deploy\t60\t0\tstructural\t')" ] \
  && [ "$(cut -f8 "$T/out" | sort -u)" = "structural" ] && [ -z "$(cut -f9 "$T/out" | tr -d '\n')" ] \
  && ok "asks --no-text sets privacy=structural, empties text column, preserves categories" \
  || bad "asks --no-text: $(cat "$T/out")"
arun asks --no-archive && [ "$(wc -l < "$T/out")" = 9 ] && ! grep -q "^claude\.ai" "$T/out" \
  && ok "asks --no-archive drops archive rows" || bad "asks --no-archive: $(cat "$T/out")"
arun asks --project claude && [ "$(wc -l < "$T/out")" = 3 ] && grep -q "^claude\.ai	cse_01AAAAAAAA" "$T/out" \
  && ok "asks --project claude keeps archive rows only and still dedups against full local uuid set" \
  || bad "asks --project claude: $(cat "$T/out")"

arun asks --summary && [ "$(wc -l < "$T/out")" = 9 ] \
  && [ "$(sed -n 1p "$T/out")" = "$(printf 'kind\tcategory\tcount\tunanswered\texpired\tmedian_wait\tmax_wait')" ] \
  && [ "$(sed -n 2p "$T/out")" = "$(printf 'auq\tprod-deploy\t5\t3\t3\t50\t60')" ] \
  && [ "$(sed -n 3p "$T/out")" = "$(printf 'proseask\tforce-push\t2\t1\t1\t30\t30')" ] \
  && [ "$(sed -n 4p "$T/out")" = "$(printf 'auq\tother\t1\t1\t1\t\t')" ] \
  && [ "$(sed -n 5p "$T/out")" = "$(printf 'auq\tscratch-delete\t1\t0\t0\t30\t30')" ] \
  && [ "$(sed -n 6p "$T/out")" = "$(printf 'bang\tworktree-removal\t1\t0\t0\t45\t45')" ] \
  && [ "$(sed -n 7p "$T/out")" = "$(printf 'deny\tscratch-delete\t1\t0\t1\t90000\t90000')" ] \
  && [ "$(sed -n 8p "$T/out")" = "$(printf 'proseask\tother\t1\t0\t0\t120\t120')" ] \
  && [ "$(sed -n 9p "$T/out")" = "$(printf 'TOTAL\t\t12\t5\t6\t45\t90000')" ] \
  && ok "asks --summary prints sorted kind*category aggregate table plus TOTAL instead of rows" \
  || bad "asks --summary: $(cat "$T/out")"

arun asks --summary --kinds proseask --category force-push --until 2026-09-25T02:00 \
  && [ "$(sed -n 2p "$T/out")" = "$(printf 'proseask\tforce-push\t1\t1\t1\t\t')" ] \
  && [ "$(sed -n 3p "$T/out")" = "$(printf 'TOTAL\t\t1\t1\t1\t\t')" ] \
  && ok "asks --summary with only unanswered rows leaves median_wait/max_wait empty" \
  || bad "asks --summary unanswered: $(cat "$T/out")"

arun asks --json && python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["total"] == 12 and len(d["rows"]) == 12 and len(d["summary"]) == 7, d
r0, r3 = d["rows"][0], d["rows"][3]
assert r0["kind"] == "auq" and r0["category"] == "prod-deploy" and r0["wait_s"] == 60 and r0["expired"] == 0 and r0["privacy"] == "text", r0
assert r3["wait_s"] is None and r3["expired"] == 1, r3
s0, s1 = d["summary"][0], d["summary"][1]
assert s0 == {"kind": "auq", "category": "prod-deploy", "count": 5, "unanswered": 3, "expired": 3, "median_wait": 50, "max_wait": 60}, s0
assert s1 == {"kind": "proseask", "category": "force-push", "count": 2, "unanswered": 1, "expired": 1, "median_wait": 30, "max_wait": 30}, s1
' < "$T/out" && ok "asks --json emits rows, summary and total with null for unknown wait_s" || bad "asks --json: $(cat "$T/out" "$T/err")"

arun asks --json --no-text --kinds proseask --category force-push --until 2026-09-25T02:00 && python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["total"] == 1 and len(d["rows"]) == 1, d
r = d["rows"][0]
assert r["privacy"] == "structural" and r["text"] is None and r["wait_s"] is None, r
s = d["summary"][0]
assert s["median_wait"] is None and s["max_wait"] is None and s["unanswered"] == 1, s
' < "$T/out" && ok "asks --json --no-text sets text=null and unknown median_wait/max_wait=null" || bad "asks --json --no-text: $(cat "$T/out" "$T/err")"

arun asks --kinds auq,bang && [ "$(wc -l < "$T/out")" = 8 ] && ok "asks --kinds filters comma-separated kinds" || bad "asks --kinds: $(cat "$T/out")"
arun asks --category prod-deploy,scratch-delete && [ "$(wc -l < "$T/out")" = 7 ] && ok "asks --category filters comma-separated categories" || bad "asks --category: $(cat "$T/out")"
arun asks --max 2 && [ "$(wc -l < "$T/out")" = 2 ] && [ "$(cat "$T/err")" = "session-log: 10 more suppressed" ] \
  && ok "asks --max caps printed rows and warns 'N more suppressed' to stderr" || bad "asks --max: out=$(wc -l < "$T/out") err=$(cat "$T/err")"
arun asks --max 2 --summary && [ "$(wc -l < "$T/out")" = 9 ] && [ ! -s "$T/err" ] \
  && ok "asks --max never caps --summary and emits no suppression warning" || bad "asks --max --summary: $(cat "$T/out" "$T/err")"
arun asks --max 2 --json && python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["rows"]) == 2 and d["total"] == 12 and len(d["summary"]) == 7, d
' < "$T/out" && [ "$(cat "$T/err")" = "session-log: 10 more suppressed" ] \
  && ok "asks --max --json caps rows only, leaving summary and total uncapped" || bad "asks --max --json: $(cat "$T/out" "$T/err")"

arun asks --since 2026-09-26; [ $rc = 1 ] && [ ! -s "$T/out" ] && ok "asks with no matching rows exits 1" || bad "asks empty: rc=$rc $(cat "$T/out")"
arun asks --kinds bogus; [ $rc = 2 ] && grep -q "unknown kind" "$T/err" && ok "asks unknown --kinds exits 2" || bad "asks bogus kind: rc=$rc $(cat "$T/err")"
arun asks --category bogus; [ $rc = 2 ] && grep -q "unknown category" "$T/err" && ok "asks unknown --category exits 2" || bad "asks bogus category: rc=$rc $(cat "$T/err")"
arun asks --max 0; [ $rc = 2 ] && grep -q -- "--max must be at least 1" "$T/err" && ok "asks --max 0 exits 2" || bad "asks --max 0: rc=$rc $(cat "$T/err")"

# 6. no full ids anywhere
grep -q -e "$A_ID" -e "$B_ID" -e "$C_ID" -e "$D_ID" -e "$UNKNOWN" -e "$BRIDGE" -e "$CLOUD" -e "$ARCH_CLOUD" -e "$SKEW" "$ALL" \
  && bad "a full transcript or bridge id leaked: $(grep -m1 -e "$A_ID" -e "$B_ID" -e "$C_ID" -e "$D_ID" -e "$UNKNOWN" -e "$BRIDGE" -e "$CLOUD" -e "$ARCH_CLOUD" -e "$SKEW" "$ALL")" \
  || ok "no full transcript/bridge/archive id in any output"
grep -q "cse_01AAAAAAAA" "$ALL" && ok "(leak check positive control: the short app id does appear)" || bad "leak check positive control"
grep -q "cse_01BBBBBBBB" "$ALL" && ok "(leak check positive control: the short archive cse id does appear)" || bad "archive leak check positive control"

# 7. help / usage
run --help; [ $rc = 0 ] && grep -q "^Usage:" "$T/out" && grep -q -- "--extract-due" "$T/out" && grep -q "mtime-approximated" "$T/out" && grep -q "session-log asks" "$T/out" \
  && ok "--help exits 0 with Usage, asks and --extract-due notes" || bad "--help rc=$rc"
run grep -h; [ $rc = 0 ] && grep -q "^Usage:" "$T/out" && ok "verb -h exits 0 with Usage" || bad "grep -h rc=$rc"
run bogus; [ $rc = 2 ] && ok "unknown verb exits 2" || bad "unknown verb rc=$rc"
run grep; [ $rc = 2 ] && ok "grep without a pattern exits 2" || bad "grep no pattern rc=$rc"
exit $fail
