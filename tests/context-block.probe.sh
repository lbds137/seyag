#!/bin/bash
# Component probe for the hard context tier (SYG_CONTEXT_BLOCK): the arm side
# in context-size-reminder.sh (UserPromptSubmit) and its end-to-end contract
# with context-block-gate.sh (PreToolUse). The gate's own payload-by-payload
# behaviour is pinned by plugins/seyag/hooks/context-block-gate.probe.sh; this
# file pins what writes and rewrites the marker pair the gate reads.
#
# Each reminder case builds a fixture transcript and invokes the hook with a
# crafted UserPromptSubmit envelope; each integration case then replays the
# armed state through the gate. Session ids are unique per run; markers are
# removed on exit.
#
# Usage: tests/context-block.probe.sh   (from repo root)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/plugins/seyag/hooks/context-size-reminder.sh"
GATE="$REPO/plugins/seyag/hooks/context-block-gate.sh"

# The defaults are pinned below; an ambient override must not skew them.
unset SYG_CONTEXT_THRESHOLD SYG_CONTEXT_THRESHOLD_FABLE SYG_CONTEXT_COOLDOWN_MIN
unset SYG_CONTEXT_BLOCK SYG_CONTEXT_BLOCK_CMDS SYG_CONTEXT_BLOCK_PATHS

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is required — the hooks parse their stdin payloads with it" >&2
    exit 1
}

TMPDIR_PROBE=$(mktemp -d)
STATE_DIR="/tmp/claude-$(id -u)"
# Same fresh-runner guard as the gate probe: the hook mkdirs the state dir on
# its first run, but nothing here may depend on that ordering.
mkdir -m 700 "$STATE_DIR" 2>/dev/null || true
SESSION_PREFIX="probe-ctxblk-$$"

PATHS_LIST='*/handoff-notes/*'
CMDS_LIST='handoff-write --note:handoff-write --set'

cleanup() {
    rm -rf "$TMPDIR_PROBE"
    rm -f "$STATE_DIR/context-reminder-$SESSION_PREFIX"-* 2>/dev/null
    rm -f "$STATE_DIR/context-block-$SESSION_PREFIX"-* 2>/dev/null
    rm -f "$STATE_DIR/context-block-done-$SESSION_PREFIX"-* 2>/dev/null
    rm -f "$STATE_DIR/context-block-note-$SESSION_PREFIX"-* 2>/dev/null
}
trap cleanup EXIT

fail=0
OUT=""
ERR=""
RC=0

armed_file() { # $1 = session suffix
    printf '%s/context-block-%s-%s' "$STATE_DIR" "$SESSION_PREFIX" "$1"
}

done_file() { # $1 = session suffix
    printf '%s/context-block-done-%s-%s' "$STATE_DIR" "$SESSION_PREFIX" "$1"
}

stamp_file() { # $1 = session suffix
    printf '%s/context-reminder-%s-%s' "$STATE_DIR" "$SESSION_PREFIX" "$1"
}

# One assistant transcript line whose usage sums to the given cache_read
# (input 1, creation 0) — the model defaults to a non-Fable one.
assistant_line() { # $1 cache_read
    jq -nc --argjson r "$1" \
        '{type: "assistant", message: {model: "claude-opus-5-5", usage: {input_tokens: 1, cache_read_input_tokens: $r, cache_creation_input_tokens: 0, output_tokens: 100}}}'
}

user_line() {
    jq -nc '{type: "user", message: {content: "hello"}}'
}

transcript_at() { # $1 = cache_read total → echoes the transcript path
    local t="$TMPDIR_PROBE/t-$1.jsonl"
    [ -f "$t" ] || { user_line; assistant_line "$1"; } >"$t"
    printf '%s' "$t"
}

