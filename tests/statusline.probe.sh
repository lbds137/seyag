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
# The API-credit segments read these from the process env; a caller's values must not leak in.
unset SYG_CREDIT_LEDGER SYG_CREDIT_GRANTS SYG_CREDIT_WHEN SYG_CREDIT_FORCE SYG_CREDIT_NOW SYG_CREDIT_ROUTE

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
render() {
  local env_args=(-u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u SYG_CREDIT_LEDGER -u SYG_CREDIT_GRANTS -u SYG_CREDIT_FORCE)
  if [ -n "${PROBE_AUTH_TOKEN:-}" ]; then
    env_args+=("ANTHROPIC_AUTH_TOKEN=$PROBE_AUTH_TOKEN")
  fi
  printf '%s' "$1" | env "${env_args[@]}" bash "$SL"
}
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
printf '{"plugins":{"seyag@example-market":[{"installPath":"%s/.claude/plugins/cache/example-market/seyag/0.3.18"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
smanifest="$h/syg-manifest.json"
export SYG_PLUGIN_MANIFEST="$smanifest" CLAUDE_PLUGIN_REGISTRY="$h/.claude/plugins/installed_plugins.json"
printf '{"version":"0.3.19"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.18⬆' <<< "$out" && ok "syg: newer manifest renders yellow ⬆" || bad "syg nudge: $out"
# 20b. The marketplace name is the installer's choice: any registry key
# starting with seyag@ reads identically.
printf '{"plugins":{"seyag@other-market":[{"installPath":"%s/.claude/plugins/cache/other-market/seyag/0.3.21"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
printf '{"version":"0.3.22"}' > "$smanifest"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.21⬆' <<< "$out" && ok "syg: any seyag@<marketplace> registry key reads" || bad "syg seyag-key: $out"
# 20b2. A record under a key that is not seyag@... is not this plugin's
# identity: the segment hides.
printf '{"plugins":{"harness@old-market":[{"installPath":"%s/.claude/plugins/cache/old-market/harness/0.3.18"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -q 'SYG:' <<< "$out" && bad "syg foreign key: segment leaked: $out" \
    || ok "syg: a registry holding only a non-seyag key hides the segment"
printf '{"plugins":{"seyag@example-market":[{"installPath":"%s/.claude/plugins/cache/example-market/seyag/0.3.18"}]}}' "$h" \
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
# 20c. Directory-marketplace wiring: settings declares a marketplace named
# example-market as a DIRECTORY source whose path contains the manifest.
# The running plugin is then the repo tip, no install record is written,
# and a stale record (0.3.19) must not trip the nudge. Expect plain SYG
# 0.3.21, no arrow. The manifest sits under the marketplace path.
syg_set_dirmarket() {  # $1 = marketplace path
    jq --arg p "$1" '.extraKnownMarketplaces = {"example-market":{"source":{"source":"directory","path":$p}}}' \
        "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
}
printf '{"plugins":{"seyag@example-market":[{"installPath":"%s/.claude/plugins/cache/example-market/seyag/0.3.19"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"
mkdir -p "$h/Projects/plug/plugins/seyag/.claude-plugin"
smanifest="$h/Projects/plug/plugins/seyag/.claude-plugin/plugin.json"
export SYG_PLUGIN_MANIFEST="$smanifest"
printf '{"version":"0.3.21"}' > "$smanifest"
syg_set_dirmarket "$h/Projects/plug"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: directory-marketplace mode renders plain at repo version" || bad "syg dir-mode: $out"
# A trailing slash on the marketplace path compares the same.
syg_set_dirmarket "$h/Projects/plug/"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: directory-marketplace path with a trailing slash still matches" || bad "syg dir-mode slash: $out"
# A string-valued source entry beside a matching directory entry must not
# abort the scan (a github-style marketplace is a plain string here).
jq --arg p "$h/Projects/plug" '.extraKnownMarketplaces = {"y":{"source":"github"},"x":{"source":{"source":"directory","path":$p}}}' \
    "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: a string-valued source entry does not break directory mode" || bad "syg dir-mode string source: $out"
