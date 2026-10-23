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
# fixture_extra <5h %> <week %> <fable %> <is_enabled> <spend_limit_reached|omit for an absent key> <disabled_reason|null> [<spend.used json>]
fixture_extra() {
    fixture "$1" "$2" "$3"
    jq --argjson en "$4" --argjson lim "$5" --arg dr "${6:-null}" --argjson su "${7:-null}" \
        '. + {extra_usage: ({is_enabled: $en, disabled_reason: (if $dr == "null" or $dr == "" then null else $dr end)}
             + (if $lim == "omit" then {} else {spend_limit_reached: $lim} end))}
         + (if $su == null then {} else {spend: {used: $su}} end)' \
        "$tmp/claude-statusline/usage.json" > "$tmp/claude-statusline/usage.json.tmp"
    mv "$tmp/claude-statusline/usage.json.tmp" "$tmp/claude-statusline/usage.json"
}
run() { HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" "$@"; }

fixture 10 50 0
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=anthropic meter=5h 5h=10%<90% week=50%<75% source=api" ] \
    && ok "week 50%: --ok passes with stderr verdict line" || bad "week 50%: rc=$rc out=[$out] err=[$err]"
fixture 10 74 0
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=anthropic meter=5h 5h=10%<90% week=74%<75% source=api" ] \
    && ok "week 74%: --ok passes with stderr verdict line" || bad "week 74%: rc=$rc out=[$out] err=[$err]"
fixture 10 75 0
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=75%>=75% source=api" ] \
    && ok "week 75%: --ok fails (wind-down, week binding verdict)" || bad "week 75%: rc=$rc out=[$out] err=[$err]"
fixture 10 99 0
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=99%>=75% source=api" ] \
    && ok "week 99%: --ok fails (week binding verdict)" || bad "week 99%: rc=$rc out=[$out] err=[$err]"
fixture 95 10 0
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=5h 5h=95%>=90% week=10%<75% source=api" ] \
    && ok "5h 95%: --ok fails (5h binding verdict)" || bad "5h 95%: rc=$rc out=[$out] err=[$err]"
# The week reserve is overridable; a non-integer override keeps the default (and doesn't crash).
fixture 10 80 0
CLAUDE_USAGE_WEEK_RESERVE=85 run --ok 90 2>/dev/null; [ $? = 0 ] && ok "week 80% with CLAUDE_USAGE_WEEK_RESERVE=85: passes" || bad "week reserve override: --ok should pass"
CLAUDE_USAGE_WEEK_RESERVE=lots run --ok 90 2>/dev/null; [ $? = 1 ] && ok "week 80% with a non-integer reserve: default 75 gates" || bad "week reserve 'lots': --ok should fail"
# A stale cache whose refresh fails (no credentials in hermetic HOME) discloses its age on the verdict line.
fixture 10 50 0; touch -d "@$(($(date +%s) - 600))" "$tmp/claude-statusline/usage.json"
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=anthropic meter=5h 5h=10%<90% week=50%<75% source=api (cache 10m old)" ] \
    && ok "stale cache (10m old, refresh fails): --ok appends (cache 10m old) to verdict" || bad "stale cache verdict: rc=$rc out=[$out] err=[$err]"

# Paid extra usage opt-in (CLAUDE_USAGE_EXTRA_OK=1): lifts only the weekly reserve while extra_usage is enabled and under spend limit.
fixture_extra 10 98 0 true false null
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$0.00 used source=api" ] \
    && ok "extra-usage opted in + on at week 98%: passes with meter=extra-usage" || bad "extra-usage pass: rc=$rc out=[$out] err=[$err]"
fixture_extra 10 98 0 false false out_of_credits
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75% extra=off (out_of_credits) source=api" ] \
    && ok "extra-usage opted in + off (out_of_credits): fails with extra=off (out_of_credits)" || bad "extra-usage out_of_credits: rc=$rc out=[$out] err=[$err]"
fixture_extra 10 98 0 true true null
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75% extra=off (spend_limit_reached) source=api" ] \
    && ok "extra-usage opted in + spend_limit_reached: fails with extra=off (spend_limit_reached)" || bad "extra-usage spend_limit_reached: rc=$rc out=[$out] err=[$err]"
fixture 10 98 0
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75% extra=off (disabled) source=api" ] \
    && ok "extra-usage opted in + no extra_usage key: fails with extra=off (disabled)" || bad "extra-usage missing key: rc=$rc out=[$out] err=[$err]"
fixture_extra 10 98 0 true false null
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75% source=api" ] \
    && ok "extra-usage on, not opted in: fails with today's exact week line" || bad "extra-usage not opted in: rc=$rc out=[$out] err=[$err]"
out=$(CLAUDE_USAGE_EXTRA_OK=yes run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75% source=api" ] \
    && ok "CLAUDE_USAGE_EXTRA_OK=yes: fails with today's exact week line" || bad "extra-usage =yes: rc=$rc out=[$out] err=[$err]"
fixture_extra 95 98 0 true false null
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=5h 5h=95%>=90% week=98%>=75% source=api" ] \
    && ok "extra-usage opted in + 5h 95%: fails with meter=5h, no suffix" || bad "extra-usage 5h 95%: rc=$rc out=[$out] err=[$err]"
fixture_extra 10 98 100 true false null
out=$(CLAUDE_USAGE_EXTRA_OK=1 CLAUDE_USAGE_MODEL=claude-fable-5-1 HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=model-cap model=Fable cap=100%>=100% source=api" ] \
    && ok "extra-usage opted in + Fable cap 100% on Fable: fails with model-cap line" || bad "extra-usage Fable cap: rc=$rc out=[$out] err=[$err]"
fixture_extra 10 50 0 true false null
out=$(CLAUDE_USAGE_EXTRA_OK=1 run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=anthropic meter=5h 5h=10%<90% week=50%<75% source=api" ] \
    && ok "extra-usage opted in at week 50%: unchanged normal meter=5h pass line" || bad "extra-usage week 50%: rc=$rc out=[$out] err=[$err]"
# The pass spends money, so it fails closed. extra_raw <5h> <week> <extra_usage JSON>: any shape.
extra_raw() {
    fixture "$1" "$2" 0
    jq --argjson x "$3" '. + {extra_usage: $x}' "$tmp/claude-statusline/usage.json" > "$tmp/claude-statusline/usage.json.tmp"
    mv "$tmp/claude-statusline/usage.json.tmp" "$tmp/claude-statusline/usage.json"
}
# expect_opt <rc> <stderr line> <label> [extra env ...]: one opted-in --ok 90 run.
expect_opt() {
    local want_rc=$1 want=$2 label=$3; shift 3
    out=$(env CLAUDE_USAGE_EXTRA_OK=1 "$@" HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
    [ "$rc" = "$want_rc" ] && [ -z "$out" ] && [ "$err" = "$want" ] && ok "$label" || bad "$label: rc=$rc out=[$out] err=[$err]"
}
wk98="claude-usage: --ok FAIL lane=anthropic meter=week 5h=10%<90% week=98%>=75%"
extra_raw 10 98 '{"is_enabled": true}'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: spend_limit_reached missing fails closed"
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": null}'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: spend_limit_reached null fails closed"
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": "true"}'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: spend_limit_reached \"true\" (string) fails closed"
extra_raw 10 98 '{"is_enabled": "true", "spend_limit_reached": false}'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: is_enabled \"true\" (string) fails closed"
extra_raw 10 98 '"on"'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: extra_usage a string fails closed"
extra_raw 10 98 '[true]'
expect_opt 1 "$wk98 extra=off (disabled) source=api" "extra-usage: extra_usage an array fails closed"
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": true, "disabled_reason": "x"}'
expect_opt 1 "$wk98 extra=off (spend_limit_reached) source=api" "extra-usage: spend_limit_reached wins over disabled_reason"
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false, "disabled_reason": "x"}'
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$0.00 used source=api" "extra-usage: on and under the limit passes whatever disabled_reason says"
extra_raw 10 98 '{"is_enabled": false, "spend_limit_reached": false, "disabled_reason": "a b\nFAKE ok"}'
expect_opt 1 "$wk98 extra=off (a_b_FAKE_ok) source=api" "extra-usage: disabled_reason reduced to [A-Za-z0-9_.-]"
# Boundaries: 5h exactly at the threshold stays a 5h fail; the week exactly at the reserve takes the extra pass.
extra_raw 90 98 '{"is_enabled": true, "spend_limit_reached": false}'
expect_opt 1 "claude-usage: --ok FAIL lane=anthropic meter=5h 5h=90%>=90% week=98%>=75% source=api" "extra-usage: 5h at the threshold still fails on 5h"
extra_raw 10 75 '{"is_enabled": true, "spend_limit_reached": false}'
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=75%>=75% extra=\$0.00 used source=api" "extra-usage: week at the reserve passes on extra usage"
# Only exactly 1 opts in.
for v in 0 "" 10 true; do
    extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'
    out=$(CLAUDE_USAGE_EXTRA_OK="$v" run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
    [ $rc = 1 ] && [ "$err" = "$wk98 source=api" ] && ok "CLAUDE_USAGE_EXTRA_OK='$v': not opted in" || bad "CLAUDE_USAGE_EXTRA_OK='$v': rc=$rc err=[$err]"
done
# A stale cache (refresh fails in the hermetic HOME) never passes on extra usage: 10m > 2 x 120 s.
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'; touch -d "@$(($(date +%s) - 600))" "$tmp/claude-statusline/usage.json"
expect_opt 1 "$wk98 extra=off (stale) source=api (cache 10m old)" "extra-usage: a cache older than two TTLs fails closed"
# Within two TTLs it still passes, with the age disclosed: 3m old with CLAUDE_USAGE_TTL=120 (> 1 TTL, < 2).
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'; touch -d "@$(($(date +%s) - 180))" "$tmp/claude-statusline/usage.json"
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$0.00 used source=api (cache 3m old)" "extra-usage: a cache within two TTLs passes and discloses its age"
# A long TTL doesn't stretch it: with CLAUDE_USAGE_TTL=3600 the ceiling is 10 minutes (11m fails, 9m passes).
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'; touch -d "@$(($(date +%s) - 660))" "$tmp/claude-statusline/usage.json"
expect_opt 1 "$wk98 extra=off (stale) source=api" "extra-usage: TTL 3600, an 11m cache fails closed (10-minute ceiling)" CLAUDE_USAGE_TTL=3600
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'; touch -d "@$(($(date +%s) - 540))" "$tmp/claude-statusline/usage.json"
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$0.00 used source=api" "extra-usage: TTL 3600, a 9m cache passes" CLAUDE_USAGE_TTL=3600
# --wait inherits the opt-in: at week 98% with extra usage on it returns at once.
extra_raw 10 98 '{"is_enabled": true, "spend_limit_reached": false}'
out=$(timeout 5 env CLAUDE_USAGE_EXTRA_OK=1 HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait 2>/dev/null); rc=$?
[ $rc = 0 ] && grep -q "week 98%" <<< "$out" && ok "extra-usage: --wait returns at once when opted in" || bad "extra-usage --wait: rc=$rc out=[$out]"

# The balance suffix (SYG_EXTRA_USAGE_BUDGET_USD, invalid = unset): an extra-usage --ok
# pass gains ` extra=…` after week=, and the plain line gains ` · extra …` after the plan
# windows — "$X.XX over $B.BB" past a budget, "$X.XX left of $B.BB" under it, "$X.XX
# used" without one; a missing spend counts as $0.00. FAIL lines and non-extra pass
# lines are pinned byte-identical above.
fixture_extra 10 98 0 true false null '{"currency":"USD","amount_minor":1234,"exponent":2}'
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$87.66 left of \$100.00 source=api" \
    "extra-usage pass with a \$100 budget: gains 'extra=\$87.66 left of \$100.00'" SYG_EXTRA_USAGE_BUDGET_USD=100
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$12.34 used source=api" \
    "extra-usage pass without a budget: gains 'extra=\$12.34 used'"
fixture_extra 10 98 0 true false null '{"currency":"USD","amount_minor":6000,"exponent":2}'
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$60.00 over \$50.00 source=api" \
    "extra-usage pass over budget: gains 'extra=\$60.00 over \$50.00'" SYG_EXTRA_USAGE_BUDGET_USD=50
fixture_extra 10 98 0 true false null '{"currency":"USD","amount_minor":1234,"exponent":2}'
expect_opt 0 "claude-usage: --ok pass lane=anthropic meter=extra-usage 5h=10%<90% week=98%>=75% extra=\$12.34 over \$0.00 source=api" \
    "extra-usage pass with budget 0: gains 'extra=\$12.34 over \$0.00'" SYG_EXTRA_USAGE_BUDGET_USD=0
fixture_extra 10 99 0 true false null '{"currency":"USD","amount_minor":1234,"exponent":2}'
out=$(SYG_EXTRA_USAGE_BUDGET_USD=100 run)
[[ $out == *' · extra $87.66 left of $100.00' ]] \
    && ok "plain line with a budget: ' · extra \$87.66 left of \$100.00' (week < 100, spend > 0)" \
    || bad "plain line left: $out"
out=$(run)
[[ $out == *' · extra $12.34 used' ]] \
    && ok "plain line without a budget: ' · extra \$12.34 used'" || bad "plain line used-only: $out"
fixture_extra 10 99 0 true false null '{"currency":"USD","amount_minor":6000,"exponent":2}'
out=$(SYG_EXTRA_USAGE_BUDGET_USD=50 run)
[[ $out == *' · extra $60.00 over $50.00' ]] \
    && ok "plain line over budget: ' · extra \$60.00 over \$50.00'" || bad "plain line over: $out"
fixture_extra 10 50 0 false false null
out=$(run)
[[ $out != *'extra'* ]] \
    && ok "plain line hidden: disabled, no spend, week < 100 -> no suffix" || bad "plain line hidden: $out"
# The text line's off shape: a maxed week with the limit reached flips the money
# figure to off, and is_enabled false must not hide it (the gate's extra=off parity).
fixture_extra 10 101 0 true true null '{"currency":"USD","amount_minor":1234,"exponent":2}'
out=$(run)
[[ $out == *' · extra off (limit reached)' ]] \
    && ok "plain line: limit-reached at week >= 100 -> ' · extra off (limit reached)'" \
    || bad "plain line off limit-reached: $out"
# Red-first: the pre-fix code enabled-gated the whole suffix, so it rendered nothing here.
fixture_extra 10 101 0 false false admin_disabled '{"currency":"USD","amount_minor":1234,"exponent":2}'
out=$(run)
[[ $out == *' · extra off (admin_disabled)' ]] \
    && ok "plain line: disabled_reason at week >= 100 -> ' · extra off (admin_disabled)' with is_enabled false" \
    || bad "plain line off disabled: $out"
# Gate parity, the enabled+reason shape: the gate passes enabled + reason + under the
# limit, so the plain line shows the balance, not off. Red-first: the pre-fix code
# rendered ' · extra off (x)' here.
fixture_extra 10 101 0 true false x '{"currency":"USD","amount_minor":1234,"exponent":2}'
out=$(SYG_EXTRA_USAGE_BUDGET_USD=50 run)
[[ $out == *' · extra $37.66 left of $50.00'* ]] && [[ $out != *'extra off'* ]] \
    && ok "plain line: the gate passes enabled+reason under the limit, so the suffix shows the balance, not off" \
    || bad "plain line enabled+reason: $out"

# Any non-flag argument prints the usage block from the script's own header lines.
out=$(run --help); rc=$?
[ $rc = 2 ] && grep -q '^ *claude-usage --ok \[PCT\]' <<< "$out" && grep -q 'prints one verdict line to stderr' <<< "$out" \
    && grep -q '^ *claude-usage --json' <<< "$out" && grep -q '^ *claude-usage --all' <<< "$out" \
    && grep -q 'api_credit_remaining_usd' <<< "$out" && grep -q 'CLAUDE_USAGE_EXTRA_OK=1' <<< "$out" \
    && grep -q 'always exits 0$' <<< "$out" \
    && ok "--help: exit 2 with the header's usage block" || bad "--help (rc $rc): $out"

# The reported bug: at 95-99% of the week, --wait returned at once. It must block now, and silence inner --ok stderr.
fixture 10 97 0
timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait >/dev/null 2>"$tmp/wait-block.err"; rc=$?
[ $rc = 124 ] && [ ! -s "$tmp/wait-block.err" ] \
    && ok "week 97%: --wait blocks and silences inner --ok stderr" || bad "week 97%: --wait returned (rc $rc, err [$(cat "$tmp/wait-block.err")])"
fixture 10 50 0
out=$(timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait 2>"$tmp/wait-wake.err"); rc=$?
[ $rc = 0 ] && grep -q "week 50%" <<< "$out" \
    && [ "$(cat "$tmp/wait-wake.err")" = "claude-usage: --ok pass lane=anthropic meter=5h 5h=10%<50% week=50%<75% source=api" ] \
    && ok "week 50%: --wait returns with the line and one wake verdict on stderr" || bad "week 50%: --wait (rc $rc): out=[$out] err=[$(cat "$tmp/wait-wake.err")]"

# A model's own cap still gates only that model, at 100%.
fixture 10 50 100
out=$(CLAUDE_USAGE_MODEL=claude-fable-5-1 HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=anthropic meter=model-cap model=Fable cap=100%>=100% source=api" ] \
    && ok "Fable cap 100%: Fable session blocked with model-cap verdict" || bad "Fable cap: rc=$rc out=[$out] err=[$err]"
run --ok 90 2>/dev/null; [ $? = 0 ] && ok "Fable cap 100%: Opus session passes" || bad "Fable cap: Opus should pass"
# No CLAUDE_USAGE_MODEL: the caller's model is the last assistant reply in its session transcript.
mkdir -p "$tmp/.claude/projects/slugA"
{
    jq -cn '{type: "assistant", message: {model: "claude-opus-5-5"}}'
    jq -cn '{type: "user", message: {content: "next"}}'
    jq -cn '{type: "assistant", message: {model: "claude-fable-5-1"}}'
    jq -cn '{type: "user", message: {content: "last"}}'
} > "$tmp/.claude/projects/slugA/probe-session.jsonl"
CLAUDE_CODE_SESSION_ID=probe-session HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90 2>/dev/null; [ $? = 1 ] \
    && ok "transcript model (Fable), Fable cap 100%: blocked" || bad "transcript model, Fable cap 100%: should block"
fixture 10 50 50
CLAUDE_CODE_SESSION_ID=probe-session HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90 2>/dev/null; [ $? = 0 ] \
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
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=zai meter=zai-5h 5h=10%<80% week=74%<75% source=api" ] \
    && ok "z.ai week 74% (api): --ok passes with capped-at-80 verdict" || bad "z.ai week 74%: rc=$rc out=[$out] err=[$err]"
zai_stub api 10 75
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=zai meter=week 5h=10%<80% week=75%>=75% source=api" ] \
    && ok "z.ai week 75% (api): --ok fails (wind-down)" || bad "z.ai week 75%: rc=$rc out=[$out] err=[$err]"
zai_stub api 95 10
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=zai meter=zai-5h 5h=95%>=80% week=10%<75% source=api" ] \
    && ok "z.ai 5h 95% (api): --ok fails" || bad "z.ai 5h 95%: rc=$rc out=[$out] err=[$err]"
# z.ai's 5h gate is capped at 80 whatever PCT asks, below Tzurot's guest cutoff (90)
zai_stub api 82 10
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 1 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok FAIL lane=zai meter=zai-5h 5h=82%>=80% week=10%<75% source=api" ] \
    && ok "z.ai 5h 82% with --ok 90: fails (capped at 80)" || bad "z.ai 5h 82%: rc=$rc out=[$out] err=[$err]"
zai_stub api 79 10
run --ok 90 2>/dev/null; [ $? = 0 ] && ok "z.ai 5h 79%: passes" || bad "z.ai 5h 79%: --ok should pass"
run --ok 50 2>/dev/null; [ $? = 1 ] && ok "z.ai 5h 79% with --ok 50: a lower PCT still wins" || bad "z.ai --ok 50: should fail at 79%"
CLAUDE_USAGE_ZAI_FIVE_CAP=70 run --ok 90 2>/dev/null; [ $? = 1 ] && ok "z.ai 5h 79% with CLAUDE_USAGE_ZAI_FIVE_CAP=70: fails" || bad "z.ai cap override 70: --ok should fail at 79%"
CLAUDE_USAGE_ZAI_FIVE_CAP=7x run --ok 90 2>/dev/null; [ $? = 0 ] && ok "z.ai 5h 79% with a non-integer cap: default 80 applies" || bad "z.ai cap '7x': --ok should pass at 79%"
zai_stub local 10 308
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=zai meter=zai-5h source=estimate FAIL-OPEN: z.ai quota API unavailable, local estimate never blocks; gate passes" ] \
    && ok "z.ai local estimate only: passes with FAIL-OPEN verdict" || bad "z.ai local (rc $rc): out=[$out] err=[$err]"
zai_stub api 10 10
run --ok 90 2>/dev/null; [ $? = 0 ] && ok "z.ai-routed, week 99%: --ok passes" || bad "z.ai-routed, week 99%: --ok should pass"
CLAUDE_USAGE_MODEL=claude-fable-5-1 HOME="$tmp" XDG_CACHE_HOME="$tmp" "$CU" --ok 90 2>/dev/null; [ $? = 0 ] && ok "z.ai-routed, Fable cap 100%: --ok passes" || bad "z.ai-routed, Fable cap: --ok should pass"
out=$(timeout 5 env HOME="$tmp" XDG_CACHE_HOME="$tmp" CLAUDE_USAGE_MODEL=claude-opus-5-5 "$CU" --wait 2>/dev/null); rc=$?
[ $rc = 0 ] && grep -q "z.ai-routed" <<< "$out" && ok "z.ai-routed: --wait returns at once with the note" || bad "z.ai-routed: --wait (rc $rc): $out"
out=$(run); grep -q "z.ai-routed" <<< "$out" && ok "z.ai-routed: plain line carries the note" || bad "z.ai-routed: plain line missing note: $out"
run --json | jq -e '.routed == 1' >/dev/null && ok "z.ai-routed: --json reports routed:1" || bad "z.ai-routed: --json routed flag"
# The process env is the truth even when it sets the base URL to empty: an overlay that clears the
# route puts the session back on the plan lane over a z.ai settings.json, so the plan's 99% gates.
ANTHROPIC_BASE_URL='' run --ok 90 2>/dev/null; [ $? = 1 ] && ok "env set-but-empty over z.ai settings: plan lane, plan 99% gates" || bad "env empty over z.ai: --ok should fail"
# Per-session overlay: settings.json on anthropic, the calling session's env routed to z.ai. The
# session's own route decides: z.ai's quota gates, the plan's 99% doesn't.
route_anthropic
zai_stub api 10 10
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic run --ok 90 2>/dev/null; [ $? = 0 ] && ok "session env z.ai over anthropic settings: plan 99% doesn't gate" || bad "session env z.ai: --ok should pass"
zai_stub api 10 80
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic run --ok 90 2>/dev/null; [ $? = 1 ] && ok "session env z.ai: z.ai's week 80% gates" || bad "session env z.ai 80%: --ok should fail"
run --ok 90 2>/dev/null; [ $? = 1 ] && ok "no session env: anthropic settings, plan 99% gates" || bad "anthropic settings 99%: --ok should fail"
route_url https://openrouter.ai/api
zai_stub api 10 99
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=or gate=pass-through source=none (provider enforces its own cap)" ] \
    && ok "OpenRouter-routed: --ok passes with pass-through verdict" || bad "OpenRouter: rc=$rc out=[$out] err=[$err]"
out=$(run); grep -q "OpenRouter-routed" <<< "$out" && ! grep -q "z.ai" <<< "$out" && ok "OpenRouter line says OpenRouter, not z.ai" || bad "OpenRouter line: $out"
# A lookalike host is not the plan lane: its gate passes and it never reads plan meters as its own.
route_url https://api.anthropic.com.evil.com
out=$(run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=unknown gate=pass-through source=none (provider enforces its own cap)" ] \
    && ok "api.anthropic.com.evil.com: not the plan lane, gate passes with pass-through verdict" || bad "lookalike host: rc=$rc out=[$out] err=[$err]"
out=$(run); grep -q '^api\.anthropic\.com\.evil\.com-routed (gate passes' <<< "$out" \
    && ok "lookalike host: line labels the raw host" || bad "lookalike line: $out"
route_anthropic
# A base URL with no host has no label to show (the statusline renders none either): no note at all.
out=$(ANTHROPIC_BASE_URL=https:// run)
[[ $out == "5h "* ]] && ! grep -q -- '-routed' <<< "$out" && ok "hostless env base URL: no empty '-routed' note" || bad "hostless line: $out"
# A Console API key (the anthropic-api route preset) bills credits, not the plan: the plan's 99%
# doesn't gate. The lane is the overlay's CC_ROUTE_PRESET marker, never the key alone.
out=$(CC_ROUTE_PRESET=anthropic-api ANTHROPIC_API_KEY=sk-ant-test run --ok 90 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
[ $rc = 0 ] && [ -z "$out" ] && [ "$err" = "claude-usage: --ok pass lane=console gate=pass-through source=none (provider enforces its own cap)" ] \
    && ok "anthropic-api session: --ok passes (Console credits pass-through verdict)" || bad "anthropic-api session: rc=$rc out=[$out] err=[$err]"
out=$(CC_ROUTE_PRESET=anthropic-api ANTHROPIC_API_KEY=sk-ant-test run); grep -q "Console API key-routed" <<< "$out" && ok "API key line names the lane" || bad "API key line: $out"
ANTHROPIC_API_KEY=sk-ant-test run --ok 90 2>/dev/null; [ $? = 1 ] && ok "a stray exported API key in a plan session still gates" || bad "stray API key: --ok should fail"
CC_ROUTE_PRESET=zai run --ok 90 2>/dev/null; [ $? = 1 ] && ok "another preset's marker on the anthropic base doesn't skip the gate" || bad "zai marker: --ok should fail"
run --ok 90 2>/dev/null; [ $? = 1 ] && ok "back on Anthropic: week 99% fails again" || bad "unrouted week 99%: --ok should fail"
run --json | jq -e '.routed == 0' >/dev/null && ok "anthropic: --json reports routed:0" || bad "anthropic: --json routed flag"
# Routed-lane plain line: the extra suffix rides before the z.ai tail.
route_zai
zai_stub api 10 20
fixture_extra 10 101 0 true false null '{"currency":"USD","amount_minor":1234,"exponent":2}'
out=$(run)
[[ $out == *' · extra $12.34 used · z.ai '* ]] \
    && ok "z.ai-routed plain line: ' · extra \$12.34 used' before the ' · z.ai ' tail" || bad "zai extra tail: $out"
route_anthropic

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
run --ok 90 2>/dev/null; [ $? = 0 ] && ok "weird.example.org: unknown lane, gate passes" || bad "weird.example.org: --ok should pass"
route_anthropic

# --all: one line per lane (plan, z.ai, api credit), whatever lane the caller is on, exit 0.
fixture 10 50 0
# Resets 2m30s past a whole hour: the countdown floors to "…h2m" for the first 30 s of the run.
nowe=$(date +%s); r5=$((nowe + 3600 + 150)); rw=$((nowe + 30 * 3600 + 150))
zai_stub api 42 17 "$r5" "$rw"
credit_stub '{"remaining_usd":128.557512,"spent_usd":21.44,"next_expiry":"2026-10-21T00:00:00Z","days_left":11}'
out=$(run --all); rc=$?
want_z="z.ai: 5h 42% (resets $(date -d "@$r5" +%H:%M), in 1h 2m) · week 17% (resets $(date -d "@$rw" +%H:%M), in 30h 2m)"
[ $rc = 0 ] && [ "$(wc -l <<< "$out")" = 3 ] \
    && [[ $(sed -n 1p <<< "$out") == "Anthropic plan: 5h 10% (resets "*" · week 50% (resets "*" · Fable 0% of its own weekly cap" ]] \
    && ok "--all: plan line first, composed like the plain line" || bad "--all plan line (rc $rc): $out"
grep -qE 'in [0-9]+d [0-9]+h' <<< "$out" && ok "--all: plan week tail formats countdown as 'in Nd Nh'" \
    || bad "--all plan week tail: $(sed -n 1p <<< "$out")"
grep -qE 'in [0-9]+h [0-9]+m' <<< "$(sed -n 1p <<< "$out")" && ok "--all: plan five tail formats countdown as 'in Nh Nm'" \
    || bad "--all plan five tail: $(sed -n 1p <<< "$out")"
[ "$(sed -n 2p <<< "$out")" = "$want_z" ] && ok "--all: z.ai line from zai-usage --json (api), local reset times + countdowns" \
    || bad "--all z.ai line: got [$(sed -n 2p <<< "$out")], want [$want_z]"
[ "$(sed -n 3p <<< "$out")" = 'api credit: $128.56 est (exp 10-21, 11d)' ] && ok "--all: api credit line from balance --json (estimate: 'est' after the figure)" \
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
[ "$(run --all | sed -n 3p)" = 'api credit: $3.50 spent est (no live grants)' ] && ok "--all: no grants config -> spent" \
    || bad "--all credit spent: $(run --all | sed -n 3p)"
credit_stub '{"remaining_usd":0,"spent_usd":200,"next_expiry":null,"days_left":null}'
[ "$(run --all | sed -n 3p)" = 'api credit: $0.00 est' ] && ok "--all: remaining 0 -> \$0.00 est" \
    || bad "--all credit zero: $(run --all | sed -n 3p)"
credit_stub '{"remaining_usd":5,"spent_usd":1,"next_expiry":null,"days_left":null}'
[ "$(run --all | sed -n 3p)" = 'api credit: $5.00 est' ] && ok "--all: no expiry -> no parenthetical" \
    || bad "--all credit no expiry: $(run --all | sed -n 3p)"
credit_stub '{"estimate":false,"remaining_usd":83.797,"spent_usd":16.2,"next_expiry":"2026-10-21T00:00:00Z","days_left":11}'
[ "$(run --all | sed -n 3p)" = 'api credit: $83.80 (exp 10-21, 11d)' ] && ok "--all: exact balance (estimate false) -> the bare figure, no est" \
    || bad "--all credit exact: $(run --all | sed -n 3p)"
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
fixture 10 50 0
j=$(run --json)
jq -e 'has("extra_usage") == false' <<< "$j" >/dev/null \
    && ok "--json no extra_usage key in cache: has(\"extra_usage\") is false" || bad "--json no extra_usage key: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":1234,"currency":"USD","exponent":2}'
j=$(run --json)
[[ $j == "$old_prefix"* ]] && [[ $j == *',"routed":0,"lane":"anthropic","extra_usage":{"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":12.34}}' ]] \
    && jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":12.34}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: enabled + spend.used 12.34 USD, old_prefix first, extra_usage after lane" || bad "--json extra_usage on: $j"
route_zai
zai_stub api 42 17
j=$(run --json)
jq -e '.lane == "zai" and .zai_five_hour_pct == 42 and .extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":12.34}' <<< "$j" >/dev/null \
    && ok "--json extra_usage on z.ai lane: appended after lane fields" || bad "--json extra_usage zai: $j"
route_anthropic
fixture_extra 10 50 0 false false out_of_credits
j=$(run --json)
jq -e '.extra_usage == {"enabled":false,"spend_limit_reached":false,"disabled_reason":"out_of_credits","used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: off, out_of_credits, no spend key -> used_usd null" || bad "--json extra_usage out_of_credits: $j"
fixture_extra 10 50 0 true true null
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":true,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend_limit_reached true" || bad "--json extra_usage spend_limit_reached: $j"
fixture_extra 10 50 0 false false 'bad "reason"'
j=$(run --json)
jq -e '.extra_usage == {"enabled":false,"spend_limit_reached":false,"disabled_reason":"bad__reason_","used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: disabled_reason with space and quote reduced to underscores" || bad "--json extra_usage reason reduction: $j"
fixture_extra 10 50 0 '"true"' false null
j=$(run --json)
jq -e '.extra_usage == {"enabled":false,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: is_enabled string \"true\" -> enabled false" || bad "--json extra_usage string is_enabled: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":1234,"currency":"EUR","exponent":2}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used currency EUR -> used_usd null" || bad "--json extra_usage EUR: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":1234,"currency":"USD","exponent":"2"}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used string exponent -> used_usd null" || bad "--json extra_usage string exponent: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":1235,"currency":"USD","exponent":3}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":1.24}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used {1235, USD, 3} rounds to 1.24" || bad "--json extra_usage round 1.24: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":7,"currency":"USD","exponent":0}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":7}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used exponent 0 {7, USD, 0} -> 7" || bad "--json extra_usage exp 0: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":1500000,"currency":"USD","exponent":6}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":1.5}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used exponent 6 {1500000, USD, 6} -> 1.5" || bad "--json extra_usage exp 6: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":10000000,"currency":"USD","exponent":7}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used exponent 7 -> used_usd null" || bad "--json extra_usage exp 7: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":10,"currency":"USD","exponent":-1}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used exponent -1 -> used_usd null" || bad "--json extra_usage exp -1: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":-1,"currency":"USD","exponent":2}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used amount_minor -1 -> used_usd null" || bad "--json extra_usage amount_minor -1: $j"
fixture_extra 10 50 0 true false null '{"amount_minor":12.5,"currency":"USD","exponent":2}'
j=$(run --json)
jq -e '.extra_usage == {"enabled":true,"spend_limit_reached":false,"disabled_reason":null,"used_usd":null}' <<< "$j" >/dev/null \
    && ok "--json extra_usage: spend.used amount_minor 12.5 -> used_usd null" || bad "--json extra_usage amount_minor 12.5: $j"
extra_raw 10 50 '"on"'
j=$(run --json); rc=$?
[ $rc = 0 ] && jq -e 'type == "object" and has("extra_usage") == false' <<< "$j" >/dev/null \
    && ok "--json extra_usage: string extra_usage omitted, exits 0 with valid JSON" || bad "--json string extra_usage (rc $rc): $j"
printf '{not json\n' > "$tmp/claude-statusline/usage.json"
# Pins the stdout from before extra_usage: zeroed plan fields, no extra_usage key. The exit code is
# left unpinned: printf's "invalid number" on the empty fields is rc 1 under bash 5.3 and rc 0 on CI.
j=$(run --json 2>/dev/null); rc=$?
[ "$j" = '{"five_hour_pct":0,"five_hour_resets_at":0,"seconds_to_reset":0,"weekly_pct":0,"weekly_resets_at":0,"scoped":"","routed":0,"lane":"anthropic"}' ] \
    && ok "--json malformed cache ({not json): zeroed plan fields, no extra_usage key" || bad "--json malformed cache (rc $rc): $j"
fixture 10 50 0

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
run >/dev/null; run --ok 90 2>/dev/null; run --json >/dev/null
[ "$(wc -l < "$log")" = 1 ] && ok "log: three runs on one reading write one line" || bad "log: want 1 line, got $(wc -l < "$log")"
jq -e '.five_hour_pct == 12.5 and .weekly_pct == 40 and .scoped.Fable == 7 and (.ts | test("Z$")) and (.epoch > 0)' "$log" >/dev/null \
    && ok "log: line holds ts, epoch, raw 5h/week % and scoped caps" || bad "log: line shape: $(cat "$log")"
fixture 13 40 7
run >/dev/null
[ "$(wc -l < "$log")" = 2 ] && [ "$(tail -1 "$log" | jq '.five_hour_pct')" = 13 ] \
    && ok "log: a changed reading appends a line" || bad "log: changed reading not appended: $(cat "$log")"

# --- prev_epoch and CLAUDE_USAGE_TTL ---
# A first-ever reading has no prev_epoch key.
rm -f "$log" "$log.last"
now=$(date +%s)
fixture 10 20 0; touch -d "@$((now - 120))" "$tmp/claude-statusline/usage.json"; run >/dev/null
[ "$(wc -l < "$log")" = 1 ] && jq -e 'has("prev_epoch") | not' "$log" >/dev/null \
    && ok "log: first-ever reading has no prev_epoch key" || bad "log first-ever prev_epoch: $(cat "$log")"

# Two fetches with different mtimes and the SAME numbers, then a third with new numbers:
# the log has 2 lines, and the second line's prev_epoch equals the second fetch's mtime.
rm -f "$log" "$log.last"
t1=$((now - 120))
t2=$((now - 60))
t3=$now
fixture 10 20 0; touch -d "@$t1" "$tmp/claude-statusline/usage.json"; run >/dev/null
fixture 10 20 0; touch -d "@$t2" "$tmp/claude-statusline/usage.json"; run >/dev/null
fixture 11 20 0; touch -d "@$t3" "$tmp/claude-statusline/usage.json"; run >/dev/null
[ "$(wc -l < "$log")" = 2 ] && [ "$(tail -1 "$log" | jq -r '.prev_epoch')" = "$t2" ] \
    && ok "log: prev_epoch records the last unchanged fetch epoch ($t2)" || bad "log prev_epoch: $(cat "$log")"

# CLAUDE_USAGE_TTL=40 with a 50-second-old cache tries a refresh; CLAUDE_USAGE_TTL=10 keeps 120.
fixture 10 20 0; touch -d "@$((now - 50))" "$tmp/claude-statusline/usage.json"
rm -f "$tmp/claude-statusline/usage.json.lock"
CLAUDE_USAGE_TTL=10 run >/dev/null
[ ! -e "$tmp/claude-statusline/usage.json.lock" ] \
    && ok "CLAUDE_USAGE_TTL=10 keeps 120s TTL (50s cache not refreshed)" || bad "TTL=10 refreshed"
CLAUDE_USAGE_TTL=40 run >/dev/null
[ -e "$tmp/claude-statusline/usage.json.lock" ] \
    && ok "CLAUDE_USAGE_TTL=40 refreshes 50s cache (lock created)" || bad "TTL=40 did not refresh"

# Producer -> consumer: two readings written by claude-usage feed usage-sweep --points, which
# also reaches claude-usage --json through PATH (a shim execs this build).
rm -f "$log" "$log.last"
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

# --- five_hour_resets_at / weekly_resets_at in reading log ---
# A logged line carries five_hour_resets_at and weekly_resets_at rounded to the minute (...:59.7 rounds up)
rm -f "$log" "$log.last"
jq -n '{
    five_hour: {utilization: 15, resets_at: "2026-10-13T06:09:59.700000+00:00"},
    seven_day: {utilization: 25, resets_at: "2026-10-20T06:09:59.700000+00:00"}
}' > "$tmp/claude-statusline/usage.json"
run >/dev/null
[ "$(wc -l < "$log")" = 1 ] \
    && jq -e '.five_hour_resets_at == 1791871800 and .weekly_resets_at == 1792476600' "$log" >/dev/null \
    && ok "log: carries five_hour_resets_at and weekly_resets_at rounded to minute (...:59.7 -> :10:00)" \
    || bad "log resets_at rounded: $(cat "$log")"

# A cache with no resets_at logs null
rm -f "$log" "$log.last"
jq -n '{
    five_hour: {utilization: 15},
    seven_day: {utilization: 25}
}' > "$tmp/claude-statusline/usage.json"
run >/dev/null
[ "$(wc -l < "$log")" = 1 ] \
    && jq -e '.five_hour_resets_at == null and .weekly_resets_at == null' "$log" >/dev/null \
    && ok "log: cache with no resets_at logs null for reset fields" \
    || bad "log resets_at null: $(cat "$log")"

# Two fetches with identical percentages but resets_at 5 h apart log two lines
rm -f "$log" "$log.last"
now=$(date +%s)
jq -n '{
    five_hour: {utilization: 15, resets_at: "2026-10-13T06:00:00.000000+00:00"},
    seven_day: {utilization: 25, resets_at: "2026-10-20T06:00:00.000000+00:00"}
}' > "$tmp/claude-statusline/usage.json"
touch -d "@$((now - 60))" "$tmp/claude-statusline/usage.json"
run >/dev/null
jq -n '{
    five_hour: {utilization: 15, resets_at: "2026-10-13T11:00:00.000000+00:00"},
    seven_day: {utilization: 25, resets_at: "2026-10-20T06:00:00.000000+00:00"}
}' > "$tmp/claude-statusline/usage.json"
touch -d "@$now" "$tmp/claude-statusline/usage.json"
run >/dev/null
[ "$(wc -l < "$log")" = 2 ] \
    && ok "log: two fetches with identical percentages but resets_at 5h apart log two lines" \
    || bad "log identical pct with 5h reset: want 2 lines, got $(wc -l < "$log") ($(cat "$log"))"

# --- Cross-reader parity: the plain line's ` · extra …` suffix and the statusline's
# `extra:` segment read the same shared cache, so each shape must classify the same
# way (off / shown / hidden) in both tools. Five shapes cover the gate-parity matrix;
# no colors asserted here.
parity_sl_in() { # the statusline's stdin: the fixture week as seven_day.used_percentage
    jq -cn --argjson w "$1" '{rate_limits:{five_hour:{used_percentage:10,resets_at:1790790548},
        seven_day:{used_percentage:$w,resets_at:1791093600}},
        context_window:{current_usage:{input_tokens:1000}},model:{display_name:"X"},cwd:"/tmp"}'
}
cu_extra_class() { # claude-usage's plain line -> off | shown | hidden
    if [[ $1 == *' · extra off'* ]]; then echo off
    elif [[ $1 == *' · extra $'* ]]; then echo shown
    else echo hidden; fi
}
sl_extra_class() { # the statusline's stripped render -> off | shown | hidden
    if [[ $1 == *'extra: off'* ]]; then echo off
    elif [[ $1 == *'extra: $'* ]]; then echo shown
    else echo hidden; fi
}
parity_case() { # parity_case <name> <fixture_extra args...>; cu_out/sl_out stay global so a
                # case can take a follow-up assertion on its renders
    local name=$1; shift
    fixture_extra "$@"
    local week=$2 c1 c2
    cu_out=$(run)
    sl_out=$(env HOME="$tmp" XDG_CACHE_HOME="$tmp" bash "$SL" <<< "$(parity_sl_in "$week")" | strip)
    c1=$(cu_extra_class "$cu_out"); c2=$(sl_extra_class "$sl_out")
    if [ "$c1" = "$c2" ]; then
        ok "parity $name: claude-usage '$c1' == statusline '$c2'"
    else
        bad "parity $name: claude-usage '$c1' vs statusline '$c2' (cu: $cu_out | sl: $sl_out)"
    fi
}
echo '{}' > "$tmp/.claude/settings.json" # plan lane for both readers
parity_case "enabled+spend, week 101" 10 101 0 true false null '{"currency":"USD","amount_minor":1234,"exponent":2}'
# The figure, not only the class: that shape's $12.34 shows in both readers' renders.
[[ $cu_out == *'extra $12.34'* && $sl_out == *'extra: $12.34'* ]] \
    && ok "parity enabled+spend: the \$12.34 figure shows in both readers" \
    || bad "parity enabled+spend figure: (cu: $cu_out | sl: $sl_out)"
parity_case "enabled+reason, week 101" 10 101 0 true false x '{"currency":"USD","amount_minor":1234,"exponent":2}'
parity_case "disabled+reason, week 101" 10 101 0 false false admin_disabled '{"currency":"USD","amount_minor":1234,"exponent":2}'
parity_case "disabled+no-spend, week 50" 10 50 0 false false null
parity_case "enabled+lim-missing, week 101" 10 101 0 true omit null '{"currency":"USD","amount_minor":1234,"exponent":2}'

exit $fail
