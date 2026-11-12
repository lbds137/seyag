#!/bin/bash
# Context-size reminder (UserPromptSubmit).
#
# The owner carried the "should we compact?" monitoring ~10 times across four
# days (2026-08-09..12 mining, R2) and proposed a context-keyed reminder hook
# themselves — the assistant's "compact proactively at unit boundaries" rule
# demonstrably does not self-execute at long context. This hook is the
# mechanical trigger: when the LAST assistant turn began at or above the
# threshold (per model; see Tunables), it injects a reminder to name the next
# clean boundary and the pick there (/clear, /compact or keep, with the
# reason), throttled per session so it nags at most once per cooldown window.
#
# Mechanism: Claude Code hands UserPromptSubmit hooks the session transcript
# path; each assistant entry carries message.usage, whose input_tokens +
# cache_read_input_tokens + cache_creation_input_tokens is the context size
# that turn started from. Only the transcript TAIL is read — session files
# reach tens of MB and this runs on every user prompt.
#
# A trailing `{"type":"system","subtype":"compact_boundary"}` entry silences the
# hook: the first prompt after a compaction runs before any post-compaction
# assistant turn exists, so the last usage total describes the context that was
# just discarded, not the one now live. The event shape is observed in real
# transcripts; if Claude Code ever changes it, the hook simply stops muting
# (fail-open).
#
# Hard tier: when SYG_CONTEXT_BLOCK is set to a token
# count and the last turn is at or above it, this hook arms the hard tier
# instead of printing the soft banner — a mandatory handoff instruction, with
# context-block-gate.sh (PreToolUse) blocking every tool call that is not the
# handoff write itself or a read until ONE handoff write clears the session.
# The tier must fire every prompt while over threshold (mining: the soft
# reminder did not self-execute), so it ignores the cooldown below. It also
# re-sends on the first prompt after a compaction (a trailing compact_boundary
# entry): no turn has measured the new context yet, but the gate blocks either
# way, so the instruction is rendered from the armed marker's stored TOTAL.
#
# Fail-open everywhere: no jq, no transcript, unreadable tail, non-numeric
# total — silent exit 0. A reminder hook must never block a prompt.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
SESSION=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || echo "")

[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0
[ -n "$SESSION" ] || exit 0

# Tunables (env): SYG_CONTEXT_THRESHOLD (tokens, default 500000 — tuned for
# a 1M-context model), SYG_CONTEXT_THRESHOLD_FABLE (tokens, default 200000 —
# used instead when the LAST assistant entry's model starts with
# `claude-fable`, the lane that burns the week fastest; measured Fable
# sessions peaked at p50 272K / p90 655K, so 500K caught them late) and
# SYG_CONTEXT_COOLDOWN_MIN (minutes, default 30). A non-numeric or empty
# value falls back to its default.
THRESHOLD_DEFAULT=${SYG_CONTEXT_THRESHOLD:-500000}
THRESHOLD_FABLE=${SYG_CONTEXT_THRESHOLD_FABLE:-200000}
COOLDOWN_MIN=${SYG_CONTEXT_COOLDOWN_MIN:-30}
case "$THRESHOLD_DEFAULT" in '' | *[!0-9]*) THRESHOLD_DEFAULT=500000 ;; esac
case "$THRESHOLD_FABLE" in '' | *[!0-9]*) THRESHOLD_FABLE=200000 ;; esac
case "$COOLDOWN_MIN" in '' | *[!0-9]*) COOLDOWN_MIN=30 ;; esac

# Hard-tier threshold (env): SYG_CONTEXT_BLOCK (tokens). Unset or non-numeric
# keeps the hard tier off entirely — no new behaviour for anyone not opting in.
BLOCK_THRESHOLD=${SYG_CONTEXT_BLOCK:-}
case "$BLOCK_THRESHOLD" in '' | *[!0-9]*) BLOCK_THRESHOLD='' ;; esac

# The tier only makes sense with its gate able to run: when the context-block
# component is switched off (SYG_PROFILE / SYG_ENABLE / SYG_DISABLE — the same
# resolver run.sh applies to context-block-gate), the reminder treats the tier
# as off too. Otherwise every prompt would carry "your next tool calls are
# blocked" with no gate enforcing it, and the soft banner suppressed. A
# resolver that will not load leaves the tier on (run.sh leaves every hook
# enabled then too). Same pattern as session-start.sh.
if [ -n "$BLOCK_THRESHOLD" ]; then
    HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=lib/components.sh
    if [ -r "$HOOK_DIR/lib/components.sh" ] && source "$HOOK_DIR/lib/components.sh" 2>/dev/null \
        && declare -F syg_enabled >/dev/null; then
        syg_enabled context-block-gate || BLOCK_THRESHOLD=''
    fi
fi

# The session id reaches a filesystem path, so anything outside the safe set is
# folded to `_` rather than trusted (same set as queued-message-receipt.sh).
SAFE_SESSION=$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9._-' '_')

