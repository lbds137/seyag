#!/bin/bash
# Fixture check for plugins/seyag/bin/zai-usage: the quota-API path (source=api, rounded pcts, the
# "5h: N% (→HH:MM) wk: N%" line), which key reaches z.ai (key file, then a z.ai-routed env, then a
# z.ai-routed settings.json; a key routed elsewhere never), the local-estimate fallback, the state
# format bump that keeps console anchors, --calibrate (and its wait on the sweep lock), --models,
# the transcript scan's model buckets, and the default peak window read in UTC+8.
# Quota fixtures are file:// URLs; the key cases need to see the Authorization header, so they use a
# loopback http.server that logs it.
# Usage: tests/zai-usage.probe.sh   (from anywhere; never touches the real key file, settings, API or ~/.claude)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZS=${ZAI_SPEND_BIN:-"$REPO/plugins/seyag/bin/zai-usage"} # override: test another build
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
# Hermetic: drop every ambient var zai-usage reads, so a routed session can run this probe.
# shellcheck disable=SC2046 # word-splitting the variable-name list is the point
unset $(compgen -v | grep -E '^(ANTHROPIC_|CC_ROUTE_|SYG_|ZAI_SPEND_|XDG_)')
export TZ=UTC NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
mkdir -p "$tmp/home/.claude" "$tmp/empty" "$tmp/projects/slugA"
nokeys="$tmp/no-such-keys.env"

# Quota fixture: a 5h entry (number 5), a weekly entry (unit 6), and a non-token limit to skip.
now=$(date +%s)
jq -n --argjson r5 "$(( (now + 3600) * 1000 ))" --argjson rw "$(( (now + 86400) * 1000 ))" '{success: true, data: {limits: [
    {type: "TIME_LIMIT", number: 5, unit: 6, percentage: 99},
    {type: "TOKENS_LIMIT", number: 5, unit: 3, percentage: 42.6, nextResetTime: $r5},
    {type: "TOKENS_LIMIT", number: 1, unit: 6, percentage: 17.4, nextResetTime: $rw}]}}' > "$tmp/quota.json"
QOK="file://$tmp/quota.json"
QDOWN="file://$tmp/no-such-quota.json"

# zs <case dir> [VAR=value ...] -- <args>: one run with its own cache and state under $tmp/<case dir>.
zs() {
    local d=$tmp/$1; shift
    local vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    env HOME="$tmp/home" XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" \
        ZAI_SPEND_PROJECTS="$tmp/empty" CC_ROUTE_KEYS="$nokeys" SEYAG_KEYS_BIN="$tmp/no-keys-bin" "${vars[@]}" "$ZS" "$@"
}
cache() { cat "$tmp/$1/cache/claude-statusline/zai-usage.json" 2>/dev/null; }
state() { cat "$tmp/$1/state/zai-spend/state.json" 2>/dev/null; }
settings() { # settings <base url> <token>
    jq -n --arg u "$1" --arg t "$2" '{env: {ANTHROPIC_BASE_URL: $u, ANTHROPIC_AUTH_TOKEN: $t}}' > "$tmp/home/.claude/settings.json"
}
printf 'ZAI_AUTH_TOKEN="fixture-keyfile"\n' > "$tmp/keys.env"

# 1. API path: source=api, rounded pcts (42.6 -> 43, 17.4 -> 17), TIME_LIMIT ignored; --line shape.
zs c1 ZAI_SPEND_QUOTA_URL="$QOK" CC_ROUTE_KEYS="$tmp/keys.env" -- --sweep; rc=$?
j=$(cache c1)
[ $rc = 0 ] && jq -e '.source == "api" and .five_hour_pct == 43 and .week_pct == 17 and .five_hour_reset_at > 0 and .week_reset_at > 0' <<< "$j" >/dev/null \
    && ok "api: --sweep caches source=api with rounded pcts" || bad "api cache (rc $rc): $j"
out=$(zs c1 ZAI_SPEND_QUOTA_URL="$QOK" CC_ROUTE_KEYS="$tmp/keys.env" -- --json)
jq -e '.source == "api" and .five_hour_pct == 43 and .week_pct == 17' <<< "$out" >/dev/null \
    && ok "api: --json prints the cache" || bad "api --json: $out"
