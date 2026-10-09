#!/bin/bash
# Fixture check for plugins/seyag/bin/claude-usage --ok / --wait against a fake usage cache: the
# week gate stops sessions at 75% (fleet wind-down; the rest is reserved for the owner and
# claude-review), --wait blocks instead of returning at once, and while a session is routed to
# z.ai the gate reads z.ai's quota instead of the plan's (OpenRouter passes). Also pins that
# claude-usage classifies the base-URL host exactly as the statusline does (the Console-key lane
# differs on purpose: CC_ROUTE_PRESET here, a non-empty ANTHROPIC_API_KEY there), and that
# usage-sweep --points consumes the readings log it writes. Also: the caller's model read from its
# session transcript, and --json's scoped string escaping. Also: --all's three lane lines and their
# degrades, --json's lane fields, and OpenRouter dollars read-only from the statusline's credits cache.
# Usage: tests/claude-usage.probe.sh   (from anywhere; never touches the real cache, settings or API)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CU=${CLAUDE_USAGE_BIN:-"$REPO/plugins/seyag/bin/claude-usage"} # override: test another build
SL="$REPO/plugins/seyag/bin/statusline"
US="$REPO/plugins/seyag/bin/usage-sweep"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/claude-statusline" "$tmp/.claude" "$tmp/.local/bin"
# Hermetic: a routed session exports its base URL, key and route marker, and the script prefers
# them; drop every ambient var this probe's tools read so any session can run it.
# shellcheck disable=SC2046 # word-splitting the variable-name list is the point
unset $(compgen -v | grep -E '^(ANTHROPIC_|CC_ROUTE_|SYG_|ZAI_SPEND_|CLAUDE_USAGE_|XDG_)') \
    CLAUDE_CODE_SESSION_ID CLAUDE_PLUGIN_REGISTRY OPENROUTER_CREDITS_URL
