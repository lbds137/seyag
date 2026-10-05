#!/bin/bash
# Stop hook: when a turn ends with a TOOL CALL as its last content block,
# block the stop once and ask for the closing text.
#
# Why it matters: a unit-completing turn owes the owner two utterances — the
# report leads, a short confirmation closes. A turn that ends on the tool
# result itself delivers neither; the owner sees a silent stop and reads it as
# a stall (the seyag rules, rules/core.md). A PushNotification is the
# same failure in costume: it feels like delivery, but it is not the report.
#
# Enforcement geometry mirrors the two sibling Stop hooks: a deterministic scan
# of the ASSISTANT'S OWN output, blocking at most once via the native
# `stop_hook_active` flag (not an ack file — the retry mechanism is built into
# the Stop-hook contract). If the turn genuinely ended correctly and the last
# block is a tool call for some other reason, one line of text and a second
# stop proceeds.
#
# Transcript shape this reads (verified against the real corpus, not assumed):
# each assistant entry's `.message.content` is an ARRAY, and Claude Code
# currently fills it with exactly ONE block — it splits one API response into
# one JSONL entry per block, which is what the entry's `apiBlockIndex` field
# indexes. Block types observed: `thinking`, `text`, `tool_use`. Reading "the
# last block of the last assistant entry" is therefore correct under BOTH the
# split shape and a multi-block shape, which is why it is written that way
# rather than as "the last entry's only block".
#
# Primary signal: the Stop payload's `last_assistant_message` (the turn's final
# assistant text, absent when empty). The transcript can lag the payload — the
# final text entry may be flushed after this hook runs — so when the transcript
# ends on a tool_use and the payload names text that is NOT that tool-ending
# message's own, the final text exists and the stop passes. The transcript poll
# below is the fallback for payloads without the field. Residual: if the field
# ever named an EARLIER message's text on a tool-ending turn, the gate would
# miss that turn, and any failure computing the tool-ending message's text also
# passes the stop (fail-open, like every other external doubt here).
#
# Every external failure — no jq, no transcript, an entry with no content
# array — exits 0: a missed reminder is cheaper than blocking every turn end.
#
# Pinned by turn-end-shape-gate.probe.sh.

set -uo pipefail

INPUT=$(cat)

# Already blocked once this turn-end → allow the stop (no infinite loop).
ACTIVE=$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null || echo "false")
[ "$ACTIVE" = "true" ] && exit 0

# The turn's final assistant text, when the Stop payload carries it (Claude
# Code 2.1.289+); empty or absent on older versions.
LAM=$(jq -r '.last_assistant_message // empty' <<<"$INPUT" 2>/dev/null || echo "")

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Bounded tail rather than the whole file: the transcript runs to hundreds of
# megabytes on a long session, and the entry this hook wants is at its very
# end. `tail -n` counts newlines from the end, so every line it yields is
# complete — no partial-first-line JSON to strip.
#
# The 2000 is a bound, not a guarantee: if the last assistant entry sits older
# than the window, the tail yields none and the hook exits 0 — failing open,
# which is this hook's posture everywhere else too.
#
# A non-JSON line is skipped, not fatal: jq's default stream parser halts at
# the first parse error and everything after it in the stream would go
# unseen, silently blinding the hook to a real tool_use ending past that
# point. `fromjson? // empty` (the same pattern tests/replay-hook.sh uses)
# parses each line independently, so one bad line costs only itself.
read_last_content() {
  tail -n 2000 "$TRANSCRIPT" 2>/dev/null \
    | jq -Rc '(fromjson? // empty) | select(.type == "assistant") | select(.isSidechain != true) | .message.content' 2>/dev/null \
    | tail -n 1
}

# text_of_tool_ending_message: the text blocks of every main-chain assistant
# entry in the tail that shares the last assistant entry's `.message.id`
# (or of that entry alone when it has no id), joined with "\n" and trimmed.
text_of_tool_ending_message() {
  tail -n 2000 "$TRANSCRIPT" 2>/dev/null \
    | jq -Rrs '[split("\n")[] | (fromjson? // empty) | select(type == "object" and .type == "assistant" and .isSidechain != true)]
        | if length == 0 then "" else
            .[-1] as $l
            | (if $l.message.id then [.[] | select(.message.id == $l.message.id)] else [$l] end)
            | [.[].message.content | arrays | .[] | objects | select(.type == "text") | .text]
            | join("\n")
          end' 2>/dev/null
}