# A symlinked marketplace path resolves to the plug dir.
ln -sfn "$h/Projects/plug" "$h/Projects/plug-link"
syg_set_dirmarket "$h/Projects/plug-link"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: a symlinked marketplace path matches" || bad "syg dir-mode symlink: $out"
# A path with a .. segment that resolves to the plug dir.
mkdir -p "$h/Projects/elsewhere"
syg_set_dirmarket "$h/Projects/elsewhere/../plug"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
grep -q 'SYG: 0\.3\.21' <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: a marketplace path with a .. segment matches" || bad "syg dir-mode dotdot: $out"
# 20d. A string prefix without a / boundary (.../pl vs .../plug) is not a
# path prefix: the nudge stays.
syg_set_dirmarket "$h/Projects/pl"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.19⬆' <<< "$out" \
    && ok "syg: string-prefix directory marketplace (no / boundary) keeps the nudge" || bad "syg dir-mode boundary: $out"
# 20d2. An unrelated directory marketplace (a sibling dir) keeps the nudge.
syg_set_dirmarket "$h/Projects/elsewhere"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mSYG: 0.3.19⬆' <<< "$out" \
    && ok "syg: unrelated directory marketplace keeps the nudge" || bad "syg dir-mode unrelated: $out"
# 20e. No override: the manifest resolves next to the script, so the
# segment renders the repo's real version. The installed record equals it,
# so no arrow; the fixture settings carry no directory marketplace.
unset SYG_PLUGIN_MANIFEST
jq 'del(.extraKnownMarketplaces)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" \
    && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
repo_version=$(jq -r '.version' "$REPO/plugins/seyag/.claude-plugin/plugin.json")
printf '{"plugins":{"seyag@example-market":[{"installPath":"%s/.claude/plugins/cache/example-market/seyag/%s"}]}}' "$h" "$repo_version" \
    > "$h/.claude/plugins/installed_plugins.json"
