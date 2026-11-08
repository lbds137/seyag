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
unset SYG_STATE_DIR SYG_STATE_MAX_DAYS SYG_USER_RULES_DIR SYG_INSTALLED_PLUGINS SYG_PROFILE SYG_ENABLE SYG_DISABLE SYG_MEM_GATE_CMD SYG_LONG_JOB_CMD SYG_SECURITY_SWEEP SYG_SECURITY_SWEEP_REPOS SECURITY_SWEEP_GH CLAUDE_CODE_ENTRYPOINT
# The git-hooks relink acts on ${XDG_DATA_HOME}/seyag/git-hooks: a scratch one,
# so a run with the real plugin root never re-points a real install.
export XDG_DATA_HOME="$TMP/xdg"
# relink prefers the dir the GLOBAL core.hooksPath names: a scratch global
# config, so a real install is never what it rewrites.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
: >"$GIT_CONFIG_GLOBAL"

mkdir -p "$TMP/root/rules" "$TMP/rules-linked" "$TMP/rules-empty"
printf '# Core\nfixture\n' > "$TMP/root/rules/core.md"
cp "$TMP/root/rules/core.md" "$TMP/rules-linked/seyag-core.md"  # same content, different path (cache copy case)
printf 'unrelated\n' > "$TMP/rules-empty/other.md"

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '      got: %s\n' "$2"; fail=1; }

run() { # $1 source, $2 user rules dir → sets OUT, RC
  OUT=$(jq -nc --arg s "$1" '{session_id: "probe", source: $s}' \
    | env -u SYG_MEM_GATE_CMD -u SYG_LONG_JOB_CMD \
      CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$2" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
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
case "$(ctx)" in *"seyag git hooks"*) bad "startup, not installed: a relink line appeared" "$OUT" ;;
  *) ok "startup, git hooks not installed: no relink line" ;; esac

# An installed dispatcher dir left at an older plugin root: startup relinks
# it, adds one line after the version line, and the version line stays first.
D="$TMP/xdg/seyag/git-hooks"
mkdir -p "$D"
printf 'seyag git hooks dispatcher dir (seyag-git-hooks)\n' >"$D/.seyag-git-hooks"
printf '%s\n' "$TMP/old-version" >"$D/plugin-root"
OUT=$(jq -nc '{session_id: "probe", source: "startup"}' \
  | CLAUDE_PLUGIN_ROOT="$REAL_ROOT" SYG_USER_RULES_DIR="$TMP/rules-empty" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
if [ "$(cat "$D/plugin-root")" = "$(cd "$REAL_ROOT" && pwd -P)" ] && [ -x "$D/pre-push" ] \
  && [ "$(ctx | head -1)" = "seyag plugin $REAL_VERSION" ] && ctx | grep -q '^seyag git hooks: relinked'; then
  ok "startup relinks a stale dispatcher dir; the version line stays first"
else
  bad "startup relink of a stale dispatcher dir" "$OUT"
fi
OUT=$(jq -nc '{session_id: "probe", source: "startup"}' \
  | CLAUDE_PLUGIN_ROOT="$REAL_ROOT" SYG_USER_RULES_DIR="$TMP/rules-empty" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
case "$(ctx)" in *"seyag git hooks"*) bad "second startup: relink line again" "$OUT" ;;
  *) ok "second startup: the link is current, no relink line" ;; esac
# A relink that fails (a stale root in a dir it cannot write) says so in one line.
printf '%s\n' "$TMP/old-version" >"$D/plugin-root"
chmod 555 "$D"
OUT=$(jq -nc '{session_id: "probe", source: "startup"}' \
  | CLAUDE_PLUGIN_ROOT="$REAL_ROOT" SYG_USER_RULES_DIR="$TMP/rules-empty" SYG_STATE_DIR="$TMP/state" bash "$HOOK" 2>/dev/null)
RC=$?
chmod 755 "$D"
if [ "$RC" = 0 ] && [ "$(ctx | head -1)" = "seyag plugin $REAL_VERSION" ] \
  && ctx | grep -qx 'seyag git hooks: relink failed (run seyag-git-hooks status)'; then
  ok "a failed relink adds one line naming status, and the hook still exits 0"