out=$(zs c1 ZAI_SPEND_QUOTA_URL="$QOK" CC_ROUTE_KEYS="$tmp/keys.env" -- --line)
grep -qE '^5h: 43% \(→[0-9]{2}:[0-9]{2}\) wk: 17% \(→[A-Z][a-z]{2} [0-9]{2}:[0-9]{2}\)$' <<< "$out" \
    && ok "api: --line prints '5h: N% (→HH:MM) wk: N% (→Ddd HH:MM)'" || bad "api --line: $out"
# The old name stays a committed alias (callers outside this repo run zai-spend by PATH name).
alias_bin="$REPO/plugins/seyag/bin/zai-spend"
alias_out=$(env HOME="$tmp/home" XDG_CACHE_HOME="$tmp/c1/cache" XDG_STATE_HOME="$tmp/c1/state" \
    ZAI_SPEND_PROJECTS="$tmp/empty" CC_ROUTE_KEYS="$tmp/keys.env" ZAI_SPEND_QUOTA_URL="$QOK" "$alias_bin" --line)
[ -L "$alias_bin" ] && [ "$(readlink "$alias_bin")" = zai-usage ] && [ "$alias_out" = "$out" ] \
    && ok "alias: bin/zai-spend is a relative symlink to zai-usage and prints the same --line" \
    || bad "alias: $(readlink "$alias_bin" 2>&1) -> $alias_out"

# 2. Key precedence, observed at a loopback server that logs each request's Authorization header.
cat > "$tmp/srv.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log, body, portfile = sys.argv[1:4]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log, "a") as f:
            f.write(f"{self.path}\t{self.headers.get('Authorization', '-')}\n")
        data = open(body, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(s.server_port))
import os
os.rename(portfile + ".tmp", portfile)
s.serve_forever()
PY
python3 -I "$tmp/srv.py" "$tmp/req.log" "$tmp/quota.json" "$tmp/port" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || { echo "zai-usage.probe: mock server did not start"; exit 2; }
QSRV="http://127.0.0.1:$(cat "$tmp/port")/quota"
ZENV=(ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_AUTH_TOKEN=fixture-env)
# key_case <name> <want: token | none> [VAR=value ...]: a fresh case dir, then which token arrived.
key_case() {
    local name=$1 want=$2 got src d; shift 2
    d="k$((++kn))"
    : > "$tmp/req.log"
    zs "$d" ZAI_SPEND_QUOTA_URL="$QSRV" "$@" -- --sweep
    got=$(cut -f2 "$tmp/req.log" | sort -u | tr '\n' ' ')
    src=$(cache "$d" | jq -r '.source // empty')
    if [ "$want" = none ]; then
        [ ! -s "$tmp/req.log" ] && [ "$src" = local ] && ok "key: $name -> nothing sent, local fallback" \
            || bad "key: $name: want no request, got '$got' (source '$src')"
    else
        [ "$got" = "Bearer $want " ] && [ "$src" = api ] && ok "key: $name -> $want" \
            || bad "key: $name: want 'Bearer $want', got '$got' (source '$src')"
    fi
}
kn=0
settings https://api.z.ai/api/anthropic fixture-settings
key_case "key file beats a z.ai env and z.ai settings" fixture-keyfile CC_ROUTE_KEYS="$tmp/keys.env" "${ZENV[@]}"
printf 'ZAI_AUTH_TOKEN=PASTE-your-key-here\n' > "$tmp/placeholder.env"
key_case "the template's PASTE- placeholder is skipped" fixture-env CC_ROUTE_KEYS="$tmp/placeholder.env" "${ZENV[@]}"
# The keys store: a stub that answers `get ZAI_AUTH_TOKEN`, and one that fails like a stalled TPM.
printf '#!/bin/sh\n[ "$1 $2" = "get ZAI_AUTH_TOKEN" ] && echo fixture-store && exit 0\nexit 1\n' > "$tmp/keys-ok"
printf '#!/bin/sh\necho "keys: store failed to decrypt" >&2\nexit 1\n' > "$tmp/keys-fail"
chmod +x "$tmp/keys-ok" "$tmp/keys-fail"
key_case "key file beats the keys store" fixture-keyfile CC_ROUTE_KEYS="$tmp/keys.env" SEYAG_KEYS_BIN="$tmp/keys-ok" "${ZENV[@]}"
key_case "no key file: the keys store beats a z.ai env" fixture-store SEYAG_KEYS_BIN="$tmp/keys-ok" "${ZENV[@]}"
key_case "no key file, no env: the keys store beats z.ai settings" fixture-store SEYAG_KEYS_BIN="$tmp/keys-ok"
key_case "a failing keys store falls through to the z.ai env" fixture-env SEYAG_KEYS_BIN="$tmp/keys-fail" "${ZENV[@]}"
printf '#!/bin/sh\nexit 0\n' > "$tmp/keys-empty"
printf '#!/bin/sh\nsleep 5\necho fixture-late\n' > "$tmp/keys-slow"
printf '#!/bin/sh\n[ -n "$SYG_KEYS_LOCK_WAIT_S" ] && [ -n "$SYG_KEYS_TIMEOUT_S" ] && echo fixture-budgeted && exit 0\nexit 1\n' > "$tmp/keys-budget"
printf '#!/bin/sh\ntouch "%s/keys-called"\necho fixture-store\n' "$tmp" > "$tmp/keys-mark"
chmod +x "$tmp/keys-empty" "$tmp/keys-slow" "$tmp/keys-budget" "$tmp/keys-mark"
key_case "a keys store answering exit 0 with nothing falls through" fixture-env SEYAG_KEYS_BIN="$tmp/keys-empty" "${ZENV[@]}"
key_case "a stalled keys store is killed and falls through" fixture-env SEYAG_KEYS_BIN="$tmp/keys-slow" ZAI_USAGE_KEYS_KILL_S=1 "${ZENV[@]}"
# A stalled keys whose own child (systemd-creds stand-in) outlives it: the kill must take the group.
printf '#!/bin/sh\nsleep 30 &\necho $! > "%s/grandchild.pid"\nwait\n' "$tmp" > "$tmp/keys-grandchild"
printf '#!/bin/sh\nprintf "\\377\\376"\n' > "$tmp/keys-binary"
chmod +x "$tmp/keys-grandchild" "$tmp/keys-binary"
key_case "a stalled keys store's grandchild is killed with it" fixture-env SEYAG_KEYS_BIN="$tmp/keys-grandchild" ZAI_USAGE_KEYS_KILL_S=1 "${ZENV[@]}"
gc=$(cat "$tmp/grandchild.pid" 2>/dev/null)
[ -n "$gc" ] && ! kill -0 "$gc" 2>/dev/null && ok "key: no grandchild left running after the kill" \
    || { bad "key: grandchild ${gc:-?} still running"; kill "$gc" 2>/dev/null; }