out=$(render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
strip=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
[ -n "$repo_version" ] && grep -qF "SYG: $repo_version" <<< "$strip" && ! grep -q '⬆' <<< "$strip" \
    && ok "syg: no override resolves the manifest next to the script" || bad "syg script-relative: $out"
# Restore the override, the directory marketplace and the 0.3.19 record
# for the later cases (21-29), which expect the state 20c left behind.
export SYG_PLUGIN_MANIFEST="$smanifest"
syg_set_dirmarket "$h/Projects/plug"
printf '{"plugins":{"seyag@example-market":[{"installPath":"%s/.claude/plugins/cache/example-market/seyag/0.3.19"}]}}' "$h" \
    > "$h/.claude/plugins/installed_plugins.json"

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
# token is emptied; own $15 cache: a sub-cent cache degrades with or without a
# token, which made this case vacuous.)
printf '{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api/v1"}}' > "$h/.claude/settings.json"
printf '{"data":{"total_credits":20,"total_usage":5}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
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
# shellcheck disable=SC2088 # the tilde is literal text in the output under test
grep -qF '~/x/' <<< "$out" && ok "cwd: a path under \$HOME/ shortens to ~/x/" || bad "cwd under home: $out"

# 29. Two-yellow join: CC nudge and SYG nudge both pending — both blocks
# render yellow ⬆ in one line, joined by the single-space separator.
route_anthropic
touch "$h/.local/share/claude/versions/2.1.287"
jq 'del(.extraKnownMarketplaces)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
out=$(render '{"version":"2.1.286","context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
grep -qF $'\x1b[33mCC: 2.1.286⬆\x1b[0m \x1b[33mSYG: 0.3.19⬆' <<< "$out" \
    && ok "join: CC and SYG nudges render yellow ⬆ in one line" || bad "join: $out"

# 30. Read-only git: the statusline never takes index.lock. A fake git first
# on PATH records GIT_OPTIONAL_LOCKS per call; at least one call must be
# recorded and every value must be 0.
mkdir -p "$h/fakebin" "$h/lockcwd"
cat > "$h/fakebin/git" <<'EOF'
#!/bin/bash
echo "${GIT_OPTIONAL_LOCKS-unset}" >> "$GIT_LOCKS_LOG"
exit 0
EOF
chmod +x "$h/fakebin/git"
: > "$h/git-locks.log"
env -u GIT_OPTIONAL_LOCKS GIT_LOCKS_LOG="$h/git-locks.log" PATH="$h/fakebin:$PATH" \
    bash "$SL" <<< "{\"context_window\":{\"current_usage\":{\"input_tokens\":1000}},\"model\":{\"display_name\":\"X\"},\"cwd\":\"$h/lockcwd\"}" >/dev/null 2>&1
git_calls=$(wc -l < "$h/git-locks.log"); git_nonzero=$(grep -vxc '0' "$h/git-locks.log")
[ "$git_calls" -ge 1 ] && [ "$git_nonzero" = 0 ] \
    && ok "git: statusline exports GIT_OPTIONAL_LOCKS=0 ($git_calls git calls recorded)" \
    || bad "git locks: calls=$git_calls non-zero=$git_nonzero: $(tr '\n' ' ' < "$h/git-locks.log")"

# 35-39. API-credit segment (opt-in via SYG_CREDIT_LEDGER; the metered route is read
# from the process env). Fixtures: an invented grants file and a per-case ledger,
# seeded with one entry (the statusline only reads; the hook records).
mkdir -p "$h/credit"
cat > "$h/credit/grants.json" <<'EOF'
{"currency":"USD","grants":[{"amount":200,"granted":"2026-10-01","expires":"2026-10-21"}]}
EOF
cr_render() { # ledger-name now [grants-path]; stdin: the cost of the one ledger entry, dated now
    local cost; cost=$(cat)
    printf '{"session_id":"cr-%s","day":"%s","first_ts":"%s","last_ts":"%s","cost_usd":%s,"source":"transcript"}\n' \
        "$1" "${2:0:10}" "$2" "$2" "$cost" > "$h/credit/$1.jsonl"
    env -u ANTHROPIC_BASE_URL -u SYG_CREDIT_FORCE -u SYG_CREDIT_GRANTS ANTHROPIC_API_KEY=sk-probe \
        SYG_CREDIT_LEDGER="$h/credit/$1.jsonl" SYG_CREDIT_NOW="$2" ${3:+SYG_CREDIT_GRANTS="$3"} \
        bash "$SL" <<< "{\"session_id\":\"cr-$1\",\"cost\":{\"total_cost_usd\":$cost},\"rate_limits\":{\"five_hour\":{\"used_percentage\":83,\"resets_at\":1790790548}},\"context_window\":{\"current_usage\":{\"input_tokens\":1000}},\"model\":{\"id\":\"m\",\"display_name\":\"X\"},\"cwd\":\"/tmp\"}"
}
anth_label=$'\x1b[38;2;240;238;230mplatform.claude.com\x1b[0m'
plan_label=$'\x1b[38;2;240;238;230mclaude.ai\x1b[0m'
# 35. Ledger var unset on the API-key lane: the label alone, no credit text, no ledger, no meters.
raw=$(env -u SYG_CREDIT_LEDGER -u ANTHROPIC_BASE_URL -u SYG_CREDIT_FORCE ANTHROPIC_API_KEY=sk-probe SYG_CREDIT_GRANTS="$h/credit/grants.json" \
    bash "$SL" <<< '{"session_id":"cr-off","cost":{"total_cost_usd":1},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -qF "$anth_label" <<< "$raw" && ! grep -qE 'platform.claude.com ~|spent|over' <<< "$out" \
    && [ -z "$(find "$h/credit" -type f ! -name grants.json)" ] \
    && ok "api-key lane: SYG_CREDIT_LEDGER unset -> 'platform.claude.com' label alone, no ledger" || bad "api-key lane off: $out"
# 36. Metered with grants: remaining after the session's spend, expiry date and days; no plan meters.
raw=$(cr_render ok 2026-10-08T00:00:00Z "$h/credit/grants.json" <<< 1.00)
out=$(strip <<< "$raw")
grep -qF 'platform.claude.com ~$199.00 (exp 10-21, 13d)' <<< "$out" && grep -qF "$anth_label"$' \x1b[32m~$199.00' <<< "$raw" \
    && ! grep -qE '5h:|wk:| est' <<< "$out" \
    && ok "api-key lane: grants -> ivory label, green '~\$199.00 (exp 10-21, 13d)', no meters, no fleet segment" || bad "api-key credit: $out"
# 37. Two days or fewer: the Nd part turns red.
raw=$(cr_render soon 2026-10-19T12:00:00Z "$h/credit/grants.json" <<< 1.00)
grep -qF $'\x1b[31m1d\x1b[0m' <<< "$raw" && grep -qF '(exp 10-21, 1d)' <<< "$(strip <<< "$raw")" \
    && ok "api-key lane: <=2 days left -> '1d' in red" || bad "api-key red days: $(strip <<< "$raw")"
# 38. No grants file: spend only.
raw=$(cr_render nogrants 2026-10-08T00:00:00Z <<< 12.30)
grep -qF 'platform.claude.com ~$12.30 spent' <<< "$(strip <<< "$raw")" && grep -qF $'\x1b[90m~$12.30 spent' <<< "$raw" \
    && ok "api-key lane: no grants -> gray 'platform.claude.com ~\$12.30 spent'" || bad "api-key spent-only: $(strip <<< "$raw")"
# 39. Overage: magenta.
cat > "$h/credit/small.json" <<'EOF'
{"grants":[{"amount":5,"granted":"2026-10-01"}]}
EOF
raw=$(cr_render over 2026-10-08T00:00:00Z "$h/credit/small.json" <<< 8.00)
grep -qF $'\x1b[35mover ~$3.00' <<< "$raw" && grep -qF 'platform.claude.com over ~$3.00' <<< "$(strip <<< "$raw")" \
    && ok "api-key lane: spend beyond grants -> magenta 'over ~\$3.00'" || bad "api-key overage: $(strip <<< "$raw")"
# 39b. A grant with no expiry: credit shown, no "(exp" text.
echo '{"grants":[{"amount":50,"granted":"2026-10-01"}]}' > "$h/credit/noexp.json"
raw=$(cr_render noexp 2026-10-08T00:00:00Z "$h/credit/noexp.json" <<< 2.00)
out=$(strip <<< "$raw")
grep -qF 'platform.claude.com ~$48.00' <<< "$out" && ! grep -qF '(exp' <<< "$out" \
    && ok "api-key lane: grant without expiry -> '~\$48.00', no (exp text" || bad "api-key no-expiry: $out"
# 39c. Mixed: the expiring grant is fully spent, the non-expiring one has credit -> no "(exp".
echo '{"grants":[{"amount":10,"granted":"2026-10-01","expires":"2026-10-21"},{"amount":50,"granted":"2026-10-01"}]}' > "$h/credit/mixed.json"
raw=$(cr_render mixed 2026-10-08T00:00:00Z "$h/credit/mixed.json" <<< 12.00)
out=$(strip <<< "$raw")
grep -qF 'platform.claude.com ~$48.00' <<< "$out" && ! grep -qF '(exp' <<< "$out" \
    && ok "api-key lane: exhausted expiring grant + non-expiring remainder -> no (exp text" || bad "api-key mixed: $out"

# 40-44. Lane routing, each with rate_limits in the input. The process env decides.
lane_in='{"rate_limits":{"five_hour":{"used_percentage":83,"resets_at":1790790548},"seven_day":{"used_percentage":56,"resets_at":1791093600}},"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}'
lane() { # VAR=value ...: render lane_in under exactly these env vars
    env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u SYG_CREDIT_LEDGER -u SYG_CREDIT_GRANTS -u SYG_CREDIT_FORCE "$@" bash "$SL" <<< "$lane_in"
}
route_anthropic
jq 'del(.env.ANTHROPIC_BASE_URL)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
raw=$(lane ANTHROPIC_API_KEY=sk-probe); out=$(strip <<< "$raw")
grep -qF "$anth_label" <<< "$raw" && ! grep -qE '5h:|wk:' <<< "$out" \
    && ok "lane: API key, no base URL -> ivory 'platform.claude.com', no plan meters" || bad "lane api-key: $out"
raw=$(lane); out=$(strip <<< "$raw")
grep -qF "$plan_label 5h:" <<< "$raw" && grep -qF 'claude.ai 5h:' <<< "$out" && ! grep -q 'platform.claude.com' <<< "$out" \
    && ok "lane: no API key -> ivory 'claude.ai' label then plan meters" || bad "lane plan: $out"
lane_in_save=$lane_in
lane_in='{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}'
raw=$(lane); out=$(strip <<< "$raw")
lane_in=$lane_in_save
grep -qF "$plan_label" <<< "$raw" && ! grep -qE '5h:|wk:|platform.claude.com' <<< "$out" \
    && ok "lane: plan lane without rate_limits -> the 'claude.ai' label alone" || bad "lane plan no-limits: $out"
raw=$(lane ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 ANTHROPIC_API_KEY=); out=$(strip <<< "$raw")
grep -q 'openrouter.ai' <<< "$out" && ! grep -qE 'platform.claude.com|claude.ai|5h:|wk:' <<< "$out" \
    && ok "lane: env OpenRouter URL + empty API key -> openrouter label, no Anthropic labels, no meters" || bad "lane or: $out"
route_zai
raw=$(lane ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 ANTHROPIC_API_KEY=); out=$(strip <<< "$raw")
grep -q 'openrouter.ai' <<< "$out" && ! grep -q 'z.ai' <<< "$out" \
    && ok "lane: process-env base URL (openrouter) wins over settings.json (z.ai)" || bad "lane env-over-settings: $out"
raw=$(lane ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_API_KEY=sk-probe); out=$(strip <<< "$raw")
grep -q 'z.ai' <<< "$out" && ! grep -qE 'platform.claude.com|claude.ai' <<< "$out" \
    && ok "lane: API key set but env base URL is z.ai -> z.ai lane, no Anthropic label" || bad "lane key+zai: $out"

# 45. z.ai lane with zai-spend silent (no quota, empty --line): the label alone.
mv "$h/.local/bin/zai-spend" "$h/.local/bin/zai-spend.keep"
printf '#!/bin/bash\nexit 0\n' > "$h/.local/bin/zai-spend"; chmod +x "$h/.local/bin/zai-spend"
route_zai
raw=$(render "$lane_in"); out=$(strip <<< "$raw")
grep -qF $'\x1b[38;2;11;127;255mz.ai\x1b[0m' <<< "$raw" && ! grep -qE '5h:|claude' <<< "$out" \
    && ok "z.ai lane: zai-spend silent -> the z.ai label alone" || bad "zai silent: $out"
mv "$h/.local/bin/zai-spend.keep" "$h/.local/bin/zai-spend"
route_anthropic

# 46. SYG_CREDIT_WHEN decides the API-key lane when set: match -> platform.claude.com
# (no key needed); mismatch -> the plan lane even with a non-empty key.
jq 'del(.env.ANTHROPIC_BASE_URL)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
raw=$(lane SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=metered); out=$(strip <<< "$raw")
grep -qF "$anth_label" <<< "$raw" && ! grep -qE '5h:|wk:|claude\.ai 5h' <<< "$out" \
    && ok "lane: SYG_CREDIT_WHEN matches -> 'platform.claude.com', no plan meters" || bad "lane WHEN match: $out"
raw=$(lane SYG_CREDIT_WHEN=MY_ROUTE=metered MY_ROUTE=other ANTHROPIC_API_KEY=sk-probe); out=$(strip <<< "$raw")
grep -qF "$plan_label 5h:" <<< "$raw" && ! grep -q 'platform.claude.com' <<< "$out" \
    && ok "lane: SYG_CREDIT_WHEN mismatch with a non-empty key -> plan lane 'claude.ai'" || bad "lane WHEN mismatch: $out"

# 47. Fleet credit segment on non-API-key lanes: needs both vars and a live grant.
printf '{"session_id":"f1","day":"2026-10-07","first_ts":"2026-10-07T10:00:00Z","last_ts":"2026-10-07T10:00:00Z","cost_usd":12.5,"source":"transcript"}\n' > "$h/credit/fleet.jsonl"
echo '{"grants":[{"amount":200,"granted":"2026-10-01","expires":"2026-10-05"}]}' > "$h/credit/expired.json"
echo '{"grants":[{"amount":12.5,"granted":"2026-10-01","expires":"2026-10-21"}]}' > "$h/credit/spent.json"
fleet() { # grants-path-or-empty: render the plan-lane input with the fleet vars
    lane SYG_CREDIT_LEDGER="$h/credit/fleet.jsonl" ${1:+SYG_CREDIT_GRANTS="$1"} SYG_CREDIT_NOW=2026-10-08T00:00:00Z
}
raw=$(fleet "$h/credit/grants.json"); out=$(strip <<< "$raw")
grep -qE 'claude\.ai 5h:.* · platform\.claude\.com \$187\.50 est · session ' <<< "$out" \
    && grep -qF "$anth_label"$' \x1b[90m$187.50 est\x1b[0m' <<< "$raw" \
    && ok "fleet: plan lane + ledger + grants -> gray 'platform.claude.com \$187.50 est' after claude.ai, before session" || bad "fleet plan: $out"
raw=$(fleet "$h/credit/expired.json"); out=$(strip <<< "$raw")
! grep -qE 'platform\.claude\.com| est' <<< "$out" && grep -q 'claude.ai 5h:' <<< "$out" \
    && ok "fleet: expired-only grants -> no segment" || bad "fleet expired: $out"
raw=$(fleet ""); out=$(strip <<< "$raw")
! grep -qE 'platform\.claude\.com| est' <<< "$out" && grep -q 'claude.ai 5h:' <<< "$out" \
    && ok "fleet: SYG_CREDIT_GRANTS unset -> no segment" || bad "fleet no grants: $out"
raw=$(fleet "$h/credit/spent.json"); out=$(strip <<< "$raw")
grep -qF 'platform.claude.com $0.00 est' <<< "$out" && grep -qF $'\x1b[31m$0.00 est' <<< "$raw" \
    && ok "fleet: live grant fully spent -> red '\$0.00 est'" || bad "fleet zero: $out"
route_zai
raw=$(fleet "$h/credit/grants.json"); out=$(strip <<< "$raw")
grep -qE 'z\.ai .* · platform\.claude\.com \$187\.50 est · session ' <<< "$out" \
    && ok "fleet: z.ai lane + both vars -> segment after the z.ai segment" || bad "fleet zai: $out"
route_anthropic

# 48. Balance cache: a matching key under 60s is reused (a sentinel planted in the
# cache shows); a ledger mtime change or a cache older than 60s is a miss.
jq 'del(.env.ANTHROPIC_BASE_URL)' "$h/.claude/settings.json" > "$h/.claude/settings.json.new" && mv "$h/.claude/settings.json.new" "$h/.claude/settings.json"
cr_cache="$h/cache/claude-statusline/api-credit-balance.json"
plant() { { head -n 1 "$cr_cache"; echo '{"live_grants":1,"remaining_usd":123.45}'; } > "$cr_cache.new" && mv "$cr_cache.new" "$cr_cache"; }
rm -f "$cr_cache"
out1=$(strip <<< "$(fleet "$h/credit/grants.json")")
lines=$(wc -l < "$cr_cache" 2>/dev/null | tr -d ' ')
plant
out2=$(strip <<< "$(fleet "$h/credit/grants.json")")
touch -d '+2 seconds' "$h/credit/fleet.jsonl"
out3=$(strip <<< "$(fleet "$h/credit/grants.json")")
grep -qF 'platform.claude.com $187.50 est' <<< "$out1" && [ "$lines" = 2 ] \
    && grep -qF 'platform.claude.com $123.45 est' <<< "$out2" && grep -qF 'platform.claude.com $187.50 est' <<< "$out3" \
    && ok "balance cache: written on a miss, reused on a key match, missed after the ledger mtime changes" \
    || bad "balance cache: '$out1' / lines=$lines / '$out2' / '$out3'"
plant
touch -d '-120 seconds' "$cr_cache"
out4=$(strip <<< "$(fleet "$h/credit/grants.json")")
grep -qF 'platform.claude.com $187.50 est' <<< "$out4" \
    && ok "balance cache: older than 60s -> recomputed despite a matching key" || bad "balance cache TTL: '$out4'"

# 49. Precedence: settings.json says z.ai, the process env says OpenRouter, no
# rate_limits in the input. Both set and conflicting: the env must win.
route_zai
lane_in_save=$lane_in
lane_in='{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}'
raw=$(OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" lane ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1); out=$(strip <<< "$raw")
lane_in=$lane_in_save
grep -q 'openrouter\.ai' <<< "$out" && ! grep -q 'z\.ai' <<< "$out" && ! grep -q '5h:' <<< "$out" \
    && ok "precedence: env OpenRouter URL beats settings.json z.ai with both set, no rate_limits" || bad "precedence: $out"

# 50. Env token: the OpenRouter balance renders from a process-env
# ANTHROPIC_AUTH_TOKEN when settings.json carries none (a --settings overlay
# session). Warm cache, so no network.
printf '{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api/v1"}}' > "$h/.claude/settings.json"
printf '{"data":{"total_credits":20,"total_usage":5}}' > "$h/cache/claude-statusline/or-credits.json"
touch "$h/cache/claude-statusline/or-credits.json"
raw=$(PROBE_AUTH_TOKEN=dummy-probe-token OPENROUTER_CREDITS_URL="file://$h/missing-credits.json" render '{"context_window":{"current_usage":{"input_tokens":1000}},"model":{"display_name":"X"},"cwd":"/tmp"}')
out=$(strip <<< "$raw")
grep -Eq 'openrouter\.ai \$15\.00' <<< "$out" \
    && ok "env token: OpenRouter balance renders from the process-env token" || bad "env token: $out"
printf '{"env":{"ANTHROPIC_AUTH_TOKEN":"dummy-probe-token"},"modelSettings":{"glm-5.3":{"effortLevel":"high"},"glm-5.3-flash":{"effortLevel":"max"},"claude-opus-5-5":{"effortLevel":"high"}}}' > "$h/.claude/settings.json"

exit $fail
