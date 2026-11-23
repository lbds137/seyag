#!/usr/bin/env bash
# tests/config-env.probe.sh — hermetic probe for the optional config.toml loader
# (plugins/seyag/hooks/lib/config-env.sh, wired from hooks/run.sh and
# bin/claude-usage): scope and precedence (the environment wins, even when set
# empty; the project file overwrites the user file between the two), the key
# rule in both forms, the settable set (knobs.tsv user rows minus the
# harness-owned and envonly names), the _CMD/exec and path project-scope
# refusals, the envonly refusal in both scopes, SYG_CONFIG=0, the accepted TOML
# subset (one warning per offending line, fail-open, multiline-string body skip,
# warnings name file and line; file content is never echoed; name text is
# truncated to 40 characters on regular files and omitted on symlinked project
# files, invalid-section reset, unsupported number-form
# message, malformed tab-less knobs.tsv row warning), the skip-list and
# flags-coverage parity with tests/config-reference.py and knobs.tsv, and both
# integrations. The (o1)-(o6) battery pins the round-2 behaviours and (p)-(v)
# pin the cfg2 security refusals and parser hardenings.

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
  -u SYG_CLOCK_STAMP_HINT -u CLAUDE_USAGE_WEEK_RESERVE -u SYG_MEM_GATE_CMD -u SYG_CROSS_REVIEW_CMD -u CLAUDE_CONFIG_DIR
  -u SYG_PROFILE -u SYG_EVENT_HOOK_TIMEOUT -u SYG_PRIVATE_TERMS_FILE -u SYG_ROUTE_MARKER_FIELD
  -u SYG_STATUS_CLAIM_MARKERS -u SYG_BQ_PENDING_MARKERS -u SYG_STATUSLINE_ZAI_USAGE
  -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_API_KEY -u CC_ROUTE_PRESET -u CLAUDE_USAGE_MODEL -u CLAUDE_USAGE_TTL -u CLAUDE_USAGE_WEEK_STOP
  -u CLAUDE_USAGE_WEEK_RESERVE_CMD -u CLAUDE_USAGE_EXTRA_OK -u CLAUDE_USAGE_ZAI_WEEK_RESERVE
  -u SYG_ENABLE -u SYG_LAUNCH_RECORD_DIR -u SYG_CLASSIFIER_LEDGER -u SYG_ROLE_PREAMBLE_FILE -u SYG_OWNER_NAME
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
seyag config: $U3/seyag/config.toml: line 4: malformed key: invalid name
seyag config: $U3/seyag/config.toml: line 5: malformed section: invalid name
seyag config: $U3/seyag/config.toml: line 6: syg_private_terms_file: malformed value: strings and paths must be quoted
seyag config: $U3/seyag/config.toml: line 7: syg_route_marker_field: malformed value: unsupported escape
seyag config: $U3/seyag/config.toml: line 8: syg_status_claim_markers: unsupported value: trailing content after the value
seyag config: $U3/seyag/config.toml: line 9: syg_bq_pending_markers: malformed value: unterminated string
seyag config: $U3/seyag/config.toml: line 10: syg_clock_stamp_hint: duplicate key: first value wins")
if [ "$RC" = 0 ] && [ "$OUT" = "SYG_CLOCK_STAMP_HINT=[applied]" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(f) malformed/unsupported battery: one warning per line, exit 0, good lines applied"
else
  fail "(f) battery: rc $RC, out '$OUT', err:
$(cat "$TMP/err")"
fi

# (f2) L1 multiline-string skip: mid-file opener warns once and skips body lines
# (valid-looking and malformed alike) until the closing delimiter, after which
# normal parsing resumes; an opener unterminated at EOF warns once and skips the
# rest of the file; a single-line """abc""" opener warns once and skips nothing.
U3f2a="$TMP/xdg3-f2a"
mkdir -p "$U3f2a/seyag"
cat >"$U3f2a/seyag/config.toml" <<'EOF'
syg_event_hook_timeout = """abc
syg_enable = 1
malformed body line with no equals
closing delimiter line """
syg_clock_stamp_hint = "after-close"
EOF
OUT_F2A=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U3f2a" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_EVENT_HOOK_TIMEOUT SYG_ENABLE SYG_CLOCK_STAMP_HINT 2>"$TMP/err.f2a")
WANT_ERR_F2A="seyag config: $U3f2a/seyag/config.toml: line 1: syg_event_hook_timeout: unsupported value: multiline strings are not supported"

U3f2b="$TMP/xdg3-f2b"
mkdir -p "$U3f2b/seyag"
cat >"$U3f2b/seyag/config.toml" <<'EOF'
syg_event_hook_timeout = """abc
syg_enable = 1
syg_clock_stamp_hint = "unreached-at-eof"
EOF
OUT_F2B=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U3f2b" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_EVENT_HOOK_TIMEOUT SYG_ENABLE SYG_CLOCK_STAMP_HINT 2>"$TMP/err.f2b")
WANT_ERR_F2B=$(printf '%s' \
"seyag config: $U3f2b/seyag/config.toml: line 1: syg_event_hook_timeout: unsupported value: multiline strings are not supported
seyag config: $U3f2b/seyag/config.toml: line 3: unterminated multiline string: rest of file skipped")

U3f2c="$TMP/xdg3-f2c"
mkdir -p "$U3f2c/seyag"
cat >"$U3f2c/seyag/config.toml" <<'EOF'
syg_event_hook_timeout = """abc"""
syg_clock_stamp_hint = "not-skipped"
EOF
OUT_F2C=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U3f2c" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_EVENT_HOOK_TIMEOUT SYG_CLOCK_STAMP_HINT 2>"$TMP/err.f2c")
WANT_ERR_F2C="seyag config: $U3f2c/seyag/config.toml: line 1: syg_event_hook_timeout: unsupported value: multiline strings are not supported"

if [ "$OUT_F2A" = $'SYG_EVENT_HOOK_TIMEOUT=UNSET\nSYG_ENABLE=UNSET\nSYG_CLOCK_STAMP_HINT=[after-close]' ] \
  && [ "$(cat "$TMP/err.f2a")" = "$WANT_ERR_F2A" ] \
  && [ "$OUT_F2B" = $'SYG_EVENT_HOOK_TIMEOUT=UNSET\nSYG_ENABLE=UNSET\nSYG_CLOCK_STAMP_HINT=UNSET' ] \
  && [ "$(cat "$TMP/err.f2b")" = "$WANT_ERR_F2B" ] \
  && [ "$OUT_F2C" = $'SYG_EVENT_HOOK_TIMEOUT=UNSET\nSYG_CLOCK_STAMP_HINT=[not-skipped]' ] \
  && [ "$(cat "$TMP/err.f2c")" = "$WANT_ERR_F2C" ]; then
  ok "(f2) L1 multiline-string opener skips body lines to closing delimiter (mid-file, EOF, single-line)"
else
  fail "(f2) L1 multiline skip: f2a=($OUT_F2A / $(cat "$TMP/err.f2a")) f2b=($OUT_F2B / $(cat "$TMP/err.f2b")) f2c=($OUT_F2C / $(cat "$TMP/err.f2c"))"
fi

# (f2d) unknown-key multiline opener warns multiline-unsupported once, skips its
# body (so syg_enable = 1 and a malformed line inside do not run), and resumes
# after the closer.
U3f2d="$TMP/xdg3-f2d"
mkdir -p "$U3f2d/seyag"
cat >"$U3f2d/seyag/config.toml" <<'EOF'
totally_made_up = """abc
syg_enable = 1
malformed body line with no equals
closing delimiter line """
syg_clock_stamp_hint = "after-unknown-close"
EOF
OUT_F2D=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U3f2d" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_ENABLE SYG_CLOCK_STAMP_HINT 2>"$TMP/err.f2d")
WANT_ERR_F2D="seyag config: $U3f2d/seyag/config.toml: line 1: totally_made_up: unsupported value: multiline strings are not supported"
if [ "$OUT_F2D" = $'SYG_ENABLE=UNSET\nSYG_CLOCK_STAMP_HINT=[after-unknown-close]' ] \
  && [ "$(cat "$TMP/err.f2d")" = "$WANT_ERR_F2D" ]; then
  ok "(f2d) unknown-key multiline opener warns once, skips body (SYG_ENABLE=UNSET), resumes after closer"
else
  fail "(f2d) unknown-key multiline skip: out '$OUT_F2D', err '$(cat "$TMP/err.f2d")' (want '$WANT_ERR_F2D')"
fi

# (f2e) project-scope path-knob multiline opener warns multiline-unsupported (not
# path refusal) and skips its body so syg_clock_stamp_hint inside does not leak.
P3f2e="$TMP/proj3-f2e"
mkdir -p "$P3f2e/.claude"
cat >"$P3f2e/.claude/seyag.toml" <<'EOF'
syg_clock_stamp_paths_file = """x
syg_clock_stamp_hint = "leak"
"""
EOF
OUT_F2E=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$P3f2e" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err.f2e")
WANT_ERR_F2E="seyag config: $P3f2e/.claude/seyag.toml: line 1: syg_clock_stamp_paths_file: unsupported value: multiline strings are not supported"
if [ "$OUT_F2E" = "SYG_CLOCK_STAMP_HINT=UNSET" ] \
  && [ "$(cat "$TMP/err.f2e")" = "$WANT_ERR_F2E" ]; then
  ok "(f2e) project-scope path-knob multiline opener emits multiline warning and skips body (SYG_CLOCK_STAMP_HINT=UNSET)"
else
  fail "(f2e) project-scope path-knob multiline skip: out '$OUT_F2E', err '$(cat "$TMP/err.f2e")' (want '$WANT_ERR_F2E')"
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
# (i3) SYG_CROSS_REVIEW_CMD is a _CMD key: applies from user scope, refused from project scope.
U5b="$TMP/xdg5b"
mkdir -p "$U5b/seyag"
printf 'syg_cross_review_cmd = "xfam-route --for review"\n' >"$U5b/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U5b" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CROSS_REVIEW_CMD 2>"$TMP/err")
if [ "$OUT" = "SYG_CROSS_REVIEW_CMD=[xfam-route --for review]" ] && [ ! -s "$TMP/err" ]; then
  ok "(i3a) SYG_CROSS_REVIEW_CMD applies from user scope"
else
  fail "(i3a) SYG_CROSS_REVIEW_CMD user scope: out '$OUT', err '$(cat "$TMP/err")'"
fi
P7="$TMP/proj7"
mkdir -p "$P7/.claude"
printf 'syg_cross_review_cmd = "xfam-route --for review"\n' >"$P7/.claude/seyag.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$P7" \
  bash "$TMP/report" "$LIB" SYG_CROSS_REVIEW_CMD 2>"$TMP/err")
WANT_ERR="seyag config: $P7/.claude/seyag.toml: line 1: 'SYG_CROSS_REVIEW_CMD' cannot be set from project scope (command-execution knob)"
if [ "$OUT" = "SYG_CROSS_REVIEW_CMD=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(i3b) SYG_CROSS_REVIEW_CMD is refused from project scope with the exact warning"
else
  fail "(i3b) SYG_CROSS_REVIEW_CMD project scope: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
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

# (o1) event mode honours a config-set SYG_EVENT_HOOK_TIMEOUT: a stub that
# sleeps past a 1-second config timeout is killed before it can touch its
# marker file. Event mode ignores a timed-out hook's exit code, so the kill is
# observed by the marker staying absent, not by run.sh's exit code (run.probe.sh's
# event harness has no cheaper observable either); the control config with a
# 10-second timeout lets the same stub finish and block.
EVFIX="$TMP/evplug"
mkdir -p "$EVFIX/hooks/lib" "$EVFIX/config"
cp "$REPO_ROOT/plugins/seyag/hooks/run.sh" "$EVFIX/hooks/"
cp "$REPO_ROOT/plugins/seyag/hooks/components.tsv" "$EVFIX/hooks/"
cp "$REPO_ROOT/plugins/seyag/hooks/lib/components.sh" "$EVFIX/hooks/lib/"
cp "$LIB" "$EVFIX/hooks/lib/"
cp "$KNOBS" "$EVFIX/config/"
cat >"$EVFIX/hooks/slow-guard.sh" <<EOF
#!/bin/bash
cat >/dev/null
sleep 5
: > "$TMP/o1-done"
echo SLOW-BLOCK >&2
exit 2
EOF
cat >"$EVFIX/hooks/hooks.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" slow-guard"}]}]}}
EOF
printf '{"tool_name":"Bash","tool_input":{"command":"x"},"cwd":"/tmp"}' >"$TMP/o1-payload"
EVO1="$TMP/xdg-o1"
mkdir -p "$EVO1/seyag"
printf 'syg_event_hook_timeout = 1\n' >"$EVO1/seyag/config.toml"
EVO1C="$TMP/xdg-o1c"
mkdir -p "$EVO1C/seyag"
printf 'syg_event_hook_timeout = 10\n' >"$EVO1C/seyag/config.toml"
runev() { # $1 XDG dir
  env -u CLAUDE_PROJECT_DIR -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u SYG_CONFIG -u SYG_EVENT_HOOK_TIMEOUT \
    -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE -u CLAUDE_CODE_ENTRYPOINT \
    XDG_CONFIG_HOME="$1" CLAUDE_PROJECT_DIR="$TMP/proj-none" XDG_CACHE_HOME="$TMP/xdg-cache" HOME="$TMP/home" \
    bash "$EVFIX/hooks/run.sh" --event PreToolUse <"$TMP/o1-payload" 2>"$TMP/err"
}
rm -f "$TMP/o1-done"
OUT=$(runev "$EVO1")
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$TMP/err" ] && [ ! -e "$TMP/o1-done" ]; then
  ok "(o1a) event mode kills a hook past the config-set SYG_EVENT_HOOK_TIMEOUT (marker absent, fail-open exit 0)"
else
  fail "(o1a) event timeout: rc $RC, out '$OUT', err '$(cat "$TMP/err")', marker $([ -e "$TMP/o1-done" ] && echo present || echo absent)"
fi
OUT=$(runev "$EVO1C")
RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && [ "$(cat "$TMP/err")" = "SLOW-BLOCK" ] && [ -e "$TMP/o1-done" ]; then
  ok "(o1b) control: a generous config timeout lets the hook finish and block"
else
  fail "(o1b) control: rc $RC, out '$OUT', err '$(cat "$TMP/err")', marker $([ -e "$TMP/o1-done" ] && echo present || echo absent)"
fi

# (o2) a config-set SYG_PROFILE reaches the component resolver through run.sh:
# the fixture registry (overwriting the (k) copy in $FIX) maps fake-guard to a
# component only the full profile includes.
O2="$TMP/xdg-o2"
mkdir -p "$O2/seyag"
printf 'fake-guard\tfake-comp\n@profile\tfull\tfake-comp\n@profile\tbare\t\n' >"$FIX/hooks/components.tsv"
printf 'syg_profile = "bare"\n' >"$O2/seyag/config.toml"
OUT=$(runfix "$O2")
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$TMP/err" ]; then
  ok "(o2a) config-set SYG_PROFILE=bare skips the hook (component outside the profile)"
else
  fail "(o2a) profile skip: rc $RC, out '$OUT', err '$(cat "$TMP/err")'"
fi
printf 'syg_profile = "full"\n' >"$O2/seyag/config.toml"
OUT=$(runfix "$O2")
RC=$?
if [ "$RC" = 2 ] && [ "$OUT" = "hint=UNSET" ] && [ ! -s "$TMP/err" ]; then
  ok "(o2b) control: a config profile including the component runs the hook"
else
  fail "(o2b) profile control: rc $RC, out '$OUT', err '$(cat "$TMP/err")'"
fi

# (o3) the duplicate-section warning says what the parser does: keys merge.
U9="$TMP/xdg9"
mkdir -p "$U9/seyag"
printf '[claude_usage]\nweek_reserve = 55\n[claude_usage]\nweek_reserve = 66\n' >"$U9/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U9" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
WANT_ERR="seyag config: $U9/seyag/config.toml: line 3: [claude_usage]: duplicate section: keys merge, first value per key wins
seyag config: $U9/seyag/config.toml: line 4: week_reserve: duplicate key: first value wins"
if [ "$OUT" = "CLAUDE_USAGE_WEEK_RESERVE=[55]" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(o3) duplicate section: new message byte-exact, keys merge, first value per key wins"
else
  fail "(o3) duplicate section: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

# (o4) the third key form: a top-level dotted key applies like a section.
U10="$TMP/xdg10"
mkdir -p "$U10/seyag"
printf 'claude_usage.week_reserve = 61\n' >"$U10/seyag/config.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U10" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err")
if [ "$OUT" = "CLAUDE_USAGE_WEEK_RESERVE=[61]" ] && [ ! -s "$TMP/err" ]; then
  ok "(o4) a top-level dotted key applies (claude_usage.week_reserve = 61)"
else
  fail "(o4) dotted key: out '$OUT', err '$(cat "$TMP/err")'"
fi

# (o5) the exec-list pin: every user-scope knobs.tsv row whose description
# names a binary "invoked by" (the exec-knob description signature) is covered
# by the loader's project-scope refusal — _SYG_CFG_PROJECT_EXEC, the _CMD
# suffix, or _SYG_CFG_HARNESS — and the set is non-empty with the known gap in it.
INVOKED=$(awk -F'\t' '$2=="user" && $5 ~ /invoked by/ {print $1}' "$KNOBS")
MISSING=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  case $r in *_CMD) continue ;; esac
  bash -c 'source "$1"; for n in "${_SYG_CFG_PROJECT_EXEC[@]}" "${_SYG_CFG_HARNESS[@]}"; do [ "$n" = "$2" ] && exit 0; done; exit 1' _ "$LIB" "$r" || MISSING="$MISSING $r"
done <<EOF
$INVOKED
EOF
if [ -n "$INVOKED" ] && [ -z "$MISSING" ] && grep -qx 'SYG_STATUSLINE_ZAI_USAGE' <<<"$INVOKED"; then
  ok "(o5) every 'invoked by' user knob is project-refused (positive control: $(printf '%s ' $INVOKED))"
else
  fail "(o5) exec-list pin: invoked ($(printf '%s ' $INVOKED)), uncovered:${MISSING:- none}"
fi

# (o6) a project file cannot set a binary-path knob that lacks the _CMD suffix.
P6="$TMP/proj6"
mkdir -p "$P6/.claude"
printf 'syg_statusline_zai_usage = "./evil"\n' >"$P6/.claude/seyag.toml"
OUT=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$P6" \
  bash "$TMP/report" "$LIB" SYG_STATUSLINE_ZAI_USAGE 2>"$TMP/err")
WANT_ERR="seyag config: $P6/.claude/seyag.toml: line 1: 'SYG_STATUSLINE_ZAI_USAGE' cannot be set from project scope (command-execution knob)"
if [ "$OUT" = "SYG_STATUSLINE_ZAI_USAGE=UNSET" ] && [ "$(cat "$TMP/err")" = "$WANT_ERR" ]; then
  ok "(o6) SYG_STATUSLINE_ZAI_USAGE refused from project scope with the exact warning"
else
  fail "(o6) project exec refusal: out '$OUT', err '$(cat "$TMP/err")' (want '$WANT_ERR')"
fi

# (p) path refusals: project scope refuses path-flagged knobs (top-level and
# sectioned forms alike) with the exact message and leaves them unset; user
# scope still applies the same knob.
PP="$TMP/proj-p"
mkdir -p "$PP/.claude"
cat >"$PP/.claude/seyag.toml" <<'EOF'
syg_launch_record_dir = "/tmp/evil-lr"
syg_classifier_ledger = "/tmp/evil-cl"
syg_role_preamble_file = "/tmp/evil-pre"
[syg.launch_record]
dir = "/tmp/evil-lr2"
EOF
OUT_P=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$PP" \
  bash "$TMP/report" "$LIB" SYG_LAUNCH_RECORD_DIR SYG_CLASSIFIER_LEDGER SYG_ROLE_PREAMBLE_FILE 2>"$TMP/err.p")
WANT_ERR_P=$(printf '%s' \
"seyag config: $PP/.claude/seyag.toml: line 1: 'SYG_LAUNCH_RECORD_DIR' cannot be set from project scope (path knob)
seyag config: $PP/.claude/seyag.toml: line 2: 'SYG_CLASSIFIER_LEDGER' cannot be set from project scope (path knob)
seyag config: $PP/.claude/seyag.toml: line 3: 'SYG_ROLE_PREAMBLE_FILE' cannot be set from project scope (path knob)
seyag config: $PP/.claude/seyag.toml: line 5: 'SYG_LAUNCH_RECORD_DIR' cannot be set from project scope (path knob)")
UP="$TMP/xdg-p"
mkdir -p "$UP/seyag"
printf 'syg_launch_record_dir = "/tmp/user-lr"\n' >"$UP/seyag/config.toml"
OUT_PU=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$UP" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_LAUNCH_RECORD_DIR 2>"$TMP/err.pu")
if [ "$OUT_P" = $'SYG_LAUNCH_RECORD_DIR=UNSET\nSYG_CLASSIFIER_LEDGER=UNSET\nSYG_ROLE_PREAMBLE_FILE=UNSET' ] \
  && [ "$(cat "$TMP/err.p")" = "$WANT_ERR_P" ] \
  && [ "$OUT_PU" = "SYG_LAUNCH_RECORD_DIR=[/tmp/user-lr]" ] \
  && [ ! -s "$TMP/err.pu" ]; then
  ok "(p) path knobs refused from project scope (top-level and sectioned) and allowed from user scope"
else
  fail "(p) path refusal: proj=($OUT_P / $(cat "$TMP/err.p")) user=($OUT_PU / $(cat "$TMP/err.pu"))"
fi

# (q) envonly refusal: refused from both user and project files with the exact warning.
UQ="$TMP/xdg-q"
mkdir -p "$UQ/seyag"
printf 'syg_owner_name = "spoof-user"\n' >"$UQ/seyag/config.toml"
OUT_QU=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$UQ" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_OWNER_NAME 2>"$TMP/err.qu")
WANT_ERR_QU="seyag config: $UQ/seyag/config.toml: line 1: 'SYG_OWNER_NAME' is environment only (not settable from a config file)"
PQ="$TMP/proj-q"
mkdir -p "$PQ/.claude"
printf 'syg_owner_name = "spoof-proj"\n' >"$PQ/.claude/seyag.toml"
OUT_QP=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$PQ" \
  bash "$TMP/report" "$LIB" SYG_OWNER_NAME 2>"$TMP/err.qp")
WANT_ERR_QP="seyag config: $PQ/.claude/seyag.toml: line 1: 'SYG_OWNER_NAME' is environment only (not settable from a config file)"
if [ "$OUT_QU" = "SYG_OWNER_NAME=UNSET" ] && [ "$(cat "$TMP/err.qu")" = "$WANT_ERR_QU" ] \
  && [ "$OUT_QP" = "SYG_OWNER_NAME=UNSET" ] && [ "$(cat "$TMP/err.qp")" = "$WANT_ERR_QP" ]; then
  ok "(q) envonly knob refused from both user and project config files"
else
  fail "(q) envonly refusal: user=($OUT_QU / $(cat "$TMP/err.qu")) proj=($OUT_QP / $(cat "$TMP/err.qp"))"
fi

# (r) knobs.tsv flags coverage pins (r1 heuristic + allowlist, r2 envonly parity,
# r3 required-list pin).
# Explicit r1 allowlist with one-line reasons:
#   ZAI_AUTH_TOKEN                — a token value ("lane key file" names where it is looked up)
#   SYG_HANDOFF_PATHS             — regex value
#   SYG_LEDGER_PATH_RE            — regex value
#   SYG_DISPATCH_SPEC_RE          — regex value
#   SYG_DISPATCH_SRC_RE           — regex value
#   SYG_HANDOFF_SECTIONS          — description names the knob SYG_HANDOFF_PATHS
#   SYG_LAUNCH_RECORD_ENV         — env-var names ("files" names the record files)
#   SYG_NEEDS_OWNER_SECTION       — heading string ("role file" names where it lives)
#   SYG_IN_PERSON_SECTION         — heading string ("role file" names where it lives)
#   SYG_ROUTE_MARKER_FIELD        — a field name (names the file knob)
#   SYG_CONFIG                    — a 0/1 enable value ("config files" names what it disables)
#   SYG_EPG_TRUSTED_VARS          — variable names ("file-sink" names the guard's sink class)
#   SYG_HANDOFF_CMDS              — a regex value ("path defaults" names the built-in regex's subject)
#   SYG_ROLE_CONTEXT_CMD          — _CMD knob ("folder" is a JSON key in its documented output)
#   SYG_ROLE_CONTEXT_LINE         — a text line ("role file" names where it prints)
#   SYG_SCRATCH_RM_EXEMPT         — a 0/1 value ("scratch dir" names the guard's scope)
#   SYG_SESSION_CONTEXT_EXTRA_CMD — _CMD knob ("folder" is a JSON key)
#   SYG_STATE_MAX_DAYS            — a day count ("state files" names what ages out)
R1_ALLOWLIST=" ZAI_AUTH_TOKEN SYG_HANDOFF_PATHS SYG_LEDGER_PATH_RE SYG_DISPATCH_SPEC_RE SYG_DISPATCH_SRC_RE SYG_HANDOFF_SECTIONS SYG_LAUNCH_RECORD_ENV SYG_NEEDS_OWNER_SECTION SYG_IN_PERSON_SECTION SYG_ROUTE_MARKER_FIELD SYG_CONFIG SYG_EPG_TRUSTED_VARS SYG_HANDOFF_CMDS SYG_ROLE_CONTEXT_CMD SYG_ROLE_CONTEXT_LINE SYG_SCRATCH_RM_EXEMPT SYG_SESSION_CONTEXT_EXTRA_CMD SYG_STATE_MAX_DAYS "
R1_BAD=$(awk -F'\t' -v allow="$R1_ALLOWLIST" '
  $2 == "user" && tolower($5) ~ /(^|[^a-z0-9_])(dir|directory|file|path|glob|folder)s?([^a-z0-9_]|$)/ {
    has_path = ((" " $6 " ") ~ / path /)
    in_allow = (index(allow, " " $1 " ") > 0)
    if (!has_path && !in_allow) print "missing-path:" $1
    if (has_path && in_allow) print "allowlisted-has-path:" $1
  }
' "$KNOBS")
R2_BAD=$(awk -F'\t' '
  !/^#/ && NF > 0 {
    has_desc = ($5 ~ /Environment only/)
    has_flag = ((" " $6 " ") ~ / envonly /)
    if ($2 == "user" && has_desc && !has_flag) print "missing-envonly:" $1
    if (has_flag && ($2 != "user" || !has_desc)) print "unmatched-envonly:" $1
    if ($1 == "SYG_OWNER_NAME" && has_desc && has_flag) owner_ok = 1
  }
  END { if (!owner_ok) print "missing-control:SYG_OWNER_NAME" }
' "$KNOBS")
R3_REQ="SYG_GATE_SANDBOX_RO_BINDS SYG_WORKER_SANDBOX_RO_BINDS SYG_AGY_SUMMARIES_DB SYG_CLASSIFIER_LEDGER SYG_CREDIT_LEDGER SYG_WORKTREE_REGENERABLE SYG_SCRATCH_ROOT"
R3_BAD=$(awk -F'\t' -v req="$R3_REQ" '
  BEGIN { n = split(req, arr, " "); for (i = 1; i <= n; i++) need[arr[i]] = 1 }
  $2 == "user" && (" " $6 " ") ~ / path / { delete need[$1] }
  END { for (k in need) print "missing-r3:" k }
' "$KNOBS")
if [ -z "$R1_BAD" ] && [ -z "$R2_BAD" ] && [ -z "$R3_BAD" ]; then
  ok "(r) knobs.tsv flags coverage pins hold (r1 path heuristic, r2 envonly parity, r3 required list)"
else
  fail "(r) flags coverage: r1=[$R1_BAD] r2=[$R2_BAD] r3=[$R3_BAD]"
fi

# (s) F3 content-free raw warnings and bounded 40-char name echoes: =-less lines,
# invalid section headers, and invalid key names echo no file content; unknown
# key names truncate at 40 chars + "..." while short unknown keys show in full.
US="$TMP/xdg-s"
mkdir -p "$US/seyag"
KEY40="a234567890a234567890a234567890a234567890"
KEY200="${KEY40}${KEY40}${KEY40}${KEY40}${KEY40}"
cat >"$US/seyag/config.toml" <<EOF
FAKE_SECRET_20_CHARS
[spaced header]
{"a":"b"} = x
${KEY200}=1
short_unknown = 1
EOF
OUT_S=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$US" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err.s")
WANT_ERR_S=$(printf '%s' \
"seyag config: $US/seyag/config.toml: line 1: malformed line: expected 'key = value' or a [section] header
seyag config: $US/seyag/config.toml: line 2: malformed section: invalid name
seyag config: $US/seyag/config.toml: line 3: malformed key: invalid name
seyag config: $US/seyag/config.toml: line 4: unknown key '${KEY40}...' (not a settable seyag knob; see docs/config.md)
seyag config: $US/seyag/config.toml: line 5: unknown key 'short_unknown' (not a settable seyag knob; see docs/config.md)")
if [ "$OUT_S" = "SYG_CLOCK_STAMP_HINT=UNSET" ] && [ "$(cat "$TMP/err.s")" = "$WANT_ERR_S" ]; then
  ok "(s) content-free raw warnings (=-less line, invalid section, invalid key) and 40-char bounded unknown-key name echo"
else
  fail "(s) content-free/bounded echo: out '$OUT_S', err '$(cat "$TMP/err.s")' (want '$WANT_ERR_S')"
fi

# (s2) M4 invalid section header closes the active section instead of leaving
# the previous section open.
US2="$TMP/xdg-s2"
mkdir -p "$US2/seyag"
printf '[claude_usage]\nttl = 60\n[ claude_usage.zai ]\nweek_reserve = 40\n' >"$US2/seyag/config.toml"
OUT_S2=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$US2" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" CLAUDE_USAGE_TTL CLAUDE_USAGE_WEEK_RESERVE CLAUDE_USAGE_ZAI_WEEK_RESERVE 2>"$TMP/err.s2")
WANT_ERR_S2=$(printf '%s' \
"seyag config: $US2/seyag/config.toml: line 3: malformed section: invalid name
seyag config: $US2/seyag/config.toml: line 4: unknown key 'week_reserve' (not a settable seyag knob; see docs/config.md)")
if [ "$OUT_S2" = $'CLAUDE_USAGE_TTL=[60]\nCLAUDE_USAGE_WEEK_RESERVE=UNSET\nCLAUDE_USAGE_ZAI_WEEK_RESERVE=UNSET' ] \
  && [ "$(cat "$TMP/err.s2")" = "$WANT_ERR_S2" ]; then
  ok "(s2) M4 invalid section header resets the section so subsequent keys do not inherit it"
else
  fail "(s2) M4 section reset: out '$OUT_S2', err '$(cat "$TMP/err.s2")' (want '$WANT_ERR_S2')"
fi

# (s3) Symlinked (foreign) project config gets content-free warnings everywhere:
# padded-base64, JWT, known-typo, harness-owned, envonly, path-knob, exec-knob,
# multiline opener, duplicate section/key, and malformed value lines emit zero
# bytes of file content on stderr while rc stays 0.
PS3="$TMP/proj-s3"
mkdir -p "$PS3/.claude"
B64_KEY="canary00canary00canary00canary00canary00canary00"
JWT_KEY="ey0canary0canary0.ey0canary0canary0.s0canary0"
cat >"$TMP/foreign-s3.toml" <<EOF
${B64_KEY}==
${JWT_KEY}=
syg_clock_stamp_hintt = "x"
claude_config_dir = "/pwned"
syg_owner_name = "spoof-foreign"
syg_launch_record_dir = "/tmp/foreign-lr"
syg_mem_gate_cmd = "echo foreign-cmd"
syg_event_hook_timeout = """foreign_ml"""
syg_clock_stamp_hint = unquoted_foreign_val
[claude_usage]
week_reserve = 55
[claude_usage]
week_reserve = 66
EOF
ln -s "$TMP/foreign-s3.toml" "$PS3/.claude/seyag.toml"
OUT_S3=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$PS3" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT SYG_OWNER_NAME SYG_LAUNCH_RECORD_DIR SYG_MEM_GATE_CMD CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err.s3")
RC_S3=$?
WANT_ERR_S3=$(printf '%s' \
"seyag config: $PS3/.claude/seyag.toml: line 1: unknown key (not a settable seyag knob; see docs/config.md)
seyag config: $PS3/.claude/seyag.toml: line 2: unknown key (not a settable seyag knob; see docs/config.md)
seyag config: $PS3/.claude/seyag.toml: line 3: unknown key (not a settable seyag knob; see docs/config.md)
seyag config: $PS3/.claude/seyag.toml: line 4: unknown key (not a settable seyag knob; see docs/config.md)
seyag config: $PS3/.claude/seyag.toml: line 5: a knob is environment only (not settable from a config file)
seyag config: $PS3/.claude/seyag.toml: line 6: a knob cannot be set from project scope (path knob)
seyag config: $PS3/.claude/seyag.toml: line 7: a knob cannot be set from project scope (command-execution knob)
seyag config: $PS3/.claude/seyag.toml: line 8: unsupported value: multiline strings are not supported
seyag config: $PS3/.claude/seyag.toml: line 9: key: malformed value: strings and paths must be quoted
seyag config: $PS3/.claude/seyag.toml: line 12: duplicate section: keys merge, first value per key wins
seyag config: $PS3/.claude/seyag.toml: line 13: duplicate key: first value wins")
LEAK_S3=$(grep -E 'canary00|ey0canary0|syg_clock_stamp_hintt|claude_config_dir|syg_owner_name|SYG_OWNER_NAME|spoof-foreign|syg_launch_record_dir|SYG_LAUNCH_RECORD_DIR|foreign-lr|syg_mem_gate_cmd|SYG_MEM_GATE_CMD|foreign-cmd|syg_event_hook_timeout|foreign_ml|claude_usage|week_reserve|syg_clock_stamp_hint|unquoted_foreign_val' "$TMP/err.s3" || true)
if [ "$RC_S3" = 0 ] \
  && [ "$OUT_S3" = $'SYG_CLOCK_STAMP_HINT=UNSET\nSYG_OWNER_NAME=UNSET\nSYG_LAUNCH_RECORD_DIR=UNSET\nSYG_MEM_GATE_CMD=UNSET\nCLAUDE_USAGE_WEEK_RESERVE=[55]' ] \
  && [ -z "$LEAK_S3" ] \
  && [ "$(cat "$TMP/err.s3")" = "$WANT_ERR_S3" ]; then
  ok "(s3) symlinked project config emits content-free warnings (zero file bytes on stderr, rc 0)"
else
  fail "(s3) symlinked project config: rc $RC_S3, out '$OUT_S3', leak '$LEAK_S3', err '$(cat "$TMP/err.s3")' (want '$WANT_ERR_S3')"
fi

PS3B="$TMP/proj-s3b"
mkdir -p "$PS3B" "$TMP/foreign-s3-dir"
cp "$TMP/foreign-s3.toml" "$TMP/foreign-s3-dir/seyag.toml"
ln -s "$TMP/foreign-s3-dir" "$PS3B/.claude"
OUT_S3B=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$PS3B" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT SYG_OWNER_NAME SYG_LAUNCH_RECORD_DIR SYG_MEM_GATE_CMD CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err.s3b")
RC_S3B=$?
WANT_ERR_S3B=${WANT_ERR_S3//"$PS3"/"$PS3B"}
LEAK_S3B=$(grep -E 'canary00|ey0canary0|syg_clock_stamp_hintt|claude_config_dir|syg_owner_name|SYG_OWNER_NAME|spoof-foreign|syg_launch_record_dir|SYG_LAUNCH_RECORD_DIR|foreign-lr|syg_mem_gate_cmd|SYG_MEM_GATE_CMD|foreign-cmd|syg_event_hook_timeout|foreign_ml|claude_usage|week_reserve|syg_clock_stamp_hint|unquoted_foreign_val' "$TMP/err.s3b" || true)
if [ "$RC_S3B" = 0 ] \
  && [ "$OUT_S3B" = $'SYG_CLOCK_STAMP_HINT=UNSET\nSYG_OWNER_NAME=UNSET\nSYG_LAUNCH_RECORD_DIR=UNSET\nSYG_MEM_GATE_CMD=UNSET\nCLAUDE_USAGE_WEEK_RESERVE=[55]' ] \
  && [ -z "$LEAK_S3B" ] \
  && [ "$(cat "$TMP/err.s3b")" = "$WANT_ERR_S3B" ]; then
  ok "(s3b) symlinked .claude directory resolving outside the project emits content-free warnings (zero file bytes on stderr, rc 0)"
else
  fail "(s3b) symlinked .claude directory: rc $RC_S3B, out '$OUT_S3B', leak '$LEAK_S3B', err '$(cat "$TMP/err.s3b")' (want '$WANT_ERR_S3B')"
fi

# (s4) Negative control for (s3): a REGULAR project file with the same
# padded-base64 and JWT lines keeps today's 40-char bounded name echo.
PS4="$TMP/proj-s4"
mkdir -p "$PS4/.claude"
cat >"$PS4/.claude/seyag.toml" <<EOF
${B64_KEY}==
${JWT_KEY}=
EOF
OUT_S4=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$TMP/no-xdg" CLAUDE_PROJECT_DIR="$PS4" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err.s4")
RC_S4=$?
WANT_ERR_S4=$(printf '%s' \
"seyag config: $PS4/.claude/seyag.toml: line 1: unknown key '${B64_KEY:0:40}...' (not a settable seyag knob; see docs/config.md)
seyag config: $PS4/.claude/seyag.toml: line 2: unknown key '${JWT_KEY:0:40}...' (not a settable seyag knob; see docs/config.md)")
if [ "$RC_S4" = 0 ] && [ "$OUT_S4" = "SYG_CLOCK_STAMP_HINT=UNSET" ] && [ "$(cat "$TMP/err.s4")" = "$WANT_ERR_S4" ]; then
  ok "(s4) regular project file keeps the 40-char bounded unknown-key echo for padded-base64 and JWT lines"
else
  fail "(s4) regular project file control: rc $RC_S4, out '$OUT_S4', err '$(cat "$TMP/err.s4")' (want '$WANT_ERR_S4')"
fi

# (u) L4 number-form message: numeric-shaped non-int/float bare tokens (+5, 1e3)
# get the dedicated number-form message while plain bare strings keep the old one.
UU="$TMP/xdg-u"
mkdir -p "$UU/seyag"
printf 'syg_clock_stamp_hint = +5\nsyg_clock_stamp_hint = 1e3\n' >"$UU/seyag/config.toml"
OUT_U=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$UU" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT 2>"$TMP/err.u")
WANT_ERR_U=$(printf '%s' \
"seyag config: $UU/seyag/config.toml: line 1: syg_clock_stamp_hint: unsupported value: number form not supported (use plain digits or a quoted string)
seyag config: $UU/seyag/config.toml: line 2: syg_clock_stamp_hint: unsupported value: number form not supported (use plain digits or a quoted string)")
if [ "$OUT_U" = "SYG_CLOCK_STAMP_HINT=UNSET" ] && [ "$(cat "$TMP/err.u")" = "$WANT_ERR_U" ]; then
  ok "(u) L4 numeric-shaped bare tokens (+5, 1e3) emit the dedicated number-form warning"
else
  fail "(u) L4 number-form: out '$OUT_U', err '$(cat "$TMP/err.u")' (want '$WANT_ERR_U')"
fi

# (v) L3b tab-less row in knobs.tsv warns once and is skipped; a 5-field
# user row warns once that no flags column disables path/envonly refusals;
# 6-field rows, 5-field internal rows, and comment/blank rows stay silent.
KNV="$TMP/knobsplug-v"
mkdir -p "$KNV/config"
cat >"$KNV/config/knobs.tsv" <<'EOF'
# comment row stays silent

malformed_tabless_row_here
SYG_CLOCK_STAMP_HINT	user	guards	unset	Optional line appended to clock-stamp-guard block messages.	-
CLAUDE_USAGE_WEEK_RESERVE	user	usage	75	Weekly usage percentage threshold.
SYG_INTERNAL_NOFLAGS	internal	guards	unset	Internal 5-field row stays silent.
EOF
OUT_V=$("${CFG_ENV[@]}" XDG_CONFIG_HOME="$U1" SYG_TEST_PLUGIN_DIR="$KNV" CLAUDE_PROJECT_DIR="$TMP/proj-none" \
  bash "$TMP/report" "$LIB" SYG_CLOCK_STAMP_HINT CLAUDE_USAGE_WEEK_RESERVE 2>"$TMP/err.v")
WANT_ERR_V=$(printf '%s' \
"seyag config: $KNV/config/knobs.tsv: line 3: malformed row: skipped
seyag config: $KNV/config/knobs.tsv: line 5: CLAUDE_USAGE_WEEK_RESERVE: no flags column: path/envonly refusals disabled for this row")
if [ "$OUT_V" = $'SYG_CLOCK_STAMP_HINT=[from-user]\nCLAUDE_USAGE_WEEK_RESERVE=[61]' ] && [ "$(cat "$TMP/err.v")" = "$WANT_ERR_V" ]; then
  ok "(v) L3b tab-less row and 5-field user row warn once; 6-field, 5-field internal, comment and blank rows stay silent"
else
  fail "(v) L3b/5-field knobs rows: out '$OUT_V', err '$(cat "$TMP/err.v")' (want '$WANT_ERR_V')"
fi

# (w) Python parity: plugins/seyag/lib/config_env.py must export the same names and
# print the same stderr bytes as the shell loader for the same files. Each case
# runs both loaders from one scrubbed environment (env -i, LC_ALL pinned) and
# compares the exported names (sorted, interpreter noise dropped) and stderr with
# cmp. Fixtures use invented names only.
PY3=$(command -v python3) || { fail "(w) python3 not on PATH"; PY3=""; }
PY_LIB="$PLUGIN/lib"
cat >"$TMP/py-report.py" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import config_env
config_env.syg_config_env(sys.argv[2])
sys.stdout.buffer.write(b"\0".join(os.fsencode(k) + b"=" + os.fsencode(v) for k, v in os.environ.items()) + b"\0")
EOF
cat >"$TMP/env-filter.py" <<'EOF'
import sys
SKIP = {"_", "SHLVL", "PWD", "OLDPWD", "LC_CTYPE"}
items = sys.stdin.buffer.read().split(b"\0")
keep = sorted(i for i in items if i and i.split(b"=", 1)[0].decode("ascii", "replace") not in SKIP)
sys.stdout.buffer.write(b"".join(i + b"\n" for i in keep))
EOF

# write_body BODY FILE: write BODY to FILE, with each <NUL> marker a real NUL byte
# (a bash string cannot hold one: $'...\x00...' truncates the whole string there).
write_body() {
  printf '%s' "$1" | "$PY3" -I -B -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"<NUL>", b"\0"))' >"$2"
}

# parity_case NAME SCOPE BODY [EXTRA_ENV] [symlink]: BODY goes to the user file
# (SCOPE=user) or the project file (SCOPE=project; "symlink" makes it a link to a
# file outside the project, a foreign project file).
parity_case() {
  local name=$1 scope=$2 body=$3 extra=${4:-} shape=${5:-plain}
  local d="$TMP/par-$name-$scope" f
  mkdir -p "$d/home/.config/seyag" "$d/proj/.claude"
  if [ "$scope" = user ]; then
    f="$d/home/.config/seyag/config.toml"
    write_body "$body" "$f"
  elif [ "$shape" = symlink ]; then
    write_body "$body" "$d/outside.toml"
    ln -s "$d/outside.toml" "$d/proj/.claude/seyag.toml"
  else
    write_body "$body" "$d/proj/.claude/seyag.toml"
  fi
  # shellcheck disable=SC2086
  env -i PATH="$PATH" LC_ALL=C.UTF-8 HOME="$d/home" CLAUDE_PROJECT_DIR="$d/proj" $extra \
    bash -c 'source "$1"; syg_config_env "$2"; env -0' _ "$LIB" "$PLUGIN" >"$d/sh.env" 2>"$d/sh.err"
  # shellcheck disable=SC2086
  env -i PATH="$PATH" LC_ALL=C.UTF-8 HOME="$d/home" CLAUDE_PROJECT_DIR="$d/proj" $extra \
    "$PY3" -I -B "$TMP/py-report.py" "$PY_LIB" "$PLUGIN" >"$d/py.env" 2>"$d/py.err"
  "$PY3" -I -B "$TMP/env-filter.py" <"$d/sh.env" >"$d/sh.x"
  "$PY3" -I -B "$TMP/env-filter.py" <"$d/py.env" >"$d/py.x"
  if cmp -s "$d/sh.x" "$d/py.x" && cmp -s "$d/sh.err" "$d/py.err"; then
    ok "(w) parity $name ($scope): same exports ($(wc -l <"$d/sh.x") names), byte-equal stderr ($(wc -c <"$d/sh.err") bytes)"
  else
    fail "(w) parity $name ($scope): exports or stderr differ (diff $d/sh.x $d/py.x; diff $d/sh.err $d/py.err)"
  fi
}

if [ -n "$PY3" ]; then
  PW_VALID='syg_enable = 1
[statusline]
zai_timeout = "5"
'
  PW_REFUSE='syg_owner_name = "x"
foo = 1
syg_statusline_zai_usage = "/bin/x"
claude_projects_dir = "/x"
syg_agy_brain_dir = "/tmp/brain"
'
  PW_MALFORMED='syg_enable = maybe
syg_enable = [1]
syg_enable = {a=1}
syg_enable = "abc
syg_enable = "a\q"
syg_enable = 1 2
syg_enable = +5
syg_enable = 1e3
syg_enable = # c
no equals here
[bad section]
syg_enable = 1
'
  PW_MULTI='a = 1
x = """
syg_enable = 1
"""
syg_enable = 2
k = """one"""
z = '"'''"'
body
'
  PW_MULTI_EOF='syg_enable = 1
k = """abc
syg_enable = 0
'
  PW_DUP='syg_enable = 1
syg_enable = 0
[s]
x = 1
[s]
x = 2
'
  PW_NUMS='syg_enable = -3
syg_enable = 1.5
syg_clock_stamp_hint = true
syg_enable = false
'
  PW_ESC='syg_clock_stamp_hint = "a\tb\nc\\d\"e"
syg_enable = "x\z"
'
  PW_TRAIL='syg_enable = "1" junk
syg_clock_stamp_hint = "1" # ok
syg_enable = 1 # ok
syg_enable = '"'1'"' x
'
  PW_BADSEC='[a]
x = 1
[bad..x]
syg_enable = 1
'
  PW_CRLF=$'syg_enable = 1\r\n# c\r\nsyg_clock_stamp_hint = "x"\r\n'
  PW_LONG='syg_this_is_a_really_long_unknown_key_name_that_goes_past_forty_chars = 1
'
  PW_CTRL=$'k\x01ey = 1\nsyg_enable = "a\x7fb"\n'
  PW_NONL='syg_enable = 1'
  PW_EMPTY='syg_enable =
syg_enable = ""
'
  PW_DOTTED='a.b = 1
'
  # A NUL byte truncates its line at the NUL, as bash's C strings do; the next line still applies.
  PW_NUL='syg_clock_stamp_hint = "a<NUL>b"
syg_enable = 1
'
  PW_SECURE='syg_keys_name = "evil"
syg_keys_with_key = "host"
zai_auth_token = "tok"
syg_credit_when = "X=1"
syg_credit_route = "fake"
'
  parity_case valid user "$PW_VALID"
  parity_case valid project "$PW_VALID"
  parity_case refuse user "$PW_REFUSE"
  parity_case refuse project "$PW_REFUSE"
  parity_case malformed user "$PW_MALFORMED"
  parity_case malformed project "$PW_MALFORMED"
  parity_case multiline user "$PW_MULTI"
  parity_case multiline_eof project "$PW_MULTI_EOF"
  parity_case duplicates user "$PW_DUP"
  parity_case numbers project "$PW_NUMS"
  parity_case escapes user "$PW_ESC"
  parity_case trailing project "$PW_TRAIL"
  parity_case bad_section user "$PW_BADSEC"
  parity_case crlf user "$PW_CRLF"
  parity_case long_name user "$PW_LONG"
  parity_case ctrl user "$PW_CTRL"
  parity_case no_newline user "$PW_NONL"
  parity_case empty_val project "$PW_EMPTY"
  parity_case dotted user "$PW_DOTTED"
  parity_case foreign project "$PW_REFUSE$PW_MALFORMED" "" symlink
  parity_case sys_config_off user "$PW_VALID" "SYG_CONFIG=0"
  parity_case nul user "$PW_NUL"
  parity_case secure project "$PW_SECURE"
  parity_case secure user "$PW_SECURE"
  # The NUL case must also export the line after the truncated one (parity alone would pass two equal losses).
  if grep -qx 'SYG_ENABLE=1' "$TMP/par-nul-user/sh.x" && grep -qx 'SYG_ENABLE=1' "$TMP/par-nul-user/py.x" \
    && grep -q 'unterminated string' "$TMP/par-nul-user/sh.err"; then
    ok "(w) NUL in a value: both loaders warn unterminated and still export SYG_ENABLE=1"
  else
    fail "(w) NUL in a value: SYG_ENABLE not exported by both, or no unterminated warn (sh.x '$(cat "$TMP/par-nul-user/sh.x")', py.x '$(cat "$TMP/par-nul-user/py.x")')"
  fi
  # The project-secure knobs are refused from the project file and accepted from the user file.
  if grep -qx 'SYG_KEYS_NAME=evil' "$TMP/par-secure-user/sh.x" && grep -qx 'SYG_KEYS_WITH_KEY=host' "$TMP/par-secure-user/sh.x" \
    && grep -qx 'ZAI_AUTH_TOKEN=tok' "$TMP/par-secure-user/sh.x" && grep -qx 'SYG_CREDIT_WHEN=X=1' "$TMP/par-secure-user/sh.x" \
    && grep -qx 'SYG_CREDIT_ROUTE=fake' "$TMP/par-secure-user/sh.x" \
    && ! grep -qE 'SYG_KEYS|ZAI_AUTH_TOKEN|CREDIT_WHEN|CREDIT_ROUTE' "$TMP/par-secure-project/sh.x"; then
    ok "(w) security-material knobs: project file refused, user file exports all five"
  else
    fail "(w) security-material knobs: user '$(cat "$TMP/par-secure-user/sh.x")', project '$(cat "$TMP/par-secure-project/sh.x")'"
  fi

  PW_WT_SECURE='syg_worktree_branch_re = "."
'
  parity_case wt_secure project "$PW_WT_SECURE"
  parity_case wt_secure user "$PW_WT_SECURE"
  if grep -qx 'SYG_WORKTREE_BRANCH_RE=.' "$TMP/par-wt_secure-user/sh.x" \
    && ! grep -q '^SYG_WORKTREE_BRANCH_RE=' "$TMP/par-wt_secure-project/sh.x" \
    && grep -q "'SYG_WORKTREE_BRANCH_RE' cannot be set from project scope (security-material knob)" "$TMP/par-wt_secure-project/sh.err"; then
    ok "(w) worktree project-secure knob (syg_worktree_branch_re): project file refused, user file exported"
  else
    fail "(w) worktree project-secure knob: user '$(cat "$TMP/par-wt_secure-user/sh.x")', project '$(cat "$TMP/par-wt_secure-project/sh.x")', err '$(cat "$TMP/par-wt_secure-project/sh.err")'"
  fi

  PW_WT_ELIG_SECURE='syg_worktree_eligible_reasons = "branch-name ignored"
'
  parity_case wt_elig_secure project "$PW_WT_ELIG_SECURE"
  parity_case wt_elig_secure user "$PW_WT_ELIG_SECURE"
  if grep -qx 'SYG_WORKTREE_ELIGIBLE_REASONS=branch-name ignored' "$TMP/par-wt_elig_secure-user/sh.x" \
    && ! grep -q '^SYG_WORKTREE_ELIGIBLE_REASONS=' "$TMP/par-wt_elig_secure-project/sh.x" \
    && grep -q "'SYG_WORKTREE_ELIGIBLE_REASONS' cannot be set from project scope (security-material knob)" "$TMP/par-wt_elig_secure-project/sh.err"; then
    ok "(w) worktree project-secure knob (syg_worktree_eligible_reasons): project file refused, user file exported"
  else
    fail "(w) worktree project-secure knob (syg_worktree_eligible_reasons): user '$(cat "$TMP/par-wt_elig_secure-user/sh.x")', project '$(cat "$TMP/par-wt_elig_secure-project/sh.x")', err '$(cat "$TMP/par-wt_elig_secure-project/sh.err")'"
  fi

  # The harness-owned and project-exec lists: the shell's arrays and the python
  # tuples name the same knobs (both files parsed here, nothing imported).
  LISTS_OK=$("$PY3" -I -B - "$LIB" "$PY_LIB/config_env.py" <<'PYEOF'
import re, sys
sh = open(sys.argv[1], encoding="utf-8").read()
py = open(sys.argv[2], encoding="utf-8").read()
def names(block):
    return sorted(set(re.findall(r"[A-Z][A-Z0-9_]+", block)))
pairs = {
    "harness": (re.search(r"_SYG_CFG_HARNESS=\((.*?)\n\)", sh, re.S),
                re.search(r"_HARNESS = frozenset\(\s*\[(.*?)\]", py, re.S)),
    "project-exec": (re.search(r"_SYG_CFG_PROJECT_EXEC=\((.*?)\)", sh, re.S),
                     re.search(r"_PROJECT_EXEC = frozenset\(\s*\[(.*?)\]", py, re.S)),
    "project-secure": (re.search(r"_SYG_CFG_PROJECT_SECURE=\((.*?)\)", sh, re.S),
                       re.search(r"_PROJECT_SECURE = frozenset\(\s*\[(.*?)\]", py, re.S)),
}
bad = []
for label, (a, b) in pairs.items():
    if a is None or b is None:
        bad.append(f"{label}: list not found (shell {a is not None}, python {b is not None})")
        continue
    if names(a.group(1)) != names(b.group(1)) or not names(a.group(1)):
        bad.append(f"{label}: shell {names(a.group(1))} python {names(b.group(1))}")
print("ok" if not bad else "; ".join(bad))
PYEOF
)
  if [ "$LISTS_OK" = ok ]; then
    ok "(w) harness and project-exec lists equal in config-env.sh and config_env.py"
  else
    fail "(w) list parity: $LISTS_OK"
  fi

  # Every python bin adopts the loader (the uniform rule): python shebang in the
  # shipped form, and the wiring call present. zai-spend is a link to zai-usage.
  # Named exceptions skip only the wiring call, never the shebang:
  #   change-class: CI runs the same file standalone (no plugin lib), and the
  #   project config loader can set guard bypasses a classifier must not take.
  ADOPT_EXEMPT=" change-class "
  ADOPT_BAD=""
  for b in "$PLUGIN"/bin/*; do
    first=$(head -1 "$b" 2>/dev/null)
    case $first in '#!'*python*) ;; *) continue ;; esac
    grep -qx '#!/usr/bin/env -S python3 -I -B' "$b" || ADOPT_BAD="$ADOPT_BAD $(basename "$b"):shebang"
    case $ADOPT_EXEMPT in *" $(basename "$b") "*)
      ! grep -q 'config_env' "$b" || ADOPT_BAD="$ADOPT_BAD $(basename "$b"):exempt-but-imports-config_env"
      continue ;;
    esac
    grep -q 'config_env.syg_config_env(_SYG_ROOT)' "$b" || ADOPT_BAD="$ADOPT_BAD $(basename "$b"):adoption"
  done
  if [ -z "$ADOPT_BAD" ]; then
    ok "(w) every python bin in bin/ has the -I -B shebang and calls config_env.syg_config_env (exempt:$ADOPT_EXEMPT)"
  else
    fail "(w) python bins not adopting the loader:$ADOPT_BAD"
  fi
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED ($FAILURES failure(s))"
  exit 1
fi
echo "ALL PASSED"
exit 0