# HOME points the script's routing check at a fixture settings.json, never the real routing.
route_url()       { jq -n --arg u "$1" '{env: {ANTHROPIC_BASE_URL: $u}}' > "$tmp/.claude/settings.json"; }
route_anthropic() { route_url https://api.anthropic.com; }
route_zai()       { route_url https://api.z.ai/api/anthropic; }
route_anthropic
# Every run logs its reading: keep the fixtures out of the real ~/.local/state log.
export XDG_STATE_HOME="$tmp/state"
# api-credit: a fixture stub, never the real ledger. It answers only `balance --json` (the plain
# text is not the shape claude-usage reads); "fail" exits 2 like api-credit without a ledger.
credit_stub() { # credit_stub <balance json | fail>
    if [ "$1" = fail ]; then
        printf '#!/bin/sh\necho "api-credit: SYG_CREDIT_LEDGER is not set" >&2\nexit 2\n' > "$tmp/api-credit"
    else
        printf '#!/bin/sh\n[ "$1 $2" = "balance --json" ] && { echo %s; exit 0; }\necho "api plain text"\n' "'$1'" > "$tmp/api-credit"
    fi
    chmod +x "$tmp/api-credit"
}
credit_stub fail
export CLAUDE_USAGE_API_CREDIT="$tmp/api-credit"
log="$tmp/state/claude-usage/readings.jsonl"

# fixture <5h %> <week %> <fable %>: a fresh cache (mtime now), so the script never refreshes.
fixture() {
    jq -n --argjson f "$1" --argjson w "$2" --argjson m "$3" '{
        five_hour: {utilization: $f, resets_at: "2099-01-01T00:00:00.000000+00:00"},
        seven_day: {utilization: $w, resets_at: "2099-01-07T00:00:00.000000+00:00"},
        limits: [{kind: "weekly_scoped", percent: $m, scope: {model: {display_name: "Fable"}}}]}' \
        > "$tmp/claude-statusline/usage.json"
}
run() { HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" "$@"; }

fixture 10 50 0;  run --ok 90; [ $? = 0 ] && ok "week 50%: --ok passes" || bad "week 50%: --ok should pass"
fixture 10 74 0;  run --ok 90; [ $? = 0 ] && ok "week 74%: --ok passes" || bad "week 74%: --ok should pass"
fixture 10 75 0;  run --ok 90; [ $? = 1 ] && ok "week 75%: --ok fails (wind-down)" || bad "week 75%: --ok should fail"
fixture 10 99 0;  run --ok 90; [ $? = 1 ] && ok "week 99%: --ok fails" || bad "week 99%: --ok should fail"
fixture 95 10 0;  run --ok 90; [ $? = 1 ] && ok "5h 95%: --ok fails" || bad "5h 95%: --ok should fail"
# The week reserve is overridable; a non-integer override keeps the default (and doesn't crash).
fixture 10 80 0
CLAUDE_USAGE_WEEK_RESERVE=85 run --ok 90; [ $? = 0 ] && ok "week 80% with CLAUDE_USAGE_WEEK_RESERVE=85: passes" || bad "week reserve override: --ok should pass"
CLAUDE_USAGE_WEEK_RESERVE=lots run --ok 90 2>/dev/null; [ $? = 1 ] && ok "week 80% with a non-integer reserve: default 75 gates" || bad "week reserve 'lots': --ok should fail"

# Any non-flag argument prints the usage block from the script's own header lines.
out=$(run --help); rc=$?
[ $rc = 2 ] && grep -q '^ *claude-usage --ok \[PCT\]' <<< "$out" && grep -q '^ *claude-usage --json' <<< "$out" \
    && grep -q '^ *claude-usage --all' <<< "$out" && grep -q 'api_credit_remaining_usd' <<< "$out" \
    && ok "--help: exit 2 with the header's usage block" || bad "--help (rc $rc): $out"

# The reported bug: at 95-99% of the week, --wait returned at once. It must block now.
fixture 10 97 0
timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait >/dev/null; rc=$?
[ $rc = 124 ] && ok "week 97%: --wait blocks" || bad "week 97%: --wait returned (rc $rc, want 124 = still waiting)"
fixture 10 50 0
out=$(timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait); rc=$?
[ $rc = 0 ] && grep -q "week 50%" <<< "$out" && ok "week 50%: --wait returns with the line" || bad "week 50%: --wait (rc $rc): $out"

# A model's own cap still gates only that model, at 100%.
fixture 10 50 100
CLAUDE_USAGE_MODEL=claude-fable-5-1 HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90; [ $? = 1 ] && ok "Fable cap 100%: Fable session blocked" || bad "Fable cap: Fable should block"
run --ok 90; [ $? = 0 ] && ok "Fable cap 100%: Opus session passes" || bad "Fable cap: Opus should pass"
# No CLAUDE_USAGE_MODEL: the caller's model is the last assistant reply in its session transcript.
mkdir -p "$tmp/.claude/projects/slugA"
{
    jq -cn '{type: "assistant", message: {model: "claude-opus-5-5"}}'
    jq -cn '{type: "user", message: {content: "next"}}'
    jq -cn '{type: "assistant", message: {model: "claude-fable-5-1"}}'
    jq -cn '{type: "user", message: {content: "last"}}'
} > "$tmp/.claude/projects/slugA/probe-session.jsonl"
CLAUDE_CODE_SESSION_ID=probe-session HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90; [ $? = 1 ] \
    && ok "transcript model (Fable), Fable cap 100%: blocked" || bad "transcript model, Fable cap 100%: should block"
fixture 10 50 50
CLAUDE_CODE_SESSION_ID=probe-session HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90; [ $? = 0 ] \
    && ok "transcript model (Fable), Fable cap 50%: passes" || bad "transcript model, Fable cap 50%: should pass"
# A display name with a quote, a backslash and a space round-trips exactly: --json and the plain line.
jq -n '{five_hour: {utilization: 10}, seven_day: {utilization: 50},
        limits: [{kind: "weekly_scoped", percent: 7, scope: {model: {display_name: "Q\"B\\x y"}}}]}' \
    > "$tmp/claude-statusline/usage.json"
want='Q"B\x y 7%'
s=$(run --json | jq -re '.scoped'); rc=$?
[ $rc = 0 ] && [ "$s" = "$want" ] \
    && ok "--json: scoped round-trips a name with \", \\ and a space ($s)" || bad "--json scoped round-trip (rc $rc): got [$s], want [$want]"
line=$(run)
[[ $line == *"· $want of its own weekly cap"* ]] \
    && ok "plain line: the scoped name renders with a single backslash" || bad "plain line scoped name: $line"

# Routing: while settings.json points sessions at z.ai, the Anthropic plan's numbers don't gate;
# z.ai's own quota does (a stub zai-usage stands in for the live API), and the line says so.
# Both tools are handed the stub by their override (each defaults to its sibling zai-usage).
zai_stub() { # zai_stub <source> <5h %> <week %> [<5h reset epoch> <week reset epoch>]
    printf '#!/bin/sh\n[ "$1" = --json ] && echo %s || echo "z.ai line"\n' \
        "'{\"source\":\"$1\",\"five_hour_pct\":$2,\"week_pct\":$3${4:+,\"five_hour_reset_at\":$4,\"week_reset_at\":$5}}'" > "$tmp/.local/bin/zai-usage"
    chmod +x "$tmp/.local/bin/zai-usage"
}
export CLAUDE_USAGE_ZAI_USAGE="$tmp/.local/bin/zai-usage" SYG_STATUSLINE_ZAI_USAGE="$tmp/.local/bin/zai-usage"
route_zai
fixture 10 99 100
zai_stub api 10 74
run --ok 90; [ $? = 0 ] && ok "z.ai week 74% (api): --ok passes" || bad "z.ai week 74%: --ok should pass"
zai_stub api 10 75
run --ok 90; [ $? = 1 ] && ok "z.ai week 75% (api): --ok fails (wind-down)" || bad "z.ai week 75%: --ok should fail"
zai_stub api 95 10
run --ok 90; [ $? = 1 ] && ok "z.ai 5h 95% (api): --ok fails" || bad "z.ai 5h 95%: --ok should fail"
# z.ai's 5h gate is capped at 80 whatever PCT asks, below Tzurot's guest cutoff (90)
zai_stub api 82 10
run --ok 90; [ $? = 1 ] && ok "z.ai 5h 82% with --ok 90: fails (capped at 80)" || bad "z.ai 5h 82%: --ok 90 should fail"
zai_stub api 79 10
run --ok 90; [ $? = 0 ] && ok "z.ai 5h 79%: passes" || bad "z.ai 5h 79%: --ok should pass"
run --ok 50; [ $? = 1 ] && ok "z.ai 5h 79% with --ok 50: a lower PCT still wins" || bad "z.ai --ok 50: should fail at 79%"
CLAUDE_USAGE_ZAI_FIVE_CAP=70 run --ok 90; [ $? = 1 ] && ok "z.ai 5h 79% with CLAUDE_USAGE_ZAI_FIVE_CAP=70: fails" || bad "z.ai cap override 70: --ok should fail at 79%"
CLAUDE_USAGE_ZAI_FIVE_CAP=7x run --ok 90 2>/dev/null; [ $? = 0 ] && ok "z.ai 5h 79% with a non-integer cap: default 80 applies" || bad "z.ai cap '7x': --ok should pass at 79%"
zai_stub local 10 308
err=$(run --ok 90 2>&1); rc=$?
[ $rc = 0 ] && grep -q 'local estimate' <<< "$err" && ok "z.ai local estimate only: passes, says why" || bad "z.ai local (rc $rc): $err"
zai_stub api 10 10
run --ok 90; [ $? = 0 ] && ok "z.ai-routed, week 99%: --ok passes" || bad "z.ai-routed, week 99%: --ok should pass"
CLAUDE_USAGE_MODEL=claude-fable-5-1 HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90; [ $? = 0 ] && ok "z.ai-routed, Fable cap 100%: --ok passes" || bad "z.ai-routed, Fable cap: --ok should pass"
out=$(timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait); rc=$?
[ $rc = 0 ] && grep -q "z.ai-routed" <<< "$out" && ok "z.ai-routed: --wait returns at once with the note" || bad "z.ai-routed: --wait (rc $rc): $out"
out=$(run); grep -q "z.ai-routed" <<< "$out" && ok "z.ai-routed: plain line carries the note" || bad "z.ai-routed: plain line missing note: $out"
run --json | jq -e '.routed == 1' >/dev/null && ok "z.ai-routed: --json reports routed:1" || bad "z.ai-routed: --json routed flag"
# The process env is the truth even when it sets the base URL to empty: an overlay that clears the
# route puts the session back on the plan lane over a z.ai settings.json, so the plan's 99% gates.
ANTHROPIC_BASE_URL='' run --ok 90; [ $? = 1 ] && ok "env set-but-empty over z.ai settings: plan lane, plan 99% gates" || bad "env empty over z.ai: --ok should fail"
# Per-session overlay: settings.json on anthropic, the calling session's env routed to z.ai. The
# session's own route decides: z.ai's quota gates, the plan's 99% doesn't.
route_anthropic
zai_stub api 10 10
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic run --ok 90; [ $? = 0 ] && ok "session env z.ai over anthropic settings: plan 99% doesn't gate" || bad "session env z.ai: --ok should pass"
zai_stub api 10 80
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic run --ok 90; [ $? = 1 ] && ok "session env z.ai: z.ai's week 80% gates" || bad "session env z.ai 80%: --ok should fail"
run --ok 90; [ $? = 1 ] && ok "no session env: anthropic settings, plan 99% gates" || bad "anthropic settings 99%: --ok should fail"
route_url https://openrouter.ai/api
zai_stub api 10 99
run --ok 90; [ $? = 0 ] && ok "OpenRouter-routed: --ok passes (dollar cap, not a quota)" || bad "OpenRouter: --ok should pass"
out=$(run); grep -q "OpenRouter-routed" <<< "$out" && ! grep -q "z.ai" <<< "$out" && ok "OpenRouter line says OpenRouter, not z.ai" || bad "OpenRouter line: $out"
# A lookalike host is not the plan lane: its gate passes and it never reads plan meters as its own.
route_url https://api.anthropic.com.evil.com
run --ok 90; [ $? = 0 ] && ok "api.anthropic.com.evil.com: not the plan lane, gate passes" || bad "lookalike host: --ok should pass"
out=$(run); grep -q '^api\.anthropic\.com\.evil\.com-routed (gate passes' <<< "$out" \
    && ok "lookalike host: line labels the raw host" || bad "lookalike line: $out"
route_anthropic
# A base URL with no host has no label to show (the statusline renders none either): no note at all.
out=$(ANTHROPIC_BASE_URL=https:// run)
[[ $out == "5h "* ]] && ! grep -q -- '-routed' <<< "$out" && ok "hostless env base URL: no empty '-routed' note" || bad "hostless line: $out"
# A Console API key (the anthropic-api route preset) bills credits, not the plan: the plan's 99%
# doesn't gate. The lane is the overlay's CC_ROUTE_PRESET marker, never the key alone.
CC_ROUTE_PRESET=anthropic-api ANTHROPIC_API_KEY=sk-ant-test run --ok 90; [ $? = 0 ] && ok "anthropic-api session: --ok passes (Console credits)" || bad "anthropic-api session: --ok should pass"
out=$(CC_ROUTE_PRESET=anthropic-api ANTHROPIC_API_KEY=sk-ant-test run); grep -q "Console API key-routed" <<< "$out" && ok "API key line names the lane" || bad "API key line: $out"
ANTHROPIC_API_KEY=sk-ant-test run --ok 90; [ $? = 1 ] && ok "a stray exported API key in a plan session still gates" || bad "stray API key: --ok should fail"
CC_ROUTE_PRESET=zai run --ok 90; [ $? = 1 ] && ok "another preset's marker on the anthropic base doesn't skip the gate" || bad "zai marker: --ok should fail"
run --ok 90; [ $? = 1 ] && ok "back on Anthropic: week 99% fails again" || bad "unrouted week 99%: --ok should fail"
run --json | jq -e '.routed == 0' >/dev/null && ok "anthropic: --json reports routed:0" || bad "anthropic: --json routed flag"

# Routing equivalence: the same base URL through claude-usage and the statusline lands on the
# same lane. claude-usage's lane is read from its plain line's note; the statusline's from its
# vendor label (rate_limits in the input, so a plan-lane render shows "claude.ai 5h:").
fixture 10 50 0
zai_stub api 10 20
sl_in='{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548},"seven_day":{"used_percentage":56,"resets_at":1791093600}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}'
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
cu_lane() { # stdin: claude-usage's plain line -> plan | zai | or | console | unknown:<label>
    local l
    IFS= read -r l
    case "$l" in
        "5h "*) echo plan ;;
        "z.ai-routed "*) echo zai ;;
        "OpenRouter-routed "*) echo or ;;
        "Console API key-routed "*) echo console ;;
        *"-routed (gate passes"*) echo "unknown:${l%%-routed (gate passes*}" ;;
        *) echo "?:$l" ;;
    esac
}
sl_lane() { # $1: the statusline's raw render -> plan | zai | or | unknown:<gray label>
    local s; s=$(strip <<< "$1")
    if grep -q 'claude\.ai 5h:' <<< "$s"; then echo plan
    elif grep -q 'z\.ai 5h:' <<< "$s"; then echo zai
    elif grep -q 'openrouter\.ai' <<< "$s" && ! grep -q '5h:' <<< "$s"; then echo or
    elif ! grep -qE '5h:|wk:' <<< "$s"; then
        # Unknown lane: the vendor label is the first segment that opens gray right after a
        # separator (the statusline's sep, then gray); the model segment before it is bold.
        local after=$'\e[90m · \e[0m\e[90m' g=""
        [[ $1 == *"$after"* ]] && { g=${1#*"$after"}; g=${g%%$'\e[0m'*}; }
        echo "unknown:$g"
    else echo "?"
    fi
}
equiv() { # equiv <name> <want: plan|zai|or|unknown:HOST> <settings base URL, or - for none> [VAR=value ...]
    local name=$1 want=$2 url=$3 cu sl cu_out sl_raw sl_want h
    shift 3
    if [ "$url" = - ]; then echo '{}' > "$tmp/.claude/settings.json"; else route_url "$url"; fi
    cu_out=$(env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$@" "$CU")
    sl_raw=$(env HOME="$tmp" XDG_CACHE_HOME="$tmp" "$@" bash "$SL" <<< "$sl_in")
    cu=$(cu_lane <<< "$cu_out"); sl=$(sl_lane "$sl_raw")
    # The statusline drops a leading "api." from an unknown host's label; claude-usage keeps it.
    sl_want=$want
    case "$want" in unknown:*) h=${want#unknown:}; sl_want="unknown:${h#api.}" ;; esac
    if [ "$cu" = "$want" ] && [ "$sl" = "$sl_want" ]; then
        ok "equiv: $name -> $want in both tools"
    else
        bad "equiv: $name: claude-usage '$cu', statusline '$sl', want '$want' / '$sl_want' (cu: $cu_out | sl: $(strip <<< "$sl_raw"))"
    fi
    EQ_OUT="$cu_out$sl_raw"
}
equiv "no base URL in settings" plan -
equiv "settings z.ai" zai https://api.z.ai/api/anthropic
equiv "settings openrouter.ai" or https://openrouter.ai/api
equiv "env set-but-empty over z.ai settings" plan https://api.z.ai/api/anthropic ANTHROPIC_BASE_URL=
equiv "https://api.anthropic.com" plan https://api.anthropic.com
equiv "https://api.anthropic.com.evil.com" unknown:api.anthropic.com.evil.com https://api.anthropic.com.evil.com
equiv "https://foo.z.ai" zai https://foo.z.ai
equiv "userinfo on z.ai" zai https://probeuser:s3cr3t-probe@z.ai/x
grep -qE 's3cr3t|probeuser' <<< "$EQ_OUT" && bad "userinfo: a credential reached the output: $(strip <<< "$EQ_OUT")" \
    || ok "userinfo: no credential string in either tool's output"
equiv "env https://openrouter.ai/api/v1 over z.ai settings" or https://api.z.ai/api/anthropic ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1
equiv "https://weird.example.org/v1" unknown:weird.example.org https://weird.example.org/v1
route_url https://weird.example.org/v1
fixture 10 99 0
run --ok 90; [ $? = 0 ] && ok "weird.example.org: unknown lane, gate passes" || bad "weird.example.org: --ok should pass"
route_anthropic

# --all: one line per lane (plan, z.ai, api credit), whatever lane the caller is on, exit 0.
fixture 10 50 0
# Resets 2m30s past a whole hour: the countdown floors to "…h2m" for the first 30 s of the run.
nowe=$(date +%s); r5=$((nowe + 3600 + 150)); rw=$((nowe + 30 * 3600 + 150))
zai_stub api 42 17 "$r5" "$rw"
credit_stub '{"remaining_usd":128.557512,"spent_usd":21.44,"next_expiry":"2026-10-21T00:00:00Z","days_left":11}'
out=$(run --all); rc=$?
want_z="z.ai: 5h 42% (resets $(date -d "@$r5" +%H:%M), in 1h2m) · week 17% (resets $(date -d "@$rw" +%H:%M), in 30h2m)"
[ $rc = 0 ] && [ "$(wc -l <<< "$out")" = 3 ] \
    && [[ $(sed -n 1p <<< "$out") == "Anthropic plan: 5h 10% (resets "*" · week 50% (resets "*" · Fable 0% of its own weekly cap" ]] \
    && ok "--all: plan line first, composed like the plain line" || bad "--all plan line (rc $rc): $out"
[ "$(sed -n 2p <<< "$out")" = "$want_z" ] && ok "--all: z.ai line from zai-usage --json (api), local reset times + countdowns" \
    || bad "--all z.ai line: got [$(sed -n 2p <<< "$out")], want [$want_z]"
[ "$(sed -n 3p <<< "$out")" = 'api credit: ~$128.56 (exp 10-21, 11d)' ] && ok "--all: api credit line from balance --json" \
    || bad "--all credit line: $(sed -n 3p <<< "$out")"
# The calling lane doesn't matter: a z.ai-routed caller still sees the plan line.
route_zai
out=$(run --all); rc=$?
[ $rc = 0 ] && grep -q '^Anthropic plan: 5h 10%' <<< "$out" && grep -q '^z\.ai: 5h 42%' <<< "$out" \
    && ok "--all: a z.ai-routed caller sees the plan line too" || bad "--all from z.ai (rc $rc): $out"
route_anthropic
zai_stub api 42 17
[ "$(run --all | sed -n 2p)" = "z.ai: 5h 42% · week 17%" ] && ok "--all: a 0 reset renders without the parenthetical" \
    || bad "--all z.ai no resets: $(run --all | sed -n 2p)"
zai_stub local 10 308
[ "$(run --all | sed -n 2p)" = "z.ai: z.ai line" ] && ok "--all: no live quota -> zai-usage's own --line text" \
    || bad "--all z.ai local: $(run --all | sed -n 2p)"
printf '#!/bin/sh\nexit 0\n' > "$tmp/.local/bin/zai-usage"
[ "$(run --all | sed -n 2p)" = "z.ai: no data" ] && ok "--all: zai-usage silent -> z.ai: no data" \
    || bad "--all z.ai silent: $(run --all | sed -n 2p)"
printf '#!/bin/sh\n[ "$1" = --line ] && echo "…"\nexit 0\n' > "$tmp/.local/bin/zai-usage"
[ "$(run --all | sed -n 2p)" = "z.ai: no data" ] && ok "--all: zai-usage's '…' (no cache yet) -> z.ai: no data" \
    || bad "--all z.ai ellipsis: $(run --all | sed -n 2p)"
credit_stub '{"remaining_usd":null,"spent_usd":3.5,"next_expiry":null,"days_left":null}'
[ "$(run --all | sed -n 3p)" = 'api credit: ~$3.50 spent (no live grants)' ] && ok "--all: no grants config -> spent" \
    || bad "--all credit spent: $(run --all | sed -n 3p)"
credit_stub '{"remaining_usd":0,"spent_usd":200,"next_expiry":null,"days_left":null}'
[ "$(run --all | sed -n 3p)" = 'api credit: ~$0.00' ] && ok "--all: remaining 0 -> ~\$0.00" \
    || bad "--all credit zero: $(run --all | sed -n 3p)"
credit_stub '{"remaining_usd":5,"spent_usd":1,"next_expiry":null,"days_left":null}'
[ "$(run --all | sed -n 3p)" = 'api credit: ~$5.00' ] && ok "--all: no expiry -> no parenthetical" \
    || bad "--all credit no expiry: $(run --all | sed -n 3p)"
credit_stub fail
[ "$(run --all | sed -n 3p)" = 'api credit: not configured' ] && ok "--all: api-credit exits 2 -> not configured" \
    || bad "--all credit fail: $(run --all | sed -n 3p)"
# No plan cache and nothing to refresh with: a line of its own, still exit 0 (never the exit 2 path).
mv "$tmp/claude-statusline/usage.json" "$tmp/usage.json.keep"
out=$(run --all 2>&1); rc=$?
[ $rc = 0 ] && [ "$(sed -n 1p <<< "$out")" = "Anthropic plan: no data" ] && [ "$(wc -l <<< "$out")" = 3 ] \
    && ok "--all: no plan cache -> 'Anthropic plan: no data', exit 0" || bad "--all no cache (rc $rc): $out"
mv "$tmp/usage.json.keep" "$tmp/claude-statusline/usage.json"

# --json: the original fields byte-for-byte, then the calling lane and its numbers.
fixture 10 50 0
old_prefix='{"five_hour_pct":10,"five_hour_resets_at":4070908800,"seconds_to_reset":'
j=$(run --json)
[[ $j == "$old_prefix"* ]] && [[ $j == *',"routed":0,"lane":"anthropic"}' ]] \
    && ok "--json anthropic: original fields unchanged, then lane, no extra numbers" || bad "--json anthropic: $j"
route_zai
zai_stub api 42 17
j=$(run --json)
jq -e '.lane == "zai" and .zai_five_hour_pct == 42 and .zai_week_pct == 17 and .routed == 1 and .weekly_pct == 50' <<< "$j" >/dev/null \
    && ok "--json z.ai lane: lane + zai_five_hour_pct/zai_week_pct from the live quota" || bad "--json zai: $j"
zai_stub local 10 308
j=$(run --json)
jq -e '.lane == "zai" and .zai_five_hour_pct == null and .zai_week_pct == null and has("zai_week_pct")' <<< "$j" >/dev/null \
    && ok "--json z.ai lane, local estimate only: both null" || bad "--json zai local: $j"
route_anthropic
credit_stub '{"remaining_usd":128.557512,"spent_usd":21.44,"next_expiry":"2026-10-21T00:00:00Z","days_left":11}'
j=$(CC_ROUTE_PRESET=anthropic-api run --json)
jq -e '.lane == "console" and .api_credit_remaining_usd == 128.557512' <<< "$j" >/dev/null \
    && ok "--json Console lane: api_credit_remaining_usd from balance --json" || bad "--json console: $j"
credit_stub '{"remaining_usd":null,"spent_usd":3.5,"next_expiry":null,"days_left":null}'
j=$(CC_ROUTE_PRESET=anthropic-api run --json)
jq -e '.lane == "console" and .api_credit_remaining_usd == null and has("api_credit_remaining_usd")' <<< "$j" >/dev/null \
    && ok "--json Console lane, no grants: null" || bad "--json console null: $j"
credit_stub fail
j=$(CC_ROUTE_PRESET=anthropic-api run --json)
jq -e '.api_credit_remaining_usd == null' <<< "$j" >/dev/null && ok "--json Console lane, api-credit fails: null" || bad "--json console fail: $j"
j=$(ANTHROPIC_BASE_URL=https://weird.example.org/v1 run --json)
jq -e '.lane == "unknown" and (keys | length) == 8' <<< "$j" >/dev/null && ok "--json unknown lane: lane only" || bad "--json unknown: $j"

# OpenRouter: the remaining dollars come from the statusline's credits cache, read-only.
orc="$tmp/claude-statusline/or-credits.json"
or_settings() { jq -n '{env: {ANTHROPIC_BASE_URL: "https://openrouter.ai/api", ANTHROPIC_AUTH_TOKEN: "dummy-or-token"}}' > "$tmp/.claude/settings.json"; }
or_settings
echo '{"data":{"total_credits":780,"total_usage":762.456759698}}' > "$orc"
out=$(run)
[[ $out == "OpenRouter-routed (gate passes; Anthropic plan idle) · 5h 10% "*' · $17.54' ]] \
    && ok "OpenRouter line: remaining dollars appended from the credits cache" || bad "OpenRouter dollars: $out"
run --json | jq -e '.lane == "or" and .or_remaining_usd == 17.54' >/dev/null \
    && ok "--json OpenRouter lane: or_remaining_usd" || bad "--json or: $(run --json)"
# A stale cache (a day old) still renders, and nothing refreshes it: no fetch path here.
touch -d '@1000000000' "$orc"; before=$(stat -c '%Y %s' "$orc")
out=$(run)
[[ $out == *' · $17.54' ]] && [ "$(stat -c '%Y %s' "$orc")" = "$before" ] \
    && ok "OpenRouter line: stale cache still renders, left untouched (read-only)" || bad "OpenRouter stale: $out ($(stat -c '%Y %s' "$orc") vs $before)"
echo '{"data":{"total_credits":780,"total_usage":779.999}}' > "$orc"
out=$(run); [[ $out != *'$'* ]] && ok "OpenRouter line: sub-cent balance -> no dollars" || bad "OpenRouter sub-cent: $out"
echo '{"data":{"total_credits":780,"total_usage":762.456759698}}' > "$orc"
out=$(ANTHROPIC_AUTH_TOKEN='' run); route_url https://openrouter.ai/api; out2=$(run)
[[ $out == *' · $17.54' ]] && [[ $out2 != *'$'* ]] \
    && ok "OpenRouter line: no token anywhere -> no dollars (the statusline's degrade)" || bad "OpenRouter token gate: [$out] [$out2]"
run --json | jq -e '.or_remaining_usd == null and has("or_remaining_usd")' >/dev/null \
    && ok "--json OpenRouter lane, no token anywhere: null" || bad "--json or no token: $(run --json)"
or_settings
rm -f "$orc"
out=$(run)
[[ $out == "OpenRouter-routed (gate passes; Anthropic plan idle) · 5h 10% "* ]] && [[ $out != *'$'* ]] && [ ! -e "$orc" ] \
    && ok "OpenRouter line: cold cache -> label without dollars, no cache file created" || bad "OpenRouter cold: $out"
run --json | jq -e '.or_remaining_usd == null and has("or_remaining_usd")' >/dev/null \
    && ok "--json OpenRouter lane, cold cache: null" || bad "--json or cold: $(run --json)"
route_anthropic

# Reading log: one line per distinct reading, raw percentages, scoped caps as an object.
rm -f "$log"
fixture 12.5 40 7
run >/dev/null; run --ok 90; run --json >/dev/null
[ "$(wc -l < "$log")" = 1 ] && ok "log: three runs on one reading write one line" || bad "log: want 1 line, got $(wc -l < "$log")"
jq -e '.five_hour_pct == 12.5 and .weekly_pct == 40 and .scoped.Fable == 7 and (.ts | test("Z$")) and (.epoch > 0)' "$log" >/dev/null \
    && ok "log: line holds ts, epoch, raw 5h/week % and scoped caps" || bad "log: line shape: $(cat "$log")"
fixture 13 40 7
run >/dev/null
[ "$(wc -l < "$log")" = 2 ] && [ "$(tail -1 "$log" | jq '.five_hour_pct')" = 13 ] \
    && ok "log: a changed reading appends a line" || bad "log: changed reading not appended: $(cat "$log")"

# Producer -> consumer: two readings written by claude-usage feed usage-sweep --points, which
# also reaches claude-usage --json through PATH (a shim execs this build).
rm -f "$log"
now=$(date +%s)
fixture 20 30 5; touch -d "@$((now - 60))" "$tmp/claude-statusline/usage.json"; run >/dev/null
fixture 25 32 5; touch -d "@$now" "$tmp/claude-statusline/usage.json"; run >/dev/null
mkdir -p "$tmp/shim" "$tmp/projects/slugA"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$CU" > "$tmp/shim/claude-usage"; chmod +x "$tmp/shim/claude-usage"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
j=$(env -i HOME="$tmp" PATH="$tmp/shim:$PATH" XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp" \
    CLAUDE_PROJECTS_DIR="$tmp/projects" "$US" --since "$(iso $((now - 90)))" --until "$(iso "$now")" --points --json 2>&1); rc=$?
[ $rc = 0 ] && jq -e '.meter.weekly_pct == 32 and .meter.routed == 0' <<< "$j" >/dev/null \
    && ok "consumer: usage-sweep reads claude-usage --json through PATH" || bad "consumer meter (rc $rc): $j"
jq -e '.points.readings_used == 2 and .points.readings_skipped == 0 and .points.weekly_delta == 2
       and .points.five_hour_delta == 5 and .points.five_hour_usable == true' <<< "$j" >/dev/null 2>&1 \
    && ok "consumer: --points prices the producer's two readings (week +2, 5h +5)" \
    || bad "consumer points (rc $rc): $(jq -c '.points' <<< "$j" 2>/dev/null || echo "$j")"

exit $fail