else
  bad "failed relink line" "$OUT"
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

# Components: SYG_DISABLE=rules (or a profile without `rules`) drops the checklist and
# the rules-link warning; the version line never goes. An unset env keeps both.
runenv() { # $1 source, $2 user rules dir, rest = NAME=value env → sets OUT, RC
  local src=$1 dir=$2
  shift 2
  OUT=$(jq -nc --arg s "$src" '{session_id: "probe", source: $s}' \
    | env -u SYG_MEM_GATE_CMD -u SYG_LONG_JOB_CMD \
      CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$dir" SYG_STATE_DIR="$TMP/state" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}
runenv compact "$TMP/rules-linked" SYG_DISABLE=rules
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "SYG_DISABLE=rules, compact: no checklist, exit 0" || bad "SYG_DISABLE=rules compact: expected empty output" "$OUT"
runenv compact "$TMP/rules-linked" SYG_PROFILE=none
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "SYG_PROFILE=none, compact: no checklist" || bad "profile none compact: expected empty output" "$OUT"
runenv compact "$TMP/rules-linked" SYG_PROFILE=none SYG_ENABLE=rules
[ "$RC" = 0 ] && valid && ctx | grep -q 'POST-COMPACTION RECOVERY' && ok "SYG_PROFILE=none SYG_ENABLE=rules, compact: checklist back" || bad "enable rules compact: expected the checklist" "$OUT"
runenv startup "$TMP/rules-empty" SYG_DISABLE=rules
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "SYG_DISABLE=rules, startup, link missing: version line present, warning absent"
else
  bad "SYG_DISABLE=rules startup: expected the version line alone" "$OUT"
fi
runenv startup "$TMP/rules-empty" SYG_PROFILE=guards
[ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ] && ok "SYG_PROFILE=guards, startup, link missing: version line only" || bad "profile guards startup: expected the version line alone" "$OUT"
runenv startup "$TMP/rules-empty" SYG_PROFILE=none SYG_DISABLE=session
[ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ] && ok "SYG_DISABLE=session is ignored: version line stays" || bad "disable session: version line must stay" "$OUT"
runenv startup "$TMP/rules-empty" SYG_PROFILE=bogus
[ "$RC" = 0 ] && valid && ctx | grep -q 'core rules are not loaded' && ok "SYG_PROFILE=bogus behaves as full: warning present" || bad "bogus profile: expected the warning" "$OUT"

# Machine gates: SYG_MEM_GATE_CMD and SYG_LONG_JOB_CMD append on startup/clear/compact,
# stay off when empty or multiline, and are not gated by the `rules` component.
MEM_LINE='Memory gate: run `mem-gate --ok` before launching a worker, a test suite or a fan-out (exit 0 = go).'
JOB_LINE='Long jobs (over ~10 min): run them as `long-job-run NAME -- CMD` so a low-memory reaper can'\''t kill them.'
runenv startup "$TMP/rules-linked" SYG_MEM_GATE_CMD="mem-gate --ok" SYG_LONG_JOB_CMD="long-job-run"
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "$(printf 'seyag plugin unknown\n%s\n%s' "$MEM_LINE" "$JOB_LINE")" ]; then
  ok "startup with both gate vars set: version line first, then the two lines"
else
  bad "startup with both gate vars set: expected version line + two gate lines" "$OUT"
fi
runenv compact "$TMP/rules-linked" SYG_MEM_GATE_CMD="mem-gate --ok"
if [ "$RC" = 0 ] && valid && ctx | grep -q '^POST-COMPACTION RECOVERY' \
  && [ "$(ctx | tail -1)" = "$MEM_LINE" ] && ! ctx | grep -q 'Long jobs'; then
  ok "compact with SYG_MEM_GATE_CMD set: checklist then the gate line"
else
  bad "compact with SYG_MEM_GATE_CMD set: expected checklist + gate line" "$OUT"
fi
runenv compact "$TMP/rules-linked" SYG_DISABLE=rules SYG_MEM_GATE_CMD="mem-gate --ok"
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "$MEM_LINE" ]; then
  ok "compact with SYG_DISABLE=rules and gate set: only the gate line"