key_case "a non-UTF-8 keys answer falls through" fixture-env SEYAG_KEYS_BIN="$tmp/keys-binary" "${ZENV[@]}"
key_case "keys gets its own lock-wait and decrypt budgets" fixture-budgeted SEYAG_KEYS_BIN="$tmp/keys-budget"
key_case "a malformed ZAI_USAGE_KEYS_KILL_S keeps the default" fixture-store SEYAG_KEYS_BIN="$tmp/keys-ok" ZAI_USAGE_KEYS_KILL_S=abc
key_case "a nan ZAI_USAGE_KEYS_KILL_S keeps the default" fixture-store SEYAG_KEYS_BIN="$tmp/keys-ok" ZAI_USAGE_KEYS_KILL_S=nan
# keys get prefers an ambient ZAI_AUTH_TOKEN over its store; zai-usage passes its env through, by design.
printf '#!/bin/sh\n[ -n "$ZAI_AUTH_TOKEN" ] && echo "$ZAI_AUTH_TOKEN" && exit 0\necho fixture-store\n' > "$tmp/keys-envpref"
chmod +x "$tmp/keys-envpref"
key_case "an ambient ZAI_AUTH_TOKEN reaches keys get and wins there" fixture-ambient SEYAG_KEYS_BIN="$tmp/keys-envpref" ZAI_AUTH_TOKEN=fixture-ambient
key_case "the PASTE- placeholder key file falls through to the store" fixture-store CC_ROUTE_KEYS="$tmp/placeholder.env" SEYAG_KEYS_BIN="$tmp/keys-ok"
rm -f "$tmp/keys-called"
key_case "key file present: the store is not asked" fixture-keyfile CC_ROUTE_KEYS="$tmp/keys.env" SEYAG_KEYS_BIN="$tmp/keys-mark"
[ ! -e "$tmp/keys-called" ] && ok "key: the key file path never runs keys" || bad "key: keys ran although the key file answered"
# Default resolution: with SEYAG_KEYS_BIN unset, zai-usage runs the `keys` beside its real path,
# also when called through a symlink.
mkdir -p "$tmp/plug" "$tmp/link"
cp "$ZS" "$tmp/plug/zai-usage"; cp "$tmp/keys-ok" "$tmp/plug/keys"; ln -s "$tmp/plug/zai-usage" "$tmp/link/zai-usage"
: > "$tmp/req.log"
env HOME="$tmp/home" XDG_CACHE_HOME="$tmp/kd/cache" XDG_STATE_HOME="$tmp/kd/state" ZAI_SPEND_PROJECTS="$tmp/empty" \
    CC_ROUTE_KEYS="$nokeys" SEYAG_KEYS_BIN= ZAI_SPEND_QUOTA_URL="$QSRV" "$tmp/link/zai-usage" --sweep
