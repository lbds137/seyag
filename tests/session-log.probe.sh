#!/bin/bash
# Fixture check for bin/session-log against a synthetic projects root and ledger.
# Usage: tests/session-log.probe.sh   (from anywhere)
# Fixture clock: TZ=America/New_York (EDT, UTC-4), so local 2026-09-24 starts at 04:00Z.

set -uo pipefail
SL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/session-log"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TZ=America/New_York CLAUDE_PROJECTS_DIR="$T/projects" SESSION_LEDGER="$T/ledger.tsv" CLAUDE_SESSION_ARCHIVE="$T/archive" PYTHONDONTWRITEBYTECODE=1
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
head -1 "$T/out" | grep -q '^# times local (EDT)$' && ok "list header names the local zone" || bad "list header: $(head -1 "$T/out")"
[ "$(tail -1 "$T/out")" = "3 transcripts (1 app sessions, 1 local-only); archive: none ($T/archive)" ] && ok "list summary groups A+B by bridge id; archive dir absent is never silent" || bad "list summary: $(tail -1 "$T/out")"
grep -q "aaaaaaaa  cse_01AAAAAAAA .*Custom Title A *early bird$" "$T/out" \
  && ok "A: later custom-title beats ai-title; first prompt" || bad "A row: $(grep aaaaaaaa "$T/out" | head -1)"
grep "^2026-09-23 23:30  09-24 00:36" "$T/out" | grep -q "aaaaaaaa" && ok "A first/last in local time" || bad "A times: $(grep -m1 aaaaaaaa "$T/out")"
grep -q "cccccccc  local " "$T/out" && ok "C shows app=local" || bad "C row"
grep -q "aaaaaaaa  cse_01AAAAAAAA      6 " "$T/out" && ok "A turn count ignores the nested \"type\":\"user\" inside a tool input" || bad "A turns: $(grep -m1 aaaaaaaa "$T/out")"
grep -q "cccccccc.*Session cccccccc… wrap-up" "$T/out" && ok "list title masks a full uuid embedded in message-derived text" || bad "title mask: $(grep -m1 cccccccc "$T/out")"
grep -q "eeeeeeee" "$T/out" && bad "a transcript with only non-mineable entries got a list row" || ok "non-mineable-only transcript has no list row"
grep -q "aaaaaaaa: 1 unparseable lines skipped" "$T/err" && ok "malformed line warned once, not fatal" || bad "malformed warning: $(cat "$T/err")"

# 2. --since is local midnight; --project
run list --since 2026-09-24 && grep "aaaaaaaa" "$T/out" | grep -q "^2026-09-24 00:30 .* please fix the parser" \
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
head -1 "$SESSION_LEDGER" | grep -q "^# marked_at_utc	lens	transcript_id	app_id	slug	from_utc	to_utc	note$" && ok "ledger created with its header" || bad "ledger header: $(head -1 "$SESSION_LEDGER")"
cut -f2-7 "$SESSION_LEDGER" | grep -q "^owner	$C_ID	-	-home-deck-Projects-beta	2026-09-24T06:00:00Z	2026-09-24T06:01:00Z$" && ok "ledger row has full ids and ISO UTC" || bad "ledger row: $(tail -1 "$SESSION_LEDGER")"
run mark --lens owner --note "tab	and
newline" aaaaaaaa-1111 2026-09-24T00:35 2026-09-24T00:35 && ok "minute-precision mark accepted" || bad "minute mark: $(cat "$T/err")"
tail -1 "$SESSION_LEDGER" | grep -q "	tab and newline$" && ok "note tabs/newlines become spaces" || bad "note: $(tail -1 "$SESSION_LEDGER")"
run ledger --lens owner --project alpha && grep -q "^  aaaaaaaa  2026-09-24T03:30Z → 2026-09-24T04:36Z  [0-9]*K  owner: gaps 2026-09-24T03:30Z→2026-09-24T04:34Z, 2026-09-24T04:36Z→2026-09-24T04:36Z$" "$T/out" \
  && ok "minute-precision TO covers the entry at HH:MM:30" || bad "TO round-up: $(grep aaaaaaaa "$T/out")"