else
  bad "compact with SYG_DISABLE=rules and gate set: expected only the gate line" "$OUT"
fi
NL=$'\n'
runenv startup "$TMP/rules-linked" SYG_MEM_GATE_CMD="mem-gate${NL}evil" SYG_LONG_JOB_CMD="long-job${NL}evil"
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "gate values with an embedded newline: ignored (no gate line)"
else
  bad "gate values with an embedded newline: expected no gate line" "$OUT"
fi

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

# Security sweep opt-in line (component `security`):
# - runs on startup/clear when syg_enabled security and SYG_SECURITY_SWEEP=1 or SYG_SECURITY_SWEEP_REPOS is set
# - version line stays FIRST
# - env unset, SYG_DISABLE=security, CLAUDE_CODE_ENTRYPOINT=sdk-cli, source compact, or a >2s timeout adds no line
# - a >2s timeout (exit 124) detaches a cache-warming run so the next startup reads a warm cache
[ -x "$REAL_ROOT/bin/security-sweep" ] && ok "security-sweep bin is executable" || bad "security-sweep bin is not executable at $REAL_ROOT/bin/security-sweep"
ln -s "$REAL_ROOT/bin" "$TMP/root/bin"
mkdir -p "$TMP/sec-bin" "$TMP/sec-repo"
git init -q "$TMP/sec-repo"
git -C "$TMP/sec-repo" remote add origin "https://github.com/example-org/widget.git"
cat > "$TMP/sec-bin/gh" <<'EOF'
#!/bin/bash
if [ -n "${STUB_GH_HOLD:-}" ]; then
  for ((_i = 0; _i < 300; _i++)); do
    [ -e "$STUB_GH_HOLD" ] && break
    sleep 0.1
  done
fi
case "$*" in
  *repos/example-org/widget/code-scanning/alerts*)
    printf '[{"number":1,"rule":{"id":"r1","security_severity_level":"critical"},"tool":{"name":"CodeQL"}}]\n' ;;
  *repos/example-org/gadget/dependabot/alerts*)
    printf '[{"number":2,"security_advisory":{"severity":"high"},"dependency":{"package":{"name":"pkg-a"}}}]\n' ;;
  *)
    printf '[]\n' ;;
esac
EOF
chmod +x "$TMP/sec-bin/gh"

