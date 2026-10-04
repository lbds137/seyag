#!/bin/bash
# Fixture check for session-start.sh. Uses a temp CLAUDE_PLUGIN_ROOT and a temp
# user rules dir (SYG_USER_RULES_DIR), so it never depends on the real ones.
#
# Usage: hooks/session-start.probe.sh   (from anywhere)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/session-start.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic: the fixtures below set the SYG_ knobs explicitly, so an ambient
# SYG_ variable must not override them.
unset SYG_STATE_DIR SYG_STATE_MAX_DAYS SYG_USER_RULES_DIR SYG_INSTALLED_PLUGINS

mkdir -p "$TMP/root/rules" "$TMP/rules-linked" "$TMP/rules-empty"
printf '# Core\nfixture\n' > "$TMP/root/rules/core.md"
cp "$TMP/root/rules/core.md" "$TMP/rules-linked/seyag-core.md"  # same content, different path (cache copy case)
printf 'unrelated\n' > "$TMP/rules-empty/other.md"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

run() { # $1 source, $2 user rules dir → sets OUT, RC
  OUT=$(jq -nc --arg s "$1" '{session_id: "probe", source: $s}' \
    | CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$2" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
  RC=$?
}
ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT" 2>/dev/null; }
valid() {
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | type == "string")' \
    <<<"$OUT" >/dev/null 2>&1
}

for src in startup clear; do
  run "$src" "$TMP/rules-linked"
  # No plugin.json under $TMP/root, so the version falls back to "unknown"; with
  # rules linked, that version line is the only output.
  [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ] && ok "$src with rules linked: version line only" || bad "$src linked: expected version-only output" "$OUT"
  run "$src" "$TMP/rules-empty"
  if [ "$RC" = 0 ] && valid && [ "$(ctx | head -1)" = "seyag plugin unknown" ] && ctx | grep -q 'core rules are not loaded'; then
    ok "$src without the link: version line then warning"
  else
    bad "$src without link: expected version line + warning JSON" "$OUT"
  fi
done