# Run the reminder hook. $1 = session suffix, $2 = transcript path ("" omits
# the field). SYG_CONTEXT_BLOCK* env for the run is set by the caller as a
# prefix to this call.
run_reminder() {
    local session="$SESSION_PREFIX-$1" json
    if [ -z "$2" ]; then
        json=$(jq -nc --arg s "$session" '{prompt: "next", session_id: $s}')
    else
        json=$(jq -nc --arg s "$session" --arg t "$2" \
            '{prompt: "next", session_id: $s, transcript_path: $t}')
    fi
    OUT=$(printf '%s' "$json" | "$HOOK" 2>"$TMPDIR_PROBE/err")
    RC=$?
    ERR=$(cat "$TMPDIR_PROBE/err")
}

context_of() { # additionalContext of the last run's JSON stdout ("" if none)
    printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

assert_eq() { # $1 got, $2 want, $3 label
    if [ "$1" = "$2" ]; then
        echo "ok: $3"
    else
        echo "FAIL: $3"
        printf '     got:  %s\n     want: %s\n' "$1" "$2"
        fail=1
    fi
}

assert_silent_stdout() { # $1 = label
    if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
        echo "ok: $1"
    else
        echo "FAIL [exit=$RC | stdout=$([ -n "$OUT" ] && echo present || echo empty) want=empty]: $1"
        [ -n "$OUT" ] && printf '     got: %s\n' "$OUT"
        fail=1
    fi
}

# The rendered form of a colon-separated list: entries joined with ", " —
# the raw config syntax is never printed.
join_list() { # $1 = colon-separated list
    local out="" e
    local IFS=:
    read -r -a JE <<<"$1"
    for e in "${JE[@]+"${JE[@]}"}"; do
        [ -n "$e" ] || continue
        out="${out:+$out, }$e"
    done
    printf '%s' "$out"
}

# The pinned instruction, with <KTOK> and the machine-config line substituted.
expected_instruction() { # $1 = ktok, $2 = paths list ("" omit), $3 = cmds list
    local live=""
    [ -z "$2" ] || live="handoff file paths: $(join_list "$2")"
    [ -z "$3" ] || live="${live:+$live; }handoff commands: $(join_list "$3")"
    local txt
    read -r -d '' txt <<EOF || true
CONTEXT BLOCK: this session is over the hard context limit (~$1k tokens).
Your next tool calls are blocked except the handoff write itself and read-only
tools. Write the handoff now: update your role file's Handoff and Next (via
your configured handoff command or a file write to a SYG_CONTEXT_BLOCK_PATHS path).
After one handoff write, the block lifts for the rest of the session.
EOF
    [ -z "$live" ] || txt="$txt
Machine config: $live"
    printf '%s' "$txt"
}

# ---- Case 1: arm fires at the hard threshold ---------------------------------
T=$(transcript_at 300000)
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder arm "$T"
assert_eq "$RC" 0 "arm branch exits 0"
assert_eq "$(context_of)" "$(expected_instruction 300 "$PATHS_LIST" "$CMDS_LIST")" \
    "instruction text is pinned (5 lines + machine-config line)"
case "$OUT" in
    *'CONTEXT SIZE'*) echo "FAIL: hard tier stacked the soft banner"; fail=1 ;;
    *) echo "ok: hard tier replaces the soft banner" ;;
esac
[ -f "$(armed_file arm)" ] && echo "ok: arm created the armed marker" || {
    echo "FAIL: no armed marker after arm"
    fail=1
}
case "$(cat "$(armed_file arm)" 2>/dev/null)" in
    # assistant_line sums input 1 + cache 300000 = 300001.
    '300001 '*) echo "ok: armed marker content starts with the total" ;;
    *) echo "FAIL: armed marker content is not 'TOTAL epoch'"; fail=1 ;;
esac
[ -e "$(done_file arm)" ] && echo "FAIL: arm created a done marker" && fail=1

# ---- Case 2: re-arm is idempotent and refreshes the marker --------------------
M1=$(stat -c '%Y.%y' "$(armed_file arm)" 2>/dev/null)
sleep 1
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder arm "$T"
assert_eq "$(context_of)" "$(expected_instruction 300 "$PATHS_LIST" "$CMDS_LIST")" \
    "re-arm over threshold re-emits the instruction"