runsec() { # $1 source, rest = env assignments
  local src=$1
  shift
  rm -rf "$TMP/sec-state"
  OUT=$(cd "$TMP/sec-repo" && jq -nc --arg s "$src" '{session_id: "probe", source: $s}' \
    | env -u SYG_MEM_GATE_CMD -u SYG_LONG_JOB_CMD \
      CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$TMP/rules-linked" SYG_STATE_DIR="$TMP/state" \
      XDG_STATE_HOME="$TMP/sec-state" SECURITY_SWEEP_GH="$TMP/sec-bin/gh" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
}

WANT_SEC="security: example-org/widget: 1 code-scanning (1 critical) — dispositions per skill seyag:security-sweep"
runsec startup SYG_SECURITY_SWEEP=1
if [ "$RC" = 0 ] && valid && [[ "$(ctx | head -1)" == "seyag plugin "* ]] && ctx | grep -qxF "$WANT_SEC"; then
  ok "security-sweep startup with SYG_SECURITY_SWEEP=1: version line first, then security line"
else
  bad "security-sweep startup with SYG_SECURITY_SWEEP=1" "$OUT"
fi

WANT_SEC_REPOS="security: example-org/widget: 1 code-scanning (1 critical); example-org/gadget: 1 dependabot — dispositions per skill seyag:security-sweep"
runsec clear SYG_SECURITY_SWEEP_REPOS="example-org/widget example-org/gadget"
if [ "$RC" = 0 ] && valid && [[ "$(ctx | head -1)" == "seyag plugin "* ]] && ctx | grep -qxF "$WANT_SEC_REPOS"; then
  ok "security-sweep clear with SYG_SECURITY_SWEEP_REPOS: sweeps listed repos with version line first"
else
  bad "security-sweep clear with SYG_SECURITY_SWEEP_REPOS" "$OUT"
fi

runsec startup SYG_SECURITY_SWEEP_REPOS="-bad/x example-org/widget"
if [ "$RC" = 0 ] && valid && [[ "$(ctx | head -1)" == "seyag plugin "* ]] && ctx | grep -qxF "$WANT_SEC"; then
  ok "security-sweep startup with leading-dash token in SYG_SECURITY_SWEEP_REPOS: sweeps valid widget repo"
else
  bad "security-sweep startup with leading-dash token in SYG_SECURITY_SWEEP_REPOS" "$OUT"
fi

runsec startup
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "security-sweep env unset: no security line"
else
  bad "security-sweep env unset: expected version line only" "$OUT"
fi

runsec startup SYG_SECURITY_SWEEP=1 SYG_DISABLE=security
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "security-sweep SYG_DISABLE=security: no security line"
else
  bad "security-sweep SYG_DISABLE=security: expected version line only" "$OUT"
fi

runsec startup SYG_SECURITY_SWEEP=1 CLAUDE_CODE_ENTRYPOINT=sdk-cli
if [ "$RC" = 0 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "security-sweep headless (CLAUDE_CODE_ENTRYPOINT=sdk-cli): no security line"
else
  bad "security-sweep headless: expected version line only" "$OUT"
fi

rm -f "$TMP/gh-release"
t0=$SECONDS
runsec startup SYG_SECURITY_SWEEP=1 STUB_GH_HOLD="$TMP/gh-release"
elapsed=$((SECONDS - t0))
if [ "$RC" = 0 ] && [ "$elapsed" -lt 20 ] && valid && [ "$(ctx)" = "seyag plugin unknown" ]; then
  ok "security-sweep held stub times out within 2s cap (${elapsed}s < 20s), exit 0, no security line"
else
  bad "security-sweep timeout (rc=$RC, elapsed=${elapsed}s)" "$OUT"
fi
: > "$TMP/gh-release"

SEC_CACHE="$TMP/sec-state/seyag/security-sweep/example-org_widget.json"
for _ in $(seq 1 30); do
  [ -s "$SEC_CACHE" ] && break
  sleep 0.5
done
if [ -s "$SEC_CACHE" ]; then
  sleep 0.1
  ok "security-sweep timeout detached warm run populates cache file"
else
  bad "security-sweep timeout detached warm run did not populate $SEC_CACHE within 15s"
fi

OUT=$(cd "$TMP/sec-repo" && jq -nc '{session_id: "probe", source: "startup"}' \
  | env -u SYG_MEM_GATE_CMD -u SYG_LONG_JOB_CMD \
    CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$TMP/rules-linked" SYG_STATE_DIR="$TMP/state" \
    XDG_STATE_HOME="$TMP/sec-state" SECURITY_SWEEP_GH="$TMP/sec-bin/gh" \
    SYG_SECURITY_SWEEP=1 STUB_GH_HOLD="$TMP/gh-never-released" bash "$HOOK" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && valid && [[ "$(ctx | head -1)" == "seyag plugin "* ]] && ctx | grep -qxF "$WANT_SEC"; then
  ok "security-sweep second startup after timeout warm run reads warm cache and emits security line"
else
  bad "security-sweep second startup after timeout warm run" "$OUT"
fi

runsec compact SYG_SECURITY_SWEEP=1
if [ "$RC" = 0 ] && valid && ctx | grep -q 'POST-COMPACTION RECOVERY' && ! ctx | grep -q '^security:'; then
  ok "security-sweep compact: no security line"
else
  bad "security-sweep compact: unexpected security line" "$OUT"
fi

# Canary 10: dropping `syg_enabled security` from a temp copy of session-start.sh fails the SYG_DISABLE=security check
sed 's/syg_enabled security/true/' "$HOOK" > "$TMP/hook-no-sec-gate.sh"
if grep -q 'syg_enabled security' "$TMP/hook-no-sec-gate.sh"; then
  bad "canary 10: mutation of syg_enabled security did not apply"
else
  SAVED_HOOK="$HOOK"
  HOOK="$TMP/hook-no-sec-gate.sh"
  runsec startup SYG_SECURITY_SWEEP=1 SYG_DISABLE=security
  HOOK="$SAVED_HOOK"
  if [ "$(ctx)" != "seyag plugin unknown" ] && ctx | grep -qxF "$WANT_SEC"; then
    ok "canary 10: dropping syg_enabled security makes SYG_DISABLE=security row fail as expected"
  else
    bad "canary 10: dropping syg_enabled security did not fail SYG_DISABLE=security check" "$OUT"
  fi
fi

# Canary 11: removing the detached warm launch on exit 124 makes the second-start assertion fail
sed 's/elif \[ "\$SEC_RC" -eq 124 \]; then/elif false; then/' "$HOOK" > "$TMP/hook-no-warm.sh"
if grep -q 'SEC_RC" -eq 124' "$TMP/hook-no-warm.sh"; then
  bad "canary 11: mutation of SEC_RC -eq 124 did not apply"
else
  SAVED_HOOK="$HOOK"
  HOOK="$TMP/hook-no-warm.sh"
  rm -f "$TMP/gh-release-c11" "$TMP/gh-release-c11-2"
  runsec startup SYG_SECURITY_SWEEP=1 STUB_GH_HOLD="$TMP/gh-release-c11"
  : > "$TMP/gh-release-c11"
  sleep 3.5
  OUT=$(cd "$TMP/sec-repo" && jq -nc '{session_id: "probe", source: "startup"}' \
    | env -u SYG_MEM_GATE_CMD -u SYG_LONG_JOB_CMD \
      CLAUDE_PLUGIN_ROOT="$TMP/root" SYG_USER_RULES_DIR="$TMP/rules-linked" SYG_STATE_DIR="$TMP/state" \
      XDG_STATE_HOME="$TMP/sec-state" SECURITY_SWEEP_GH="$TMP/sec-bin/gh" \
      SYG_SECURITY_SWEEP=1 STUB_GH_HOLD="$TMP/gh-release-c11-2" bash "$HOOK" 2>/dev/null)
  : > "$TMP/gh-release-c11-2"
  HOOK="$SAVED_HOOK"
  if [ ! -s "$SEC_CACHE" ] && ! ctx | grep -qxF "$WANT_SEC"; then
    ok "canary 11: removing warm launch makes second-start assertion fail as expected"
  else
    bad "canary 11: removing warm launch did not fail second-start assertion" "$OUT"
  fi
fi

# Canary 12: reverting "--repo=$_syg_r" to -R "$_syg_r" makes the leading-dash SYG_SECURITY_SWEEP_REPOS assertion fail
sed 's/"--repo=\$_syg_r"/-R "$_syg_r"/' "$HOOK" > "$TMP/hook-dash-repo.sh"
if grep -q -- '--repo=\$_syg_r' "$TMP/hook-dash-repo.sh"; then
  bad "canary 12: mutation of --repo=\$_syg_r did not apply"
else
  SAVED_HOOK="$HOOK"
  HOOK="$TMP/hook-dash-repo.sh"
  runsec startup SYG_SECURITY_SWEEP_REPOS="-bad/x example-org/widget"
  HOOK="$SAVED_HOOK"
  if [ "$RC" = 0 ] && [ "$(ctx)" = "seyag plugin unknown" ] && ! ctx | grep -qxF "$WANT_SEC"; then
    ok "canary 12: reverting --repo=\$_syg_r to -R \"\$_syg_r\" makes leading-dash repo row fail as expected"
  else
    bad "canary 12: reverting --repo=\$_syg_r did not fail leading-dash repo assertion" "$OUT"
  fi
fi

exit $fail
