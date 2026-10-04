#!/bin/bash
# Fixture check for plugins/seyag/bin/statusline — the plugin's copy (override with
# STATUSLINE_BIN, e.g. to test the deployed ~/.claude/statusline.sh). Covers the provider split: routing decides
# the data backend (z.ai quota API vs harness stdin rate_limits), while rendering goes through
# the shared render_windows template — colors, hybrid format, reset arrows and the fable cap.
# Hermetic: HOME, caches, the token, both z.ai endpoints and zai-spend (stub) are
# fixtures; nothing touches the network or the real caches. ZAI_SPEND_BIN overrides
# the stub to integration-test against the real dev-docs binary.
# Usage: tests/statusline.probe.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SL="${STATUSLINE_BIN:-$REPO/plugins/seyag/bin/statusline}"
[ -f "$SL" ] || { echo "statusline.probe: no statusline at $SL"; exit 2; }
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

h=$(mktemp -d)
trap 'rm -rf "$h"' EXIT
mkdir -p "$h/.claude" "$h/.local/bin" "$h/cache/claude-statusline" "$h/projects/empty"
# zai-spend: a fixture stub, not the real tool (the real one is a dev-docs
# binary no CI runner or foreign checkout has — review finding on #24).
# Same output shapes the statusline consumes: --json percentages from
# $ZAI_SPEND_QUOTA_URL (file://, unit 3 = 5h window, unit 6 = week),
# --line falls back to a 'local est' text when the quota is unreadable.
if [ -n "${ZAI_SPEND_BIN:-}" ]; then
    ln -sf "$(readlink -f "$ZAI_SPEND_BIN")" "$h/.local/bin/zai-spend"
else
    cat > "$h/.local/bin/zai-spend" <<'STUB'
#!/bin/bash
case "$1" in
--json)
    f=${ZAI_SPEND_QUOTA_URL#file://}
    [ -n "$f" ] && [ -r "$f" ] || exit 0
    jq -c '{five_hour_pct:(.data.limits[]|select(.unit==3).percentage),week_pct:(.data.limits[]|select(.unit==6).percentage),five_hour_reset_at:(.data.limits[]|select(.unit==3).nextResetTime/1000|floor),week_reset_at:(.data.limits[]|select(.unit==6).nextResetTime/1000|floor)}' "$f" 2>/dev/null
    ;;
--line)
    f=${ZAI_SPEND_QUOTA_URL#file://}
    if [ -n "$f" ] && [ -r "$f" ]; then
        jq -r '"\(.data.limits[]|select(.unit==3).percentage)% / \(.data.limits[]|select(.unit==6).percentage)%"' "$f" 2>/dev/null
    else
        echo "local est (stub: quota unreadable)"
    fi
    ;;
esac
STUB
    chmod +x "$h/.local/bin/zai-spend"
fi
printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"dummy-probe-token"},"modelSettings":{"glm-5.3":{"effortLevel":"high"},"glm-5.3-flash":{"effortLevel":"max"},"claude-opus-5-5":{"effortLevel":"high"}}}' > "$h/.claude/settings.json"
export HOME="$h" XDG_CACHE_HOME="$h/cache" XDG_STATE_HOME="$h/state" XDG_STATE_HOME="$h/state"
export ZAI_SPEND_PROJECTS="$h/projects/empty" ZAI_SPEND_PEAK_UTC="0-24"

