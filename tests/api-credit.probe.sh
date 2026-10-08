#!/bin/bash
# Fixture check for plugins/seyag/bin/api-credit: the route rule (SYG_CREDIT_WHEN,
# else the metered API-key test), the transcript recorder behind `hook` (streaming
# dedupe, subagent transcripts, UTC day split, pricing incl. 1h vs 5m cache writes,
# unpriced models, idempotence, cross-session dedupe, old-format entries, garbage
# lines, concurrency), the read-only `statusline`, the FIFO-by-expiry balance
# estimate and the daily view.
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
uline msg-c2 req-c2 m-a ${D1}T10:05:00Z $M 0 >> "$P/C.jsonl"
hk C "$T/c/l.jsonl"; n3=$(nlines "$T/pt-calls")
if [ "$n1" = 1 ] && [ "$n2" = 1 ] && [ "$n3" = 2 ] && near "$(jq .cost_usd "$T/c/l.jsonl")" 2 \
  && jq -e '(.sources_sig|length)==1 and .sources_sig[0][0]==$tp' --arg tp "$P/C.jsonl" "$T/c/l.jsonl" > /dev/null; then
  ok "sources_sig: unchanged files -> price-table not run (1, 1); after an append -> run again (2), cost 2.00"
else bad "sources_sig: calls $n1/$n2/$n3 $(cat "$T/c/l.jsonl")"; fi

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
if near "$(jq .overage_usd <<< "$b")" 10 && near "$(jq .remaining_usd <<< "$b")" 0 && [ "$txt" = 'api credit over ~$10.00' ]; then
  ok "overage: 70 against 60 granted -> overage 10, text 'api credit over ~\$10.00'"
else bad "overage: $b / $txt"; fi

# 16. No grants file: spend only, never an invented balance.
txt=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_NOW=2026-10-06T00:00:00Z -- statusline < /dev/null)
b=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_GRANTS="$T/missing.json" -- balance --json)
echo 'not json' > "$T/garbled-grants.json"
b2=$(ac SYG_CREDIT_LEDGER="$T/b9.jsonl" SYG_CREDIT_GRANTS="$T/garbled-grants.json" -- balance --json)
if [ "$txt" = 'api ~$12.00 spent' ] && [ "$(jq .remaining_usd <<< "$b")" = null ] && [ "$(jq .remaining_usd <<< "$b2")" = null ]; then
  ok "no usable grants file: 'api ~\$12.00 spent', remaining null"
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

exit $fail