[ "$(cut -f2 "$tmp/req.log" | sort -u)" = "Bearer fixture-store" ] && ok "key: default keys path resolves beside the real script through a symlink" \
    || bad "key: default keys resolution sent '$(cut -f2 "$tmp/req.log" | sort -u)'"
key_case "no key file: a z.ai-routed env beats settings" fixture-env "${ZENV[@]}"
key_case "no key file, no env: z.ai settings" fixture-settings
key_case "an env token routed to openrouter.ai is not sent; z.ai settings' is" fixture-settings \
    ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=fixture-or
settings https://openrouter.ai/api fixture-or-settings
key_case "openrouter.ai env and openrouter.ai settings" none \
    ANTHROPIC_BASE_URL=https://openrouter.ai/api ANTHROPIC_AUTH_TOKEN=fixture-or
key_case "a lookalike z.ai.evil.invalid env" none \
    ANTHROPIC_BASE_URL=https://z.ai.evil.invalid/api ANTHROPIC_AUTH_TOKEN=fixture-or
grep -q 'fixture-or' "$tmp/req.log" && bad "key: an openrouter token reached the server" || ok "key: no openrouter token in the last request log"
echo '{}' > "$tmp/home/.claude/settings.json"
key_case "anthropic-direct (no route env, empty settings): the keys store still answers" fixture-store SEYAG_KEYS_BIN="$tmp/keys-ok"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
echo '{}' > "$tmp/home/.claude/settings.json"

# 2b. --models: per-model lines and the total line, from the same loopback server on a models body.
jq -n '{success: true, data: {modelSummaryList: [{modelName: "glm-5.3", totalTokens: 12345678},
        {modelName: "glm-5.3-flash", totalTokens: 3400000}],
        totalUsage: {totalTokensUsage: 15745678, totalModelCallCount: 42}}}' > "$tmp/models.json"
python3 -I "$tmp/srv.py" "$tmp/req.log" "$tmp/models.json" "$tmp/mport" &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/mport" ] && break; sleep 0.1; done
[ -s "$tmp/mport" ] || { echo "zai-usage.probe: models mock server did not start"; exit 2; }
out=$(zs cm ZAI_SPEND_MODELS_URL="http://127.0.0.1:$(cat "$tmp/mport")/models" CC_ROUTE_KEYS="$tmp/keys.env" -- --models); rc=$?
want=$'glm-5.3: 12M tok\nglm-5.3-flash: 3M tok\ntotal: 16M tok, 42 calls (7d, bucket tz UTC+8)'
[ $rc = 0 ] && [ "$out" = "$want" ] && ok "--models: 'name: NM tok' per model, then the total line" || bad "--models (rc $rc): $out"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# 3. Local fallback: quota URL unreachable, no transcripts, no state -> source=local, "local est", exit 0.
out=$(zs c3 ZAI_SPEND_QUOTA_URL="$QDOWN" CC_ROUTE_KEYS="$tmp/keys.env" -- 2>&1); rc=$?
j=$(cache c3)
[ $rc = 0 ] && jq -e '.source == "local" and .week_inv == 0 and .files == 0' <<< "$j" >/dev/null \
    && ok "local: unreachable API on an empty dir caches source=local" || bad "local cache (rc $rc): $j"
[ $rc = 0 ] && grep -q '· local est$' <<< "$out" && ! grep -qi 'traceback' <<< "$out" \
    && ok "local: line tagged 'local est', exit 0" || bad "local line (rc $rc): $out"

