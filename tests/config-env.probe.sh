#!/usr/bin/env bash
# tests/config-env.probe.sh — hermetic probe for the optional config.toml loader
# (plugins/seyag/hooks/lib/config-env.sh, wired from hooks/run.sh and
# bin/claude-usage): scope and precedence (the environment wins, even when set
# empty; the project file overwrites the user file between the two), the key
# rule in both forms, the settable set (knobs.tsv user rows minus the
# harness-owned names), the _CMD project-scope refusal, SYG_CONFIG=0, the
# accepted TOML subset (one warning per offending line, fail-open), the
# skip-list parity with tests/config-reference.py, and both integrations.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/plugins/seyag/hooks/lib/config-env.sh"
PLUGIN="$REPO_ROOT/plugins/seyag"
KNOBS="$PLUGIN/config/knobs.tsv"

FAILURES=0
ok()   { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

echo "=== config-env probe ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home" "$TMP/no-xdg/seyag.d" "$TMP/proj-none"

# report: sources the lib, runs the loader against $SYG_TEST_PLUGIN_DIR, then
# prints name=[value] or name=UNSET per requested variable.
cat >"$TMP/report" <<'EOF'
#!/usr/bin/env bash
source "$1"
shift
syg_config_env "$SYG_TEST_PLUGIN_DIR"
for n in "$@"; do
  if [[ -n ${!n+x} ]]; then printf '%s=[%s]\n' "$n" "${!n}"; else printf '%s=UNSET\n' "$n"; fi
done
EOF

# Scrubbed environment for every loader call (a superset of unsets: env stops
# parsing options at the first assignment, so every -u comes first); per-case
# assignments come after (env lets the last one win).
CFG_ENV=(env
  -u CLAUDE_PROJECT_DIR -u XDG_CONFIG_HOME -u SYG_CONFIG
  -u SYG_CLOCK_STAMP_HINT -u CLAUDE_USAGE_WEEK_RESERVE -u SYG_MEM_GATE_CMD -u CLAUDE_CONFIG_DIR
  -u SYG_PROFILE -u SYG_EVENT_HOOK_TIMEOUT -u SYG_PRIVATE_TERMS_FILE -u SYG_ROUTE_MARKER_FIELD
  -u SYG_STATUS_CLAIM_MARKERS -u SYG_BQ_PENDING_MARKERS
  -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_API_KEY -u CC_ROUTE_PRESET -u CLAUDE_USAGE_MODEL -u CLAUDE_USAGE_TTL -u CLAUDE_USAGE_WEEK_STOP
  -u CLAUDE_USAGE_WEEK_RESERVE_CMD -u CLAUDE_USAGE_EXTRA_OK
  HOME="$TMP/home" SYG_TEST_PLUGIN_DIR="$PLUGIN")

# (a) no files: exit 0, empty stderr, nothing exported.
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = $'SYG_CLOCK_STAMP_HINT=UNSET\nCLAUDE_USAGE_WEEK_RESERVE=UNSET' ] && [ ! -s "$TMP/err" ]; then
  ok "(a) no files: exit 0, empty stderr, no vars exported"
else
  fail "(a) no files: rc $RC, out '$OUT', err '$(cat "$TMP/err")'"
fi

# The positive-control fixture (known to parse): both key forms, a basic string,
# an int and a section path.
U1="$TMP/xdg1"
mkdir -p "$U1/seyag"
printf 'syg_clock_stamp_hint = "from-user"\n[claude_usage]\nweek_reserve = 61\n' >"$U1/seyag/config.toml"

# (b) user file sets knobs the environment left unset.
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U1" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = $'SYG_CLOCK_STAMP_HINT=[from-user]\nCLAUDE_USAGE_WEEK_RESERVE=[61]' ] && [ ! -s "$TMP/err" ]; then
  ok "(b) user file sets a knob (both key forms) with env unset"
else
  fail "(b) user file: rc $RC, out '$OUT', err '$(cat "$TMP/err")'"
fi

# (c) env set to the empty string: env wins, the file value is NOT exported.
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U1" CLAUDE_PROJECT_DIR="$TMP/proj-none" CLAUDE_USAGE_WEEK_RESERVE= \
  bash "$TMP/report" "$LIB" CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
if [ "$OUT" = "CLAUDE_USAGE_WEEK_RESERVE=[]" ]; then
  ok "(c) env set to empty wins over the file"
else
  fail "(c) env-set-empty: out '$OUT' (want [] not [61])"
fi