# True when LAM (the payload's last_assistant_message) describes the
# tool-ending message itself. A truncated LAM ends in "… [+N chars]"; the
# stripped value then only has to be a prefix. An empty OWN never matches.
# OWN is trimmed here in bash (a jq regex trim is quadratic on long space
# runs) and computed once per run: the loop exits as soon as the transcript
# stops ending on a tool_use, so a cached value is never read stale.
OWN="" OWN_DONE=""
lam_is_own_message() {
  local own stripped
  if [ -z "$OWN_DONE" ]; then
    OWN=$(text_of_tool_ending_message)
    OWN=${OWN#"${OWN%%[![:space:]]*}"}
    OWN=${OWN%"${OWN##*[![:space:]]}"}
    OWN_DONE=1
  fi
  own=$OWN
  [ -n "$own" ] || return 1
  [ "$LAM" = "$own" ] && return 0
  if [[ "$LAM" =~ …\ \[\+[0-9]+\ chars\]$ ]]; then
    stripped=${LAM%"${BASH_REMATCH[0]}"}
    [[ "$own" == "$stripped"* ]] && return 0
  fi
  return 1
}

# The read is retried rather than taken once. Observed premise: Claude Code can
# flush the turn's final TEXT entry after this hook has already started, so one
# immediate read can see the turn's last tool call as the last assistant entry
# and block a turn that did end on text. Observed on two of three text-ending
# turn ends (naming Bash once and SendMessage once as the supposed last block);
# in one, the text entry's timestamp preceded the hook's own feedback entry by
# ~180 ms, and in another (text stamped ~1.6 s before the feedback entry) the
# hook still blocked after the whole poll window. The flush window itself was
# not measured, so the five reads are a hedge, not a derived bound.
#
# The payload's `last_assistant_message` is the primary defense (see the header
# paragraph); this poll is the fallback for payloads without it. Residual,
# stated plainly: on such a payload a flush slower than the whole poll window
# still produces a false block. The `stop_hook_active` guard above bounds that
# to a single retry, after which the stop proceeds.
#
# Only the BLOCK path pays for the waiting: a turn that already reads as
# text-ended returns on the first read.
LAST_CONTENT=""
for attempt in 1 2 3 4 5; do
  [ "$attempt" -gt 1 ] && sleep 0.3
  LAST_CONTENT=$(read_last_content)

  # No assistant entry in the tail, or no content array → nothing to judge.
  [ -z "$LAST_CONTENT" ] && exit 0

  LAST_TYPE=$(jq -r 'if type == "array" and length > 0 then (.[-1].type // "") else "" end' <<<"$LAST_CONTENT" 2>/dev/null || echo "")
  [ "$LAST_TYPE" = "tool_use" ] || exit 0

  # The payload says the turn's final text exists, and it is not the text of
  # the tool-ending message itself → it simply has not been flushed yet.
  if [ -n "$LAM" ] && ! lam_is_own_message; then exit 0; fi
done

TOOL=$(jq -r 'if type == "array" and length > 0 then (.[-1].name // "a tool") else "a tool" end' <<<"$LAST_CONTENT" 2>/dev/null || echo "a tool")

cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TURN END SHAPE — this turn ends on a tool call ($TOOL)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
A unit-completing turn ends on TEXT. The report leads and a short
confirmation closes; ending on the tool result delivers neither, and
the owner reads the silence as a stall.

Deliver it now:
  - the user-facing report, if it has not been said yet, or
  - the one-line confirmation that the bookkeeping writes landed.

A PushNotification is not the report — it is the same failure in a
costume that feels like delivery. Say it in the turn.

If this turn was not unit-completing (mid-work, or the tool call is
genuinely the last thing the owner needs), say so in one line and stop
again — this gate fires once per turn end.
(the seyag rules, rules/core.md)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
exit 2