# 4. State format bump: a v3 state with a calW anchor and a stale cache -> v4, calW kept, old files gone.
mkdir -p "$tmp/c4/state/zai-spend" "$tmp/c4/cache/claude-statusline"
jq -n '{v: 3, files: {"/gone/old.jsonl": {offset: 9, glm: true, hours: {"1": {"i": 1}}}},
        calW: {pct: 40, at: 123, winv: 50.0}}' > "$tmp/c4/state/zai-spend/state.json"
echo '{"as_of": 1, "source": "local", "stale_marker": 1}' > "$tmp/c4/cache/claude-statusline/zai-usage.json"
zs c4 ZAI_SPEND_QUOTA_URL="$QDOWN" -- --sweep; rc=$?
jq -e '.v == 4 and .calW.pct == 40 and .calW.winv == 50 and (.files | has("/gone/old.jsonl") | not)' <<< "$(state c4)" >/dev/null \
    && ok "state: v3 -> v4, calW anchor kept, old file entries dropped" || bad "state bump (rc $rc): $(state c4)"
jq -e '(has("stale_marker") | not) and .source == "local" and .week_pct == 0 and .anchors.calW.pct == 40' <<< "$(cache c4)" >/dev/null \
    && ok "state: stale cache rebuilt, the kept anchor still yields week_pct" || bad "state bump cache: $(cache c4)"

# Transcript fixture (cases 5 and 6): an hour ago, so inside both windows. glm-5.3 twice (thinking
# above output once: added; below once: not), glm-5.3-flash once (thinking added), a Claude reply
# (ignored), one string prompt after the first glm reply.
ts=$(date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%S.000Z)
{
    jq -cn --arg t "$ts" '{type: "user", timestamp: $t, message: {content: "before any glm reply"}}'
    jq -cn --arg t "$ts" '{type: "assistant", timestamp: $t, message: {model: "glm-5.3",
        usage: {input_tokens: 100, output_tokens: 50, output_tokens_details: {thinking_tokens: 200}}}}'
    jq -cn --arg t "$ts" '{type: "user", timestamp: $t, message: {content: "a prompt"}}'
    jq -cn --arg t "$ts" '{type: "user", timestamp: $t, message: {content: [{type: "tool_result"}]}}'
    jq -cn --arg t "$ts" '{type: "assistant", timestamp: $t, message: {model: "glm-5.3-flash",
        usage: {input_tokens: 10, output_tokens: 5, output_tokens_details: {thinking_tokens: 20}}}}'
    jq -cn --arg t "$ts" '{type: "assistant", timestamp: $t, message: {model: "glm-5.3",
        usage: {input_tokens: 100, output_tokens: 50, output_tokens_details: {thinking_tokens: 10}}}}'
    jq -cn --arg t "$ts" '{type: "assistant", timestamp: $t, message: {model: "claude-opus-5-5",
        usage: {input_tokens: 999, output_tokens: 999}}}'
} > "$tmp/projects/slugA/sess.jsonl"
TR=(ZAI_SPEND_PROJECTS="$tmp/projects" ZAI_SPEND_QUOTA_URL="$QDOWN")

# 6. Model buckets: glm-5.3 -> main (i5/t5), glm-5.3-flash -> flash (if/tf); weights off-peak and peak.
zs c6 "${TR[@]}" ZAI_SPEND_PEAK_UTC=0-0 -- --sweep
jq -e '[.files[].hours[]] | (map(.i5) | add) == 2 and (map(.if) | add) == 1 and (map(.t5) | add) == 500
       and (map(.tf) | add) == 35 and (map(.p) | add) == 1' <<< "$(state c6)" >/dev/null \
    && ok "scan: glm-5.3 x2 (500 tok) main, glm-5.3-flash x1 (35 tok) flash, 1 prompt, Claude skipped" \
    || bad "scan buckets: $(state c6 | jq -c '.files')"
jq -e '.five_hour_inv == 3 and .five_hour_winv == 2.4 and .week_winv == 2.4 and .five_hour_prompts == 1' <<< "$(cache c6)" >/dev/null \
    && ok "scan: off-peak weights 1.0/0.4 -> 2.4 winv" || bad "scan off-peak: $(cache c6)"
zs c6 "${TR[@]}" ZAI_SPEND_PEAK_UTC=0-24 -- --sweep
jq -e '.five_hour_winv == 7.2' <<< "$(cache c6)" >/dev/null \
    && ok "scan: peak weights 3.0/1.2 -> 7.2 winv" || bad "scan peak: $(cache c6)"