# SYG_STATE_DIR relocates the state family — session-start prunes it there, so
# the prompt hooks must write their markers into the same place.
STATE_DIR="${SYG_STATE_DIR:-/tmp/claude-$(id -u)}"
STAMP="$STATE_DIR/context-reminder-$SAFE_SESSION"
BLOCK_ARMED="$STATE_DIR/context-block-$SAFE_SESSION"
BLOCK_DONE="$STATE_DIR/context-block-done-$SAFE_SESSION"
BLOCK_NOTE="$STATE_DIR/context-block-note-$SAFE_SESSION"

# Mode is set atomically at creation (-m), and a pre-existing directory is
# trusted only if this user owns it: the path is predictable, so on a shared
# /tmp another user could pre-create it (dir squat / symlink plant, CWE-377) —
# chmod on a dir we don't own would fail silently and the write would proceed
# into hostile territory. Fail open instead. (Verbatim from
# queued-message-receipt.sh, which hardened this exact directory first.)
# shellcheck disable=SC2174 # only the leaf holds state; parents take the default mode
mkdir -p -m 700 "$STATE_DIR" 2>/dev/null || exit 0
[ ! -L "$STATE_DIR" ] || exit 0
[ -O "$STATE_DIR" ] || exit 0
chmod 700 "$STATE_DIR" 2>/dev/null || true

# Throttle: if a reminder fired within the cooldown, stay silent. find prints
# the stamp only when it is OLDER than the cooldown, so empty output while the
# stamp exists means "recent" — skip. One exception: the hard tier below
# ignores the cooldown while armed and uncleared (it must fire every prompt
# until the handoff lands), so the early exit is skipped in exactly that case.
block_armed_uncleared() {
    [ -n "$BLOCK_THRESHOLD" ] || return 1
    [ -f "$BLOCK_ARMED" ] || return 1
    if [ -f "$BLOCK_DONE" ] && [ "$BLOCK_DONE" -nt "$BLOCK_ARMED" ]; then
        return 1
    fi
    return 0
}
# block_join LIST: a colon-separated list rendered with its entries joined
# by ", " — the machine-config line never prints raw config syntax.
block_join() {
    local out="" e
    local IFS=:
    read -r -a JE <<<"$1"
    for e in "${JE[@]+"${JE[@]}"}"; do
        [ -n "$e" ] || continue
        out="${out:+$out, }$e"
    done
    printf '%s' "$out"
}
# block_lists_usable: 0 when at least one clear list has an entry — the same
# condition the gate fails open under and the arm branch refuses to arm with.
block_lists_usable() {
    local cmds=${SYG_CONTEXT_BLOCK_CMDS:-} paths=${SYG_CONTEXT_BLOCK_PATHS:-}
    if [ -z "${cmds//:/}" ] && [ -z "${paths//:/}" ]; then
        return 1
    fi
    return 0
}
# block_emit TOTAL: print the hard-tier instruction as UserPromptSubmit JSON.
# Used by the threshold arm path and by the compaction-boundary re-send (which
# has no live TOTAL and passes the armed marker's stored one). Writes no state.
block_emit() {
    local ktok=$(($1 / 1000)) instruction="" live=""
    local cmds=${SYG_CONTEXT_BLOCK_CMDS:-} paths=${SYG_CONTEXT_BLOCK_PATHS:-}
    read -r -d '' instruction <<EOF || true
CONTEXT BLOCK: this session is over the hard context limit (~${ktok}k tokens).
Your next tool calls are blocked except the handoff write itself and read-only
tools. Write your session handoff now: update your handoff notes (via your
configured handoff command or a file write to a SYG_CONTEXT_BLOCK_PATHS path).
After one handoff write, the block lifts for the rest of the session.
EOF
    # One machine-configured line naming the live clears, each list rendered
    # with its entries joined by ", " — never the raw config syntax; a half
    # with an empty list is omitted.
    [ -z "${paths//:/}" ] || live="handoff file paths: $(block_join "$paths")"
    [ -z "${cmds//:/}" ] || live="${live:+$live; }handoff commands: $(block_join "$cmds")"
    [ -z "$live" ] || instruction="$instruction
Machine config: $live"
    jq -nc --arg ctx "$instruction" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
}
if [ -f "$STAMP" ] && [ -z "$(find "$STAMP" -mmin +"$COOLDOWN_MIN" 2>/dev/null)" ]; then
    block_armed_uncleared || exit 0
fi

