#!/bin/bash
# Fixture check for plugins/seyag/bin/api-credit: the route rule (SYG_CREDIT_WHEN,
# else the metered API-key test), the transcript recorder behind `hook` (streaming
# dedupe, subagent transcripts, UTC day split, pricing incl. 1h vs 5m cache writes,
# unpriced models, idempotence, cross-session dedupe, old-format entries, garbage
# lines, concurrency), the read-only `statusline`, the FIFO-by-expiry balance
# estimate and the daily view, and the provider balance (Admin API cost_report:
# window, pagination, ledger bridge, TTL and failure caching, labeled fallback)
# against a loopback mock server with a fixture admin key (SYG_CREDIT_ADMIN_URL).
# Hermetic: HOME and every SYG_CREDIT_* / ANTHROPIC_* variable are set per call
# (env -i); transcripts are invented fixtures; the price table is a stub script
# (SYG_CREDIT_PRICE_TABLE_CMD); all paths are under one temp dir.
# Usage: tests/api-credit.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AC="${API_CREDIT_BIN:-$REPO/plugins/seyag/bin/api-credit}"
[ -f "$AC" ] || { echo "api-credit.probe: no api-credit at $AC"; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

export PYTHONDONTWRITEBYTECODE=1
G="$T/grants.json"
P="$T/proj"   # the fixture project dir holding transcripts
mkdir -p "$P"

# Price table stub (USD per million tokens). m-b has a row; m-b[1m] resolves to it.
cat > "$T/prices.json" <<'EOF'
{"or_keys":[],"table":{
 "m-a":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25},
 "m-b":{"input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75}}}
EOF
# Each call appends a line to pt-calls, so a probe can count price-table runs.
printf '#!/bin/bash\n[ "$1" = --json ] || exit 9\necho x >> %q\ncat %q\n' "$T/pt-calls" "$T/prices.json" > "$T/pt.sh"
printf '#!/bin/bash\nexit 3\n' > "$T/pt-fail.sh"
chmod +x "$T/pt.sh" "$T/pt-fail.sh"

# ac [VAR=value ...] -- args: a clean environment plus the given variables.
ac() {
  local vars=()
  while [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  env -i PATH="$PATH" HOME="$T" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt.sh" "${vars[@]}" python3 -B "$AC" "$@"
}
# uline MSGID REQID MODEL TS IN OUT [CACHE_READ W5M W1H EXTRA]: one assistant usage line.
uline() {
  printf '{"type":"assistant","timestamp":"%s","requestId":"%s","message":{"model":"%s","id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s}%s}}}\n' \
    "$4" "$2" "$3" "$1" "$5" "$6" "${7:-0}" "$(( ${8:-0} + ${9:-0} ))" "${8:-0}" "${9:-0}" "${10:-}"
}
# payload SESSION: the Stop hook JSON for a session whose transcript is $P/SESSION.jsonl.
payload() { printf '{"session_id":"%s","transcript_path":"%s/%s.jsonl","hook_event_name":"Stop"}' "$1" "$P" "$1"; }
# hk SESSION LEDGER [VAR=value ...]: run the hook for SESSION, force-metered.
hk() {
  local s=$1 l=$2; shift 2
  payload "$s" | ac SYG_CREDIT_FORCE=1 SYG_CREDIT_LEDGER="$l" "$@" -- hook
}
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if (d<0) d=-d; exit !(d<0.000001)}'; }
nlines() { wc -l < "$1" | tr -d ' '; }
M=1000000
D1=2026-10-10
D2=2026-10-11

# A plain one-request transcript for the route cases.
uline msg-r req-r m-a ${D1}T10:00:00Z $M 0 > "$P/R.jsonl"
# rt LEDGER-DIR [VAR=value ...]: run the hook for R under exactly these variables (no force).
rt() { local d=$1; shift; payload R | ac SYG_CREDIT_LEDGER="$T/$d/l.jsonl" "$@" -- hook 2>&1; }

# 1. Route rules.
out=$(rt w1 SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered)
[ -z "$out" ] && [ -s "$T/w1/l.jsonl" ] && ok "route: SYG_CREDIT_WHEN matches -> ledger written, no output" || bad "WHEN match: '$out'"
out=$(rt w2 SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=other ANTHROPIC_API_KEY=sk-probe)
[ -z "$out" ] && [ ! -e "$T/w2/l.jsonl" ] && ok "route: SYG_CREDIT_WHEN mismatch -> nothing, even with an API key" || bad "WHEN mismatch: '$out'"
out=$(rt w3 SYG_CREDIT_WHEN=MY_ROUTE MY_ROUTE=MY_ROUTE ANTHROPIC_API_KEY=sk-probe)
[ -z "$out" ] && [ ! -e "$T/w3/l.jsonl" ] && ok "route: malformed SYG_CREDIT_WHEN (no '=') matches nothing" || bad "WHEN malformed: '$out'"
rt w4 SYG_CREDIT_WHEN=MY_ROUTE= MY_ROUTE= > /dev/null
rt w5 SYG_CREDIT_WHEN=MY_ROUTE= > /dev/null
[ -s "$T/w4/l.jsonl" ] && [ ! -e "$T/w5/l.jsonl" ] \
  && ok "route: 'NAME=' matches a set-but-empty var, not an unset one" || bad "WHEN empty value: w4 $(ls "$T/w4" 2>&1) / w5 $(ls "$T/w5" 2>&1)"
rt w6 ANTHROPIC_API_KEY=sk-probe > /dev/null
rt w7 SYG_CREDIT_WHEN= ANTHROPIC_API_KEY=sk-probe > /dev/null
[ -s "$T/w6/l.jsonl" ] && [ -s "$T/w7/l.jsonl" ] \
  && ok "route: SYG_CREDIT_WHEN unset or empty -> the API-key test (key set: written)" || bad "WHEN unset -> key test"
unmet=""
out=$(rt u1); [ -z "$out" ] && [ ! -e "$T/u1/l.jsonl" ] || unmet="$unmet no-key"
out=$(rt u2 ANTHROPIC_API_KEY=); [ -z "$out" ] && [ ! -e "$T/u2/l.jsonl" ] || unmet="$unmet empty-key"
n=3
for base in https://gateway.example.com/api https://api.anthropic.com.evil.test/v1 https://evilanthropic.com https://openrouter.ai/api/v1; do
  out=$(rt "u$n" ANTHROPIC_API_KEY=sk-probe ANTHROPIC_BASE_URL="$base")
  [ -z "$out" ] && [ ! -e "$T/u$n/l.jsonl" ] || unmet="$unmet $base"
  n=$((n + 1))
done
out=$(payload R | ac ANTHROPIC_API_KEY=sk-probe -- hook 2>&1)
[ -z "$out" ] || unmet="$unmet ledger-unset"
[ -z "$unmet" ] && ok "not metered (no key, empty key, gateway hosts, ledger unset): no ledger, no output" || bad "not metered leaked:$unmet"
n=0
for base in "" https://api.anthropic.com https://user:pw@API.Anthropic.com:443/v1/ https://eu.anthropic.com; do
  rt "m$n" ANTHROPIC_API_KEY=sk-probe ANTHROPIC_BASE_URL="$base" > /dev/null
  [ -s "$T/m$n/l.jsonl" ] && n=$((n + 1))
done
[ "$n" = 4 ] && ok "metered: empty base URL and first-party hosts all record" || bad "metered control: only $n of 4 recorded"

# 2. First entry: the documented fields.
e=$(head -n 1 "$T/w1/l.jsonl")
if [ "$(nlines "$T/w1/l.jsonl")" = 1 ] && jq -e --arg d "$D1" --arg tp "$P/R.jsonl" '
    .session_id=="R" and .day==$d and .route=="anthropic-api" and .source=="transcript"
    and .first_ts=="2026-10-10T10:00:00Z" and .last_ts==.first_ts and .cost_usd==1 and .requests==1
    and .request_ids==["req-r"] and .unpriced_models==[] and .transcript_path==$tp and (.updated_ts|type)=="string"
    and (.models|keys)==["m-a"] and .models["m-a"].requests==1 and .models["m-a"].input_tokens==1000000
    and .models["m-a"].cost_usd==1 and (.models["m-a"]|keys|length)==10
    and (has("raw_last")|not) and (has("run")|not)' <<< "$e" > /dev/null; then
  ok "entry: one line, cost 1.00, all documented fields"
else bad "entry fields: $e"; fi

# 3. Streaming dedupe: three lines of one reply (output 2, 2, 6) are one request with output 6.
{ uline msg-s req-s m-a ${D1}T10:00:00Z $M 2; uline msg-s req-s m-a ${D1}T10:00:01Z $M 2; uline msg-s req-s m-a ${D1}T10:00:02Z $M 6; } > "$P/S.jsonl"
hk S "$T/s/l.jsonl"
e=$(cat "$T/s/l.jsonl")
if jq -e '.requests==1 and .models["m-a"].output_tokens==6 and .models["m-a"].input_tokens==1000000' <<< "$e" > /dev/null \
  && near "$(jq .cost_usd <<< "$e")" 1.000012; then
  ok "streaming dedupe: 3 lines, output 2/2/6 -> one request, output 6, cost 1.000012"
else bad "streaming dedupe: $e"; fi

# 4. Subagent transcripts (nested too) are part of the session.
mkdir -p "$P/SA/subagents/deep"
uline msg-a1 req-a1 m-a ${D1}T10:00:00Z $M 0 > "$P/SA.jsonl"
uline msg-a2 req-a2 m-a ${D1}T10:05:00Z $M 0 > "$P/SA/subagents/agent-1.jsonl"
uline msg-a3 req-a3 m-b ${D1}T10:06:00Z $M 0 > "$P/SA/subagents/deep/agent-2.jsonl"
hk SA "$T/sa/l.jsonl"
e=$(cat "$T/sa/l.jsonl")
if jq -e '.requests==3 and .request_ids==["req-a1","req-a2","req-a3"] and .last_ts=="2026-10-10T10:06:00Z"' <<< "$e" > /dev/null \
  && near "$(jq .cost_usd <<< "$e")" 5; then
  ok "subagent transcripts included: 3 requests, cost 1 + 1 + 3 = 5"
else bad "subagents: $e"; fi

# 5. Per-day split by request timestamp (UTC), fractional seconds accepted.
{ uline msg-d1 req-d1 m-a ${D1}T23:59:00.500Z $M 0; uline msg-d2 req-d2 m-a ${D2}T00:01:00.250Z $((2 * M)) 0; } > "$P/D.jsonl"
hk D "$T/d/l.jsonl"
if [ "$(nlines "$T/d/l.jsonl")" = 2 ] \
  && near "$(jq -s --arg d "$D1" '.[]|select(.day==$d)|.cost_usd' "$T/d/l.jsonl")" 1 \
  && near "$(jq -s --arg d "$D2" '.[]|select(.day==$d)|.cost_usd' "$T/d/l.jsonl")" 2 \
  && [ "$(jq -s -r --arg d "$D1" '.[]|select(.day==$d)|.last_ts' "$T/d/l.jsonl")" = 2026-10-10T23:59:00Z ]; then
  ok "day split: one entry per UTC day of the requests (1.00 on $D1, 2.00 on $D2)"
else bad "day split: $(cat "$T/d/l.jsonl")"; fi

# 6. Idempotent: a second call leaves the ledger bytes unchanged.
cp "$T/d/l.jsonl" "$T/d-before.jsonl"
hk D "$T/d/l.jsonl" SYG_CREDIT_NOW=2030-01-01T00:00:00Z
cmp -s "$T/d/l.jsonl" "$T/d-before.jsonl" && ok "idempotent: second hook call, ledger bytes unchanged" || bad "second call rewrote: $(cat "$T/d/l.jsonl")"
# A missing transcript never wipes recorded entries.
mv "$P/D.jsonl" "$T/D.jsonl.away"
hk D "$T/d/l.jsonl"
cmp -s "$T/d/l.jsonl" "$T/d-before.jsonl" && ok "missing transcript_path: ledger bytes unchanged (entries kept)" || bad "missing transcript wiped: $(cat "$T/d/l.jsonl")"
mv "$T/D.jsonl.away" "$P/D.jsonl"
# A grown transcript replaces the session's entries (absolute values, not added).
uline msg-d3 req-d3 m-a ${D2}T01:00:00Z $M 0 >> "$P/D.jsonl"
hk D "$T/d/l.jsonl"
if [ "$(nlines "$T/d/l.jsonl")" = 2 ] && near "$(jq -s '[.[].cost_usd]|add' "$T/d/l.jsonl")" 4 \
  && [ "$(jq -s --arg d "$D2" '.[]|select(.day==$d)|.requests' "$T/d/l.jsonl")" = 2 ]; then
  ok "grown transcript: entries recomputed (total 4.00, not added to 3.00)"
else bad "grown transcript: $(cat "$T/d/l.jsonl")"; fi

# 7. Cross-session dedupe: B (a resume) repeats one of A's requests; it counts once.
{ uline msg-x1 req-x1 m-a ${D1}T09:00:00Z $M 0; uline msg-x2 req-x2 m-a ${D1}T09:10:00Z $M 0; } > "$P/A.jsonl"
{ uline msg-x1 req-x1 m-a ${D1}T09:00:00Z $M 0; uline msg-y1 req-y1 m-a ${D1}T11:00:00Z $M 0; } > "$P/B.jsonl"
X="$T/x/l.jsonl"
hk A "$X"; hk B "$X"; hk A "$X"
if near "$(jq -s '[.[].cost_usd]|add' "$X")" 3 && [ "$(jq -s '[.[].requests]|add' "$X")" = 3 ] \
  && [ "$(jq -s -c '.[]|select(.session_id=="B")|.request_ids' "$X")" = '["req-y1"]' ] \
  && [ "$(jq -s -c '.[]|select(.session_id=="A")|.request_ids' "$X")" = '["req-x1","req-x2"]' ]; then
  ok "cross-session dedupe: B's copy of A's request skipped; 3 requests, 3.00 total"
else bad "cross-session: $(cat "$X")"; fi

# 8. Pricing: 5m writes at cacheWrite, 1h writes at 2x input, no cache_creation object
#    -> all writes 5m; cache reads; an [x]-suffixed id resolves to its base row.
{
  uline msg-p1 req-p1 m-a ${D1}T10:00:00Z 0 0 $M $M 0
  uline msg-p2 req-p2 m-a ${D1}T10:01:00Z 0 0 0 0 $M
  printf '{"type":"assistant","timestamp":"%sT10:02:00Z","requestId":"req-p3","message":{"model":"m-a","id":"msg-p3","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":%s}}}\n' "$D1" "$M"
  uline msg-p4 req-p4 'm-b[1m]' ${D1}T10:03:00Z $M $M
} > "$P/PR.jsonl"
hk PR "$T/pr/l.jsonl"
e=$(cat "$T/pr/l.jsonl")
if near "$(jq .cost_usd <<< "$e")" 23 && near "$(jq '.models["m-a"].cost_usd' <<< "$e")" 5 \
  && near "$(jq '.models["m-b[1m]"].cost_usd' <<< "$e")" 18 \
  && jq -e '.models["m-a"].cache_write_5m_tokens==2000000 and .models["m-a"].cache_write_1h_tokens==1000000
      and .models["m-a"].cache_read_input_tokens==1000000 and .unpriced_models==[]' <<< "$e" > /dev/null; then
  ok "pricing: 5m write 1.25 + read 0.50 + 1h write 2.00 (2x input) + legacy write 1.25 + m-b[1m] 18.00 = 23.00"
else bad "pricing: $e"; fi

# 8b. A trailing -YYYYMMDD date resolves to the base row, after a [...] strip too.
{ uline msg-dt1 req-dt1 m-a-20251001 ${D1}T10:00:00Z $M 0; uline msg-dt2 req-dt2 'm-a-20251001[1m]' ${D1}T10:01:00Z $M 0; } > "$P/DT.jsonl"
hk DT "$T/dt/l.jsonl"
e=$(cat "$T/dt/l.jsonl")
near "$(jq .cost_usd <<< "$e")" 2 && jq -e '.unpriced_models==[] and .models["m-a-20251001"].cost_usd==1 and .models["m-a-20251001[1m]"].cost_usd==1' <<< "$e" > /dev/null \
  && ok "pricing: m-a-20251001 and m-a-20251001[1m] priced as m-a" || bad "date suffix: $e"

# 8c. Unchanged transcripts: the second call reads nothing and never runs price-table;
#     a changed transcript runs it again.
uline msg-c1 req-c1 m-a ${D1}T10:00:00Z $M 0 > "$P/C.jsonl"
: > "$T/pt-calls"
hk C "$T/c/l.jsonl"; n1=$(nlines "$T/pt-calls")
hk C "$T/c/l.jsonl"; n2=$(nlines "$T/pt-calls")
touch -d '+2 seconds' "$T/pt.sh"
hk C "$T/c/l.jsonl"; n2b=$(nlines "$T/pt-calls")
uline msg-c2 req-c2 m-a ${D1}T10:05:00Z $M 0 >> "$P/C.jsonl"
hk C "$T/c/l.jsonl"; n3=$(nlines "$T/pt-calls")
if [ "$n1" = 1 ] && [ "$n2" = 1 ] && [ "$n2b" = 2 ] && [ "$n3" = 3 ] && near "$(jq .cost_usd "$T/c/l.jsonl")" 2 \
  && jq -e '(.sources_sig|length)==2 and ([.sources_sig[][0]]|sort)==([$tp,$pt]|sort)' --arg tp "$P/C.jsonl" --arg pt "$T/pt.sh" "$T/c/l.jsonl" > /dev/null; then
  ok "sources_sig: unchanged files -> price-table not run (1, 1); price stub touched -> run again (2); after an append -> run again (3), cost 2.00"
else bad "sources_sig: calls $n1/$n2/$n2b/$n3 $(cat "$T/c/l.jsonl")"; fi

# 8c2. A multi-token override ("sh SCRIPT"): the script token is watched, not just "sh".
printf '[ "$1" = --json ] || exit 9\necho x >> %q\ncat %q\n' "$T/pt2-calls" "$T/prices.json" > "$T/pt2.sh"
: > "$T/pt2-calls"
uline msg-m1 req-m1 m-a ${D1}T10:00:00Z $M 0 > "$P/MT.jsonl"
hk MT "$T/mt/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="sh $T/pt2.sh"; m1=$(nlines "$T/pt2-calls")
hk MT "$T/mt/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="sh $T/pt2.sh"; m2=$(nlines "$T/pt2-calls")
touch -d '+2 seconds' "$T/pt2.sh"
hk MT "$T/mt/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="sh $T/pt2.sh"; m3=$(nlines "$T/pt2-calls")
if [ "$m1" = 1 ] && [ "$m2" = 1 ] && [ "$m3" = 2 ] \
  && jq -e '[.sources_sig[][0]] | index($pt) != null' --arg pt "$T/pt2.sh" "$T/mt/l.jsonl" > /dev/null; then
  ok "sources_sig: override \"sh SCRIPT\" -> script watched: unchanged -> not run (1, 1); touched -> run again (2)"
else bad "sources_sig multi-token: calls $m1/$m2/$m3 $(cat "$T/mt/l.jsonl")"; fi

# 8d. A rewrite keeps the ledger's mode; a new ledger gets 0644 less the umask.
want=$(printf '%o' $(( 0644 & ~0$(umask) )))
got_new=$(stat -c %a "$T/c/l.jsonl")
chmod 640 "$T/c/l.jsonl"
uline msg-c3 req-c3 m-a ${D1}T10:06:00Z $M 0 >> "$P/C.jsonl"
hk C "$T/c/l.jsonl"
[ "$got_new" = "$want" ] && [ "$(stat -c %a "$T/c/l.jsonl")" = 640 ] && near "$(jq .cost_usd "$T/c/l.jsonl")" 3 \
  && ok "ledger mode: new ledger $want (0644 & ~umask); chmod 640 survives a rewrite" || bad "mode: new $got_new (want $want), after $(stat -c %a "$T/c/l.jsonl")"

# 9. Unpriced model: tokens recorded, cost not added (null), listed.
{ uline msg-u1 req-u1 m-zzz ${D1}T10:00:00Z 500 700; uline msg-u2 req-u2 m-a ${D1}T10:01:00Z $M 0; } > "$P/U.jsonl"
hk U "$T/un/l.jsonl"
e=$(cat "$T/un/l.jsonl")
if near "$(jq .cost_usd <<< "$e")" 1 && jq -e '.unpriced_models==["m-zzz"] and .models["m-zzz"].input_tokens==500
    and .models["m-zzz"].output_tokens==700 and .models["m-zzz"].cost_usd==null and .requests==2' <<< "$e" > /dev/null; then
  ok "unpriced model: tokens recorded, cost null and not added (1.00), listed in unpriced_models"
else bad "unpriced: $e"; fi

# 10. Skipped and counted-only lines: <synthetic>, zero tokens, a half-written line;
#     web search/fetch and fast mode are counts, not priced.
{
  uline msg-q1 req-q1 '<synthetic>' ${D1}T10:00:00Z 5 5
  uline msg-q2 req-q2 m-a ${D1}T10:00:01Z 0 0
  uline msg-q3 req-q3 m-a ${D1}T10:00:02Z $M 0 0 0 0 ',"server_tool_use":{"web_search_requests":2,"web_fetch_requests":1},"speed":"fast"'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tok'
  printf '%s\n' '{"type":"user","message":{"content":"no usage here"}}'
} > "$P/Q.jsonl"
err=$(hk Q "$T/q/l.jsonl" 2>&1)
e=$(cat "$T/q/l.jsonl")
if near "$(jq .cost_usd <<< "$e")" 1 && jq -e '.requests==1 and .request_ids==["req-q3"] and (.models|keys)==["m-a"]
    and .models["m-a"].web_search_requests==2 and .models["m-a"].web_fetch_requests==1 and .models["m-a"].fast_requests==1' <<< "$e" > /dev/null \
  && [ "$err" = "api-credit: skipped 1 unparsable transcript line(s)" ]; then
  ok "synthetic and zero-token requests skipped; unparsable line counted on stderr; search/fetch/fast counted, unpriced"
else bad "skips: $e / '$err'"; fi

# 11. A failing price table: no write, one stderr line, exit 0.
err=$(payload R | ac SYG_CREDIT_FORCE=1 SYG_CREDIT_LEDGER="$T/pf/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-fail.sh" -- hook 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/pf/l.jsonl" ] && [ "$(wc -l <<< "$err" | tr -d ' ')" = 1 ] && grep -q '^api-credit: hook failed:' <<< "$err" \
  && ok "price table failure: exit 0, one stderr line, no ledger write" || bad "price failure: rc=$rc '$err'"
out=$(printf 'not json' | ac SYG_CREDIT_FORCE=1 SYG_CREDIT_LEDGER="$T/pj/l.jsonl" -- hook 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$T/pj/l.jsonl" ] && ok "unparsable hook input: exit 0, silent, no write" || bad "bad input: rc=$rc '$out'"

# 12. Old-format entries (rounds 1-3: raw_last/run, no source) and a garbage line are
#     kept through a rewrite and summed by balance and daily.
OLD="$T/old/l.jsonl"; mkdir -p "$T/old"
printf '%s\n' '{"session_id":"OLD","day":"2026-10-05","first_ts":"2026-10-05T10:00:00Z","last_ts":"2026-10-05T11:00:00Z","cost_usd":2.5,"raw_last":2.5,"run":"r1","models":["m-old"],"route":"anthropic-api"}' > "$OLD"
printf '%s\n' '{this is not json, keep me' >> "$OLD"
hk R "$OLD"
b=$(ac SYG_CREDIT_LEDGER="$OLD" -- balance --json)
daily=$(ac SYG_CREDIT_LEDGER="$OLD" -- daily --json)
if grep -qxF '{this is not json, keep me' "$OLD" && [ "$(nlines "$OLD")" = 3 ] \
  && grep -F '"session_id": "OLD"' "$OLD" | jq -e '.raw_last==2.5 and .run=="r1" and .models==["m-old"] and .cost_usd==2.5' > /dev/null \
  && near "$(jq .spent_usd <<< "$b")" 3.5 && near "$(jq .total.cost_usd <<< "$daily")" 3.5 \
  && [ "$(jq -c --arg d "$D1" '.days[]|select(.day==$d)|.models' <<< "$daily")" = '["m-a"]' ]; then
  ok "old-format entry and garbage line kept verbatim; balance and daily sum old + new (3.50)"
else bad "old-format: $(cat "$OLD") / $b / $daily"; fi
ac SYG_CREDIT_LEDGER="$OLD" -- daily | head -n 1 | grep -qE '^2026-10-05  \$2\.50  1 sessions  m-old$' \
  && ok "daily text row format" || bad "daily text: $(ac SYG_CREDIT_LEDGER="$OLD" -- daily)"
ac -- balance > /dev/null 2> "$T/err.txt"; rc=$?
[ "$rc" = 2 ] && grep -q SYG_CREDIT_LEDGER "$T/err.txt" && ok "balance without the ledger var: exit 2 naming it" || bad "balance unset: rc=$rc $(cat "$T/err.txt")"

# 13. statusline is read-only: it prints the balance with no route test and never writes.
cp "$OLD" "$T/old-before.jsonl"
out=$(payload R | ac SYG_CREDIT_LEDGER="$OLD" -- statusline --json)
new=$(ac SYG_CREDIT_LEDGER="$T/none/l.jsonl" -- statusline --json < /dev/null)
off=$(ac -- statusline --json < /dev/null)
if near "$(jq .spent_usd <<< "$out")" 3.5 && cmp -s "$OLD" "$T/old-before.jsonl" \
  && [ "$(jq .spent_usd <<< "$new")" = 0 ] && [ ! -e "$T/none/l.jsonl" ] && [ -z "$off" ]; then
  ok "statusline --json: read-only balance without a route test; no write; nothing when the ledger var is unset"
else bad "statusline read-only: '$out' / '$new' / '$off'"; fi

# Ledger fixture writer for the balance cases: entry SESSION DAY LAST_TS COST.
entry() { printf '{"session_id":"%s","day":"%s","first_ts":"%s","last_ts":"%s","cost_usd":%s,"raw_last":0}\n' "$1" "$2" "$3" "$3" "$4"; }
bal() { # ledger now [extra env]
  ac SYG_CREDIT_LEDGER="$1" SYG_CREDIT_GRANTS="$G" SYG_CREDIT_NOW="$2" -- balance --json
}
cat > "$G" <<'EOF'
{"currency":"USD","grants":[
 {"amount":10,"granted":"2026-10-01","expires":"2026-10-10","kind":"promotional"},
 {"amount":50,"granted":"2026-10-01","note":"purchased"},
 {"amount":0,"granted":"2026-10-01"},
 {"amount":5,"granted":"2026-10-01","tz":"Not/AZone"},
 {"amount":5}
]}
EOF

# 14. Drawdown: soonest expiry first, then the rest; unused remainder lapses.
entry a 2026-10-05 2026-10-05T12:00:00Z 12 > "$T/b9.jsonl"
b=$(bal "$T/b9.jsonl" 2026-10-06T00:00:00Z)
if near "$(jq .remaining_usd <<< "$b")" 48 && near "$(jq .lapsed_usd <<< "$b")" 0 \
  && [ "$(jq .live_grants <<< "$b")" = 2 ] && [ "$(jq .estimate <<< "$b")" = true ] \
  && [ "$(jq .next_expiry <<< "$b")" = null ] && [ "$(jq .days_left <<< "$b")" = null ] \
  && near "$(jq .granted_total_live <<< "$b")" 60; then
  ok "balance: 12 spent draws the 10 expiring first, then 2: remaining 48 (invalid grants skipped, exhausted grant has no expiry to warn about)"
else bad "balance 14a: $b"; fi
entry a 2026-10-05 2026-10-05T12:00:00Z 4 > "$T/b9c.jsonl"
b=$(bal "$T/b9c.jsonl" 2026-10-06T18:00:00Z)
if near "$(jq .remaining_usd <<< "$b")" 56 && [ "$(jq -r .next_expiry <<< "$b")" = 2026-10-10T00:00:00Z ] && [ "$(jq .days_left <<< "$b")" = 3 ]; then
  ok "balance: next_expiry is the soonest live grant with credit left; days_left floors (3.25 days -> 3)"
else bad "balance 14c: $b"; fi
# 14d. Grants with no expiry (bought credit): no next_expiry, no days_left.
echo '{"grants":[{"amount":50,"granted":"2026-10-01"}]}' > "$T/g-noexp.json"
b=$(ac SYG_CREDIT_LEDGER="$T/b9c.jsonl" SYG_CREDIT_GRANTS="$T/g-noexp.json" SYG_CREDIT_NOW=2026-10-06T00:00:00Z -- balance --json)
if near "$(jq .remaining_usd <<< "$b")" 46 && [ "$(jq .next_expiry <<< "$b")" = null ] && [ "$(jq .days_left <<< "$b")" = null ]; then
  ok "balance: a grant without expiry -> remaining 46, next_expiry and days_left null"
else bad "balance 14d: $b"; fi
{ entry a 2026-10-05 2026-10-05T12:00:00Z 4; entry b 2026-10-10 2026-10-10T12:00:00Z 3; } > "$T/b9b.jsonl"
b=$(bal "$T/b9b.jsonl" 2026-10-11T00:00:00Z)
if near "$(jq .lapsed_usd <<< "$b")" 6 && near "$(jq .remaining_usd <<< "$b")" 47 && [ "$(jq .live_grants <<< "$b")" = 1 ] \
  && [ "$(jq .next_expiry <<< "$b")" = null ]; then
  ok "balance: spend 4 before expiry forfeits 6; later spend 3 leaves 47"
else bad "balance 14b: $b"; fi

# 15. Overage.
entry a 2026-10-05 2026-10-05T12:00:00Z 70 > "$T/b10.jsonl"
b=$(bal "$T/b10.jsonl" 2026-10-06T00:00:00Z)
txt=$(ac SYG_CREDIT_LEDGER="$T/b10.jsonl" SYG_CREDIT_GRANTS="$G" SYG_CREDIT_NOW=2026-10-06T00:00:00Z -- statusline < /dev/null)
if near "$(jq .overage_usd <<< "$b")" 10 && near "$(jq .remaining_usd <<< "$b")" 0 && [ "$txt" = 'api credit over $10.00 est' ]; then
  ok "overage: 70 against 60 granted -> overage 10, text 'api credit over \$10.00 est'"
else bad "overage: $b / $txt"; fi

# 16. No grants file: spend only, never an invented balance.
txt=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_NOW=2026-10-06T00:00:00Z -- statusline < /dev/null)
b=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" -- balance --json)
echo 'not json' > "$T/garbled-grants.json"
b2=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_GRANTS="$T/garbled-grants.json" -- balance --json)
if [ "$txt" = 'api $12.00 spent est' ] && [ "$(jq .remaining_usd <<< "$b")" = null ] && [ "$(jq .remaining_usd <<< "$b2")" = null ]; then
  ok "no usable grants file: 'api \$12.00 spent est', remaining null"
else bad "no grants: '$txt' / $b / $b2"; fi

# 17. A date-only expiry lapses at 00:00 of that date in the grant's tz.
cat > "$G" <<'EOF'
{"grants":[{"amount":5,"granted":"2026-10-01","expires":"2026-10-10"}]}
EOF
: > "$T/empty.jsonl"
b=$(bal "$T/empty.jsonl" 2026-10-10T00:00:01Z)
b0=$(bal "$T/empty.jsonl" 2026-10-09T23:59:59Z)
cat > "$G" <<'EOF'
{"grants":[{"amount":5,"granted":"2026-10-01","expires":"2026-10-10","tz":"America/New_York"}]}
EOF
bz=$(bal "$T/empty.jsonl" 2026-10-10T00:00:01Z)
if near "$(jq .lapsed_usd <<< "$b")" 5 && near "$(jq .remaining_usd <<< "$b")" 0 \
  && near "$(jq .remaining_usd <<< "$b0")" 5 && near "$(jq .remaining_usd <<< "$bz")" 5; then
  ok "date-only expiry lapses at 00:00:00 in the grant tz (UTC lapsed, 1s earlier live, New_York still live)"
else bad "expiry: $b / $b0 / $bz"; fi

# 18. Concurrency: 20 parallel hook calls for 20 sessions all land.
for i in $(seq 1 20); do
  uline "msg-par$i" "req-par$i" m-a 2026-10-12T00:00:00Z $((i * 1000)) 0 > "$P/PAR$i.jsonl"
done
for i in $(seq 1 20); do
  hk "PAR$i" "$T/par/l.jsonl" &
done
wait
if [ "$(nlines "$T/par/l.jsonl")" = 20 ] && [ "$(jq -c . "$T/par/l.jsonl" | wc -l | tr -d ' ')" = 20 ] \
  && [ "$(jq -s '[.[].session_id]|unique|length' "$T/par/l.jsonl")" = 20 ]; then
  ok "20 parallel hook calls: 20 valid lines, 20 distinct sessions"
else bad "concurrency: $(nlines "$T/par/l.jsonl") lines"; fi
[ -z "$(find "$T" -name '*.tmp')" ] \
  && ok "no stray *.tmp files after the parallel and sequential writes" || bad "stray tmp files: $(find "$T" -name '*.tmp')"

# 19. Provider balance: cost_report from a loopback mock (SYG_CREDIT_ADMIN_URL) with a
#     fixture admin key. The mock serves $T/cr/<mode>.json (mode read from $T/cr/mode
#     per request; "401" answers 401; "paged" serves paged1 then, for page=p2, paged2;
#     "loop" always answers has_more with the same next_page), drops buckets before
#     the request's starting_at, and logs path, x-api-key and anthropic-version.
#     A curl wrapper first on PATH logs each argv, so the key's absence there is checked.
mkdir -p "$T/cr" "$T/cbin"
cat > "$T/cr/srv.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit
d = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(d, "hits.log"), "a") as f:
            f.write("%s\t%s\t%s\n" % (self.path, self.headers.get("x-api-key", "-"), self.headers.get("anthropic-version", "-")))
        mode = open(os.path.join(d, "mode")).read().strip()
        if mode == "401":
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
        if mode == "paged":
            mode = "paged2" if "page=p2" in self.path else "paged1"
        data = open(os.path.join(d, mode + ".json"), "rb").read()
        start = parse_qs(urlsplit(self.path).query).get("starting_at", [""])[0]
        try:
            doc = json.loads(data)
            doc["data"] = [b for b in doc["data"] if b.get("starting_at", "") >= start]
            data = json.dumps(doc).encode()
        except (ValueError, KeyError, TypeError, AttributeError):
            pass   # the malformed fixtures are served verbatim
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as f:
    f.write(str(s.server_port))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
echo ok > "$T/cr/mode"
python3 -I "$T/cr/srv.py" "$T/cr" &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -s "$T/cr/port" ] && break; sleep 0.1; done
[ -s "$T/cr/port" ] || { echo "api-credit.probe: mock server did not start"; exit 2; }
CR="http://127.0.0.1:$(cat "$T/cr/port")"
REAL_CURL=$(command -v curl)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$T/cr/argv.log" "$REAL_CURL" > "$T/cbin/curl"
chmod +x "$T/cbin/curl"
: > "$T/cr/hits.log"; : > "$T/cr/argv.log"
hits() { nlines "$T/cr/hits.log"; }
# Closed days 10-05..10-08: USD 370.289 + 1000 cents (= 13.70289), a EUR row ignored,
# a bucket without results and one with a non-list results skipped.
cat > "$T/cr/ok.json" <<'EOF'
{"data":[
 {"starting_at":"2026-10-05T00:00:00Z","ending_at":"2026-10-06T00:00:00Z","results":[{"currency":"USD","amount":"370.289","description":"x"}]},
 {"starting_at":"2026-10-06T00:00:00Z","ending_at":"2026-10-07T00:00:00Z"},
 {"starting_at":"2026-10-07T00:00:00Z","ending_at":"2026-10-08T00:00:00Z","results":"nope"},
 {"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"1000"},{"currency":"EUR","amount":"999"}]}
],"has_more":false,"next_page":null}
EOF
echo '{"data":[{"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"1000000"}]}]}' > "$T/cr/big.json"
echo 'not json' > "$T/cr/nonjson.json"
echo '{"error":"x"}' > "$T/cr/nodata.json"
echo '{"data":[{"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"12abc"}]}]}' > "$T/cr/badamount.json"
echo '{"data":[{"starting_at":"2026-10-05T00:00:00Z","ending_at":"2026-10-06T00:00:00Z","results":[{"currency":"USD","amount":"370.289"}]}],"has_more":true,"next_page":"p2"}' > "$T/cr/paged1.json"
echo '{"data":[{"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"1000"}]}],"has_more":false}' > "$T/cr/paged2.json"
echo '{"data":[{"starting_at":"2026-10-05T00:00:00Z","ending_at":"2026-10-06T00:00:00Z","results":[{"currency":"USD","amount":"1"}]}],"has_more":true,"next_page":"same"}' > "$T/cr/loop.json"
echo '{"data":[{"starting_at":"2026-10-07T00:00:00Z","ending_at":"2026-10-08T00:00:00Z","results":[{"currency":"USD","amount":"1000"}]}],"has_more":false}' > "$T/cr/lag.json"
echo '{"data":[],"has_more":false}' > "$T/cr/nobucket.json"
echo '{"data":[{"starting_at":"2026-10-08T00:00:00Z","results":[{"currency":"USD","amount":"100"}]},{"starting_at":"later","results":[{"currency":"USD","amount":"500"}]}],"has_more":false}' > "$T/cr/nostart.json"
echo '{"data":[{"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"1E+400"}]}]}' > "$T/cr/inf.json"
echo '{"grants":[{"amount":100,"granted":"2026-10-05","expires":"2026-10-21"}]}' > "$T/g-live.json"
{ entry a 2026-10-06 2026-10-06T12:00:00Z 5; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv.jsonl"
entry a 2026-10-06 2026-10-06T12:00:00Z 5 > "$T/lv-notoday.jsonl"
LNOW=2026-10-09T15:00:00Z
# lv CACHE-DIR CMD... [VAR=value ...]: balance/statusline with the fixture key against the mock.
lv() {
  local c=$1; shift
  local args=()
  while [ $# -gt 0 ] && [[ "$1" != *=* ]]; do args+=("$1"); shift; done
  env -i PATH="$T/cbin:$PATH" HOME="$T" XDG_CACHE_HOME="$T/cache-$c" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt.sh" \
    SYG_CREDIT_LEDGER="$T/lv.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" \
    ANTHROPIC_ADMIN_API_KEY=fixture-admin-key SYG_CREDIT_ADMIN_URL="$CR" "$@" python3 -B "$AC" "${args[@]}"
}
# The no-key reference: today's ledger estimate (spent 5 + 2.5, remaining 92.50).
nk=$(ac SYG_CREDIT_LEDGER="$T/lv.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- balance --json)
nkt=$(ac SYG_CREDIT_LEDGER="$T/lv.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- statusline < /dev/null)
nkb=$(ac SYG_CREDIT_LEDGER="$T/lv.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- balance)
nke=$(ac SYG_CREDIT_LEDGER="$T/lv.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_URL="$CR" -- balance --json)
if [ "$nk" = '{"currency": "USD", "days_left": 11, "estimate": true, "granted_total_live": 100.0, "lapsed_usd": 0.0, "live_grants": 1, "next_expiry": "2026-10-21T00:00:00Z", "overage_usd": 0.0, "remaining_by_kind": {"unspecified": 92.5}, "remaining_usd": 92.5, "spent_usd": 7.5}' ] \
  && [ "$nkt" = 'api credit $92.50 est (exp 10-21, 11d)' ] \
  && [ "$nkb" = $'api credit $92.50 est (exp 10-21, 11d)\nspent $7.50, lapsed $0.00, overage $0.00 (estimate)' ] \
  && [ "$nke" = "$nk" ] && [ "$(hits)" = 0 ]; then
  ok "provider: no key (or an empty one) -> today's ledger output byte for byte, no new fields, no request"
else bad "provider no-key: '$nk' / '$nkt' / '$nkb' / '$nke' / hits $(hits)"; fi

# 19a. Live ok: spent and remaining from one family (13.70289 closed days + 2.50 today).
b=$(lv ok balance --json)
txt=$(lv ok statusline < /dev/null)
if near "$(jq .spent_usd <<< "$b")" 16.20289 && near "$(jq .remaining_usd <<< "$b")" 83.79711 \
  && jq -e '.source=="provider" and .estimate==false and .provider_as_of=="2026-10-08" and .ledger_bridge_days==1
      and .overage_usd==0 and .next_expiry=="2026-10-21T00:00:00Z" and .days_left==11 and .live_grants==1' <<< "$b" > /dev/null; then
  ok "provider: live ok -> spent 16.20289 (13.70289 provider + 2.50 today), remaining 83.79711, source provider, as of 2026-10-08"
else bad "provider live ok: $b"; fi
[ "$txt" = 'api credit $83.80 (exp 10-21, 11d)' ] \
  && ok "provider: text 'api credit \$83.80 (exp 10-21, 11d)' (exact: no est, no as-of day)" || bad "provider text: '$txt'"
req=$(head -n 1 "$T/cr/hits.log")
[ "$req" = $'/v1/organizations/cost_report?starting_at=2026-10-05T00:00:00Z&ending_at=2026-10-09T00:00:00Z&group_by[]=description&limit=31\tfixture-admin-key\t2023-06-01' ] \
  && ok "provider: request window [earliest live grant day, start of today), group_by description, x-api-key and anthropic-version headers" || bad "provider request: '$req'"
cf="$T/cache-ok/claude-statusline/api-credit-live.json"
if [ "$(hits)" = 1 ] && ! grep -q fixture-admin-key "$T/cr/argv.log" && ! grep -q fixture-admin-key "$cf" \
  && [ "$(jq -r 'keys[0]' "$cf" | cut -d' ' -f1)" = "$(printf '%s' fixture-admin-key | sha256sum | cut -d' ' -f1)" ] \
  && ! grep -v "http://127.0.0.1:" "$T/cr/argv.log" | grep -q .; then
  ok "provider: one request (the statusline call reused the cache); key absent from curl argv and from the cache (cache key holds its SHA-256); every URL loopback"
else bad "provider key hygiene: hits $(hits) / argv $(cat "$T/cr/argv.log") / cache $(cat "$cf")"; fi
b=$(lv ok balance)
[ "$b" = $'api credit $83.80 (exp 10-21, 11d)\nspent $16.20, lapsed $0.00, overage $0.00 (provider through 2026-10-08; today from the ledger)' ] \
  && ok "provider: balance text second line names the provider basis" || bad "provider balance text: '$b'"

# 19b. TTL: inside 300 s no second request; past it, a refetch; a corrupt cache is refetched.
: > "$T/cr/hits.log"
lv ttl balance --json > /dev/null; lv ttl balance --json SYG_CREDIT_NOW=2026-10-09T15:04:59Z > /dev/null; t1=$(hits)
lv ttl balance --json SYG_CREDIT_NOW=2026-10-09T15:05:00Z > /dev/null; t2=$(hits)
echo garbage > "$T/cache-ttl/claude-statusline/api-credit-live.json"
b=$(lv ttl balance --json SYG_CREDIT_NOW=2026-10-09T15:05:00Z); t3=$(hits)
[ "$t1" = 1 ] && [ "$t2" = 2 ] && [ "$t3" = 3 ] && jq -e '.source=="provider"' <<< "$b" > /dev/null \
  && ok "provider TTL: second call at +299 s -> no request (1); at +300 s -> refetch (2); corrupt cache -> refetch (3)" \
  || bad "provider TTL: hits $t1/$t2/$t3 $b"

# 19b2. A failure is cached too: a 401, then +60 s -> no request, still the labeled
#       fallback; past 300 s -> refetch, and a success overwrites the failed record.
echo 401 > "$T/cr/mode"; : > "$T/cr/hits.log"
lv neg balance --json > /dev/null; n1=$(hits)
b=$(lv neg balance --json SYG_CREDIT_NOW=2026-10-09T15:01:00Z); n2=$(hits)
txt=$(lv neg statusline SYG_CREDIT_NOW=2026-10-09T15:01:00Z < /dev/null); n3=$(hits)
echo ok > "$T/cr/mode"
b2=$(lv neg balance --json SYG_CREDIT_NOW=2026-10-09T15:05:00Z); n4=$(hits)
lv neg balance --json SYG_CREDIT_NOW=2026-10-09T15:06:00Z > /dev/null; n5=$(hits)
if [ "$n1" = 1 ] && [ "$n2" = 1 ] && [ "$n3" = 1 ] && [ "$n4" = 2 ] && [ "$n5" = 2 ] \
  && [ "$(jq -c 'del(.source, .provider_as_of, .provider_window_start, .ledger_bridge_days)' <<< "$b")" = "$(jq -c . <<< "$nk")" ] \
  && jq -e '.source=="ledger" and .estimate==true' <<< "$b" > /dev/null && [ "$txt" = "$nkt" ] \
  && jq -e '.source=="provider"' <<< "$b2" > /dev/null; then
  ok "provider failure cache: 401 then +60 s -> no request (hits 1), labeled ledger fallback; +300 s -> refetch, success overwrites (hits 2, then reused)"
else bad "provider failure cache: hits $n1/$n2/$n3/$n4/$n5 / $b / '$txt' / $b2"; fi

# 19c. Today bridge: without today's ledger entries, spent is the provider sum alone.
b=$(lv nobridge balance --json SYG_CREDIT_LEDGER="$T/lv-notoday.jsonl")
near "$(jq .spent_usd <<< "$b")" 13.70289 && near "$(jq .remaining_usd <<< "$b")" 86.29711 && jq -e '.ledger_bridge_days==0' <<< "$b" > /dev/null \
  && ok "provider bridge: no ledger spend today -> spent 13.70289, bridge days 0 (today's 2.50 is added only when present)" || bad "provider bridge: $b"

# 19c2. A lagging provider: every ledger day after the last bucket is bridged.
{ entry a 2026-10-07 2026-10-07T12:00:00Z 4; entry b 2026-10-08 2026-10-08T12:00:00Z 5; entry c 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-lag.jsonl"
echo lag > "$T/cr/mode"
b=$(lv lag balance --json SYG_CREDIT_LEDGER="$T/lv-lag.jsonl")
near "$(jq .spent_usd <<< "$b")" 17.5 && jq -e '.source=="provider" and .provider_as_of=="2026-10-07" and .ledger_bridge_days==2' <<< "$b" > /dev/null \
  && ok "provider bridge: last bucket 10-07 -> spent 10.00 + 10-08's 5.00 + 10-09's 2.50 (10-07's ledger 4.00 not added), bridge days 2" \
  || bad "provider lag bridge: $b"
echo nobucket > "$T/cr/mode"
b=$(lv nobucket balance --json)
near "$(jq .spent_usd <<< "$b")" 7.5 && jq -e '.source=="provider" and .provider_as_of=="2026-10-04" and .ledger_bridge_days==2' <<< "$b" > /dev/null \
  && ok "provider bridge: no dated bucket -> as of 10-04 (the day before the window), the whole window bridged (spent 7.50, bridge days 2)" \
  || bad "provider no-bucket bridge: $b"
echo ok > "$T/cr/mode"

# 19c3. The window starts at the earliest LIVE grant (a lapsed one is skipped), floored
#       to 00:00 UTC whatever the grant's tz.
echo '{"grants":[{"amount":50,"granted":"2026-10-01","expires":"2026-10-05"},{"amount":100,"granted":"2026-10-06","expires":"2026-10-21"}]}' > "$T/g-lapse.json"
: > "$T/cr/hits.log"
b=$(lv lapse balance --json SYG_CREDIT_GRANTS="$T/g-lapse.json")
case "$(head -n 1 "$T/cr/hits.log")" in
  *'starting_at=2026-10-06T00:00:00Z&'*) req_ok=1 ;; *) req_ok=0 ;; esac
[ "$req_ok" = 1 ] && near "$(jq .spent_usd <<< "$b")" 12.5 && near "$(jq .remaining_usd <<< "$b")" 87.5 \
  && jq -e '.source=="provider" and .live_grants==1' <<< "$b" > /dev/null \
  && ok "provider window: lapsed 10-01..10-05 grant + live 10-06 grant -> starting_at 10-06, spent 10.00 + 2.50 (no 10-05 bucket), remaining 87.50 of the live 100" \
  || bad "provider lapsed window: $(head -n 1 "$T/cr/hits.log") / $b"
echo '{"grants":[{"amount":100,"granted":"2026-10-05","expires":"2026-10-21","tz":"America/New_York"}]}' > "$T/g-ny.json"
: > "$T/cr/hits.log"
lv ny balance --json SYG_CREDIT_GRANTS="$T/g-ny.json" > /dev/null
case "$(head -n 1 "$T/cr/hits.log")" in
  *'starting_at=2026-10-05T00:00:00Z&'*) ok "provider window: a 2026-10-05 America/New_York grant (04:00Z) -> starting_at floored to 2026-10-05T00:00:00Z" ;;
  *) bad "provider tz floor: $(head -n 1 "$T/cr/hits.log")" ;; esac

# 19c4. A key with CR or LF is no usable key: the no-key output, no request.
: > "$T/cr/hits.log"
b=$(lv crlf balance --json ANTHROPIC_ADMIN_API_KEY=$'bad\nkey')
b2=$(lv crlf2 balance --json ANTHROPIC_ADMIN_API_KEY=$'bad\rkey')
[ "$b" = "$nk" ] && [ "$b2" = "$nk" ] && [ "$(hits)" = 0 ] \
  && ok "provider: a key containing LF or CR -> today's no-key output byte for byte, no request" || bad "provider crlf key: $b / $b2 / hits $(hits)"

# 19d. Overage on the provider path: one family, clamped remaining.
echo big > "$T/cr/mode"
b=$(lv big balance --json); txt=$(lv big statusline < /dev/null)
near "$(jq .spent_usd <<< "$b")" 10002.5 && near "$(jq .remaining_usd <<< "$b")" 0 && near "$(jq .overage_usd <<< "$b")" 9902.5 \
  && [ "$txt" = 'api credit over $9902.50' ] \
  && ok "provider overage: spent 10002.50 against 100 -> remaining 0, overage 9902.50, labeled text" || bad "provider overage: $b / '$txt'"

# 19e. Pages: has_more/next_page followed, both summed.
echo paged > "$T/cr/mode"; : > "$T/cr/hits.log"
b=$(lv paged balance --json)
near "$(jq .spent_usd <<< "$b")" 16.20289 && [ "$(hits)" = 2 ] && grep -q 'page=p2' "$T/cr/hits.log" && jq -e '.provider_as_of=="2026-10-08"' <<< "$b" > /dev/null \
  && ok "provider pages: next_page followed (2 requests), sum 13.70289 + 2.50" || bad "provider pages: $b / $(cat "$T/cr/hits.log")"
echo loop > "$T/cr/mode"; : > "$T/cr/hits.log"
b=$(lv loop balance --json)
[ "$(hits)" -le 3 ] && jq -e '.source=="ledger" and .estimate==true and .spent_usd==7.5' <<< "$b" > /dev/null \
  && ok "provider pages: the same next_page again -> stop after $(hits) requests (not 20), labeled ledger fallback" \
  || bad "provider page loop: hits $(hits) / $b"

# 19f. Every failure falls back to the ledger estimate, labeled; never a non-zero exit.
fb=""
for m in 401 nonjson nodata badamount inf nostart; do
  echo "$m" > "$T/cr/mode"
  b=$(lv "fb-$m" balance --json); rc=$?
  txt=$(lv "fb-$m" statusline < /dev/null)
  if [ "$rc" = 0 ] && [ "$(jq -c 'del(.source, .provider_as_of, .provider_window_start, .ledger_bridge_days)' <<< "$b")" = "$(jq -c . <<< "$nk")" ] \
    && jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null and .ledger_bridge_days==null' <<< "$b" > /dev/null \
    && [ "$txt" = "$nkt" ]; then :; else fb="$fb $m:$b:'$txt'"; fi
done
echo ok > "$T/cr/mode"
b=$(lv fb-down balance --json SYG_CREDIT_ADMIN_URL=http://127.0.0.1:9); rc=$?
[ "$rc" = 0 ] && jq -e '.source=="ledger" and .spent_usd==7.5 and .remaining_usd==92.5' <<< "$b" > /dev/null || fb="$fb refused:$b"
[ -z "$fb" ] && ok "provider fallback: 401, non-JSON, no data array, bad amount, a non-finite sum, a bucket with amounts but no starting_at, refused connection -> ledger estimate (spent 7.50, remaining 92.50), source ledger, exit 0" \
  || bad "provider fallback:$fb"

# 19g. No fetch: hook and daily never request; no live grant or no closed day -> unchanged output.
: > "$T/cr/hits.log"
payload R | lv hookx hook SYG_CREDIT_FORCE=1 SYG_CREDIT_LEDGER="$T/hookx/l.jsonl" > /dev/null 2>&1
lv dailyx daily --json > /dev/null
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-05"}]}' > "$T/g-dead.json"
nd=$(lv nolive balance --json SYG_CREDIT_GRANTS="$T/g-dead.json")
echo '{"grants":[{"amount":100,"granted":"2026-10-09T08:00:00Z"}]}' > "$T/g-today.json"
nt=$(lv notclosed balance --json SYG_CREDIT_GRANTS="$T/g-today.json")
[ "$(hits)" = 0 ] && [ -s "$T/hookx/l.jsonl" ] && ! jq -e 'has("source")' <<< "$nd" > /dev/null && ! jq -e 'has("source")' <<< "$nt" > /dev/null \
  && ok "provider: hook, daily, no live grant and a grant from today make no request and add no fields" \
  || bad "provider no-fetch: hits $(hits) / $nd / $nt"

# 20. calibrate: a mid-day anchor. K's requests at 10:00 ($1) and 14:00 ($2) are in the
#     ledger; the anchor at 12:00 takes the 10:00 one as the same-day spend before it.
#     A 15:00 request ($4) lands later; the balance is 50 - (2 + 4) = 44.
mkdir -p "$T/anc"
AD=2026-10-15
{ uline msg-k1 req-k1 m-a ${AD}T10:00:00Z $M 0; uline msg-k2 req-k2 m-a ${AD}T14:00:00Z $((2 * M)) 0; } > "$P/K.jsonl"
KL="$T/anc/k.jsonl"
# fresh FILE...: an mtime on the fixture day. calibrate reads a transcript only when it
# was modified on or after 00:00 UTC of the anchor's day (an older one cannot hold its
# requests), and the fixture day is later than the wall clock.
fresh() { touch -d "${AD}T23:00:00Z" "$@"; }
hk K "$KL" SYG_CREDIT_NOW=${AD}T14:30:00Z
fresh "$P/K.jsonl"
cal=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- calibrate 50 --at ${AD}T12:00:00Z 2>&1); rc=$?
uline msg-k3 req-k3 m-a ${AD}T15:00:00Z $((4 * M)) 0 >> "$P/K.jsonl"
hk K "$KL" SYG_CREDIT_NOW=${AD}T15:30:00Z
fresh "$P/K.jsonl"
b=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- balance --json)
txt=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- balance 2>&1)
if [ "$rc" = 0 ] && [ "$cal" = $'anchored $50.00 at 2026-10-15T12:00:00Z (same-day spend before it $1.00)\napi credit $48.00 est' ] \
  && jq -e '(.anchors|length)==1 and .anchors[0].amount==50 and .anchors[0].at=="2026-10-15T12:00:00Z"
      and .anchors[0].pre_anchor_day_usd==1 and .anchors[0].recorded=="2026-10-15T16:00:00Z"' "$KL.anchor.json" > /dev/null; then
  ok "calibrate: anchor at 12:00 -> same-day spend before it \$1.00 (the 10:00 request only), record appended, balance line 'api credit \$48.00 est'"
else bad "calibrate mid-day: rc=$rc '$cal' / $(cat "$KL.anchor.json" 2>&1)"; fi
if near "$(jq .remaining_usd <<< "$b")" 44 && near "$(jq .spent_usd <<< "$b")" 6 \
  && jq -e '.anchor_usd==50 and .anchor_at=="2026-10-15T12:00:00Z" and .estimate==true and .live_grants==1 and .overage_usd==0' <<< "$b" > /dev/null \
  && [ "$txt" = $'api credit $44.00 est\nspent $6.00, lapsed $0.00, overage $0.00 (estimate; anchored $50.00 at 2026-10-15T12:00:00Z)' ]; then
  ok "anchor balance: 50 - (14:00 \$2 + 15:00 \$4) = 44, spent since the anchor 6, basis names the anchor"
else bad "anchor balance: $b / '$txt'"; fi
# SYG_CREDIT_ANCHOR moves the file: an anchor there governs only with the variable set.
ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_ANCHOR="$T/anc/custom.json" SYG_CREDIT_NOW=${AD}T16:00:00Z -- calibrate 10 --at ${AD}T15:30:00Z > /dev/null
bc=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_ANCHOR="$T/anc/custom.json" SYG_CREDIT_NOW=${AD}T16:00:00Z -- balance --json)
bd=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- balance --json)
near "$(jq .remaining_usd <<< "$bc")" 10 && near "$(jq .remaining_usd <<< "$bd")" 44 \
  && [ "$(jq '.anchors|length' "$T/anc/custom.json")" = 1 ] && [ "$(jq '.anchors|length' "$KL.anchor.json")" = 1 ] \
  && ok "SYG_CREDIT_ANCHOR: the anchor goes to that path (10 at 15:30, all 7 of the day's spend before it -> 10.00); the default file is untouched" \
  || bad "SYG_CREDIT_ANCHOR: $bc / $bd"

# 20b. calibrate without --at defaults to now: records anchor at now, balance line.
NATL="$T/anc/noat.jsonl"
{ uline msg-nat1 req-nat1 m-a ${AD}T10:00:00Z $M 0; } > "$P/NAT.jsonl"
hk NAT "$NATL" SYG_CREDIT_NOW=${AD}T10:30:00Z
fresh "$P/NAT.jsonl"
cal=$(ac SYG_CREDIT_LEDGER="$NATL" SYG_CREDIT_NOW=${AD}T12:00:00Z -- calibrate 50 2>&1); rc=$?
b=$(ac SYG_CREDIT_LEDGER="$NATL" SYG_CREDIT_NOW=${AD}T12:00:00Z -- balance --json)
if [ "$rc" = 0 ] && [ "$cal" = $'anchored $50.00 at 2026-10-15T12:00:00Z (same-day spend before it $1.00)\napi credit $50.00 est' ] \
  && jq -e '(.anchors|length)==1 and .anchors[0].amount==50 and .anchors[0].at=="2026-10-15T12:00:00Z"
      and .anchors[0].pre_anchor_day_usd==1 and .anchors[0].recorded=="2026-10-15T12:00:00Z"' "$NATL.anchor.json" > /dev/null \
  && near "$(jq .remaining_usd <<< "$b")" 50 && near "$(jq .spent_usd <<< "$b")" 0; then
  ok "calibrate without --at: defaults to now (records anchor at now, balance line 'api credit \$50.00 est')"
else bad "calibrate without --at: rc=$rc '$cal' / $b / $(cat "$NATL.anchor.json" 2>&1)"; fi

# 21. A top-up granted after the anchor adds its amount: 44 + 20.
echo '{"grants":[{"amount":20,"granted":"2026-10-15T13:00:00Z"}]}' > "$T/g-topup.json"
b=$(ac SYG_CREDIT_LEDGER="$KL" SYG_CREDIT_GRANTS="$T/g-topup.json" SYG_CREDIT_NOW=${AD}T16:00:00Z -- balance --json)
near "$(jq .remaining_usd <<< "$b")" 64 && near "$(jq .granted_total_live <<< "$b")" 70 \
  && ok "anchor + post-anchor grant: 20 granted at 13:00 adds to 44 -> 64 (live total 50 + 20)" || bad "anchor top-up: $b"

# 22. Pre-anchor grants are absorbed: grant 100 (expires 10-17), 20 spent before the
#     anchor day -> replay remainder 80 at the anchor.
echo '{"grants":[{"amount":100,"granted":"2026-10-10","expires":"2026-10-17"}]}' > "$T/g-abs.json"
entry p 2026-10-12 2026-10-12T12:00:00Z 20 > "$T/anc/a30.jsonl"
cp "$T/anc/a30.jsonl" "$T/anc/a120.jsonl"
entry q 2026-10-17 2026-10-17T12:00:00Z 5 >> "$T/anc/a120.jsonl"
ab() { ac SYG_CREDIT_LEDGER="$T/anc/$1.jsonl" SYG_CREDIT_GRANTS="$T/g-abs.json" SYG_CREDIT_NOW="$2" -- "${@:3}"; }
ab a30 ${AD}T13:00:00Z calibrate 30 --at ${AD}T12:00:00Z > /dev/null
ab a120 ${AD}T13:00:00Z calibrate 120 --at ${AD}T12:00:00Z > /dev/null
b1=$(ab a30 2026-10-16T00:00:00Z balance --json)
b2=$(ab a30 2026-10-18T00:00:00Z balance --json); t2=$(ab a30 2026-10-18T00:00:00Z statusline < /dev/null)
if near "$(jq .remaining_usd <<< "$b1")" 30 && near "$(jq .granted_total_live <<< "$b1")" 30 \
  && jq -e '.next_expiry=="2026-10-17T00:00:00Z" and .live_grants==2' <<< "$b1" > /dev/null \
  && near "$(jq .remaining_usd <<< "$b2")" 0 && near "$(jq .lapsed_usd <<< "$b2")" 30 && [ "$t2" = 'api credit $0.00 est' ]; then
  ok "anchor absorption: A=30 within remainder 80 -> one pool of 30 expiring 10-17 (cash pool 0); after 10-17 it lapses -> 'api credit \$0.00 est'"
else bad "anchor absorption A=30: $b1 / $b2 / '$t2'"; fi
# Before the expiry: a120's anchor over a30's ledger (the same entries without the 10-17
# spend, which balance() would replay even with now before it).
b1=$(ac SYG_CREDIT_LEDGER="$T/anc/a30.jsonl" SYG_CREDIT_GRANTS="$T/g-abs.json" SYG_CREDIT_NOW=2026-10-16T00:00:00Z \
  SYG_CREDIT_ANCHOR="$T/anc/a120.jsonl.anchor.json" -- balance --json)
b2=$(ab a120 2026-10-18T00:00:00Z balance --json)
if near "$(jq .remaining_usd <<< "$b1")" 120 && [ "$(jq -r .next_expiry <<< "$b1")" = 2026-10-17T00:00:00Z ] \
  && near "$(jq .granted_total_live <<< "$b1")" 120 \
  && near "$(jq .remaining_usd <<< "$b2")" 35 && near "$(jq .lapsed_usd <<< "$b2")" 80 && near "$(jq .granted_total_live <<< "$b2")" 40; then
  ok "anchor absorption: A=120 over remainder 80 -> pool 80 expiring 10-17 + cash 40; the pool lapses, 5 spent after it -> 35"
else bad "anchor absorption A=120: $b1 / $b2"; fi

# 23. Provider + anchor: buckets 10-12 (5.00) and 10-13 (3.00); anchor 50 at 10-12 12:00
#     with 1.00 of the day's ledger spend before it; 10-14's ledger 1.50 is bridged.
echo '{"data":[{"starting_at":"2026-10-12T00:00:00Z","ending_at":"2026-10-13T00:00:00Z","results":[{"currency":"USD","amount":"500"}]},{"starting_at":"2026-10-13T00:00:00Z","ending_at":"2026-10-14T00:00:00Z","results":[{"currency":"USD","amount":"300"}]}],"has_more":false}' > "$T/cr/anc.json"
{ entry a 2026-10-12 2026-10-12T10:00:00Z 1; entry b 2026-10-12 2026-10-12T14:00:00Z 2
  entry c 2026-10-13 2026-10-13T12:00:00Z 2.5; entry d 2026-10-14 2026-10-14T12:00:00Z 1.5; } > "$T/anc/pv.jsonl"
PNOW=2026-10-14T15:00:00Z
ac SYG_CREDIT_LEDGER="$T/anc/pv.jsonl" SYG_CREDIT_NOW=$PNOW -- calibrate 50 --at 2026-10-12T12:00:00Z > /dev/null
echo anc > "$T/cr/mode"; : > "$T/cr/hits.log"
pv() { lv "$1" "${@:2}" SYG_CREDIT_LEDGER="$T/anc/pv.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_NOW=$PNOW; }
b=$(pv anc balance --json); txt=$(pv anc statusline < /dev/null)
req=$(head -n 1 "$T/cr/hits.log" | cut -f1)
if near "$(jq .remaining_usd <<< "$b")" 41.5 && near "$(jq .spent_usd <<< "$b")" 8.5 \
  && jq -e '.source=="provider" and .estimate==false and .provider_as_of=="2026-10-13" and .ledger_bridge_days==1 and .anchor_usd==50' <<< "$b" > /dev/null \
  && [ "$txt" = 'api credit $41.50' ] && [[ "$req" == *'starting_at=2026-10-12T00:00:00Z&ending_at=2026-10-14T00:00:00Z&'* ]]; then
  ok "anchor + provider: 50 - (5.00 - 1.00) - 3.00 - 1.50 bridged = 41.50, window from the anchor's day, source provider, text without est"
else bad "anchor + provider: $b / '$txt' / $req"; fi
t2=$(pv anc balance | sed -n 2p)
[ "$t2" = 'spent $8.50, lapsed $0.00, overage $0.00 (provider through 2026-10-13; today and lapsed, from the ledger; anchored $50.00 at 2026-10-12T12:00:00Z)' ] \
  && ok "anchor + provider: basis names today and lapsed as ledger-supplied" || bad "anchor + provider basis: '$t2'"
echo 401 > "$T/cr/mode"
b=$(pv anc-fail balance --json); txt=$(pv anc-fail statusline < /dev/null)
near "$(jq .remaining_usd <<< "$b")" 44 && jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null' <<< "$b" > /dev/null \
  && [ "$txt" = 'api credit $44.00 est' ] \
  && ok "anchor + provider failure: the anchored ledger estimate 50 - (3 - 1) - 2.50 - 1.50 = 44, labeled ledger, 'est'" || bad "anchor + provider failure: $b / '$txt'"
# A bucket with amounts but an unparsable starting_at (the mock keeps "later") has no day
# to subtract from: the anchored path falls back too, never reading high.
echo nostart > "$T/cr/mode"
b=$(pv anc-nostart balance --json)
near "$(jq .remaining_usd <<< "$b")" 44 && jq -e '.source=="ledger" and .estimate==true' <<< "$b" > /dev/null \
  && ok "anchor + provider: a dayless bucket with amounts -> labeled ledger fallback (44), not a figure missing its spend" || bad "anchor + provider dayless bucket: $b"
echo ok > "$T/cr/mode"

# 24. calibrate errors: usage (exit 2, nothing written), a straddling session whose
#     transcript is gone (exit 1, file unchanged), an unparsable anchor file.
EL="$T/anc/e.jsonl"
printf '{"session_id":"gone","day":"2026-10-15","first_ts":"2026-10-15T10:00:00Z","last_ts":"2026-10-15T14:00:00Z","cost_usd":3,"transcript_path":"%s/GONE.jsonl"}\n' "$P" > "$EL"
ce() { ac SYG_CREDIT_LEDGER="$EL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- calibrate "$@" > /dev/null 2>&1; echo $?; }
codes="$(ce 10 --at 2026-10-15) $(ce 10 --at 2026-10-15T12:00:00) $(ce 10 --at 2026-10-15T17:00:00Z) $(ce -5) $(ce nan) $(ce inf)"
[ "$codes" = "2 2 2 2 2 2" ] && [ ! -e "$EL.anchor.json" ] \
  && ok "calibrate usage: date-only --at, no offset, future --at, negative, nan, inf AMOUNT -> exit 2, no anchor file" || bad "calibrate usage codes: $codes"
c1=$(ce 10 --at ${AD}T09:00:00Z); sum1=$(cksum < "$EL.anchor.json")
err=$(ac SYG_CREDIT_LEDGER="$EL" SYG_CREDIT_NOW=${AD}T16:00:00Z -- calibrate 10 --at ${AD}T12:00:00Z 2>&1 > /dev/null); rc=$?
[ "$c1" = 0 ] && [ "$rc" = 1 ] && [ "$(cksum < "$EL.anchor.json")" = "$sum1" ] \
  && [ "$err" = "api-credit: cannot split session gone's 2026-10-15 spend at 2026-10-15T12:00:00Z: its transcript is gone; choose --at outside 2026-10-15T10:00:00Z..2026-10-15T14:00:00Z" ] \
  && ok "calibrate: a session with no transcript straddling --at -> exit 1, named on stderr, anchor file unchanged (before it: exit 0)" \
  || bad "calibrate straddle: c1=$c1 rc=$rc '$err'"
chmod 640 "$EL.anchor.json"
c2=$(ce 10 --at ${AD}T15:00:00Z)
[ "$c2" = 0 ] && [ "$(stat -c %a "$EL.anchor.json")" = 640 ] \
  && jq -e '(.anchors|length)==2 and .anchors[0].pre_anchor_day_usd==0 and .anchors[1].pre_anchor_day_usd==3' "$EL.anchor.json" > /dev/null \
  && ok "calibrate: after the session's last request it counts whole (3.00); history kept (2 records); file mode 640 survives the rewrite" \
  || bad "calibrate append: c2=$c2 mode $(stat -c %a "$EL.anchor.json") $(cat "$EL.anchor.json")"
cp "$KL" "$T/anc/pf.jsonl"
err=$(ac SYG_CREDIT_LEDGER="$T/anc/pf.jsonl" SYG_CREDIT_NOW=${AD}T16:00:00Z SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-fail.sh" -- calibrate 10 --at ${AD}T12:00:00Z 2>&1); rc=$?
[ "$rc" = 1 ] && [ ! -e "$T/anc/pf.jsonl.anchor.json" ] && grep -q '^api-credit: calibrate failed:' <<< "$err" \
  && ok "calibrate: a failing price table -> exit 1, nothing written" || bad "calibrate price failure: rc=$rc '$err'"
UL="$T/anc/u.jsonl"
cp "$T/lv.jsonl" "$UL"
echo 'not json' > "$UL.anchor.json"
err=$(ac SYG_CREDIT_LEDGER="$UL" SYG_CREDIT_NOW="$LNOW" -- calibrate 10 2>&1 > /dev/null); rc=$?
ref=$(ac SYG_CREDIT_LEDGER="$UL" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_ANCHOR="$T/anc/none.json" SYG_CREDIT_NOW="$LNOW" -- balance --json)
b=$(ac SYG_CREDIT_LEDGER="$UL" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- balance --json 2> "$T/anc/err.txt")
serr=$(ac SYG_CREDIT_LEDGER="$UL" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- statusline 2>&1 < /dev/null)
[ "$rc" = 1 ] && [ "$(cat "$UL.anchor.json")" = 'not json' ] && grep -q 'unreadable anchor file' <<< "$err" \
  && [ "$b" = "$ref" ] && [ "$b" = "$nk" ] && [ "$(cat "$T/anc/err.txt")" = "api-credit: ignoring unreadable anchor file $UL.anchor.json" ] \
  && [ "$serr" = "$nkt" ] \
  && ok "unparsable anchor file: calibrate refuses (exit 1, file kept); balance ignores it with one stderr line; statusline silent" \
  || bad "unparsable anchor: rc=$rc '$err' / $b / $(cat "$T/anc/err.txt") / '$serr'"

# 25. The current, unhooked turn: the entry holds r1 (10:00, $1); r2 (11:00, $2) is in
#     the transcript only. Both are before the 12:00 anchor (S = 3); once the hook
#     records r2 it is not counted again as spend after the anchor.
{ uline msg-n1 req-n1 m-a ${AD}T10:00:00Z $M 0; } > "$P/N.jsonl"
NL="$T/anc/n.jsonl"
hk N "$NL" SYG_CREDIT_NOW=${AD}T10:30:00Z
uline msg-n2 req-n2 m-a ${AD}T11:00:00Z $((2 * M)) 0 >> "$P/N.jsonl"
fresh "$P/N.jsonl"
cal=$(ac SYG_CREDIT_LEDGER="$NL" SYG_CREDIT_NOW=${AD}T12:00:00Z -- calibrate 47 --at ${AD}T12:00:00Z)
hk N "$NL" SYG_CREDIT_NOW=${AD}T12:30:00Z
b=$(ac SYG_CREDIT_LEDGER="$NL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- balance --json)
[ "$(head -n 1 <<< "$cal")" = 'anchored $47.00 at 2026-10-15T12:00:00Z (same-day spend before it $3.00)' ] \
  && near "$(jq .remaining_usd <<< "$b")" 47 && near "$(jq .spent_usd <<< "$b")" 0 \
  && ok "calibrate: a request the entry does not hold yet (unhooked turn) counts before the anchor (S 3.00); after the hook, remaining 47, spent 0" \
  || bad "calibrate unhooked turn: '$cal' / $b"
# A resumed session copies another session's request: it counts once (as the owner's).
{ uline msg-o1 req-o1 m-a ${AD}T10:00:00Z $M 0; } > "$P/OA.jsonl"
{ uline msg-o1 req-o1 m-a ${AD}T10:00:00Z $M 0; uline msg-o2 req-o2 m-a ${AD}T10:30:00Z $((2 * M)) 0; } > "$P/OB.jsonl"
OL="$T/anc/o.jsonl"
hk OA "$OL" SYG_CREDIT_NOW=${AD}T11:00:00Z; hk OB "$OL" SYG_CREDIT_NOW=${AD}T11:00:00Z
fresh "$P/OA.jsonl" "$P/OB.jsonl"
cal=$(ac SYG_CREDIT_LEDGER="$OL" SYG_CREDIT_NOW=${AD}T12:00:00Z -- calibrate 47 --at ${AD}T12:00:00Z | head -n 1)
[ "$cal" = 'anchored $47.00 at 2026-10-15T12:00:00Z (same-day spend before it $3.00)' ] \
  && ok "calibrate: a request another session's entry holds is not counted twice (S 1 + 2 = 3.00, not 4.00)" || bad "calibrate cross-session copy: '$cal'"
# A session crossing UTC midnight: its only entry is on the day before (23:00, $1); its
# next turn (00:30 on the anchor's day, $2) is unhooked at calibrate. S counts it; once
# the hook records it, it is not spend after the anchor: remaining 47.
{ uline msg-x1 req-mx1 m-a 2026-10-14T23:00:00Z $M 0; } > "$P/MX.jsonl"
XL="$T/anc/mx.jsonl"
hk MX "$XL" SYG_CREDIT_NOW=2026-10-14T23:30:00Z
uline msg-x2 req-mx2 m-a ${AD}T00:30:00Z $((2 * M)) 0 >> "$P/MX.jsonl"
fresh "$P/MX.jsonl"
cal=$(ac SYG_CREDIT_LEDGER="$XL" SYG_CREDIT_NOW=${AD}T12:00:00Z -- calibrate 47 --at ${AD}T12:00:00Z | head -n 1)
hk MX "$XL" SYG_CREDIT_NOW=${AD}T12:30:00Z
b=$(ac SYG_CREDIT_LEDGER="$XL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- balance --json)
[ "$cal" = 'anchored $47.00 at 2026-10-15T12:00:00Z (same-day spend before it $2.00)' ] \
  && near "$(jq .remaining_usd <<< "$b")" 47 && near "$(jq .spent_usd <<< "$b")" 0 \
  && ok "calibrate: a session whose only entry is the day before -> its unhooked turn on the anchor's day counts (S 2.00); after the hook, remaining 47" \
  || bad "calibrate cross-midnight session: '$cal' / $b"
# A transcript last modified before the anchor's day is not read (it cannot hold that day's requests).
# Unread is observable: no price-table run (pt-calls stays empty), and the day's entry
# takes the whole/zero rule (00:30 is before 13:00: $2.00).
touch -d 2026-10-14T23:59:00Z "$P/MX.jsonl"
: > "$T/pt-calls"
cal=$(ac SYG_CREDIT_LEDGER="$XL" SYG_CREDIT_ANCHOR="$T/anc/mx-old.json" SYG_CREDIT_NOW=${AD}T14:00:00Z -- calibrate 47 --at ${AD}T13:00:00Z 2>&1 | head -n 1)
[ "$cal" = 'anchored $47.00 at 2026-10-15T13:00:00Z (same-day spend before it $2.00)' ] && [ ! -s "$T/pt-calls" ] \
  && ok "calibrate: a transcript older than the anchor's day is skipped unread (no price-table run); the day's entry counts whole (\$2.00)" \
  || bad "calibrate stale transcript: '$cal' / price-table runs $(nlines "$T/pt-calls")"

# 26. Pools fill latest-expiring first: grants 50 (expires 10-17) and 50 (expires 10-20),
#     nothing spent; A=60 -> pool 50 to 10-20 and 10 to 10-17. After 10-17, 50 remain.
echo '{"grants":[{"amount":50,"granted":"2026-10-10","expires":"2026-10-17"},{"amount":50,"granted":"2026-10-10","expires":"2026-10-20"}]}' > "$T/g-two.json"
: > "$T/anc/two.jsonl"
ac SYG_CREDIT_LEDGER="$T/anc/two.jsonl" SYG_CREDIT_GRANTS="$T/g-two.json" SYG_CREDIT_NOW=${AD}T13:00:00Z -- calibrate 60 --at ${AD}T12:00:00Z > /dev/null
b=$(ac SYG_CREDIT_LEDGER="$T/anc/two.jsonl" SYG_CREDIT_GRANTS="$T/g-two.json" SYG_CREDIT_NOW=2026-10-18T00:00:00Z -- balance --json)
near "$(jq .remaining_usd <<< "$b")" 50 && near "$(jq .lapsed_usd <<< "$b")" 10 && [ "$(jq -r .next_expiry <<< "$b")" = 2026-10-20T00:00:00Z ] \
  && ok "anchor pools: A=60 over 50 (exp 10-17) + 50 (exp 10-20) -> the later grant's pool is filled first; after 10-17: remaining 50, lapsed 10" \
  || bad "anchor pool order: $b"

# 27. The governing anchor is the latest "at" no later than now: a backdated record
#     appended later does not govern; a record dated after now is ignored until then.
GL="$T/anc/gov.jsonl"; : > "$GL"
ac SYG_CREDIT_LEDGER="$GL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- calibrate 30 --at ${AD}T12:00:00Z > /dev/null
ac SYG_CREDIT_LEDGER="$GL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- calibrate 99 --at ${AD}T09:00:00Z > /dev/null
jq -c '.anchors += [{"amount":5,"at":"2026-10-20T00:00:00Z","pre_anchor_day_usd":0,"recorded":"2026-10-15T13:00:00Z"}]' "$GL.anchor.json" > "$GL.anchor.new" && mv "$GL.anchor.new" "$GL.anchor.json"
g1=$(ac SYG_CREDIT_LEDGER="$GL" SYG_CREDIT_NOW=${AD}T14:00:00Z -- balance --json)
g2=$(ac SYG_CREDIT_LEDGER="$GL" SYG_CREDIT_NOW=2026-10-20T01:00:00Z -- balance --json)
jq -e '.anchor_usd==30 and .remaining_usd==30' <<< "$g1" > /dev/null && jq -e '.anchor_usd==5 and .remaining_usd==5' <<< "$g2" > /dev/null \
  && ok "governing anchor: the backdated 99 (appended later) and the future 5 lose to 30 at 12:00; once now passes 10-20, the 5 governs" \
  || bad "governing anchor: $g1 / $g2"

# 28. calibrate -0 stores and prints 0, never -0.
ZL="$T/anc/z.jsonl"; : > "$ZL"
cal=$(ac SYG_CREDIT_LEDGER="$ZL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- calibrate -0 --at ${AD}T12:00:00Z | head -n 1)
[ "$cal" = 'anchored $0.00 at 2026-10-15T12:00:00Z (same-day spend before it $0.00)' ] && grep -q '"amount": 0.0,' "$ZL.anchor.json" \
  && ok "calibrate -0 -> 'anchored \$0.00', stored 0.0 (no -0)" || bad "calibrate -0: '$cal' / $(cat "$ZL.anchor.json")"

# 29. A day-D entry whose last_ts does not parse is skipped by the anchor's day event
#     (as balance() and pre_anchor_spend skip it): not 100 of spend after the anchor.
WL="$T/anc/w.jsonl"
{ printf '{"session_id":"w","day":"2026-10-15","first_ts":"garbage","last_ts":"garbage","cost_usd":100}\n'; } > "$WL"
ac SYG_CREDIT_LEDGER="$WL" SYG_CREDIT_NOW=${AD}T13:00:00Z -- calibrate 20 --at ${AD}T12:00:00Z > /dev/null
b=$(ac SYG_CREDIT_LEDGER="$WL" SYG_CREDIT_NOW=${AD}T14:00:00Z -- balance --json)
near "$(jq .remaining_usd <<< "$b")" 20 && near "$(jq .overage_usd <<< "$b")" 0 \
  && ok "anchor day event: an entry with an unparsable last_ts is skipped -> remaining 20, no overage" || bad "anchor unparsable last_ts: $b"

# 30. Provider FIFO overlap closure: grant A ($100, 10-01..10-04) overlaps
#     live grant B ($100, 10-03..12-01); $30 spent on 10-03 is drawn from A before A lapses,
#     leaving B at 100.00 and 70.00 lapsed, with the request window starting at 10-01 (A's day).
#     Control: B granted 10-05 (no overlap with A) -> window starts at 10-05, remaining 100.00.
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-04"},{"amount":100,"granted":"2026-10-03","expires":"2026-12-01"}]}' > "$T/g-f2.json"
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-04"},{"amount":100,"granted":"2026-10-05","expires":"2026-12-01"}]}' > "$T/g-f2-ctl.json"
echo '{"data":[{"starting_at":"2026-10-03T00:00:00Z","ending_at":"2026-10-04T00:00:00Z","results":[{"currency":"USD","amount":"3000"}]}],"has_more":false}' > "$T/cr/f2.json"
: > "$T/f2-empty.jsonl"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b=$(lv f2 balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-f2.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
req=$(head -n 1 "$T/cr/hits.log")
if near "$(jq .remaining_usd <<< "$b")" 100 && near "$(jq .lapsed_usd <<< "$b")" 70 && near "$(jq .spent_usd <<< "$b")" 30 \
  && jq -e '.source=="provider" and .estimate==false and .ledger_lapsed_usd==0' <<< "$b" > /dev/null \
  && [[ "$req" == *'starting_at=2026-10-01T00:00:00Z&'* ]]; then
  ok "provider FIFO closure: overlapping lapsed grant A absorbs 10-03's \$30 -> remaining 100.00, lapsed 70.00, window starts 2026-10-01"
else bad "provider FIFO closure: $b / '$req'"; fi
: > "$T/cr/hits.log"
b_ctl=$(lv f2ctl balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-f2-ctl.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
req_ctl=$(head -n 1 "$T/cr/hits.log")
if near "$(jq .remaining_usd <<< "$b_ctl")" 100 && jq -e '.source=="provider" and .estimate==false' <<< "$b_ctl" > /dev/null \
  && [[ "$req_ctl" == *'starting_at=2026-10-05T00:00:00Z&'* ]]; then
  ok "provider FIFO closure control: non-overlapping grant B (10-05) -> window starts 2026-10-05, remaining 100.00"
else bad "provider FIFO closure control: $b_ctl / '$req_ctl'"; fi
# 30b. Non-overlapping prior grant A ($100, 01-01..02-01, $90 ledger spend on 01-15) and live
#      grant B ($100, 03-01, no expiry, $5 provider spend on 03-10): unclamped window starts
#      at 03-01 with no pre-window events -> remaining 95.00, estimate false.
#      lapsed of a grant outside every overlap chain is not provider-backed.
echo '{"grants":[{"amount":100,"granted":"2026-01-01","expires":"2026-02-01"},{"amount":100,"granted":"2026-03-01"}]}' > "$T/g-prelapse.json"
entry a 2026-01-15 2026-01-15T12:00:00Z 90 > "$T/lv-prelapse.jsonl"
echo '{"data":[{"starting_at":"2026-03-10T00:00:00Z","ending_at":"2026-03-11T00:00:00Z","results":[{"currency":"USD","amount":"500"}]}],"has_more":false}' > "$T/cr/prelapse.json"
echo prelapse > "$T/cr/mode"; : > "$T/cr/hits.log"
b_pre=$(lv prelapse balance --json SYG_CREDIT_LEDGER="$T/lv-prelapse.jsonl" SYG_CREDIT_GRANTS="$T/g-prelapse.json" SYG_CREDIT_NOW=2026-04-01T12:00:00Z)
req_pre=$(head -n 1 "$T/cr/hits.log")
if near "$(jq .remaining_usd <<< "$b_pre")" 95 \
  && jq -e '.source=="provider" and .estimate==false' <<< "$b_pre" > /dev/null \
  && [[ "$req_pre" == *'starting_at=2026-03-01T00:00:00Z&'* ]]; then
  ok "provider non-overlapping prior grant: window starts 2026-03-01, remaining 95.00, estimate false"
else bad "provider non-overlapping prior grant: $b_pre / '$req_pre'"; fi
# 30c. Spend before every grant: one grant ($100, 09-01..12-01), ledger entry $15 on 08-20,
#      provider bucket $10 on 09-05, now 09-10 -> overage 0, spent 10, remaining 90, estimate false.
echo '{"grants":[{"amount":100,"granted":"2026-09-01","expires":"2026-12-01"}]}' > "$T/g-pregrant.json"
entry a 2026-08-20 2026-08-20T12:00:00Z 15 > "$T/lv-pregrant.jsonl"
echo '{"data":[{"starting_at":"2026-09-05T00:00:00Z","ending_at":"2026-09-06T00:00:00Z","results":[{"currency":"USD","amount":"1000"}]}],"has_more":false}' > "$T/cr/pregrant.json"
echo pregrant > "$T/cr/mode"; : > "$T/cr/hits.log"
b_pg=$(lv pregrant balance --json SYG_CREDIT_LEDGER="$T/lv-pregrant.jsonl" SYG_CREDIT_GRANTS="$T/g-pregrant.json" SYG_CREDIT_NOW=2026-09-10T12:00:00Z)
if near "$(jq .overage_usd <<< "$b_pg")" 0 && near "$(jq .spent_usd <<< "$b_pg")" 10 && near "$(jq .remaining_usd <<< "$b_pg")" 90 \
  && jq -e '.source=="provider" and .estimate==false' <<< "$b_pg" > /dev/null; then
  ok "provider unclamped pre-grant ledger entry ignored: overage 0, spent 10.00, remaining 90.00, estimate false"
else bad "provider pre-grant ledger entry: $b_pg"; fi
# 30d. Clamped overlap chain (> 366 days back): 3 chained $100 grants (01-01..01-10,
#      12-01..12-10, 11-01..11-10) at now 12-01, ledger $40 on 06-01 -> request window
#      clamped to now's day minus 366 days, estimate true, source provider, basis names clamp day.
echo '{"grants":[{"amount":100,"granted":"2025-01-01","expires":"2026-01-10"},{"amount":100,"granted":"2025-12-01","expires":"2026-12-10"},{"amount":100,"granted":"2026-11-01","expires":"2027-11-10"}]}' > "$T/g-chain.json"
entry a 2025-06-01 2025-06-01T12:00:00Z 40 > "$T/lv-chain.jsonl"
clamp_day=$(date -u -d '2026-12-01 - 366 days' +%Y-%m-%d)
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_ch=$(lv chain balance --json SYG_CREDIT_LEDGER="$T/lv-chain.jsonl" SYG_CREDIT_GRANTS="$T/g-chain.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
txt_ch=$(lv chain balance SYG_CREDIT_LEDGER="$T/lv-chain.jsonl" SYG_CREDIT_GRANTS="$T/g-chain.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
req_ch=$(head -n 1 "$T/cr/hits.log")
if near "$(jq .remaining_usd <<< "$b_ch")" 170 && near "$(jq .lapsed_usd <<< "$b_ch")" 60 && near "$(jq .spent_usd <<< "$b_ch")" 70 \
  && jq -e --arg cd "$clamp_day" '.source=="provider" and .estimate==true and .provider_clamped==true and .provider_subday==false and .ledger_lapsed_usd==0 and .provider_window_start==$cd' <<< "$b_ch" > /dev/null \
  && [[ "$req_ch" == *"starting_at=${clamp_day}T00:00:00Z&"* ]] \
  && [ "$txt_ch" = $'api credit $170.00 est (exp 12-10, 8d)\nspent $70.00, lapsed $60.00, overage $0.00 (provider through 2026-10-03; today and spend before '"$clamp_day"$', from the ledger)' ]; then
  ok "provider clamped closure: window starts at $clamp_day (now - 366d), pre-clamp \$40 replayed (spent 70, lapsed 60, remaining 170), estimate true, basis names $clamp_day"
else bad "provider clamped closure: $b_ch / '$txt_ch' / '$req_ch'"; fi
# 30e. Sub-day grant times inside the window: G expires 10-03T06:00:00Z, L granted
#      10-03T12:00:00Z, provider $30 on 10-03, now 10-09 -> estimate true, source provider.
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-03T06:00:00Z"},{"amount":100,"granted":"2026-10-03T12:00:00Z","expires":"2026-12-01"}]}' > "$T/g-subday.json"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_sd=$(lv subday balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-subday.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
txt_sd=$(lv subday balance SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-subday.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
if jq -e '.source=="provider" and .estimate==true and .provider_subday==true and .provider_window_start=="2026-10-03"' <<< "$b_sd" > /dev/null \
  && [[ "$txt_sd" == *'from the ledger; grant times mid-day)' ]]; then
  ok "provider sub-day grant times in window (06:00Z expiry, 12:00Z grant on 10-03) -> source provider, estimate true, provider_subday true, basis names mid-day"
else bad "provider sub-day grant times: $b_sd / '$txt_sd'"; fi
# 30f. Fetch failure carries provider_window_start alongside provider_as_of null.
echo nodata > "$T/cr/mode"
b_fw=$(lv fb-wstart balance --json)
echo ok > "$T/cr/mode"
if jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null and .provider_window_start=="2026-10-05" and .ledger_bridge_days==null' <<< "$b_fw" > /dev/null; then
  ok "provider fetch failure (nodata): provider_window_start set to 2026-10-05 alongside provider_as_of null"
else bad "provider fetch failure provider_window_start: $b_fw"; fi
# 30g. Sub-day expiry trigger only (G 10-01..10-03T06:00:00Z, L granted 10-03 date-only) -> estimate true.
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-03T06:00:00Z"},{"amount":100,"granted":"2026-10-03","expires":"2026-12-01"}]}' > "$T/g-subday-exp.json"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_sdg=$(lv subday-exp balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-subday-exp.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
if jq -e '.source=="provider" and .estimate==true and .provider_subday==true' <<< "$b_sdg" > /dev/null; then
  ok "provider sub-day expiry trigger only (G expires 10-03T06:00:00Z, L date-only) -> estimate true"
else bad "provider sub-day expiry trigger only: $b_sdg"; fi
# 30h. Sub-day grant trigger only (G 10-01..10-03 date-only, L granted 10-03T12:00:00Z) -> estimate true.
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-10-03"},{"amount":100,"granted":"2026-10-03T12:00:00Z","expires":"2026-12-01"}]}' > "$T/g-subday-gr.json"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_sdh=$(lv subday-gr balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-subday-gr.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
if jq -e '.source=="provider" and .estimate==true and .provider_subday==true' <<< "$b_sdh" > /dev/null; then
  ok "provider sub-day grant trigger only (G date-only, L granted 10-03T12:00:00Z) -> estimate true"
else bad "provider sub-day grant trigger only: $b_sdh"; fi
# 30i. Sub-day grant time today (L granted <now's day>T09:00:00Z alongside an older date-only
#      live grant, no other sub-day time) -> exact on ledger timestamps, estimate false.
echo '{"grants":[{"amount":100,"granted":"2026-10-01","expires":"2026-12-01"},{"amount":50,"granted":"2026-10-09T09:00:00Z","expires":"2026-12-01"}]}' > "$T/g-subday-today.json"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_sdi=$(lv subday-today balance --json SYG_CREDIT_LEDGER="$T/f2-empty.jsonl" SYG_CREDIT_GRANTS="$T/g-subday-today.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
if jq -e '.source=="provider" and .estimate==false and .provider_subday==false' <<< "$b_sdi" > /dev/null; then
  ok "provider sub-day grant time today (10-09T09:00:00Z, after provider_as_of) -> estimate false, provider_subday false"
else bad "provider sub-day grant time today: $b_sdi"; fi
# 30j. Old grant out of the chain (O $50 granted 09-01 expires 09-10, ledger entry $20 on 09-05)
#      plus the case-30 grants -> lapsed_usd = 30 (O, ledger) + 70 (A, provider) = 100,
#      ledger_lapsed_usd == 30, basis names lapses before 10-01.
echo '{"grants":[{"amount":50,"granted":"2026-09-01","expires":"2026-09-10"},{"amount":100,"granted":"2026-10-01","expires":"2026-10-04"},{"amount":100,"granted":"2026-10-03","expires":"2026-12-01"}]}' > "$T/g-30j.json"
entry a 2026-09-05 2026-09-05T12:00:00Z 20 > "$T/lv-30j.jsonl"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_30j=$(lv f2-30j balance --json SYG_CREDIT_LEDGER="$T/lv-30j.jsonl" SYG_CREDIT_GRANTS="$T/g-30j.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
txt_30j=$(lv f2-30j balance SYG_CREDIT_LEDGER="$T/lv-30j.jsonl" SYG_CREDIT_GRANTS="$T/g-30j.json" SYG_CREDIT_NOW=2026-10-09T15:00:00Z)
echo ok > "$T/cr/mode"
if near "$(jq .remaining_usd <<< "$b_30j")" 100 && near "$(jq .lapsed_usd <<< "$b_30j")" 100 \
  && near "$(jq .ledger_lapsed_usd <<< "$b_30j")" 30 && near "$(jq .spent_usd <<< "$b_30j")" 30 \
  && jq -e '.source=="provider" and .estimate==false and .provider_clamped==false and .provider_subday==false' <<< "$b_30j" > /dev/null \
  && [ "$txt_30j" = $'api credit $100.00 (exp 12-01, 52d)\nspent $30.00, lapsed $100.00, overage $0.00 (provider through 2026-10-03; today and lapses before 2026-10-01, from the ledger)' ]; then
  ok "provider per-grant lapse split: O (30 from ledger) + A (70 from provider) = 100 lapsed, ledger_lapsed_usd 30, basis names lapses before 2026-10-01"
else bad "provider per-grant lapse split: $b_30j / '$txt_30j'"; fi
# 30k. Clamped chain with an older out-of-chain lapsed grant (O $50 granted 11-01..12-01
#      before the chain, ledger entry $20 on 11-15) plus the case-30d chained grants
#      and pre-clamp $40 on 06-01 -> lapsed_usd = 30 (O, ledger) + 60 (chain, provider) = 90,
#      ledger_lapsed_usd == 30, provider_chain_start names the chain start, and the basis joins
#      today, lapses before <chain start> and spend before <clamp day>.
echo '{"grants":[{"amount":50,"granted":"2024-11-01","expires":"2024-12-01"},{"amount":100,"granted":"2025-01-01","expires":"2026-01-10"},{"amount":100,"granted":"2025-12-01","expires":"2026-12-10"},{"amount":100,"granted":"2026-11-01","expires":"2027-11-10"}]}' > "$T/g-30k.json"
{ entry o 2024-11-15 2024-11-15T12:00:00Z 20; entry a 2025-06-01 2025-06-01T12:00:00Z 40; } > "$T/lv-30k.jsonl"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_30k=$(lv f2-30k balance --json SYG_CREDIT_LEDGER="$T/lv-30k.jsonl" SYG_CREDIT_GRANTS="$T/g-30k.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
txt_30k=$(lv f2-30k balance SYG_CREDIT_LEDGER="$T/lv-30k.jsonl" SYG_CREDIT_GRANTS="$T/g-30k.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
echo ok > "$T/cr/mode"
if near "$(jq .remaining_usd <<< "$b_30k")" 170 && near "$(jq .lapsed_usd <<< "$b_30k")" 90 \
  && near "$(jq .ledger_lapsed_usd <<< "$b_30k")" 30 && near "$(jq .spent_usd <<< "$b_30k")" 70 \
  && jq -e --arg cd "$clamp_day" '.source=="provider" and .estimate==true and .provider_clamped==true and .provider_subday==false and .provider_chain_start=="2025-01-01" and .provider_window_start==$cd' <<< "$b_30k" > /dev/null \
  && [ "$txt_30k" = $'api credit $170.00 est (exp 12-10, 8d)\nspent $70.00, lapsed $90.00, overage $0.00 (provider through 2026-10-03; today, lapses before 2025-01-01 and spend before '"$clamp_day"$', from the ledger)' ]; then
  ok "provider clamped + pre-chain lapse: lapsed 90 (30 pre-chain + 60 in-chain), provider_chain_start 2025-01-01, three-part basis join"
else bad "provider clamped + pre-chain lapse: $b_30k / '$txt_30k'"; fi

# 31. SYG_CREDIT_ADMIN_KEY_CMD: lazy command key source when ANTHROPIC_ADMIN_API_KEY is empty.
cat > "$T/key-ok.sh" <<EOF
#!/bin/bash
echo x >> "$T/key-calls"
printf 'fixture-admin-key\n'
EOF
cat > "$T/key-arg.sh" <<'EOF'
#!/bin/bash
[ "$1" = "two words" ] && [ "$#" = 1 ] && printf 'fixture-admin-key\n'
EOF
cat > "$T/key-fail.sh" <<EOF
#!/bin/bash
echo x >> "$T/key-fail-calls"
exit 1
EOF
cat > "$T/key-nl.sh" <<'EOF'
#!/bin/bash
printf 'a\nb\n'
EOF
cat > "$T/key-hang.sh" <<'EOF'
#!/bin/bash
sleep 30 &
echo $! > "$(dirname "$0")/key-hang.pid"
sleep 30
EOF
chmod +x "$T/key-ok.sh" "$T/key-arg.sh" "$T/key-fail.sh" "$T/key-nl.sh" "$T/key-hang.sh"
ref_env=$(lv kref balance --json)
: > "$T/key-calls"; : > "$T/cr/hits.log"; : > "$T/cr/argv.log"
b1=$(lv kcmd balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh")
b2=$(lv kcmd balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh" SYG_CREDIT_NOW=2026-10-09T15:01:00Z)
kcf="$T/cache-kcmd/claude-statusline/api-credit-live.json"
want_kid=$(printf 'cmd\0%s' "$T/key-ok.sh" | sha256sum | cut -d' ' -f1)
if [ "$(jq -c '[.remaining_usd, .source]' <<< "$b1")" = "$(jq -c '[.remaining_usd, .source]' <<< "$ref_env")" ] \
  && [ "$(jq -c '[.remaining_usd, .source]' <<< "$b2")" = "$(jq -c '[.remaining_usd, .source]' <<< "$ref_env")" ] \
  && [ "$(nlines "$T/key-calls")" = 1 ] && [ "$(hits)" = 1 ] \
  && [ "$(jq -r 'keys[0]' "$kcf" | cut -d' ' -f1)" = "$want_kid" ] \
  && ! grep -q fixture-admin-key "$kcf" && ! grep -q fixture-admin-key "$T/cr/argv.log"; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD: matches env-key provider balance, runs once across TTL cache hit (1 call), cache keyed by cmd hash"
else bad "SYG_CREDIT_ADMIN_KEY_CMD ok/lazy: b1=$b1 / b2=$b2 / calls=$(nlines "$T/key-calls") / hits=$(hits)"; fi
ba=$(lv karg balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-arg.sh 'two words'" SYG_CREDIT_KEY_CMD_TIMEOUT=invalid)
if [ "$(jq -c '[.remaining_usd, .source]' <<< "$ba")" = "$(jq -c '[.remaining_usd, .source]' <<< "$ref_env")" ] \
  && jq -e '.source=="provider" and .estimate==false' <<< "$ba" > /dev/null; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD shlex: quoted 'two words' argument passed as one token -> source provider (invalid timeout falls back to 15)"
else bad "SYG_CREDIT_ADMIN_KEY_CMD shlex: $ba"; fi
: > "$T/key-fail-calls"
bf=$(lv kfail balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-fail.sh")
bf59=$(lv kfail balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-fail.sh" SYG_CREDIT_NOW=2026-10-09T15:00:59Z)
kf59=$(nlines "$T/key-fail-calls")
bf61=$(lv kfail balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-fail.sh" SYG_CREDIT_NOW=2026-10-09T15:01:01Z)
kf61=$(nlines "$T/key-fail-calls")
bn=$(lv knl balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-nl.sh")
if jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null and .ledger_bridge_days==null' <<< "$bf" > /dev/null \
  && jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null and .ledger_bridge_days==null' <<< "$bn" > /dev/null; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD failure (exit 1) and embedded newline -> labeled ledger fallback"
else bad "SYG_CREDIT_ADMIN_KEY_CMD fallback: fail=$bf / nl=$bn"; fi
if [ "$kf59" = 1 ] && [ "$kf61" = 2 ] \
  && jq -e '.source=="ledger" and .estimate==true' <<< "$bf59" > /dev/null \
  && jq -e '.source=="ledger" and .estimate==true' <<< "$bf61" > /dev/null; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD failure TTL: cached at +59 s (1 run), retried at +61 s (2 runs, not 300 s)"
else bad "SYG_CREDIT_ADMIN_KEY_CMD failure TTL: kf59=$kf59 kf61=$kf61 / $bf59 / $bf61"; fi
t0=$SECONDS
bh=$(lv khang balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-hang.sh" SYG_CREDIT_KEY_CMD_TIMEOUT=1)
elapsed=$(( SECONDS - t0 ))
if [ "$elapsed" -lt 8 ] && ! kill -0 "$(cat "$T/key-hang.pid")" 2>/dev/null && jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null and .ledger_bridge_days==null' <<< "$bh" > /dev/null; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD timeout: background child holding stdout killed with process group (elapsed ${elapsed}s < 8s) -> source ledger"
else bad "SYG_CREDIT_ADMIN_KEY_CMD timeout: elapsed=${elapsed}s / $bh"; fi
: > "$T/key-calls"
be=$(lv kenv balance --json ANTHROPIC_ADMIN_API_KEY=fixture-admin-key SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh")
if [ ! -s "$T/key-calls" ] && jq -e '.source=="provider" and .estimate==false' <<< "$be" > /dev/null; then
  ok "SYG_CREDIT_ADMIN_KEY_CMD with ANTHROPIC_ADMIN_API_KEY set: env wins, command never run"
else bad "SYG_CREDIT_ADMIN_KEY_CMD env precedence: calls=$(nlines "$T/key-calls") / $be"; fi
# 31b. A CR/LF ANTHROPIC_ADMIN_API_KEY alongside a command: the env key is itself
#      unusable (a CR/LF key could inject a curl -K directive), so the command source
#      wins -> the provider balance, the command run once. Control: the kenv row above
#      (a clean env key short-circuits, the command never runs).
echo ok > "$T/cr/mode"; : > "$T/cr/hits.log"; : > "$T/key-calls"
b=$(lv kcr balance --json ANTHROPIC_ADMIN_API_KEY=$'bad\rkey' SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh")
if [ "$(jq -c '[.remaining_usd, .source, .estimate]' <<< "$b")" = "$(jq -c '[.remaining_usd, .source, .estimate]' <<< "$ref_env")" ] \
  && [ "$(nlines "$T/key-calls")" = 1 ] && [ "$(hits)" = 1 ]; then
  ok "CR/LF env key + command: the command source wins -> provider balance, command run once"
else bad "CR/LF env key + command: $b / calls=$(nlines "$T/key-calls") / hits=$(hits)"; fi
# 31c. Cold-fetch lock: the miss path holds a non-blocking flock beside the live cache;
#      a render finding it held runs neither the key command nor the fetch (the labeled
#      ledger estimate, nothing cached), and a render after the release fetches.
klock_dir="$T/cache-klock/claude-statusline"; mkdir -p "$klock_dir"
: > "$T/key-calls"; : > "$T/cr/hits.log"
( exec 9>"$klock_dir/api-credit-live.json.lock"; flock -x 9; sleep 2 ) & khold=$!
sleep 0.3
b_held=$(lv klock balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh")
wait "$khold"
held_calls=$(nlines "$T/key-calls"); held_hits=$(hits)
b_free=$(lv klock balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh")
if [ "$held_calls" = 0 ] && [ "$held_hits" = 0 ] \
  && jq -e '.source=="ledger" and .estimate==true and .provider_as_of==null' <<< "$b_held" > /dev/null \
  && jq -e '.source=="provider" and .estimate==false' <<< "$b_free" > /dev/null; then
  ok "cold-fetch lock: lock held -> no key command, no fetch, ledger estimate, nothing cached; released -> provider fetch"
else bad "cold-fetch lock: held=$b_held calls=$held_calls hits=$held_hits / free=$b_free"; fi

# 32. balance --month: month-to-date spend (provider closed days + ledger bridge, else ledger)
#     and multi-window cache (up to 4 windows; old 2-line cache treated as a miss).
cat > "$T/cr/month.json" <<'EOF'
{"data":[
 {"starting_at":"2026-10-02T00:00:00Z","ending_at":"2026-10-03T00:00:00Z","results":[{"currency":"USD","amount":"400"}]},
 {"starting_at":"2026-10-05T00:00:00Z","ending_at":"2026-10-06T00:00:00Z","results":[{"currency":"USD","amount":"370.289"}]},
 {"starting_at":"2026-10-08T00:00:00Z","ending_at":"2026-10-09T00:00:00Z","results":[{"currency":"USD","amount":"1000"}]}
],"has_more":false,"next_page":null}
EOF
{
  entry p 2026-09-30 2026-09-30T12:00:00Z 9
  entry q 2026-10-03 2026-10-03T12:00:00Z 6
  entry a 2026-10-06 2026-10-06T12:00:00Z 5
  entry o 2026-10-08 2026-10-08T12:00:00Z 1
  entry b 2026-10-09 2026-10-09T12:00:00Z 2.5
} > "$T/lv-month.jsonl"
echo month > "$T/cr/mode"; : > "$T/cr/hits.log"
# 32a. Without --month: no month_* keys and no month-window request.
b_nom=$(lv m-off balance --json SYG_CREDIT_LEDGER="$T/lv-month.jsonl")
if [ "$(hits)" = 1 ] && ! grep -q 'starting_at=2026-10-01T00:00:00Z' "$T/cr/hits.log" \
  && jq -e '([keys[]|select(startswith("month_"))]|length)==0' <<< "$b_nom" > /dev/null; then
  ok "balance --json without --month: no month_* keys and no month-window request"
else bad "balance without --month: hits $(hits) / $(cat "$T/cr/hits.log") / $b_nom"; fi
# 32b. Mid-month with admin key + multi-window cache reuse across balance --month and balance.
: > "$T/cr/hits.log"
b_m=$(lv m-on balance --month --json SYG_CREDIT_LEDGER="$T/lv-month.jsonl")
h_m1=$(hits)
b_m2=$(lv m-on balance --json SYG_CREDIT_LEDGER="$T/lv-month.jsonl" SYG_CREDIT_NOW=2026-10-09T15:01:00Z)
txt_m=$(lv m-on balance --month SYG_CREDIT_LEDGER="$T/lv-month.jsonl" SYG_CREDIT_NOW=2026-10-09T15:01:00Z)
h_m2=$(hits)
m_req=$(sed -n 2p "$T/cr/hits.log" | cut -f1)
if [ "$h_m1" = 2 ] && [ "$h_m2" = 2 ] \
  && [[ "$m_req" == *'starting_at=2026-10-01T00:00:00Z&ending_at=2026-10-09T00:00:00Z&'* ]] \
  && near "$(jq .spent_usd <<< "$b_m")" 16.20289 && near "$(jq .month_spend_usd <<< "$b_m")" 20.20289 \
  && jq -e '.month_start=="2026-10-01" and .month_as_of=="2026-10-08" and .month_source=="provider" and .month_bridge_days==1' <<< "$b_m" > /dev/null \
  && near "$(jq .remaining_usd <<< "$b_m2")" 83.79711 \
  && [ "$(head -n 1 <<< "$txt_m")" = 'api credit $83.80 (exp 10-21, 11d) · month $20.20' ]; then
  ok "balance --month mid-month with admin key: window [2026-10-01, 2026-10-09), month_spend_usd 20.20289 (17.70289 provider + 2.50 today), both windows cached across follow-up balance call, text appends ' · month \$20.20'"
else bad "balance --month mid-month: h=$h_m1/$h_m2 req='$m_req' / $b_m / '$txt_m'"; fi
# 32c. Mid-month without admin key: ledger-only, month_source ledger, month_as_of null.
: > "$T/cr/hits.log"
b_mnk=$(ac SYG_CREDIT_LEDGER="$T/lv-month.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- balance --month --json)
txt_mnk=$(ac SYG_CREDIT_LEDGER="$T/lv-month.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$LNOW" -- balance --month | head -n 1)
if [ "$(hits)" = 0 ] && near "$(jq .month_spend_usd <<< "$b_mnk")" 14.5 \
  && jq -e '.month_start=="2026-10-01" and .month_source=="ledger" and .month_as_of==null and .month_bridge_days==0' <<< "$b_mnk" > /dev/null \
  && [ "$txt_mnk" = 'api credit $91.50 est (exp 10-21, 11d) · month $14.50 est' ]; then
  ok "balance --month without admin key: ledger-only (6 + 5 + 1 + 2.5 = 14.50, 09-30 excluded; the 10-08 entry sits on the provider as_of day in 32b and must not be double-counted there), month_source ledger, month_as_of null, text appends ' · month \$14.50 est'"
else bad "balance --month no-key: hits $(hits) / $b_mnk / '$txt_mnk'"; fi
# 32d. On the 1st of the month: no fetch for the month window, ledger only.
echo '{"grants":[{"amount":100,"granted":"2026-09-25","expires":"2026-10-21"}]}' > "$T/g-sep.json"
{ entry p 2026-09-30 2026-09-30T12:00:00Z 9; entry r 2026-10-01 2026-10-01T08:00:00Z 3; } > "$T/lv-first.jsonl"
: > "$T/cr/hits.log"
b_1st=$(lv m-1st balance --month --json SYG_CREDIT_LEDGER="$T/lv-first.jsonl" SYG_CREDIT_GRANTS="$T/g-sep.json" SYG_CREDIT_NOW=2026-10-01T12:00:00Z)
if [ "$(hits)" = 1 ] && ! grep -q 'starting_at=2026-10-01T00:00:00Z' "$T/cr/hits.log" \
  && near "$(jq .month_spend_usd <<< "$b_1st")" 3 \
  && jq -e '.month_start=="2026-10-01" and .month_source=="ledger" and .month_as_of==null and .month_bridge_days==0 and .source=="provider"' <<< "$b_1st" > /dev/null; then
  ok "balance --month on the 1st of the month: no month-window fetch (only balance window fetched), month_spend_usd 3.00 from ledger, month_source ledger"
else bad "balance --month 1st: hits $(hits) / $(cat "$T/cr/hits.log") / $b_1st"; fi
# 32e. Fetch failure: falls back to ledger, month_source ledger.
echo 401 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_mf=$(lv m-fail balance --month --json SYG_CREDIT_LEDGER="$T/lv-month.jsonl")
txt_mf=$(lv m-fail balance --month SYG_CREDIT_LEDGER="$T/lv-month.jsonl" | head -n 1)
echo ok > "$T/cr/mode"
if near "$(jq .month_spend_usd <<< "$b_mf")" 14.5 \
  && jq -e '.month_start=="2026-10-01" and .month_source=="ledger" and .month_as_of==null and .month_bridge_days==0 and .source=="ledger"' <<< "$b_mf" > /dev/null \
  && [ "$txt_mf" = 'api credit $91.50 est (exp 10-21, 11d) · month $14.50 est' ]; then
  ok "balance --month fetch failure: falls back to ledger (14.50), month_source ledger, month_as_of null"
else bad "balance --month failure: $b_mf / '$txt_mf'"; fi
# 32e2. Provider answers with no bucket this month (as_of before month_start): all ledger, labelled ledger.
echo nobucket > "$T/cr/mode"; : > "$T/cr/hits.log"
b_mnb=$(lv m-nob balance --month --json SYG_CREDIT_LEDGER="$T/lv-month.jsonl")
echo ok > "$T/cr/mode"
if near "$(jq .month_spend_usd <<< "$b_mnb")" 14.5 \
  && jq -e '.month_source=="ledger" and .month_as_of==null and .month_bridge_days==0' <<< "$b_mnb" > /dev/null; then
  ok "balance --month with no provider bucket this month: all-ledger 14.50 labelled month_source ledger, month_as_of null"
else bad "balance --month no bucket: $b_mnb"; fi
# 32f. Anchored balance with --month: month figure is independent of the anchor.
echo anc > "$T/cr/mode"; : > "$T/cr/hits.log"
b_am=$(pv anc-m balance --month --json)
echo ok > "$T/cr/mode"
if near "$(jq .remaining_usd <<< "$b_am")" 41.5 && near "$(jq .spent_usd <<< "$b_am")" 8.5 && near "$(jq .month_spend_usd <<< "$b_am")" 9.5 \
  && jq -e '.anchor_usd==50 and .month_start=="2026-10-01" and .month_source=="provider" and .month_as_of=="2026-10-13" and .month_bridge_days==1' <<< "$b_am" > /dev/null; then
  ok "balance --month with anchor: remaining 41.50 and spent 8.50 from anchor, month_spend_usd 9.50 (5.00 + 3.00 + 1.50) independent of anchor"
else bad "balance --month with anchor: $b_am"; fi
# 32g. Old 2-line cache format treated as a miss and overwritten; cache caps at 4 windows.
mkdir -p "$T/cache-oldfmt/claude-statusline"
printf 'deadbeef %s 2026-10-05T00:00:00Z 2026-10-09T00:00:00Z\n{"as_of":"2026-10-08","days":{},"fetched_at":"2026-10-09T15:00:00Z","spent":"0"}\n' "$CR" > "$T/cache-oldfmt/claude-statusline/api-credit-live.json"
: > "$T/cr/hits.log"
b_oldc=$(lv oldfmt balance --json)
if [ "$(hits)" = 1 ] && jq -e 'type=="object" and (keys|length)==1' "$T/cache-oldfmt/claude-statusline/api-credit-live.json" > /dev/null \
  && near "$(jq .spent_usd <<< "$b_oldc")" 16.20289; then
  ok "cache: old 2-line format treated as a miss and overwritten with JSON object"
else bad "cache old format: hits $(hits) / $b_oldc / $(cat "$T/cache-oldfmt/claude-statusline/api-credit-live.json")"; fi
for d in 02 03 04 05 06; do
  echo "{\"grants\":[{\"amount\":100,\"granted\":\"2026-10-$d\",\"expires\":\"2026-10-21\"}]}" > "$T/g-cap-$d.json"
  lv cap4 balance --json SYG_CREDIT_GRANTS="$T/g-cap-$d.json" SYG_CREDIT_NOW="2026-10-09T15:0${d#0}:00Z" > /dev/null
done
capf="$T/cache-cap4/claude-statusline/api-credit-live.json"
if [ "$(jq 'keys|length' "$capf")" = 4 ] && ! jq -e 'any(keys[]; contains("2026-10-02T00:00:00Z"))' "$capf" > /dev/null \
  && jq -e 'any(keys[]; contains("2026-10-06T00:00:00Z"))' "$capf" > /dev/null; then
  ok "cache cap: 5 windows fetched -> at most 4 kept, oldest evicted"
else bad "cache cap: $(cat "$capf")"; fi

# 33. Recent provider days settle window (SYG_CREDIT_SETTLE_DAYS, default 2):
#     closed days in [as_of - (N-1), as_of] within the fetch window take max(provider, ledger).
echo ok > "$T/cr/mode"
# 33a. ledger > provider on as_of (10-08: ledger 9 + 6 = 15 vs provider 10): ledger amount used,
#      estimate true, provider_unsettled_days 1, statusline text has "est".
{ entry a1 2026-10-08 2026-10-08T10:00:00Z 9; entry a2 2026-10-08 2026-10-08T18:00:00Z 6; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-s-asof.jsonl"
b_sa=$(lv s-asof balance --json SYG_CREDIT_LEDGER="$T/lv-s-asof.jsonl")
txt_sa=$(lv s-asof statusline SYG_CREDIT_LEDGER="$T/lv-s-asof.jsonl" < /dev/null)
if near "$(jq .spent_usd <<< "$b_sa")" 21.20289 && near "$(jq .remaining_usd <<< "$b_sa")" 78.79711 \
  && jq -e '.source=="provider" and .estimate==true and .provider_unsettled_days==1 and .provider_as_of=="2026-10-08"' <<< "$b_sa" > /dev/null \
  && [ "$txt_sa" = 'api credit $78.80 est (exp 10-21, 11d)' ]; then
  ok "settle window: ledger (15.00) > provider (10.00) on as_of -> spent 21.20289, remaining 78.79711, estimate true, unsettled 1, text has est"
else bad "settle window ledger > provider on as_of: $b_sa / '$txt_sa'"; fi

# 33b. provider > ledger on as_of (10-08: provider 10 vs ledger 6): provider amount used,
#      estimate false, provider_unsettled_days 0.
{ entry a 2026-10-08 2026-10-08T12:00:00Z 6; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-s-prov.jsonl"
b_sp=$(lv s-prov balance --json SYG_CREDIT_LEDGER="$T/lv-s-prov.jsonl")
txt_sp=$(lv s-prov statusline SYG_CREDIT_LEDGER="$T/lv-s-prov.jsonl" < /dev/null)
if near "$(jq .spent_usd <<< "$b_sp")" 16.20289 && near "$(jq .remaining_usd <<< "$b_sp")" 83.79711 \
  && jq -e '.source=="provider" and .estimate==false and .provider_unsettled_days==0' <<< "$b_sp" > /dev/null \
  && [ "$txt_sp" = 'api credit $83.80 (exp 10-21, 11d)' ]; then
  ok "settle window: provider (10.00) > ledger (6.00) on as_of -> provider amount used, estimate false, unsettled 0"
else bad "settle window provider > ledger: $b_sp / '$txt_sp'"; fi

# 33c. Days older than N (10-05 ledger 20 vs provider 3.70289; 10-06 ledger 5 vs provider 0,
#      with as_of 10-08 and N=2 -> settle window is 10-07..10-08): provider amount used.
{ entry o1 2026-10-05 2026-10-05T12:00:00Z 20; entry o2 2026-10-06 2026-10-06T12:00:00Z 5; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-s-old.jsonl"
b_so=$(lv s-old balance --json SYG_CREDIT_LEDGER="$T/lv-s-old.jsonl")
if near "$(jq .spent_usd <<< "$b_so")" 16.20289 && near "$(jq .remaining_usd <<< "$b_so")" 83.79711 \
  && jq -e '.source=="provider" and .estimate==false and .provider_unsettled_days==0' <<< "$b_so" > /dev/null; then
  ok "settle window: ledger > provider on days older than N (10-05, 10-06 with as_of 10-08, N=2) -> provider amount used"
else bad "settle window older than N: $b_so"; fi

# 33d. SYG_CREDIT_SETTLE_DAYS=0: identical to pre-settle provider output for the same fixture.
b_s0=$(lv s-asof balance --json SYG_CREDIT_LEDGER="$T/lv-s-asof.jsonl" SYG_CREDIT_SETTLE_DAYS=0)
txt_s0=$(lv s-asof statusline SYG_CREDIT_LEDGER="$T/lv-s-asof.jsonl" SYG_CREDIT_SETTLE_DAYS=0 < /dev/null)
if [ "$b_s0" = "$b_sp" ] && [ "$txt_s0" = 'api credit $83.80 (exp 10-21, 11d)' ] \
  && jq -e '.estimate==false and .provider_unsettled_days==0' <<< "$b_s0" > /dev/null; then
  ok "SYG_CREDIT_SETTLE_DAYS=0: identical to provider-only output on the ledger > provider fixture"
else bad "SYG_CREDIT_SETTLE_DAYS=0: $b_s0 / '$txt_s0' vs $b_sp"; fi

# 33e. SYG_CREDIT_SETTLE_DAYS=bogus (and empty or negative): behaves as 2.
{ entry o 2026-10-06 2026-10-06T12:00:00Z 5; entry d1 2026-10-07 2026-10-07T12:00:00Z 4; entry d2 2026-10-08 2026-10-08T12:00:00Z 15; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-s-2d.jsonl"
b_s2=$(lv s-2d balance --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl")
b_sbog=$(lv s-2d balance --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl" SYG_CREDIT_SETTLE_DAYS=bogus)
b_semp=$(lv s-2d balance --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl" SYG_CREDIT_SETTLE_DAYS=)
b_sneg=$(lv s-2d balance --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl" SYG_CREDIT_SETTLE_DAYS=-1)
b_s1=$(lv s-2d balance --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl" SYG_CREDIT_SETTLE_DAYS=1)
if near "$(jq .spent_usd <<< "$b_s2")" 25.20289 && near "$(jq .remaining_usd <<< "$b_s2")" 74.79711 \
  && jq -e '.estimate==true and .provider_unsettled_days==2' <<< "$b_s2" > /dev/null \
  && [ "$b_sbog" = "$b_s2" ] && [ "$b_semp" = "$b_s2" ] && [ "$b_sneg" = "$b_s2" ] \
  && near "$(jq .spent_usd <<< "$b_s1")" 21.20289 && jq -e '.provider_unsettled_days==1' <<< "$b_s1" > /dev/null; then
  ok "SYG_CREDIT_SETTLE_DAYS=bogus (and empty/-1): behaves as 2 (10-07 +4 and 10-08 +5 settled, 10-06 ignored -> unsettled 2; N=1 -> unsettled 1)"
else bad "SYG_CREDIT_SETTLE_DAYS=bogus: s2=$b_s2 / bog=$b_sbog / s1=$b_s1"; fi

# 33f. Anchored path with ledger > provider on the anchor day: max applied before pre-anchor subtraction.
{ entry a 2026-10-12 2026-10-12T10:00:00Z 1; entry b 2026-10-12 2026-10-12T14:00:00Z 7
  entry c 2026-10-13 2026-10-13T12:00:00Z 2.5; entry d 2026-10-14 2026-10-14T12:00:00Z 1.5; } > "$T/anc/pv-settle.jsonl"
ac SYG_CREDIT_LEDGER="$T/anc/pv-settle.jsonl" SYG_CREDIT_NOW="$PNOW" -- calibrate 50 --at 2026-10-12T12:00:00Z > /dev/null
echo anc > "$T/cr/mode"
b_as=$(lv anc-s balance --json SYG_CREDIT_LEDGER="$T/anc/pv-settle.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_NOW="$PNOW")
txt_as=$(lv anc-s statusline SYG_CREDIT_LEDGER="$T/anc/pv-settle.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_NOW="$PNOW" < /dev/null)
if near "$(jq .remaining_usd <<< "$b_as")" 38.5 && near "$(jq .spent_usd <<< "$b_as")" 11.5 \
  && jq -e '.source=="provider" and .estimate==true and .provider_unsettled_days==1 and .provider_as_of=="2026-10-13" and .anchor_usd==50' <<< "$b_as" > /dev/null \
  && [ "$txt_as" = 'api credit $38.50 est' ]; then
  ok "anchor + settle window: 10-12 ledger 8.00 > provider 5.00 -> (8.00 - 1.00 pre) + 3.00 + 1.50 = 11.50 spent, remaining 38.50, estimate true, unsettled 1"
else bad "anchor + settle window: $b_as / '$txt_as'"; fi

# 33g. balance --month: settle-window excess added to month_spend_usd, month_estimate true, text has "est".
echo month > "$T/cr/mode"
b_ms=$(lv m-settle balance --month --json SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl")
txt_ms=$(lv m-settle balance --month SYG_CREDIT_LEDGER="$T/lv-s-2d.jsonl" | head -n 1)
echo ok > "$T/cr/mode"
if near "$(jq .month_spend_usd <<< "$b_ms")" 29.20289 \
  && jq -e '.month_source=="provider" and .month_estimate==true and .month_as_of=="2026-10-08" and .month_bridge_days==1' <<< "$b_ms" > /dev/null \
  && jq -e '.month_estimate==false' <<< "$b_m" > /dev/null \
  && jq -e '.month_estimate==true' <<< "$b_mnk" > /dev/null \
  && [ "$txt_ms" = 'api credit $74.80 est (exp 10-21, 11d) · month $29.20 est' ]; then
  ok "balance --month + settle window: provider 17.70289 + excess 9.00 (10-07 +4, 10-08 +5; 10-06 excluded) + 2.50 today = 29.20289, month_source provider, month_estimate true, text ' · month \$29.20 est'"
else bad "balance --month + settle window: $b_ms / '$txt_ms' / b_m=$b_m"; fi

# 34. Per-request long-prompt rate cards (price-table --json .long) and settle-window edge cases.
cat > "$T/prices-long.json" <<'EOF'
{"or_keys":[],"table":{
 "m-long":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25},
 "m-bad":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25}
},"long":{
 "m-long":{"above":1000,"input":10,"output":20,"cacheRead":5,"cacheWrite":12.5},
 "m-orphan":{"above":1000,"input":10,"output":20,"cacheRead":5,"cacheWrite":12.5},
 "m-bad":{"above":1000,"input":10,"output":20,"cacheRead":5}
}}
EOF
printf '#!/bin/bash\n[ "$1" = --json ] || exit 9\ncat %q\n' "$T/prices-long.json" > "$T/pt-long.sh"
chmod +x "$T/pt-long.sh"

# 34a. Long card threshold (above: 1000): prompt = input + cache_read + cache_write_5m + cache_write_1h.
#      - L1000: prompt = 400 + 300 + 200 + 100 = 1000 (output 500 excluded from prompt) -> base rates:
#        (400*1 + 500*2 + 300*0.5 + 200*1.25 + 100*2*1) / 1e6 = (400 + 1000 + 150 + 250 + 200) / 1e6 = 0.002
#      - L1001: prompt = 401 + 300 + 200 + 100 = 1001 > 1000 -> long rates (1h write at 2x long input = 20):
#        (401*10 + 500*20 + 300*5 + 200*12.5 + 100*2*10) / 1e6 = (4010 + 10000 + 1500 + 2500 + 2000) / 1e6 = 0.02001
uline msg-l1 req-l1 m-long ${D1}T10:00:00Z 400 500 300 200 100 > "$P/L1000.jsonl"
uline msg-l2 req-l2 m-long ${D1}T10:01:00Z 401 500 300 200 100 > "$P/L1001.jsonl"
hk L1000 "$T/l1000/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long.sh"
hk L1001 "$T/l1001/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long.sh"
e1000=$(cat "$T/l1000/l.jsonl")
e1001=$(cat "$T/l1001/l.jsonl")
if near "$(jq .cost_usd <<< "$e1000")" 0.002 && near "$(jq .cost_usd <<< "$e1001")" 0.02001 \
  && jq -e '.models["m-long"].cost_usd==0.002 and .unpriced_models==[]' <<< "$e1000" > /dev/null \
  && jq -e '.models["m-long"].cost_usd==0.02001 and .unpriced_models==[]' <<< "$e1001" > /dev/null; then
  ok "long card: prompt 1000 (== above) -> base rates (0.002); prompt 1001 (> above) -> long rates incl. 2x long input on 1h write (0.02001)"
else bad "long card 1000 vs 1001: $e1000 / $e1001"; fi

# 34b. Orphan long card (m-orphan has no table row) and malformed card (m-bad missing cacheWrite):
#      both ignored without crash; m-bad prices at base rates (1M input -> 1.00), m-orphan stays unpriced.
{ uline msg-lb1 req-lb1 m-bad ${D1}T10:00:00Z $M 0; uline msg-lb2 req-lb2 m-orphan ${D1}T10:01:00Z 2000 0; } > "$P/LBAD.jsonl"
hk LBAD "$T/lbad/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long.sh"
ebad=$(cat "$T/lbad/l.jsonl")
if near "$(jq .cost_usd <<< "$ebad")" 1 \
  && jq -e '.models["m-bad"].cost_usd==1 and .models["m-orphan"].cost_usd==null and .unpriced_models==["m-orphan"]' <<< "$ebad" > /dev/null; then
  ok "long card validation: orphan long card (no table row) and malformed card (missing cacheWrite) ignored -> base pricing 1.00, no crash"
else bad "long card validation: $ebad"; fi

# 34c. A price-table stub with no "long" key at all ($T/prices.json) prices as before.
uline msg-lnl req-lnl m-a ${D1}T10:00:00Z $M $((M / 2)) > "$P/LNOLONG.jsonl"
hk LNOLONG "$T/lnolong/l.jsonl"
enolong=$(cat "$T/lnolong/l.jsonl")
if jq -e 'has("long")|not' "$T/prices.json" > /dev/null && near "$(jq .cost_usd <<< "$enolong")" 2 \
  && jq -e '.models["m-a"].cost_usd==2 and .unpriced_models==[]' <<< "$enolong" > /dev/null; then
  ok "long card absent: stub without 'long' key prices m-a (1M in + 0.5M out = 2.00) unchanged"
else bad "long card absent: $enolong"; fi

# 34c2. Float above in long card: integral 1000.0 prices prompt 1001 on the long card (0.02001);
#       non-integral 1000.5 is ignored -> base rates (0.002001).
cat > "$T/prices-long-flt.json" <<'EOF'
{"or_keys":[],"table":{
 "m-flt-int":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25},
 "m-flt-frac":{"input":1,"output":2,"cacheRead":0.5,"cacheWrite":1.25}
},"long":{
 "m-flt-int":{"above":1000.0,"input":10,"output":20,"cacheRead":5,"cacheWrite":12.5},
 "m-flt-frac":{"above":1000.5,"input":10,"output":20,"cacheRead":5,"cacheWrite":12.5}
}}
EOF
printf '#!/bin/bash\n[ "$1" = --json ] || exit 9\ncat %q\n' "$T/prices-long-flt.json" > "$T/pt-long-flt.sh"
chmod +x "$T/pt-long-flt.sh"
uline msg-lf1 req-lf1 m-flt-int ${D1}T10:00:00Z 401 500 300 200 100 > "$P/LFLT1.jsonl"
uline msg-lf2 req-lf2 m-flt-frac ${D1}T10:01:00Z 401 500 300 200 100 > "$P/LFLT2.jsonl"
hk LFLT1 "$T/lflt1/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long-flt.sh"
hk LFLT2 "$T/lflt2/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long-flt.sh"
eflt1=$(cat "$T/lflt1/l.jsonl")
eflt2=$(cat "$T/lflt2/l.jsonl")
if near "$(jq .cost_usd <<< "$eflt1")" 0.02001 && near "$(jq .cost_usd <<< "$eflt2")" 0.002001 \
  && jq -e '.models["m-flt-int"].cost_usd==0.02001 and .unpriced_models==[]' <<< "$eflt1" > /dev/null \
  && jq -e '.models["m-flt-frac"].cost_usd==0.002001 and .unpriced_models==[]' <<< "$eflt2" > /dev/null; then
  ok "long card float above: integral 1000.0 prices prompt 1001 on long card (0.02001); non-integral 1000.5 ignored -> base rates (0.002001)"
else bad "long card float above: $eflt1 / $eflt2"; fi

# 34d. Clamped provider window together with the settle window:
#      g-chain.json (3x $100 chained grants) at a "now" over a year past the first grant
#      clamps the window to clamp_day. A pre-clamp ledger entry ($40) draws grant 1 to $60,
#      which then lapses (lapsed 60); on the provider as_of day (f2.json: provider $30) the
#      ledger has $45 -> the settle window takes $45 (unsettled 1); today has $5 bridged
#      -> spent 40 + 45 + 5 = 90, remaining 200 - 50 = 150.
{ entry pre 2025-06-01 2025-06-01T12:00:00Z 40; entry s 2026-10-03 2026-10-03T12:00:00Z 45; entry t 2026-12-01 2026-12-01T08:00:00Z 5; } > "$T/lv-s-clamp.jsonl"
echo f2 > "$T/cr/mode"; : > "$T/cr/hits.log"
b_sc=$(lv s-clamp balance --json SYG_CREDIT_LEDGER="$T/lv-s-clamp.jsonl" SYG_CREDIT_GRANTS="$T/g-chain.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
b_sc0=$(lv s-clamp balance --json SYG_CREDIT_LEDGER="$T/lv-s-clamp.jsonl" SYG_CREDIT_GRANTS="$T/g-chain.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z SYG_CREDIT_SETTLE_DAYS=0)
echo ok > "$T/cr/mode"
if near "$(jq .spent_usd <<< "$b_sc")" 90 && near "$(jq .remaining_usd <<< "$b_sc")" 150 && near "$(jq .lapsed_usd <<< "$b_sc")" 60 \
  && jq -e --arg cd "$clamp_day" '.source=="provider" and .estimate==true and .provider_clamped==true and .provider_unsettled_days==1 and .provider_window_start==$cd and .provider_as_of=="2026-10-03" and .ledger_bridge_days==1' <<< "$b_sc" > /dev/null \
  && near "$(jq .spent_usd <<< "$b_sc0")" 75 && near "$(jq .remaining_usd <<< "$b_sc0")" 165 \
  && jq -e '.provider_clamped==true and .provider_unsettled_days==0 and .estimate==true' <<< "$b_sc0" > /dev/null; then
  ok "settle window + clamped provider window: pre-clamp 40 + settled 45 (vs 30) + bridged 5 = 90 spent, remaining 150, clamped true, unsettled 1 (N=0 -> 75 spent, unsettled 0)"
else bad "settle window + clamped window: $b_sc / $b_sc0"; fi

# 34e. cost_report with no dated bucket (nobucket.json -> as_of is the day before the
#      window start): settle rows empty, provider_unsettled_days 0 even when the ledger
#      has an entry on the as_of day; in-window entries are bridged.
{ entry pre 2026-10-04 2026-10-04T12:00:00Z 99; entry a 2026-10-06 2026-10-06T12:00:00Z 5; entry b 2026-10-09 2026-10-09T12:00:00Z 2.5; } > "$T/lv-s-nobucket.jsonl"
echo nobucket > "$T/cr/mode"
b_snb=$(lv s-nobucket balance --json SYG_CREDIT_LEDGER="$T/lv-s-nobucket.jsonl")
echo ok > "$T/cr/mode"
if near "$(jq .spent_usd <<< "$b_snb")" 7.5 && near "$(jq .remaining_usd <<< "$b_snb")" 92.5 \
  && jq -e '.source=="provider" and .estimate==false and .provider_as_of=="2026-10-04" and .provider_window_start=="2026-10-05" and .provider_unsettled_days==0 and .ledger_bridge_days==2' <<< "$b_snb" > /dev/null; then
  ok "settle window + no dated bucket (as_of 2026-10-04 before window 2026-10-05): settle rows empty, provider_unsettled_days 0, estimate false, in-window 7.50 bridged"
else bad "settle window + no dated bucket: $b_snb"; fi

# 35. Per-kind remaining credit (remaining_by_kind, "by kind:" line, calibrate --kind).
# 35a. No anchor: grants A (kind "promo", $10, expires 10-20), B (kind "paid", $5,
#      expires 10-25), C (no kind, $3, no expiry).
#      - Spend $4 on 10-05 draws from soonest-expiring A ("promo"):
#        promo 10 - 4 = 6, paid 5, unspecified 3; remaining_usd = 14.
#        Text third line (draw order: promo exp 10-20, paid exp 10-25, unspecified None):
#        "by kind: promo $6.00, paid $5.00, unspecified $3.00"
#      - Spend $12 on 10-05 exhausts A ($10 -> 0, omitted) and draws $2 from B ("paid"):
#        paid 5 - 2 = 3, unspecified 3; remaining_usd = 6.
#        Text third line: "by kind: paid $3.00, unspecified $3.00"
#      - With a grants file whose grants have no kind (g-live.json): remaining_by_kind has
#        only "unspecified", so balance prints 2 lines (no third line).
#      - Without a usable grants file: remaining_by_kind == {}.
cat > "$T/g-35a.json" <<'EOF'
{"currency":"USD","grants":[
 {"amount":10,"granted":"2026-10-01","expires":"2026-10-20","kind":" promo "},
 {"amount":5,"granted":"2026-10-01","expires":"2026-10-25","kind":"paid"},
 {"amount":3,"granted":"2026-10-01"}
]}
EOF
NOW35=2026-10-15T12:00:00Z
entry s1 2026-10-05 2026-10-05T12:00:00Z 4 > "$T/k35-4.jsonl"
entry s1 2026-10-05 2026-10-05T12:00:00Z 12 > "$T/k35-12.jsonl"
b_35a4=$(ac SYG_CREDIT_LEDGER="$T/k35-4.jsonl" SYG_CREDIT_GRANTS="$T/g-35a.json" SYG_CREDIT_NOW="$NOW35" -- balance --json)
t_35a4=$(ac SYG_CREDIT_LEDGER="$T/k35-4.jsonl" SYG_CREDIT_GRANTS="$T/g-35a.json" SYG_CREDIT_NOW="$NOW35" -- balance)
b_35a12=$(ac SYG_CREDIT_LEDGER="$T/k35-12.jsonl" SYG_CREDIT_GRANTS="$T/g-35a.json" SYG_CREDIT_NOW="$NOW35" -- balance --json)
t_35a12=$(ac SYG_CREDIT_LEDGER="$T/k35-12.jsonl" SYG_CREDIT_GRANTS="$T/g-35a.json" SYG_CREDIT_NOW="$NOW35" -- balance)
t_35anok=$(ac SYG_CREDIT_LEDGER="$T/k35-4.jsonl" SYG_CREDIT_GRANTS="$T/g-live.json" SYG_CREDIT_NOW="$NOW35" -- balance)
b_35anog=$(ac SYG_CREDIT_LEDGER="$T/k35-4.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_NOW="$NOW35" -- balance --json)
if jq -e '.remaining_usd==14 and .remaining_by_kind=={"promo":6,"paid":5,"unspecified":3}' <<< "$b_35a4" > /dev/null \
  && [ "$(sed -n 3p <<< "$t_35a4")" = 'by kind: promo $6.00, paid $5.00, unspecified $3.00' ] \
  && jq -e '.remaining_usd==6 and .remaining_by_kind=={"paid":3,"unspecified":3}' <<< "$b_35a12" > /dev/null \
  && [ "$(wc -l <<< "$t_35a12" | tr -d ' ')" = 3 ] \
  && [ "$(sed -n 3p <<< "$t_35a12")" = 'by kind: paid $3.00, unspecified $3.00' ] \
  && [ "$(wc -l <<< "$t_35anok" | tr -d ' ')" = 2 ] \
  && jq -e '.remaining_by_kind=={}' <<< "$b_35anog" > /dev/null; then
  ok "35a: remaining_by_kind and 'by kind:' line (spend 4 -> promo 6, paid 5, unspecified 3; spend 12 -> promo omitted, paid 3, unspecified 3; no-kind grants -> 2 lines)"
else bad "35a: $b_35a4 / '$t_35a4' / $b_35a12 / '$t_35a12' / '$t_35anok' / $b_35anog"; fi

# 35b. Anchor without kinds: calibrate 12 over grants A ("promo", $10, exp 10-20) +
#      B ("paid", $5, exp 10-25), no pre-anchor spend.
#      - Anchor record has no "kinds" key.
#      - Pools fill latest-expiring first, capped at replay remainders (B: 5, A: 10):
#        B ("paid", exp 10-25) takes min(12, 5) = 5; A ("promo", exp 10-20) takes
#        min(12 - 5, 10) = 7; cash pool 0 -> remaining_by_kind == {"promo": 7, "paid": 5}.
cat > "$T/g-35b.json" <<'EOF'
{"currency":"USD","grants":[
 {"amount":10,"granted":"2026-10-01","expires":"2026-10-20","kind":"promo"},
 {"amount":5,"granted":"2026-10-01","expires":"2026-10-25","kind":"paid"}
]}
EOF
L35B="$T/anc/k35b.jsonl"; : > "$L35B"
cal_35b=$(ac SYG_CREDIT_LEDGER="$L35B" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" | head -n 1)
b_35b=$(ac SYG_CREDIT_LEDGER="$L35B" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
if [ "$cal_35b" = 'anchored $12.00 at 2026-10-15T12:00:00Z (same-day spend before it $0.00)' ] \
  && jq -e '(.anchors[0]|has("kinds"))|not' "$L35B.anchor.json" > /dev/null \
  && jq -e '.remaining_usd==12 and .remaining_by_kind=={"promo":7,"paid":5}' <<< "$b_35b" > /dev/null; then
  ok "35b: calibrate 12 without --kind -> no 'kinds' key in record, pools carry kinds (paid 5 latest-first, promo 7)"
else bad "35b: '$cal_35b' / $(cat "$L35B.anchor.json") / $b_35b"; fi

# 35c. Anchor with kinds: calibrate 12 --kind paid=2 over grants A+B.
#      - Record has kinds == {"paid": 2}; first printed line includes "(paid $2.00)".
#      - Stated kind "paid" takes 2 in B (exp 10-25); remaining 12 - 2 = 10 fills unstated
#        A ("promo", exp 10-20, full amount 10) -> remaining_by_kind == {"promo": 10, "paid": 2}.
#      - Then $3 spent after the anchor (on 10-16) draws soonest-expiring promo first:
#        promo 10 - 3 = 7, paid 2.
#      - With $4 pre-anchor spend (on 10-05, leaving promo replay remainder 6, paid 5):
#        * calibrate 12 --kind paid=2 leaves unstated promo uncapped at its full 10:
#          {"promo": 10, "paid": 2};
#        * calibrate 12 --kind promo=9 (stated promo uncapped at 10, unstated paid uncapped
#          at 5 takes 3): {"promo": 9, "paid": 3};
#        * no-kinds counterpart calibrate 12 (no --kind) caps at replay remainders
#          (paid 5, promo 6) and puts the leftover 1 in unspecified:
#          {"promo": 6, "paid": 5, "unspecified": 1}.
L35C="$T/anc/k35c.jsonl"; : > "$L35C"
cal_35c=$(ac SYG_CREDIT_LEDGER="$L35C" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind paid=2 | head -n 1)
b_35c1=$(ac SYG_CREDIT_LEDGER="$L35C" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
entry post 2026-10-16 2026-10-16T12:00:00Z 3 >> "$L35C"
b_35c2=$(ac SYG_CREDIT_LEDGER="$L35C" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-16T15:00:00Z -- balance --json)
L35C_PRE="$T/anc/k35c-pre.jsonl"
entry pre 2026-10-05 2026-10-05T12:00:00Z 4 > "$L35C_PRE"
ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind paid=2 > /dev/null
b_35c3=$(ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/k35c-uncap.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind promo=9 > /dev/null
b_35c4=$(ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/k35c-uncap.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/k35c-nokind.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" > /dev/null
b_35c5=$(ac SYG_CREDIT_LEDGER="$L35C_PRE" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/k35c-nokind.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
if [ "$cal_35c" = 'anchored $12.00 at 2026-10-15T12:00:00Z (paid $2.00) (same-day spend before it $0.00)' ] \
  && jq -e '.anchors[0].kinds=={"paid":2}' "$L35C.anchor.json" > /dev/null \
  && jq -e '.remaining_usd==12 and .remaining_by_kind=={"promo":10,"paid":2}' <<< "$b_35c1" > /dev/null \
  && jq -e '.remaining_usd==9 and .spent_usd==3 and .remaining_by_kind=={"promo":7,"paid":2}' <<< "$b_35c2" > /dev/null \
  && jq -e '.remaining_usd==12 and .remaining_by_kind=={"promo":10,"paid":2}' <<< "$b_35c3" > /dev/null \
  && jq -e '.remaining_usd==12 and .remaining_by_kind=={"promo":9,"paid":3}' <<< "$b_35c4" > /dev/null \
  && jq -e '.remaining_usd==12 and .remaining_by_kind=={"promo":6,"paid":5,"unspecified":1}' <<< "$b_35c5" > /dev/null; then
  ok "35c: calibrate 12 --kind paid=2 -> kinds {\"paid\":2}, promo 10 + paid 2; \$3 post-anchor spend -> promo 7, paid 2; stated + unstated uncapped with --kind, replay-capped without --kind (promo 6, paid 5, unspecified 1)"
else bad "35c: '$cal_35c' / $b_35c1 / $b_35c2 / $b_35c3 / $b_35c4 / $b_35c5"; fi

# 35d. calibrate --kind errors, each leaving the anchor file absent (and an existing one unchanged):
#      --kind paid (no =), --kind paid=-1, --kind =1, --kind paid=1 --kind paid=2,
#      --kind paid=20 with AMOUNT 12 -> exit 2; --kind nosuch=1 -> exit 1.
#      Stderr for duplicate kind ("duplicate --kind") and unknown kind ("matches no grant").
L35D="$T/anc/k35d.jsonl"; : > "$L35D"
ck35d() { ac SYG_CREDIT_LEDGER="$L35D" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" "$@" > /dev/null 2>&1; echo $?; }
codes_35d="$(ck35d --kind paid) $(ck35d --kind paid=-1) $(ck35d --kind =1) $(ck35d --kind paid=1 --kind paid=2) $(ck35d --kind paid=20) $(ck35d --kind nosuch=1)"
err_35d_dup=$(ac SYG_CREDIT_LEDGER="$L35D" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind paid=1 --kind paid=2 2>&1 > /dev/null)
sum_35c=$(cksum < "$L35C.anchor.json")
err_35d_unk=$(ac SYG_CREDIT_LEDGER="$L35C" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind nosuch=1 2>&1 > /dev/null)
if [ "$codes_35d" = "2 2 2 2 2 1" ] && [ ! -e "$L35D.anchor.json" ] && [ "$(cksum < "$L35C.anchor.json")" = "$sum_35c" ] \
  && [[ "$err_35d_dup" == *'duplicate --kind'* ]] && [[ "$err_35d_unk" == *'matches no grant'* ]]; then
  ok "35d: calibrate --kind errors (no '=', negative, empty kind, duplicate 'duplicate --kind', > AMOUNT -> exit 2; unknown kind 'matches no grant' -> exit 1), anchor file absent/unchanged"
else bad "35d: codes '$codes_35d' / dup='$err_35d_dup' / unk='$err_35d_unk' / exists $(ls "$L35D.anchor.json" 2>&1)"; fi

# 35e. Hand-written anchor file with malformed kinds ({"paid":"x"}, and one summing over
#      amount: {"paid":8,"promo":5} > 12): anchor still governs (anchor_usd == 12) and
#      falls back to the no-kinds split ({"promo": 7, "paid": 5}).
printf '{"anchors":[{"amount":12,"at":"2026-10-15T12:00:00Z","pre_anchor_day_usd":0,"recorded":"2026-10-15T13:00:00Z","kinds":{"paid":"x"}}]}\n' > "$T/anc/bad-k1.json"
printf '{"anchors":[{"amount":12,"at":"2026-10-15T12:00:00Z","pre_anchor_day_usd":0,"recorded":"2026-10-15T13:00:00Z","kinds":{"paid":8,"promo":5}}]}\n' > "$T/anc/bad-k2.json"
b_35e1=$(ac SYG_CREDIT_LEDGER="$L35B" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/bad-k1.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
b_35e2=$(ac SYG_CREDIT_LEDGER="$L35B" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_ANCHOR="$T/anc/bad-k2.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
if jq -e '.anchor_usd==12 and .remaining_usd==12 and .remaining_by_kind=={"promo":7,"paid":5}' <<< "$b_35e1" > /dev/null \
  && jq -e '.anchor_usd==12 and .remaining_usd==12 and .remaining_by_kind=={"promo":7,"paid":5}' <<< "$b_35e2" > /dev/null; then
  ok "35e: malformed anchor kinds ({paid:'x'} and sum > amount) -> anchor still governs (anchor_usd 12) with the no-kinds split (promo 7, paid 5)"
else bad "35e: $b_35e1 / $b_35e2"; fi

# 35f. Provider path with kinds on grants: ok.json has closed-day spend 3.70289 (10-05) +
#      10.00 (10-08) = 13.70289; lv.jsonl adds 2.50 bridged today (10-09) = 16.20289 total.
#      Grants: promo $20 (exp 10-15) + paid $80 (exp 10-21) -> promo takes all 16.20289:
#      promo 20 - 16.20289 = 3.79711, paid 80, remaining_usd 83.79711.
cat > "$T/g-35f.json" <<'EOF'
{"grants":[
 {"amount":20,"granted":"2026-10-05","expires":"2026-10-15","kind":"promo"},
 {"amount":80,"granted":"2026-10-05","expires":"2026-10-21","kind":"paid"}
]}
EOF
echo ok > "$T/cr/mode"
b_35f=$(lv k35f balance --json SYG_CREDIT_GRANTS="$T/g-35f.json")
if near "$(jq .remaining_usd <<< "$b_35f")" 83.79711 \
  && near "$(jq '.remaining_by_kind.promo' <<< "$b_35f")" 3.79711 \
  && near "$(jq '.remaining_by_kind.paid' <<< "$b_35f")" 80 \
  && jq -e '.source=="provider" and .estimate==false and (.remaining_by_kind|keys)==["paid","promo"]' <<< "$b_35f" > /dev/null; then
  ok "35f: provider path with kinds -> remaining_by_kind promo 3.79711 (20 - 16.20289), paid 80.00"
else bad "35f: $b_35f"; fi

# 35h. Stated kind larger than its grants: calibrate 14 --kind paid=7 over g-35b
#      (paid grant $5 exp 10-25, promo grant $10 exp 10-20) -> paid 7 (5 in the grant +
#      2 excess keeping latest paid expiry 10-25), promo 7; after 10-25 (at 10-26) both
#      paid pools (5 + 2 = 7) and promo (7) have lapsed -> paid omitted, remaining 0,
#      lapsed_usd 14 (covering paid's 7 + promo's 7).
L35H="$T/anc/k35h.jsonl"; : > "$L35H"
ac SYG_CREDIT_LEDGER="$L35H" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 14 --at "$NOW35" --kind paid=7 > /dev/null
b_35h1=$(ac SYG_CREDIT_LEDGER="$L35H" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- balance --json)
b_35h2=$(ac SYG_CREDIT_LEDGER="$L35H" SYG_CREDIT_GRANTS="$T/g-35b.json" SYG_CREDIT_NOW=2026-10-26T00:00:00Z -- balance --json)
if jq -e '.remaining_usd==14 and .remaining_by_kind=={"promo":7,"paid":7}' <<< "$b_35h1" > /dev/null \
  && jq -e '.remaining_usd==0 and .remaining_by_kind=={} and .lapsed_usd==14' <<< "$b_35h2" > /dev/null; then
  ok "35h: stated kind > grant amount (calibrate 14 --kind paid=7 over \$5 paid grant) -> promo 7, paid 7 (2 excess keeps 10-25 expiry); after 10-25 -> paid omitted, lapsed_usd 14 (covering 7 paid + 7 promo)"
else bad "35h: $b_35h1 / $b_35h2"; fi

# 35i. Lapsed-kind refusal: promo grant expired 10-10, paid grant live (exp 10-25);
#      calibrate 5 --at 10-15T12:00:00Z --kind promo=1 -> exit 1, stderr names the kind,
#      anchor file absent.
cat > "$T/g-35i.json" <<'EOF'
{"currency":"USD","grants":[
 {"amount":10,"granted":"2026-10-01","expires":"2026-10-10","kind":"promo"},
 {"amount":5,"granted":"2026-10-01","expires":"2026-10-25","kind":"paid"}
]}
EOF
L35I="$T/anc/k35i.jsonl"; : > "$L35I"
err_35i=$(ac SYG_CREDIT_LEDGER="$L35I" SYG_CREDIT_GRANTS="$T/g-35i.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 5 --at 2026-10-15T12:00:00Z --kind promo=1 2>&1 > /dev/null); rc_35i=$?
if [ "$rc_35i" = 1 ] && [ ! -e "$L35I.anchor.json" ] \
  && [[ "$err_35i" == *"'promo'"* && "$err_35i" == *"matches no grant live at 2026-10-15T12:00:00Z"* ]]; then
  ok "35i: lapsed kind refused (calibrate 5 --at 10-15 --kind promo=1 when promo expired 10-10) -> exit 1, stderr names promo, anchor file absent"
else bad "35i: rc=$rc_35i err='$err_35i' / exists $(ls "$L35I.anchor.json" 2>&1)"; fi

# 35j. A grant granted after an anchor with kinds enters unchanged with its kind:
#      calibrate 12 --kind paid=2 at 10-15T12:00:00Z over g-35b plus a third grant
#      {"amount":50,"granted":"10-16","kind":"promo"}; balance at 10-16T13:00:00Z ->
#      promo 10 + 50 = 60, paid 2, remaining_usd 62.
cat > "$T/g-35j.json" <<'EOF'
{"currency":"USD","grants":[
 {"amount":10,"granted":"2026-10-01","expires":"2026-10-20","kind":"promo"},
 {"amount":5,"granted":"2026-10-01","expires":"2026-10-25","kind":"paid"},
 {"amount":50,"granted":"2026-10-16","kind":"promo"}
]}
EOF
L35J="$T/anc/k35j.jsonl"; : > "$L35J"
ac SYG_CREDIT_LEDGER="$L35J" SYG_CREDIT_GRANTS="$T/g-35j.json" SYG_CREDIT_NOW=2026-10-15T13:00:00Z -- calibrate 12 --at "$NOW35" --kind paid=2 > /dev/null
b_35j=$(ac SYG_CREDIT_LEDGER="$L35J" SYG_CREDIT_GRANTS="$T/g-35j.json" SYG_CREDIT_NOW=2026-10-16T13:00:00Z -- balance --json)
if jq -e '.remaining_usd==62 and .remaining_by_kind=={"promo":60,"paid":2}' <<< "$b_35j" > /dev/null; then
  ok "35j: grant granted after an anchor with kinds (+50 promo on 10-16) enters unchanged -> promo 60, paid 2"
else bad "35j: $b_35j"; fi

# 36. Long-card pricing on suffixed model ids: m-long-20261006 and m-long[1m] at prompt
#     1001 (401 in + 500 out + 300 read + 200 w5m + 100 w1h, > above 1000) each price
#     on m-long's long card at 0.02001 (as in 34a), total 0.04002.
{
  uline msg-ls1 req-ls1 m-long-20261006 ${D1}T10:00:00Z 401 500 300 200 100
  uline msg-ls2 req-ls2 'm-long[1m]' ${D1}T10:01:00Z 401 500 300 200 100
} > "$P/LSUF.jsonl"
hk LSUF "$T/lsuf/l.jsonl" SYG_CREDIT_PRICE_TABLE_CMD="$T/pt-long.sh"
elsuf=$(cat "$T/lsuf/l.jsonl")
if near "$(jq .cost_usd <<< "$elsuf")" 0.04002 \
  && jq -e '.models["m-long-20261006"].cost_usd==0.02001 and .models["m-long[1m]"].cost_usd==0.02001 and .unpriced_models==[]' <<< "$elsuf" > /dev/null; then
  ok "36: suffixed ids m-long-20261006 and m-long[1m] at prompt 1001 price on m-long's long card (0.02001 each)"
else bad "36 long card suffixed ids: $elsuf"; fi

# 37. Anchored path with SYG_CREDIT_ADMIN_KEY_CMD (case 23's fixtures, the env key
#     empty): the command key drives the anchored provider pass; the TTL cache keeps
#     the second render to one run.
echo anc > "$T/cr/mode"; : > "$T/cr/hits.log"; : > "$T/key-calls"
anc37() { lv "$1" balance --json ANTHROPIC_ADMIN_API_KEY= SYG_CREDIT_ADMIN_KEY_CMD="$T/key-ok.sh" SYG_CREDIT_LEDGER="$T/anc/pv.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_NOW="$2"; }
b37=$(anc37 anc37 2026-10-14T15:00:00Z)
b37b=$(anc37 anc37 2026-10-14T15:01:00Z)
req37=$(head -n 1 "$T/cr/hits.log" | cut -f1)
if near "$(jq .remaining_usd <<< "$b37")" 41.5 \
  && jq -e '.source=="provider" and .estimate==false and .provider_as_of=="2026-10-13"' <<< "$b37" > /dev/null \
  && [ "$(jq -c '[.remaining_usd, .source]' <<< "$b37b")" = "$(jq -c '[.remaining_usd, .source]' <<< "$b37")" ] \
  && [ "$(nlines "$T/key-calls")" = 1 ] && [[ "$req37" == *'starting_at=2026-10-12T00:00:00Z&'* ]]; then
  ok "anchored SYG_CREDIT_ADMIN_KEY_CMD: command key -> the 41.50 provider figure, window from the anchor's day, run once across the TTL hit"
else bad "anchored key cmd: $b37 / $b37b / calls=$(nlines "$T/key-calls") / '$req37'"; fi

# 38. Anchored provider window clamped: an anchor more than 366 days back fetches from
#     now's day minus 366 days; the anchor's day through the clamp replays from the
#     ledger; estimate true, provider_clamped true, the window starts at the clamp day.
echo '{"anchors":[{"amount":100,"at":"2025-06-01T12:00:00Z","pre_anchor_day_usd":0,"recorded":"2025-06-01T13:00:00Z"}]}' > "$T/anc/old.json"
entry a 2025-09-15 2025-09-15T12:00:00Z 40 > "$T/anc/old.jsonl"
echo '{"data":[{"starting_at":"2026-11-20T00:00:00Z","ending_at":"2026-11-21T00:00:00Z","results":[{"currency":"USD","amount":"3000"}]}],"has_more":false}' > "$T/cr/oldanc.json"
clamp38=$(date -u -d '2026-12-01 - 366 days' +%Y-%m-%d)
echo oldanc > "$T/cr/mode"; : > "$T/cr/hits.log"
b38=$(lv oldanc balance --json SYG_CREDIT_LEDGER="$T/anc/old.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_ANCHOR="$T/anc/old.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
: > "$T/cr/hits.log"
txt38=$(lv oldanc-t balance SYG_CREDIT_LEDGER="$T/anc/old.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" SYG_CREDIT_ANCHOR="$T/anc/old.json" SYG_CREDIT_NOW=2026-12-01T12:00:00Z)
req38=$(head -n 1 "$T/cr/hits.log" | cut -f1)
if near "$(jq .remaining_usd <<< "$b38")" 30 && near "$(jq .spent_usd <<< "$b38")" 70 \
  && jq -e --arg cd "$clamp38" '.source=="provider" and .estimate==true and .provider_clamped==true and .provider_subday==false and .provider_window_start==$cd and .provider_as_of=="2026-11-20"' <<< "$b38" > /dev/null \
  && [[ "$req38" == *"starting_at=${clamp38}T00:00:00Z&"* ]] \
  && [ "$(sed -n 2p <<< "$txt38")" = "spent \$70.00, lapsed \$0.00, overage \$0.00 (provider through 2026-11-20; today, lapsed and spend before $clamp38, from the ledger; anchored \$100.00 at 2025-06-01T12:00:00Z)" ]; then
  ok "anchored clamp: anchor 100 at 2025-06-01 -> window starts $clamp38 (now - 366d), 40 pre-clamp ledger + 30 provider = spent 70, remaining 30, estimate true, basis names the clamp"
else bad "anchored clamp: $b38 / '$txt38' / '$req38'"; fi

# 39. Anchored sub-day grant boundary: a grant granted mid-UTC-day on a provider bucket
#     day, after a mid-day anchor whose own instant is exempt (its day's bucket is
#     pre-corrected through pre_anchor_day_usd) -> estimate true, provider_subday true.
echo '{"anchors":[{"amount":50,"at":"2026-10-12T12:00:00Z","pre_anchor_day_usd":0,"recorded":"2026-10-12T13:00:00Z"}]}' > "$T/anc/sub.json"
entry a 2026-10-13 2026-10-13T18:00:00Z 2.5 > "$T/anc/sub.jsonl"
echo '{"grants":[{"amount":100,"granted":"2026-10-13T12:00:00Z","expires":"2026-12-01"}]}' > "$T/anc/sub-grants.json"
echo '{"data":[{"starting_at":"2026-10-13T00:00:00Z","ending_at":"2026-10-14T00:00:00Z","results":[{"currency":"USD","amount":"500"}]}],"has_more":false}' > "$T/cr/subanc.json"
echo subanc > "$T/cr/mode"; : > "$T/cr/hits.log"
b39=$(lv subanc balance --json SYG_CREDIT_LEDGER="$T/anc/sub.jsonl" SYG_CREDIT_GRANTS="$T/anc/sub-grants.json" SYG_CREDIT_ANCHOR="$T/anc/sub.json" SYG_CREDIT_NOW=2026-10-14T15:00:00Z)
if jq -e '.source=="provider" and .estimate==true and .provider_subday==true and .provider_clamped==false' <<< "$b39" > /dev/null \
  && near "$(jq .remaining_usd <<< "$b39")" 145; then
  ok "anchored sub-day grant: a 10-13T12:00 grant on the 10-13 bucket day -> estimate true, provider_subday true (the anchor's own mid-day instant exempt)"
else bad "anchored sub-day: $b39"; fi

exit $fail