# 6b. The default window (no override, so the weekday gate is live) is Mon-Fri 14-18 in UTC+8: one
# glm-5.3 reply at the latest past Beijing-weekday 14:30 weighs 3.0; one at Beijing 22:00 (14:00
# UTC, inside 14-18 if read as UTC) weighs 1.0. Assessed on week_winv: the instants can be days old.
read -r pk_on pk_off < <(python3 -I -c '
import time
now = int(time.time())
def last(hh, mm):  # the latest past instant whose UTC+8 wall clock is a weekday hh:mm
    t = (now + 8 * 3600) // 86400 * 86400 + hh * 3600 + mm * 60 - 8 * 3600
    while t > now or time.gmtime(t + 8 * 3600).tm_wday >= 5:
        t -= 86400
    return t
print(last(14, 30), last(22, 0))')
peak_case() { # peak_case <case dir> <epoch> <want week_winv> <name>
    mkdir -p "$tmp/$1-projects/slugP"
    jq -cn --arg t "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%S.000Z)" '{type: "assistant", timestamp: $t,
        message: {model: "glm-5.3", usage: {input_tokens: 1}}}' > "$tmp/$1-projects/slugP/s.jsonl"
    zs "$1" ZAI_SPEND_PROJECTS="$tmp/$1-projects" ZAI_SPEND_QUOTA_URL="$QDOWN" -- --sweep
    jq -e --argjson w "$3" '.week_winv == $w and .week_inv == 1' <<< "$(cache "$1")" >/dev/null \
        && ok "peak: $4 -> $3 winv" || bad "peak: $4 (epoch $2): $(cache "$1")"
}
peak_case p1 "$pk_on" 3 "Beijing weekday 14:30 is peak"
peak_case p2 "$pk_off" 1 "Beijing weekday 22:00 (14:00 UTC) is off-peak"

# 5. --calibrate: anchors take the current winv, so the baked pcts equal the anchored numbers.
zs c5 "${TR[@]}" ZAI_SPEND_PEAK_UTC=0-0 -- --calibrate 40 20 --reset "2099-01-01 00:00" >/dev/null; rc=$?
want_reset=$(date -d "2099-01-01 00:00" +%s)
jq -e --argjson r "$want_reset" '.calW.pct == 40 and .calW.winv == 2.4 and .cal5.pct == 20 and .cal5.winv == 2.4
       and .reset_at == $r' <<< "$(state c5)" >/dev/null \
    && ok "calibrate: calW/cal5 anchor the scan's winv, --reset lands in state" || bad "calibrate state (rc $rc): $(state c5)"
jq -e --argjson r "$want_reset" '.week_pct == 40 and .five_hour_pct == 20 and .week_reset_at == $r and .source == "local"' \
    <<< "$(cache c5)" >/dev/null \
    && ok "calibrate: cache gains week_pct/five_hour_pct derived from winv" || bad "calibrate cache: $(cache c5)"

# 7. --calibrate waits for the sweep lock before its state write: held externally, no calW lands;
# released, calibrate finishes and calW does. (The holder gives up after 10 s on its own.)
lockf="$tmp/c7/state/zai-spend/.sweep.lock"
mkdir -p "${lockf%/*}"
flock "$lockf" -c "for _ in \$(seq 1 100); do [ -e '$tmp/c7-release' ] && exit 0; sleep 0.1; done" &
HOLD_PID=$!
for _ in $(seq 1 50); do flock -n "$lockf" true || break; sleep 0.1; done
zs c7 "${TR[@]}" ZAI_SPEND_PEAK_UTC=0-0 -- --calibrate 40 >/dev/null &
CAL_PID=$!
held_ok=1
for _ in $(seq 1 20); do grep -q calW <<< "$(state c7)" && held_ok=0; sleep 0.1; done
[ $held_ok = 1 ] && kill -0 "$CAL_PID" 2>/dev/null && ok "calibrate: no calW while another holder has the sweep lock" \
    || bad "calibrate wrote state under a held lock: $(state c7)"
touch "$tmp/c7-release"
wait "$HOLD_PID"
wait "$CAL_PID"; rc=$?
[ $rc = 0 ] && jq -e '.calW.pct == 40' <<< "$(state c7)" >/dev/null \
    && ok "calibrate: lock released -> calibrate completes, calW lands" || bad "calibrate after release (rc $rc): $(state c7)"

exit $fail