M2=$(stat -c '%Y.%y' "$(armed_file arm)" 2>/dev/null)
[ "$M2" != "$M1" ] && echo "ok: re-arm refreshed the armed marker" || {
    echo "FAIL: armed marker not refreshed on re-arm"
    fail=1
}

# ---- Case 2b: armed-uncleared re-emits BELOW the threshold (compaction) ------
# After a /compact the total drops under SYG_CONTEXT_BLOCK; an armed session
# must still get the instruction (the gate keeps blocking either way), while a
# never-armed session below the threshold keeps today's soft behaviour.
TLOW=$(transcript_at 100000)
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder arm "$TLOW"
assert_eq "$(context_of)" "$(expected_instruction 100 "$PATHS_LIST" "$CMDS_LIST")" \
    "armed session re-emits the instruction below the hard threshold (post-compaction)"
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder lowctl "$TLOW"
assert_silent_stdout "never-armed session below the hard threshold stays silent (100k under soft too)"

# ---- Case 3: the hard tier ignores the soft cooldown -------------------------
touch "$(stamp_file arm)"
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder arm "$T"
assert_eq "$(context_of)" "$(expected_instruction 300 "$PATHS_LIST" "$CMDS_LIST")" \
    "fresh soft stamp does not throttle the hard tier"
# Control: the same fresh stamp still throttles the soft tier.
T6=$(transcript_at 600000)
touch "$(stamp_file cooldown-ctl)"
run_reminder cooldown-ctl "$T6"
assert_silent_stdout "control: fresh stamp throttles the soft banner (hard tier off)"

# ---- Case 4: soft tier unaffected below the hard threshold -------------------
T55=$(transcript_at 550000)
SYG_CONTEXT_BLOCK=600000 run_reminder softonly "$T55"
case "$OUT" in
    *'CONTEXT SIZE'*) echo "ok: below the hard threshold the soft banner fires" ;;
    *) echo "FAIL: soft banner did not fire below the hard threshold"; fail=1 ;;
esac
[ -e "$(armed_file softonly)" ] && echo "FAIL: marker written below hard threshold" && fail=1

# ---- Case 5: hard tier off when SYG_CONTEXT_BLOCK is unset or non-numeric ----
T3=$(transcript_at 300000)
run_reminder off "$T3"
assert_silent_stdout "unset SYG_CONTEXT_BLOCK: 300k below the soft threshold stays silent"
SYG_CONTEXT_BLOCK=abc run_reminder nonnum "$T6"
case "$OUT" in
    *'CONTEXT SIZE'*) echo "ok: non-numeric SYG_CONTEXT_BLOCK falls back to the soft tier" ;;
    *) echo "FAIL: non-numeric SYG_CONTEXT_BLOCK did not fall back to soft"; fail=1 ;;
esac
[ -e "$(armed_file nonnum)" ] && echo "FAIL: non-numeric SYG_CONTEXT_BLOCK armed" && fail=1

# ---- Case 6: both clear lists empty → note, no arm, soft tier only -----------
SYG_CONTEXT_BLOCK=250000 run_reminder emptylists "$T3"
assert_silent_stdout "empty lists: no instruction, soft tier only (300k below soft)"
case "$ERR" in
    *'context-size-reminder: SYG_CONTEXT_BLOCK is set but SYG_CONTEXT_BLOCK_CMDS and SYG_CONTEXT_BLOCK_PATHS are both empty; hard tier not armed (soft reminder only)'*)
        echo "ok: empty lists print the one-line fail-open note on stderr" ;;
    *)
        echo "FAIL: empty-lists note missing from stderr"; fail=1 ;;
esac
[ -e "$(armed_file emptylists)" ] && echo "FAIL: empty lists still armed" && fail=1
# The note is once per session: the second prompt in the same broken state
# stays quiet instead of repeating it on every prompt.
SYG_CONTEXT_BLOCK=250000 run_reminder emptylists "$T3"
assert_silent_stdout "empty lists: second prompt emits nothing"
case "$ERR" in
    *'SYG_CONTEXT_BLOCK is set'*)
        echo "FAIL: empty-lists note repeated on the second prompt"; fail=1 ;;
    *)
        echo "ok: empty-lists note printed once per session" ;;