grep -q "no local transcript" "$T/out" && bad "C's mark shown as an orphan although C is on disk (filtered by --project): $(grep 'no local' "$T/out")" || ok "a filtered-out on-disk transcript's mark is not an orphan"
run mark --lens owner "$UNKNOWN" start end; [ $rc = 2 ] && grep -q "no transcript matches ffffffff…" "$T/err" && ok "unknown full id exits 2 with id8 only" || bad "unknown full id: rc=$rc $(cat "$T/err")"
run mark --lens owner cse_short 2026-09-24T02:00Z 2026-09-24T03:00Z; [ $rc = 2 ] && grep -q "24 letters or digits" "$T/err" && ok "malformed cse_ id exits 2 naming the shape" || bad "cse_ shape: rc=$rc $(cat "$T/err")"
run mark --lens owner --note "$(printf 'form\ffeed')" cccccccc start end && tail -1 "$SESSION_LEDGER" | grep -q "	form feed$" && ok "note form feed becomes a space" || bad "note \\\\f: $(tail -1 "$SESSION_LEDGER" | od -c | tail -2)"
run mark --lens owner aaaaaaaa-1111 2026-09-24T01:00 2026-09-24T00:00; [ $rc = 2 ] && ok "FROM > TO exits 2" || bad "FROM>TO rc=$rc"
run mark --lens bogus aaaaaaaa-1111 start end; [ $rc = 2 ] && ok "unknown lens exits 2" || bad "bogus lens rc=$rc"
run mark --lens owner aaaaaaaa-1111 start 2026-09-24T00:30Z; [ $rc = 2 ] && ok "mark FROM > TO catches start vs an early TO" || bad "start>TO rc=$rc"
run mark --lens owner "$CLOUD" start end; [ $rc = 2 ] && ok "start/end refused for a cse_ target" || bad "cse start rc=$rc"
run mark --lens owner zzzzzzzz-0000 start end; [ $rc = 2 ] && ok "unknown transcript exits 2" || bad "unknown rc=$rc"
n0=$(grep -vc '^#' "$SESSION_LEDGER")
run mark --lens owner,agent aaaaaaaa-2222 2026-09-24T05:00Z 2026-09-24T05:01Z && [ "$(grep -vc '^#' "$SESSION_LEDGER")" = $((n0 + 2)) ] \
  && [ "$(grep -c '^marked  ' "$T/out")" = 2 ] && ok "--lens owner,agent writes and echoes two rows" || bad "two lenses: $(cat "$T/out")"
run mark --lens procedure "$CLOUD" 2026-09-24T02:00Z 2026-09-24T03:00Z && tail -1 "$SESSION_LEDGER" | cut -f3-5 | grep -q "^-	$CLOUD	-$" \
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

# 6. no full ids anywhere
grep -q -e "$A_ID" -e "$B_ID" -e "$C_ID" -e "$D_ID" -e "$UNKNOWN" -e "$BRIDGE" -e "$CLOUD" -e "$ARCH_CLOUD" -e "$SKEW" "$ALL" \
  && bad "a full transcript or bridge id leaked: $(grep -m1 -e "$A_ID" -e "$B_ID" -e "$C_ID" -e "$D_ID" -e "$UNKNOWN" -e "$BRIDGE" -e "$CLOUD" -e "$ARCH_CLOUD" -e "$SKEW" "$ALL")" \
  || ok "no full transcript/bridge/archive id in any output"
grep -q "cse_01AAAAAAAA" "$ALL" && ok "(leak check positive control: the short app id does appear)" || bad "leak check positive control"
grep -q "cse_01BBBBBBBB" "$ALL" && ok "(leak check positive control: the short archive cse id does appear)" || bad "archive leak check positive control"

# 7. help / usage
run --help; [ $rc = 0 ] && grep -q "^Usage:" "$T/out" && ok "--help exits 0 with Usage" || bad "--help rc=$rc"
run grep -h; [ $rc = 0 ] && grep -q "^Usage:" "$T/out" && ok "verb -h exits 0 with Usage" || bad "grep -h rc=$rc"
run bogus; [ $rc = 2 ] && ok "unknown verb exits 2" || bad "unknown verb rc=$rc"
run grep; [ $rc = 2 ] && ok "grep without a pattern exits 2" || bad "grep no pattern rc=$rc"
exit $fail