# (d) the project file overwrites the user file for the same key.
P1="$TMP/proj1"
mkdir -p "$P1/.claude"
printf "syg_clock_stamp_hint = 'from-project'\n" >"$P1/.claude/seyag.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U1" CLAUDE_PROJECT_DIR="$P1" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
if [ "$OUT" = "SYG_CLOCK_STAMP_HINT=[from-project]" ] && [ ! -s "$TMP/err" ]; then
  ok "(d) project overwrites user for the same key (literal-string form)"
else
  fail "(d) project override: out '$OUT', err '$(cat "$TMP/err")'"
fi

# (e) unknown key: the exact warning line, valid keys still applied.
U2="$TMP/xdg2"
mkdir -p "$U2/seyag"
printf 'syg_totally_made_up = 1\nsyg_clock_stamp_hint = "kept"\n' >"$U2/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U2" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
WANT_ERR="seyag config: $U2/seyag/config.toml: line 1: unknown key 'syg_totally_made_up' (not a settable seyag knob; see docs/config.md)"
if [ "$OUT" = "SYG_CLOCK_STAMP_HINT=[kept]" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(e) unknown key warns exactly once; valid keys still applied"
else
  fail "(e) unknown key: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

# (e2) an unknown key inside a section warns with the full dotted path.
U2b="$TMP/xdg2b"
mkdir -p "$U2b/seyag"
printf '[claude_usage]\nnope = 1\n' >"$U2b/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U2b" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
WANT_ERR="seyag config: $U2b/seyag/config.toml: line 2: unknown key 'claude_usage.nope' (not a settable seyag knob; see docs/config.md)"
if [ "$OUT" = "CLAUDE_USAGE_WEEK_RESERVE=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(e2) unknown key in a section warns with the dotted path"
else
  fail "(e2) sectioned unknown key: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

# (f) malformed / unsupported values: one warning per offending line, exit 0,
# the good lines applied. Real knob names so the value checks are reached.
U3="$TMP/xdg3"
mkdir -p "$U3/seyag"
cat >"$U3/seyag/config.toml" <<'EOF'
syg_clock_stamp_hint = "applied"
syg_profile = [1, 2]
syg_profile = { a = 1 }
syg_profile. = 1
[claude_usage.]
syg_event_hook_timeout = """abc
syg_private_terms_file = hello
syg_route_marker_field = "a\qb"
syg_status_claim_markers = "x" y
syg_bq_pending_markers = "abc
syg_clock_stamp_hint = "second"
EOF
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U3" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
RC=$?
WANT_ERR=$(printf '%s' \
"seyag config: $U3/seyag/config.toml: line 2: syg_profile: unsupported value: arrays are not supported
seyag config: $U3/seyag/config.toml: line 3: syg_profile: unsupported value: inline tables are not supported
seyag config: $U3/seyag/config.toml: line 4: syg_profile.: malformed key: invalid name
seyag config: $U3/seyag/config.toml: line 5: [claude_usage.]: malformed section: invalid name
seyag config: $U3/seyag/config.toml: line 6: syg_event_hook_timeout: unsupported value: multiline strings are not supported
seyag config: $U3/seyag/config.toml: line 7: syg_private_terms_file: malformed value: strings and paths must be quoted
seyag config: $U3/seyag/config.toml: line 8: syg_route_marker_field: malformed value: unsupported escape
seyag config: $U3/seyag/config.toml: line 9: syg_status_claim_markers: unsupported value: trailing content after the value
seyag config: $U3/seyag/config.toml: line 10: syg_bq_pending_markers: malformed value: unterminated string
seyag config: $U3/seyag/config.toml: line 11: syg_clock_stamp_hint: duplicate key: first value wins")
if [ "$RC" = 0 ] && [ "$OUT" = "SYG_CLOCK_STAMP_HINT=[applied]" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(f) malformed/unsupported battery: one warning per line, exit 0, good lines applied"
else
  fail "(f) battery: rc $RC, out '$OUT', err:
$(cat "$TMP/err")"
fi

# (g) SYG_CONFIG=0: files present but ignored, no warnings.
OUT=$("${CFG_ENV[@]}" SYG_CONFIG=0 XDG_CONFIG_HOME="$U1" CLAUDE_PROJECT_DIR="$P1" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
if [ "$OUT" = $'SYG_CLOCK_STAMP_HINT=UNSET\nCLAUDE_USAGE_WEEK_RESERVE=UNSET' ] && [ ! -s "$TMP/err" ]; then
  ok "(g) SYG_CONFIG=0 ignores the files silently"
else
  fail "(g) SYG_CONFIG=0: out '$OUT', err '$(cat "$TMP/err")'"
fi

# (h) a harness-owned name warns and is skipped; a seyag-owned non-SYG name applies.
U4="$TMP/xdg4"
mkdir -p "$U4/seyag"
printf 'claude_config_dir = "/pwned"\nclaude_usage_week_reserve = 55\n' >"$U4/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U4" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" CLAUDE_CONFIG_DIR CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
WANT_ERR="seyag config: $U4/seyag/config.toml: line 1: unknown key 'claude_config_dir' (not a settable seyag knob; see docs/config.md)"
if [ "$OUT" = $'CLAUDE_CONFIG_DIR=UNSET\nCLAUDE_USAGE_WEEK_RESERVE=[55]' ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(h) harness-owned name refused with the unknown-key warning; CLAUDE_USAGE_WEEK_RESERVE applies"
else
  fail "(h) harness-owned: out '$OUT', err '$(cat "$TMP/err")'"
fi

# (i) a _CMD key: refused from project scope, accepted from user scope.
U5="$TMP/xdg5"
mkdir -p "$U5/seyag"
printf 'syg_mem_gate_cmd = "echo user-scope"\n' >"$U5/seyag/config.toml"
P5="$TMP/proj5"
mkdir -p "$P5/.claude"
printf 'syg_mem_gate_cmd = "echo project-scope"\n' >"$P5/.claude/seyag.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U5" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_MEM_GATE_CMD 2>"$TMP/err")
if [ "$OUT" = "SYG_MEM_GATE_CMD=[echo user-scope]" ] && [ ! -s "$TMP/err" ]; then
  ok "(i1) a _CMD key applies from user scope"
else
  fail "(i1) _CMD user scope: out '$OUT', err '$(cat "$TMP/err")'"
fi
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$P5" \
  bash "$TMP/report" "$LIB" SYG_MEM_GATE_CMD 2>"$TMP/err")
WANT_ERR="seyag config: $P5/.claude/seyag.toml: line 1: 'SYG_MEM_GATE_CMD' cannot be set from project scope (command-execution knob)"
if [ "$OUT" = "SYG_MEM_GATE_CMD=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(i2) a _CMD key is refused from project scope with the exact warning"
else
  fail "(i2) _CMD project scope: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

# (j) the loader's skip list equals the user-scope rows of SCAN_EXACT_NAMES in
# tests/config-reference.py intersected with knobs.tsv user rows (both parsed).
SCAN=$(sed -n '/^SCAN_EXACT_NAMES = (/,/^)/p' "$REPO_ROOT/tests/config-reference.py" \
  | grep -oE '"[A-Z0-9_]+"' | tr -d '"' | LC_ALL=C sort)
KNOB_USERS=$(awk -F'\t' '$2=="user"{print $1}' "$KNOBS" | LC_ALL=C sort)
EXPECT=$(LC_ALL=C comm -12 <(printf '%s\n' "$SCAN") <(printf '%s\n' "$KNOB_USERS"))
GOT=$(bash -c 'source "$1"; printf "%s\n" "${_SYG_CFG_HARNESS[@]}"' _ "$LIB" | LC_ALL=C sort)
if [ -n "$EXPECT" ] && [ "$(printf '%s\n' "$EXPECT" | wc -l)" = 8 ] && [ "$EXPECT" = "$GOT" ]; then
  ok "(j) loader skip list == knobs.tsv user rows ∩ SCAN_EXACT_NAMES (8 names)"
else
  fail "(j) skip-list parity: expect ($(printf '%s\n' "$EXPECT" | tr '\n' ' ')), got ($(printf '%s\n' "$GOT" | tr '\n' ' '))"
fi

# (k) run.sh integration: a fixture plugin tree, a stub hook printing the var,
# the config value reaches the hook's environment.
FIX="$TMP/plug"
mkdir -p "$FIX/hooks/lib" "$FIX/config"
cp "$REPO_ROOT/plugins/seyag/hooks/run.sh" "$FIX/hooks/"
cp "$REPO_ROOT/plugins/seyag/hooks/components.tsv" "$FIX/hooks/"
cp "$REPO_ROOT/plugins/seyag/hooks/lib/components.sh" "$FIX/hooks/lib/"
cp "$LIB" "$FIX/hooks/lib/"
cp "$KNOBS" "$FIX/config/"
cat >"$FIX/hooks/fake-guard.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "hint=${SYG_CLOCK_STAMP_HINT:-UNSET}"
exit 2
EOF
runfix() { # $1 XDG dir
  printf 'x' | env -u CLAUDE_PROJECT_DIR -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u SYG_CLOCK_STAMP_HINT \
    -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u CLAUDE_CODE_ENTRYPOINT -u SYG_CONFIG \
    XDG_CONFIG_HOME="$1" CLAUDE_PROJECT_DIR="$TMP/proj-none" XDG_CACHE_HOME="$TMP/xdg-cache" HOME="$TMP/home" \
    bash "$FIX/hooks/run.sh" fake-guard 2>"$TMP/err"
}
OUT=$(runfix "$U1")
RC=$?
if [ "$RC" = 2 ] && [ "$OUT" = "hint=from-user" ] && [ ! -s "$TMP/err" ]; then
  ok "(k1) run.sh passes the config value to the hook's env"
else
  fail "(k1) run.sh integration: rc $RC, out '$OUT', err '$(cat "$TMP/err")'"
fi
OUT=$(runfix "$TMP/no-xdg")
RC=$?
if [ "$RC" = 2 ] && [ "$OUT" = "hint=UNSET" ] && [ ! -s "$TMP/err" ]; then
  ok "(k2) run.sh control: no config file, nothing injected, stderr empty"
else
  fail "(k2) run.sh control: rc $RC, out '$OUT'"
fi

# (l) claude-usage integration: the config sets CLAUDE_USAGE_WEEK_RESERVE=61 and
# --posture reports it (HOME/XDG point at empty fixture dirs: no cache, no
# credentials, no state writes outside $TMP).
CU_HOME="$TMP/cu-home"
mkdir -p "$CU_HOME" "$TMP/cu-cache" "$TMP/cu-state"
cuposture() { # $1 XDG dir
  "${CFG_ENV[@]}" XDG_CONFIG_HOME="$1" XDG_CACHE_HOME="$TMP/cu-cache" XDG_STATE_HOME="$TMP/cu-state" HOME="$CU_HOME" \
    bash "$PLUGIN/bin/claude-usage" --posture 2>"$TMP/err"
}
OUT=$(cuposture "$U1")
RC=$?
WANT="week posture: wind-down 61% (no new units) · stop 80% (checkpoint, wake at reset) · now ?"
if [ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && [ ! -s "$TMP/err" ]; then
  ok "(l1) claude-usage --posture shows the config's week reserve (61)"
else
  fail "(l1) claude-usage integration: rc $RC, out '$OUT' (want '$WANT'), err '$(cat "$TMP/err")'"
fi
OUT=$(cuposture "$TMP/no-xdg")
RC=$?
WANT="week posture: wind-down 75% (no new units) · stop 80% (checkpoint, wake at reset) · now ?"
if [ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && [ ! -s "$TMP/err" ]; then
  ok "(l2) claude-usage control: no config file, default reserve 75, stderr empty"
else
  fail "(l2) claude-usage control: rc $RC, out '$OUT' (want '$WANT')"
fi

# (m) booleans export as 1 / 0.
U6="$TMP/xdg6"
mkdir -p "$U6/seyag"
printf 'syg_clock_stamp_hint = true\n' >"$U6/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U6" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
U7="$TMP/xdg7"
mkdir -p "$U7/seyag"
printf 'syg_clock_stamp_hint = false\n' >"$U7/seyag/config.toml"
OUT2=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U7" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
if [ "$OUT" = "SYG_CLOCK_STAMP_HINT=[1]" ] && [ "$OUT2" = "SYG_CLOCK_STAMP_HINT=[0]" ]; then
  ok "(m) booleans: true exports 1, false exports 0"
else
  fail "(m) booleans: true '$OUT', false '$OUT2'"
fi

# (n) fail-open on unreadable files: one warning, exit 0, nothing applied.
U8="$TMP/xdg8"
mkdir -p "$U8/seyag"
printf 'syg_clock_stamp_hint = "x"\n' >"$U8/seyag/config.toml"
chmod 000 "$U8/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U8" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
WANT_ERR="seyag config: cannot read $U8/seyag/config.toml: skipped"
if [ "$OUT" = "SYG_CLOCK_STAMP_HINT=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(n1) an unreadable config file warns once and is skipped"
else
  fail "(n1) unreadable config: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi
KN="$TMP/knobsplug"
mkdir -p "$KN/config"
printf 'x\n' >"$KN/config/knobs.tsv"
chmod 000 "$KN/config/knobs.tsv"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U1" SYG_TEST_PLUGIN_DIR="$KN" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err")
WANT_ERR="seyag config: cannot read $KN/config/knobs.tsv: skipped"
if [ "$OUT" = "SYG_CLOCK_STAMP_HINT=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(n2) an unreadable knobs.tsv warns once and the load is skipped"
else
  fail "(n2) unreadable knobs: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED ($FAILURES failure(s))"
  exit 1
fi
echo "ALL PASSED"
exit 0