# The LAST relevant transcript event, tagged. `jq -R 'fromjson?'` parses
# per line and silently drops anything malformed — the mid-line cut at the
# start of a >4MB tail AND a partial last line mid-write — without positional
# dropping, so a sub-4MB transcript whose first line is the relevant entry
# still counts (same pattern as queued-message-receipt.sh).
#
# Two event kinds matter and their ORDER is the whole decision, so both are
# emitted into one stream rather than queried separately: `A <total> <model>`
# for an assistant turn's context size and the model that ran it (the model
# picks the threshold), `C` for a compaction boundary.
LAST_EVENT=$(tail -c 4000000 "$TRANSCRIPT" 2>/dev/null \
    | jq -R -r 'fromjson?
             | if (.type? == "system" and .subtype? == "compact_boundary") then "C"
               elif (.type? == "assistant" and (.message.usage? != null))
                 then "A \((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)) \(.message.model // "" | tostring)"
               else empty end' 2>/dev/null \
    | tail -1)

# A compaction boundary LAST means no turn has yet measured the new context.
# Reporting the pre-compaction total there is worse than saying nothing: it
# nags for a compaction that just happened — so the soft tier is silent. The
# hard tier still re-sends while armed-uncleared (the gate blocks either way;
# the instruction would otherwise be missing exactly when tools fail),
# rendered from the armed marker's stored TOTAL.
case "$LAST_EVENT" in
    C)
        if [ -n "$BLOCK_THRESHOLD" ] && block_armed_uncleared && block_lists_usable; then
            read -r MARKER_TOTAL _ <"$BLOCK_ARMED" 2>/dev/null || MARKER_TOTAL=""
            case "$MARKER_TOTAL" in
                '' | *[!0-9]*) ;; # unreadable marker: fail open, stay silent
                *)
                    block_emit "$MARKER_TOTAL"
                    exit 0
                    ;;
            esac
        fi
        exit 0
        ;;
    'A '*) REST=${LAST_EVENT#A } ;;
    *) exit 0 ;;
esac
TOTAL=${REST%% *}
MODEL=${REST#"$TOTAL"}
MODEL=${MODEL# }

case "$TOTAL" in
    '' | *[!0-9]*) exit 0 ;;
esac

# --- Hard context tier --------------------------------------------------------
# Replaces the soft banner (never stacks with it): the FIRST arm needs TOTAL at
# or above SYG_CONTEXT_BLOCK; after that, an armed-uncleared session re-emits
# the mandatory instruction on EVERY prompt, even below the threshold — a
# post-compaction total drop must not leave the gate blocking with only its
# stderr as explanation. ONE handoff write clears the session (the done marker
# growing newer than the armed marker); context-block-gate.sh enforces the
# block on the tool side. The cooldown does not apply here; a cleared session
# falls through to the soft tier exactly as before.
if [ -n "$BLOCK_THRESHOLD" ]; then
    BLOCK_CLEARED=0
    if [ -f "$BLOCK_DONE" ] && [ "$BLOCK_DONE" -nt "$BLOCK_ARMED" ] 2>/dev/null; then
        BLOCK_CLEARED=1
    fi
    if [ "$BLOCK_CLEARED" = 0 ] && { [ "$TOTAL" -ge "$BLOCK_THRESHOLD" ] || [ -f "$BLOCK_ARMED" ]; }; then
        if ! block_lists_usable; then
            # Fail-open: with both clear lists empty a session could brick
            # with no legal clear, so the tier does not arm — one note (once
            # per session: the note marker joins the context-block state
            # session-start prunes), then the soft tier only.
            if [ ! -f "$BLOCK_NOTE" ]; then
                echo "context-size-reminder: SYG_CONTEXT_BLOCK is set but SYG_CONTEXT_BLOCK_CMDS and SYG_CONTEXT_BLOCK_PATHS are both empty; hard tier not armed (soft reminder only)" >&2
                : >"$BLOCK_NOTE" 2>/dev/null || true
            fi
        else
            # (Re)write the armed marker — content is diagnostics, the gate
            # decides on existence and mtimes; the rewrite refreshes TOTAL and
            # makes a stale done marker older than this re-arm.
            printf '%s %s\n' "$TOTAL" "$(date +%s)" >"$BLOCK_ARMED" 2>/dev/null || true
            block_emit "$TOTAL"
            exit 0
        fi
    fi
fi

case "$MODEL" in
    claude-fable*) THRESHOLD_TOKENS=$THRESHOLD_FABLE ;;
    *) THRESHOLD_TOKENS=$THRESHOLD_DEFAULT ;;
esac

[ "$TOTAL" -ge "$THRESHOLD_TOKENS" ] || exit 0

touch "$STAMP" 2>/dev/null

KTOK=$((TOTAL / 1000))
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CONTEXT SIZE: the last turn began at ~${KTOK}k tokens (threshold $((THRESHOLD_TOKENS / 1000))k${MODEL:+, $MODEL})."
echo "Proactively name the next clean boundary (unit close, PR merge) in your"
echo "reply instead of waiting for the user to ask — standing owner request."
echo "There, with the handoff on disk (your role file's Handoff/Next), name the"
echo "pick and its reason: /clear (next unit unrelated), /compact (it continues"
echo "this thread) or keep (her next message is due within the hour, so the"
echo "cache is warm). The owner runs it."
echo "This reminder throttles for ${COOLDOWN_MIN} minutes."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