esac
# One list set is enough to arm.
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" run_reminder one1 "$T3"
assert_eq "$(context_of)" "$(expected_instruction 300 "$PATHS_LIST" "")" \
    "PATHS alone arms (machine line names paths only)"
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" run_reminder one2 "$T3"
assert_eq "$(context_of)" "$(expected_instruction 300 "" "$CMDS_LIST")" \
    "CMDS alone arms (machine line names commands only)"

# ---- Case 7: missing transcript → fail open, no arm ---------------------------
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" run_reminder notrans ""
assert_silent_stdout "missing transcript_path: silent, no arm"
[ -e "$(armed_file notrans)" ] && echo "FAIL: armed without a transcript" && fail=1

# ---- Case 8: cleared session behaves exactly as today -------------------------
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder cleared "$T3"
[ -f "$(armed_file cleared)" ] || { echo "FAIL: setup for cleared case did not arm"; fail=1; }
touch "$(done_file cleared)"
M1=$(stat -c '%y' "$(armed_file cleared)" 2>/dev/null)
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder cleared "$T3"
assert_silent_stdout "cleared (done newer): soft tier again, 300k below soft stays silent"
assert_eq "$(stat -c '%y' "$(armed_file cleared)" 2>/dev/null)" "$M1" \
    "cleared re-run does not rewrite the armed marker"
# NIT 9: cleared + fresh soft stamp + a total over the SOFT threshold →
# throttled silent. Cleared means exactly today's soft semantics: the
# cooldown early-exit applies again, so no soft banner either.
T6x=$(transcript_at 600000)
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder cleared2 "$T6x"
[ -f "$(armed_file cleared2)" ] && echo "ok: NIT-9 setup armed at 600k" || fail=1
touch "$(done_file cleared2)"
touch "$(stamp_file cleared2)"
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder cleared2 "$T6x"
assert_silent_stdout "cleared + fresh stamp + over-soft total is throttled silent"

# ---- Case 9: end-to-end with the gate — arm, block, clear, lift ----------------
run_gate() { # $1 = session suffix, $2 = tool_name, $3 = tool_input JSON
    local json
    json=$(jq -nc --arg s "$SESSION_PREFIX-$1" --arg t "$2" --argjson in "$3" \
        '{hook_event_name: "PreToolUse", session_id: $s, tool_name: $t, tool_input: $in}')
    OUT=$(printf '%s' "$json" | SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
        "$GATE" 2>"$TMPDIR_PROBE/err")
    RC=$?
    ERR=$(cat "$TMPDIR_PROBE/err")
}
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder e2e "$T3"
[ -f "$(armed_file e2e)" ] && echo "ok: e2e setup armed via the reminder" || fail=1
run_gate e2e Bash '{"command": "rm -rf /tmp/probe-fixture"}'
assert_eq "$RC" 2 "e2e: the gate blocks rm while armed"
run_gate e2e Write "$(jq -nc --arg p "/tmp/probe-fixture/handoff-notes/role.md" '{file_path: $p}')"
assert_eq "$RC" 0 "e2e: the handoff write itself is allowed"
[ -f "$(done_file e2e)" ] && echo "ok: e2e: the gate wrote the done marker" || {
    echo "FAIL: e2e: no done marker after the handoff write"
    fail=1
}
SYG_CONTEXT_BLOCK=250000 SYG_CONTEXT_BLOCK_PATHS="$PATHS_LIST" SYG_CONTEXT_BLOCK_CMDS="$CMDS_LIST" \
    run_reminder e2e "$T3"
assert_silent_stdout "e2e: after one handoff write the session runs free (no re-arm)"
run_gate e2e Bash '{"command": "rm -rf /tmp/probe-fixture"}'
assert_eq "$RC" 0 "e2e: the gate no longer blocks after the handoff write"

exit $fail