cat > "$h/quota.json" <<'EOF'
{"code":200,"success":true,"data":{"limits":[
 {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":95,"nextResetTime":1790790548600},
 {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":59,"nextResetTime":1791340578979}
],"level":"max"}}
EOF
export ZAI_SPEND_QUOTA_URL="file://$h/quota.json" ZAI_SPEND_MODELS_URL="file://$h/missing.json"

route_zai() { jq '.env.ANTHROPIC_BASE_URL = "https://api.z.ai/api/anthropic"' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"; }
route_anthropic() { jq '.env.ANTHROPIC_BASE_URL = "https://api.anthropic.com"' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"; }
route_or() { jq '.env.ANTHROPIC_BASE_URL = "https://openrouter.ai/api/v1"' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"; }
route_host() { jq --arg u "$1" '.env.ANTHROPIC_BASE_URL = $u' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"; }
render() { printf '%s' "$1" | bash "$SL"; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# 1-2. Routed: the z.ai segment comes from the quota API, colored and with reset arrows.
route_zai
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3-Flash"},"cwd":"/tmp"}')
strip <<< "$out" | grep -Eq 'z\.ai 5h: 95% \(→[0-9:]+\) wk: 59% \(→[A-Za-z0-9 :]+\)' \
    && ok "routed: z.ai segment renders api pcts + reset arrows" || bad "routed text: $(strip <<< "$out" | grep -o 'z.ai.*')"
grep -q $'\x1b\\[31m95%' <<< "$out" && ok "routed: 5h pct is red at 95" || bad "routed red: $out"
grep -q $'\x1b\\[33m59%' <<< "$out" && ok "routed: wk pct is yellow at 59" || bad "routed yellow: $out"
grep -qF $'\x1b[38;2;11;127;255mz.ai' <<< "$out" \
    && ok "routed: z.ai label wears the brand blue (#0B7FFF)" || bad "routed z.ai brand: $out"

# 3. Routed, API dead: the gray local-est fallback, never silent. Drop the fresh cache first —
# within the 120s TTL the case-1 poll would otherwise be served without a re-poll.
export ZAI_SPEND_QUOTA_URL="file://$h/missing.json"
rm -f "$h/cache/claude-statusline/zai-spend.json"
strip <<< "$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')" \
    | grep -q 'local est' && ok "routed, api dead: local-est fallback renders" || bad "fallback: $out"
export ZAI_SPEND_QUOTA_URL="file://$h/quota.json"

# 4-5. Unrouted: the Anthropic segment from stdin rate_limits through the SAME template —
# hybrid format, both reset arrows, same traffic lights. Plus the fable cap from a fresh cache.
route_anthropic
printf '{"limits":[{"kind":"weekly_scoped","percent":89,"scope":{"model":{"display_name":"Fable"}}}]}' \
    > "$h/cache/claude-statusline/usage.json"
touch "$h/cache/claude-statusline/usage.json" # fresh mtime: the background curl stays asleep
out=$(render '{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548},"seven_day":{"used_percentage":56,"resets_at":1791093600}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip <<< "$out" | grep -Eq '5h: 83% \(→[0-9:]+\) wk: 56% \(→[A-Za-z0-9 :]+\)' \
    && ok "unrouted: same template, both reset arrows" || bad "unrouted text: $(strip <<< "$out" | grep -o '5h:.*')"
grep -q $'\x1b\\[31m83%' <<< "$out" && grep -q $'\x1b\\[33m56%' <<< "$out" \
    && ok "unrouted: same traffic lights (red 83, yellow 56)" || bad "unrouted colors: $out"
strip <<< "$out" | grep -q 'fable: 89%' && ok "unrouted: fable cap from the oauth cache" || bad "fable: $out"

# 6. Unrouted with no rate_limits in the input: no window segment at all (and no crash).
out=$(strip <<< "$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')")
grep -q '5h:' <<< "$out" && bad "no rate_limits: segment should be absent: $out" || ok "no rate_limits: no window segment"

# 7. Sanity: the model name still renders on both paths (the rest of the line is untouched).
render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3-Flash"},"cwd":"/tmp"}' \
    | strip | grep -q 'GLM-5.3-Flash' && ok "sanity: model name renders" || bad "model name"

# 10-13. Effort: the level is color-coded; "intended" comes from settings.json
# modelSettings (data-driven), red+hint only for drift vs the stored per-model
# intent. Deliberate boosts (xhigh/max) are never drift.
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM","id":"glm-5.3-flash"},"effort":{"level":"max"},"cwd":"/tmp"}')
grep -q '⚡max' <<< "$out" && ! grep -q '→' <<< "$out" \
    && ok "effort: exact modelSettings match renders, no drift hint" || bad "effort match: $out"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM","id":"glm-5.3-flash[1m]"},"effort":{"level":"high"},"cwd":"/tmp"}')
grep -q '→max' <<< "$out" && ! grep -q '→high' <<< "$out" \
    && ok "effort: [1m] suffix matches LONGEST prefix (glm-5.3-flash, not glm-5.3)" || bad "effort prefix: $out"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"Opus","id":"claude-opus-5-5"},"effort":{"level":"low"},"cwd":"/tmp"}')
grep -q $'\x1b\\[31m⚡low' <<< "$out" && grep -q '→high' <<< "$out" \
    && ok "effort: drift vs stored intent is red with →hint" || bad "effort drift: $out"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"Future","id":"claude-future-9"},"effort":{"level":"high"},"cwd":"/tmp"}')
grep -q '⚡high' <<< "$out" && ! grep -q '→' <<< "$out" \
    && ok "effort: model absent from map = no opinion, plain render" || bad "effort unknown: $out"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM","id":"glm-5.3-flash"},"effort":{"level":"xhigh"},"cwd":"/tmp"}')
grep -q $'\x1b\\[35m⚡xhigh' <<< "$out" && ! grep -q '→' <<< "$out" \
    && ok "effort: xhigh boost renders magenta, never flagged drift" || bad "effort xhigh: $out"

# 14-15. Cost escalation: plain base, yellow from $50 — and the base is NOT
# bold (bold base made the first colored step look like de-escalation).
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"cost":{"total_cost_usd":60},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -q $'\x1b\\[33m\$60\.00' <<< "$out" && ok "cost: yellow from \$50 (color on the dollars)" || bad "cost yellow: $out"
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'session \$60\.00' <<<"$strip" && ok "cost: session keyword labeled \$60.00" || bad "cost session keyword (yellow): $strip"
grep -q $'\x1b\\[33msession' <<< "$out" && ok "cost: yellow carries the keyword too" || bad "cost keyword color: $out"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"cost":{"total_cost_usd":3},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'session \$3\.00' <<< "$strip" && ! grep -q $'\x1b\\[1m\$3' <<< "$out" \
    && ok "cost: session keyword present, base renders plain, not bold" || bad "cost base: $strip"

# 16-17. Model gradients: GLM models get their own fades (gold strong lane,
# lime→teal flash), pinned by each fade's opening color.
render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3"},"cwd":"/tmp"}' \
    | grep -q $'\x1b\\[38;2;255;210;100mG' && ok "gradient: glm-5.3 opens gold" || bad "glm gradient: missing"
render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3-Flash"},"cwd":"/tmp"}' \
    | grep -q $'\x1b\\[38;2;215;255;130mG' && ok "gradient: glm flash opens lime" || bad "flash gradient: missing"

# 18-20. Seyag-plugin segment: reads the installed registry + the repo
# manifest (both overridable for hermeticity). Yellow ⬆ ONLY when the
# manifest is strictly newer (sort -V); plain gray when equal; the whole
# segment hides when either side is unreadable — no opinion, never a fake
# nudge.
mkdir -p "$h/.claude/plugins"
printf '{"plugins":{"harness@claude-harness":[{"installPath":"%s/.claude/plugins/cache/claude-harness/harness/0.3.18"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
smanifest="$h/syg-manifest.json"
export HARNESS_PLUGIN_MANIFEST="$smanifest" CLAUDE_PLUGIN_REGISTRY="$h/.claude/plugins/installed_plugins.json"
printf '{"version":"0.3.19"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.18⬆' <<< "$out" && ok "syg: newer manifest renders yellow ⬆" || bad "syg nudge: $out"
# 20b. Seyag end state: the registry key renames to seyag@lbds137
# (owner-named marketplace) and the segment must read it identically
# (dual-key support).
printf '{"plugins":{"seyag@lbds137":[{"installPath":"%s/.claude/plugins/cache/lbds137/seyag/0.3.21"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
printf '{"version":"0.3.22"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.21⬆' <<< "$out" && ok "syg: seyag@lbds137 registry key reads (end state)" || bad "syg seyag-key: $out"
printf '{"plugins":{"harness@claude-harness":[{"installPath":"%s/.claude/plugins/cache/claude-harness/harness/0.3.18"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
printf '{"version":"0.3.18"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.18' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: equal renders plain gray, no nudge" || bad "syg equal: $out"
rm -f "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -q 'SYG: 0\.3\.18' <<< "$out" && bad "syg hidden: segment leaked: $out" \
    || ok "syg: unreadable manifest hides the segment"
# 20c. Reload-era wiring: settings declares the lbds137 marketplace as a
# DIRECTORY source — the running plugin is the repo tip, no install record
# is written, and the stale old-identity record (0.3.19) must not trip the
# nudge. Expect plain SYG 0.3.21, no arrow.
printf '{"plugins":{"harness@claude-harness":[{"installPath":"%s/.claude/plugins/cache/claude-harness/harness/0.3.19"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
jq --arg p "$h/Projects/seyag" '.extraKnownMarketplaces.lbds137.source = {"source":"directory","path":$p}' \
    "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
printf '{"version":"0.3.21"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: directory-marketplace mode renders plain at repo version" || bad "syg dir-mode: $out"

# 21. Claude Code update nudge: a NEWER staged version in the versions dir
# (downloaded, restart-pending) escalates the WHOLE CC block to yellow with
# the arrow attached (owner feedback 10-01: a floating ⬆ between gray blocks
# read as the next block's ornament); running == newest renders the calm
# gray form, no arrow.
mkdir -p "$h/.local/share/claude/versions" && touch "$h/.local/share/claude/versions/2.1.286"
export CLAUDE_VERSIONS_DIR="$h/.local/share/claude/versions"
out=$(render '{"version":"2.1.285","context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'CC: 2\.1\.285⬆' <<< "$strip" && grep -qF $'\x1b[33mCC: 2.1.285⬆' <<< "$out" \
    && ! grep -qF $'\x1b[90m2.1.285' <<< "$out" \
    && ok "cc: newer staged version escalates the whole block, arrow attached" || bad "cc nudge: $out"
out=$(render '{"version":"2.1.286","context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'CC: 2\.1\.286' <<< "$strip" && grep -qF $'\x1b[90m2.1.286' <<< "$out" && ! grep -q '⬆' <<< "$strip" \
    && ok "cc: running newest renders the calm gray form, no arrow" || bad "cc current: $out"

# 22. Context desync guard: a zeroed mid-turn snapshot renders the cached
# last-known-good instead of blipping to 0%; a fresh session (no cache)
# honestly renders 0. (route_zai: an earlier case re-routes the fixture to
# Anthropic and the vendor block must be live for the order case below.)
route_zai
out=$(render '{"context_window":{},"session_id":"s-blip","model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q '0% (0)' <<< "$strip" && ok "ctx: fresh session renders honest 0" || bad "ctx fresh: $strip"
mkdir -p "$h/cache/claude-statusline"
printf '42\n84000\n' > "$h/cache/claude-statusline/ctx-s-blip"
out=$(render '{"context_window":{},"session_id":"s-blip","model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q '42% (84k)' <<< "$strip" && ok "ctx: desync zero renders cached last-known-good" || bad "ctx cache: $strip"

# 23. Block order (volatility gradient): identity+economy -> work-state ->
# static tail. vendor before cost before SYG, in the stripped line.
route_zai
out=$(render '{"version":"2.1.286","context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
i_zai=${strip%%z.ai*}; i_cost=${strip%%\$0.00*}; i_sym=${strip%%SYG:*}
[ "$i_zai" != "$strip" ] && [ "$i_cost" != "$strip" ] && [ "$i_sym" != "$strip" ] \
    && [ ${#i_zai} -lt ${#i_cost} ] && [ ${#i_cost} -lt ${#i_sym} ] \
    && ok "order: vendor -> cost -> work-state -> SYG tail" || bad "order: $strip"

# 24. OpenRouter, cold cache: the OR segment degrades to the plain gray host
# label — no dollars, no brand color, no z.ai branding, no quota. First-ever
# render is cold; the background fetch populates it for later renders.
route_or
rm -f "$h/cache/claude-statusline/or-credits.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3-Flash"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ! grep -q 'z\.ai' <<< "$out" && ! grep -q '5h:' <<< "$out" \
    && ok "openrouter cold: plain gray host label, no dollars, no quota" || bad "openrouter cold: $out"

# 25. OpenRouter, warm cache: brand-yellow label + remaining dollars from the
# pinned response shape (730 - 714.767219655 = 15.23), plain gray dollars,
# no pct inside the segment, no traffic light.
printf '{"data":{"total_credits":730,"total_usage":714.767219655}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json" # fresh mtime: the background curl stays asleep
out=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"GLM-5.3-Flash"},"cwd":"/tmp"}')
# OR segment = the stripped line from the label up to the next separator.
or_seg=$(strip <<< "$out" | sed 's/.*openrouter\.ai/openrouter.ai/; s/ · .*//')
grep -qF $'\x1b[38;2;252;187;60mopenrouter.ai' <<< "$out" && grep -qF $'\x1b[90m$15.23' <<< "$out" \
    && ! grep -q '%' <<< "$or_seg" \
    && ok "openrouter warm: brand-yellow label, \$15.23 from the pinned shape, no pct in segment" || bad "openrouter warm: $out"

# 26. OpenRouter, malformed cache: degrade to the plain gray host label.
printf 'not-json' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ok "openrouter malformed: degrade to the plain gray label" || bad "openrouter malformed: $out"

# 27. OpenRouter, zero remaining: degrade too — never fake a \$0.00 balance.
printf '{"data":{"total_credits":10,"total_usage":10}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ok "openrouter zero: degrade, no fake balance" || bad "openrouter zero: $out"

# 28. OpenRouter, negative remaining: same degrade (jq filter drops it).
printf '{"data":{"total_credits":10,"total_usage":12}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ok "openrouter negative: degrade, no fake balance" || bad "openrouter negative: $out"

# 29. OpenRouter, sub-cent remaining: 0.004 formats to \$0.00 — same degrade,
# the formatted-zero guard.
printf '{"data":{"total_credits":0.004,"total_usage":0}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ok "openrouter sub-cent: degrade, no fake \$0.00" || bad "openrouter sub-cent: $out"

# 30. OpenRouter, token removed: an empty ANTHROPIC_AUTH_TOKEN with a warm
# cache must degrade the same as cold — a stale balance rendered without a
# token is a lie about the lane's currency. (Keep the OR base_url: only the
# token is emptied.)
printf '{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api/v1"}}' > "$h/.claude/settings.json"
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF $'\x1b[90mopenrouter.ai' <<< "$raw" && ! grep -Eq 'openrouter\.ai \$' <<< "$out" \
    && ok "openrouter no-token: warm cache degrades to gray, stale balance hidden" || bad "openrouter no-token: $out"
printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"dummy-probe-token"},"modelSettings":{"glm-5.3":{"effortLevel":"high"},"glm-5.3-flash":{"effortLevel":"max"},"claude-opus-5-5":{"effortLevel":"high"}}}' > "$h/.claude/settings.json"

# 31. Vendor breadth (host end-anchoring): lookalike hosts must land in the
# unknown branch — no borrowed z.ai/Anthropic quota segment. rate_limits is
# in the input so a wrongly-borrowed Anthropic branch WOULD render 5h:.
route_host "https://evil-z.ai.example.com"
out=$(strip <<< "$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')")
grep -q 'evil-z\.ai\.example\.com' <<< "$out" && ! grep -q 'z\.ai ' <<< "$out" && ! grep -q '5h:' <<< "$out" \
    && ok "breadth: evil-z.ai.example.com renders the honest host label" || bad "breadth evil-z: $out"
route_host "https://api.anthropic.com.evil.com"
out=$(strip <<< "$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')")
grep -q 'anthropic\.com\.evil\.com' <<< "$out" && ! grep -q '5h:' <<< "$out" \
    && ok "breadth: api.anthropic.com.evil.com renders the honest host label" || bad "breadth evil-anthropic: $out"

# 32. Empty base_url: absent override falls through to the Anthropic rl
# branch — the '' host arm must not land in the unknown branch.
route_anthropic
jq 'del(.env.ANTHROPIC_BASE_URL)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
out=$(strip <<< "$(render '{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')")
grep -q '5h:' <<< "$out" \
    && ok "breadth: empty base_url falls through to the Anthropic windows" || bad "breadth empty-base: $out"
route_anthropic

# 33. Host normalization: :port and userinfo@ are stripped and the host is
# lowercased before the vendor match; a credential never reaches the label.
rl_in='{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}'
route_host "https://api.anthropic.com:443"
out=$(strip <<< "$(render "$rl_in")")
grep -q '5h:' <<< "$out" && ! grep -q 'anthropic\.com:443' <<< "$out" \
    && ok "host: api.anthropic.com:443 routes to the Anthropic lane, plan segment present" || bad "host port: $out"
route_host "HTTPS://API.Z.AI"
out=$(strip <<< "$(render "$rl_in")")
grep -q 'z\.ai 5h:' <<< "$out" && ! grep -q 'API\.Z\.AI' <<< "$out" \
    && ok "host: HTTPS://API.Z.AI routes to the z.ai lane" || bad "host case: $out"
route_host "https://user:tok@unknown.host"
raw=$(render "$rl_in")
grep -qF $'\x1b[90munknown.host' <<< "$raw" && ! grep -q 'tok' <<< "$raw" && ! grep -q '5h:' <<< "$(strip <<< "$raw")" \
    && ok "host: userinfo stripped, label unknown.host, credential absent" || bad "host userinfo: $(strip <<< "$raw")"
route_anthropic

# 34. cwd tilde: only $HOME itself or a path under $HOME/ shortens; a sibling
# sharing the prefix ($HOME + "2") renders as is.
out=$(strip <<< "$(render "{\"context_window\":{\"current_usage\":{\"input_tokens\":1000}},\"model\":{\"display_name\":\"X\"},\"cwd\":\"${h}2/x\"}")")
grep -qF "${h}2/x/" <<< "$out" && ! grep -q '~' <<< "$out" \
    && ok "cwd: \$HOME-prefixed sibling (\$HOME + 2) keeps its full path, no ~" || bad "cwd sibling: $out"
out=$(strip <<< "$(render "{\"context_window\":{\"current_usage\":{\"input_tokens\":1000}},\"model\":{\"display_name\":\"X\"},\"cwd\":\"$h/x\"}")")
grep -qF '~/x/' <<< "$out" && ok "cwd: a path under \$HOME/ shortens to ~/x/" || bad "cwd under home: $out"

# 29. Two-yellow join: CC nudge and SYG nudge both pending — both blocks
# render yellow ⬆ in one line, joined by the single-space separator.
route_anthropic
touch "$h/.local/share/claude/versions/2.1.287"
jq 'del(.extraKnownMarketplaces)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
out=$(render '{"version":"2.1.286","context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mCC: 2.1.286⬆\x1b[0m \x1b[33mSYG: 0.3.19⬆' <<< "$out" \
    && ok "join: CC and SYG nudges render yellow ⬆ in one line" || bad "join: $out"

exit $fail