# Real repo plugin.json: the version line reads $PLUGIN_ROOT/.claude-plugin/plugin.json.
REAL_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REAL_VERSION=$(jq -r '.version' "$REAL_ROOT/.claude-plugin/plugin.json")
OUT=$(jq -nc '{session_id: "probe", source: "startup"}' \
  | CLAUDE_PLUGIN_ROOT="$REAL_ROOT" SYG_USER_RULES_DIR="$TMP/rules-empty" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && valid && [ "$(ctx | head -1)" = "seyag plugin $REAL_VERSION" ]; then
  ok "startup with the real PLUGIN_ROOT: version line matches the repo's plugin.json ($REAL_VERSION)"
else
  bad "startup with real PLUGIN_ROOT: expected version line $REAL_VERSION" "$OUT"
fi

run compact "$TMP/rules-linked"
if [ "$RC" = 0 ] && valid && ctx | grep -q 'POST-COMPACTION RECOVERY' && ! ctx | grep -q '# Core'; then
  ok "compact: checklist only, core.md not injected"
else
  bad "compact: expected checklist without core.md" "$OUT"
fi

run resume "$TMP/rules-empty"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "resume: no output" || bad "resume: expected empty output" "$OUT"

run "" "$TMP/rules-empty"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "missing source: no output" || bad "missing source: expected empty" "$OUT"

# Output must stay far below Claude Code's ~10 KB hook-output preview cliff.
run compact "$TMP/rules-linked"
[ "${#OUT}" -lt 4000 ] && ok "compact output is ${#OUT} bytes (< 4000)" || bad "compact output too large: ${#OUT} bytes"

# State-file age-out: old prompt-hook state goes; fresh state, other files and symlinks stay.
S="$TMP/state"; mkdir -m 700 "$S"
for n in queued-receipt-state-old context-reminder-old queued-receipt-state-new cache-break-state-old.json; do echo x > "$S/$n"; done
touch -d '10 days ago' "$S/queued-receipt-state-old" "$S/context-reminder-old" "$S/cache-break-state-old.json"
echo keep > "$TMP/target"; ln -s "$TMP/target" "$S/context-reminder-link"; touch -h -d '10 days ago' "$S/context-reminder-link"
run resume "$TMP/rules-linked"
[ ! -e "$S/queued-receipt-state-old" ] && [ ! -e "$S/context-reminder-old" ] && ok "ages out old state files" || bad "old state files survived"
[ -e "$S/queued-receipt-state-new" ] && ok "keeps a fresh state file" || bad "fresh state file deleted"
[ -e "$S/cache-break-state-old.json" ] && ok "leaves other tools' files alone" || bad "deleted a foreign file"
[ -L "$S/context-reminder-link" ] && [ -e "$TMP/target" ] && ok "leaves a symlink and its target alone" || bad "symlink touched"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "pruning adds no output" || bad "pruning produced output" "$OUT"

# Install record: the installed copy's hooks.json differing from the source's no longer
# warns (hooks, agents and skills load from the source tree), so only the version line shows.
# SYG_INSTALLED_PLUGINS is set only so a reinserted drift block would read this fixture.
mkdir -p "$TMP/root/hooks" "$TMP/inst/hooks"
echo '{"h":2}' > "$TMP/root/hooks/hooks.json"; echo '{"h":1}' > "$TMP/inst/hooks/hooks.json"
jq -n --arg p "$TMP/inst" '{plugins: {"seyag@lbds137": [{installPath: $p}]}}' > "$TMP/installed.json"
OUT=$(jq -nc '{session_id: "probe", source: "startup"}' \
  | CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$TMP/rules-linked" SYG_STATE_DIR="$TMP/state" \
    SYG_INSTALLED_PLUGINS="$TMP/installed.json" bash "$HOOK" 2>/dev/null)
RC=$?
[ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ] && ok "installed copy differs from source: version line only, no warning" || bad "differing install record: expected version-only output" "$OUT"

prune() { # $1 state dir, $2 max days ("" = unset), $3 PATH (optional) → runs a resume start
  jq -nc '{session_id: "probe", source: "resume"}' >"$TMP/in.json"
  env ${3:+PATH="$3"} SYG_STATE_DIR="$1" ${2:+SYG_STATE_MAX_DAYS="$2"} \
    /usr/bin/bash "$HOOK" <"$TMP/in.json" >/dev/null 2>&1
}
old() { echo x >"$1"; touch -d '10 days ago' "$1"; }

D="$TMP/deep"
# shellcheck disable=SC2174 # the mode applies to the deepest dir only, which is all the probe needs
mkdir -p -m 700 "$D/sub"; old "$D/sub/context-reminder-deep"
prune "$D"
[ -e "$D/sub/context-reminder-deep" ] && ok "only prunes the top level (a deep match survives)" || bad "pruned inside a subdirectory"

N="$TMP/neg"; mkdir -m 700 "$N"; echo x >"$N/queued-receipt-state-fresh"
for v in -1 -7 junk "7 -o -true"; do prune "$N" "$v"; done
[ -e "$N/queued-receipt-state-fresh" ] && ok "a negative or junk max-days never deletes a fresh file" || bad "bad max-days deleted a fresh file"
old "$N/queued-receipt-state-stale"; prune "$N" junk
[ ! -e "$N/queued-receipt-state-stale" ] && ok "junk max-days falls back to the default" || bad "junk max-days disabled pruning"

W="$TMP/window"; mkdir -m 700 "$W"; echo x >"$W/context-reminder-mid"; touch -d '7 days ago 12 hours ago' "$W/context-reminder-mid"
prune "$W"
[ ! -e "$W/context-reminder-mid" ] && ok "cutoff is 7 days (a 7.5-day file goes)" || bad "7.5-day file survived the 7-day cutoff"

L="$TMP/linked"; mkdir -m 700 "$TMP/linked-real"; ln -s "$TMP/linked-real" "$L"; old "$TMP/linked-real/context-reminder-x"
prune "$L"; prune "$L/"; prune "$L//"   # pins the slash stripping; the [ ! -L ] test is backup (find -P won't descend a symlinked start point either)
[ -e "$TMP/linked-real/context-reminder-x" ] && ok "skips a symlinked state dir, with or without trailing slashes" || bad "pruned through a symlinked state dir"

J="$TMP/nojq"; mkdir -p "$J/bin" "$J/state"; chmod 700 "$J/state"; ln -s /usr/bin/find /usr/bin/id "$J/bin/"; old "$J/state/queued-receipt-state-y"
prune "$J/state" "" "$J/bin"
[ ! -e "$J/state/queued-receipt-state-y" ] && ok "prunes even without jq" || bad "no jq: pruning skipped"

exit $fail
