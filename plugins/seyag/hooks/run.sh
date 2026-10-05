#!/bin/bash
# Seyag hook dispatcher.
#   run.sh <hook-name>          run one hook (how hooks.json wires the plugin)
#   run.sh --event <EventName>  run every hook hooks.json wires for that event and
#                               merge their results (for a project that keeps the
#                               plugin disabled; see the README)
#
# If the project ships its own copy (.claude/hooks/<name>.sh under
# CLAUDE_PROJECT_DIR, else the cwd), the hook is skipped silently: the project's
# copy wins and is wired by the project's own settings, so running both would
# double-fire. Otherwise, in single-hook mode, exec the plugin's copy with stdin
# passed through; its exit code, stdout and stderr reach Claude Code unchanged.

DIR=""
SYG_LIB=""
# syg_hook_ready NAME: the per-hook checks both modes share, in this order: name,
# project copy, existence, components, syntax; then the exports every hook gets.
# Returns 0 with SYG_HOOK set when the hook should run, 1 when it is skipped.
syg_hook_ready() {
  local name=$1
  case "$name" in
    '' | */* | .*) echo "run.sh: invalid hook name '$name'" >&2; return 1 ;;
  esac
  [ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/$name.sh" ] && return 1
  [ -n "$DIR" ] || DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  SYG_HOOK="$DIR/$name.sh"
  [ -f "$SYG_HOOK" ] || { echo "run.sh: no such seyag hook '$name'" >&2; return 1; }

  # Components: hooks/components.tsv maps each hook to a component, and SYG_PROFILE,
  # SYG_ENABLE and SYG_DISABLE pick which components run (lib/components.sh).
  # Turn-shape hooks (Stop, UserPromptSubmit) and the context reminder are about
  # talking to a person. Headless runs have nobody attending, and a Stop hook there
  # can replace the script's real output, so the resolver removes those components
  # after applying the env (SYG_ENABLE cannot bring them back): CLAUDE_CODE_ENTRYPOINT
  # starting `sdk-` (`claude -p` reports sdk-cli, SDK scripts sdk-*).
  # CLAUDE_CODE_SESSION_ATTENDED is not consulted: a background session a person
  # drives live carries 0 too. The shell guards still run.
  # A resolver that will not load leaves every hook enabled, headless included: it
  # must not block tools, and tests/shell-syntax.probe.sh catches a broken lib in CI.
  # A registry the resolver cannot use falls back to its SYG_HEADLESS_OFF_HOOKS list.
  # The lib is sourced once per run.sh process.
  if [ -z "$SYG_LIB" ]; then
    SYG_LIB=0
    if [ -r "$DIR/lib/components.sh" ] && source "$DIR/lib/components.sh" 2>/dev/null \
      && declare -F syg_enabled >/dev/null; then
      SYG_LIB=1
    fi
  fi
  if [ "$SYG_LIB" = 1 ]; then
    syg_enabled "$name" || return 1
  fi

  # A hook with a syntax error would exit 2, and for PreToolUse that blocks the tool:
  # one half-saved edit would stop every Bash call in every session. Fail open instead.
  if ! bash -n "$SYG_HOOK" 2>/dev/null; then
    echo "run.sh: seyag hook '$name' has a syntax error; skipped" >&2
    return 1
  fi

  export PYTHONDONTWRITEBYTECODE=1
  # Hooks only read git; a hook killed mid-index-refresh, or one racing the
  # session's own git command, would leave or collide with index.lock.
  export GIT_OPTIONAL_LOCKS=0
  return 0
}

if [ "${1:-}" != --event ]; then
  syg_hook_ready "${1:-}" || exit 0
  exec bash "$SYG_HOOK"
fi

# --- Event mode ------------------------------------------------------------------
# Selects every hook under .hooks[EVENT] in hooks.json whose matcher matches the
# payload, applies syg_hook_ready to each, runs the survivors in parallel (each
# with the payload on stdin, under a SYG_EVENT_HOOK_TIMEOUT-second limit, default
# 45), and merges in hooks.json order:
# - A hook blocks on exit 2 (text: its stderr), or on exit 0 with JSON holding
#   hookSpecificOutput.permissionDecision "deny" or decision "block" (text: the
#   permissionDecisionReason or reason). Any block: every blocker's text, then the
#   other hooks' context, ask reasons and systemMessage under "Also from seyag
#   hooks:", go to stderr, and the exit is 2 (stderr is what reaches the model).
# - Otherwise each exit-0 hook's additionalContext is joined into one, and so is
#   each systemMessage and each permissionDecision "ask" reason (PreToolUse).
#   Plain stdout counts as context only for SessionStart and UserPromptSubmit,
#   and additionalContext is emitted only for those two and Pre/PostToolUse; for
#   other events each goes to stderr, as a direct hook's would be seen.
# - Every exit-0 hook's stderr passes through to stderr. A JSON key or value this
#   merge does not forward is named on stderr, never dropped silently. Skip
#   notices (missing hook, syntax error) print last, so block text leads.
# - Any other exit code (a timeout included) is ignored (fail open), and so is the
#   whole event when jq or hooks.json is missing, or the event is unknown. An
#   unparsable hooks.json says so on stderr.
EVENT=${2:-}
command -v jq >/dev/null 2>&1 || exit 0
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$DIR/hooks.json" ] || exit 0
PAYLOAD=$(cat)

# The payload goes to jq on stdin from the printf builtin (a Write payload can
# exceed the per-argument limit). The hook name is the word after `hooks/run.sh"`,
# the parse tests/hook-wiring.probe.sh uses; that probe pins that they agree.
HAVE_TOOL=0 TOOL="" MATCHERS=() NAMES=()
SEL=$(printf '%s' "$PAYLOAD" | jq -rRs --arg ev "$EVENT" --slurpfile hj "$DIR/hooks.json" '
  ((try fromjson catch null) as $p
   | if ($p | type) == "object" and ($p.tool_name | type) == "string"
     then @sh "HAVE_TOOL=1 TOOL=\($p.tool_name)" else "HAVE_TOOL=0" end),
  (($hj[0].hooks[$ev] // [])[]
   | ((.matcher // "") | tostring) as $m
   | (.hooks // [])[]
   | (((.command // "") | tostring | capture("hooks/run\\.sh\" *(?<n>[A-Za-z0-9._-]+)") | .n) // "") as $n
   | select($n != "")
   | @sh "MATCHERS+=(\($m)) NAMES+=(\($n))")' 2>/dev/null) && eval "$SEL" || {
  echo "run.sh: hooks.json unparsable; event mode ran nothing" >&2
  exit 0
}

# Claude Code's matcher rule, as read from its code: empty or "*" matches
# everything; a matcher of only [A-Za-z0-9_|] is a list of exact tool names; any
# other matcher is a regex. Unverified: Claude Code tests that regex with JS
# RegExp.test (unanchored); bash =~ is unanchored too, but POSIX ERE, not JS. A
# payload without tool_name matches every entry of the event.
syg_matches() {
  local m=$1 alt
  if [ -z "$m" ] || [ "$m" = '*' ] || [ "$HAVE_TOOL" = 0 ]; then return 0; fi
  if [[ $m =~ ^[A-Za-z0-9_|]+$ ]]; then
    local IFS='|'
    for alt in $m; do [ "$alt" = "$TOOL" ] && return 0; done
    return 1
  fi
  [[ $TOOL =~ $m ]]
}

SELECTED=()
for i in "${!NAMES[@]}"; do
  syg_matches "${MATCHERS[i]}" && SELECTED+=("${NAMES[i]}")
done
[ "${#SELECTED[@]}" -gt 0 ] || exit 0

WORK=$(mktemp -d) || exit 0
RUN=() PIDS=()
# No hook outlives the dispatcher: on any exit the still-running ones are killed.
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 143' TERM INT HUP
printf '%s' "$PAYLOAD" >"$WORK/payload"
: >"$WORK/notes"
# One hung hook must not stall the event and lose the other hooks' blocks.
T=${SYG_EVENT_HOOK_TIMEOUT:-45}
case "$T" in '' | *[!0-9]*) T=45 ;; esac
[ "$T" -gt 0 ] || T=45
TO=()
command -v timeout >/dev/null 2>&1 && TO=(timeout -k 2 "$T")
for name in "${SELECTED[@]}"; do
  syg_hook_ready "$name" 2>>"$WORK/notes" || continue
  n=${#RUN[@]}
  "${TO[@]+"${TO[@]}"}" bash "$SYG_HOOK" <"$WORK/payload" >"$WORK/$n.out" 2>"$WORK/$n.err" &
  PIDS[n]=$!
  RUN[n]=$name
done
if [ "${#RUN[@]}" -eq 0 ]; then
  cat "$WORK/notes" >&2
  exit 0
fi

RCS=()
ARGS=(--arg ev "$EVENT" --arg count "${#RUN[@]}")
for n in "${!RUN[@]}"; do
  wait "${PIDS[n]}"
  RCS[n]=$?
  ARGS+=(--arg "n$n" "${RUN[n]}" --arg "r$n" "${RCS[n]}" --rawfile "o$n" "$WORK/$n.out" --rawfile "e$n" "$WORK/$n.err")
done

ARGS+=(--arg sq "'")
# One jq pass computes the whole result; @sh makes its output safe to eval.
MERGED=$(jq -rn "${ARGS[@]}" '
  def chomp: sub("\n+$"; "");
  def warn($name): "run.sh: seyag hook \($sq)\($name)\($sq) emitted \(.), which event mode does not forward";
  ($ev | IN("SessionStart", "UserPromptSubmit")) as $plain
  | ($ev | IN("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse")) as $ctxok
  | [range(0; $count | tonumber) as $i
   | {name: $ARGS.named["n\($i)"], rc: $ARGS.named["r\($i)"],
      out: $ARGS.named["o\($i)"], err: $ARGS.named["e\($i)"]}
   | select(.rc == "0" or .rc == "2")
   | .name as $name
   | if .rc == "2" then {block: (.err | chomp), notes: []}
     else
       (.out | try fromjson catch null | if type == "object" then . else null end) as $j
       | ($j.hookSpecificOutput?) as $h
       | (if ($h | type) == "object" then $h else {} end) as $hs
       | ($hs.permissionDecision) as $pd
       | ($pd == "ask" and $ev == "PreToolUse") as $ask
       | {block: (if $j != null and ($pd == "deny" or $j.decision == "block")
                  then (first([$hs.permissionDecisionReason, $j.reason][] | strings)
                        // "run.sh: seyag hook \($sq)\($name)\($sq) blocked without a reason")
                  else null end),
          ask: (if $ask then (first($hs.permissionDecisionReason | strings) // "") else null end),
          ctx: (if $j == null
                then (if $plain then (first(.out | chomp | select(length > 0)) // null) else null end)
                else (first($hs.additionalContext | strings) // null) end),
          sys: (first($j.systemMessage? | strings) // null),
          notes: ([.err | chomp | select(length > 0)]
            + [if $j == null and ($plain | not) then .out | chomp | select(length > 0) else empty end]
            + [($j // {}) | keys_unsorted[]
               | select(IN("hookSpecificOutput", "systemMessage", "decision", "reason") | not) | warn($name)]
            + [if $h != null and ($h | type) != "object" then "hookSpecificOutput" | warn($name) else empty end]
            + [$hs | keys_unsorted[]
               | select(IN("hookEventName", "additionalContext", "permissionDecision", "permissionDecisionReason") | not)
               | "hookSpecificOutput." + . | warn($name)]
            + [if $hs | has("permissionDecision") and ((IN($pd; "deny", "ask") | not) or ($pd == "ask" and ($ask | not)))
               then "hookSpecificOutput.permissionDecision \($pd | tojson) on \($ev)" | warn($name) else empty end]
            + [if ($j // {}) | has("decision") and $j.decision != "block"
               then "decision \($j.decision | tojson)" | warn($name) else empty end]
            + [if $hs | has("additionalContext") and ($hs.additionalContext | type) != "string"
               then "hookSpecificOutput.additionalContext that is not a string" | warn($name) else empty end]
            + [if ($j // {}) | has("systemMessage") and ($j.systemMessage | type) != "string"
               then "systemMessage that is not a string" | warn($name) else empty end])}
     end]
  | ([.[] | .block | strings]) as $blocks
  | ([.[] | select(.block == null) | .ctx | strings]) as $ctx
  | ([.[] | select(.block == null) | .ask | strings]) as $asks
  | ([.[] | .sys | strings]) as $sys
  | ([.[] | .notes[]]) as $notes
  | ([$asks[] | select(length > 0)] | join("\n\n")) as $askr
  | (if ($sys | length) > 0 then [$sys | join("\n")] else [] end) as $sysp
  | if ($blocks | length) > 0 then
      {rc: 2, out: "",
       err: ($blocks
             + (if ($ctx + [$askr | select(length > 0)] + $sysp | length) > 0
                then ["Also from seyag hooks:\n" + ($ctx + [$askr | select(length > 0)] + $sysp | join("\n\n"))]
                else [] end)
             + (if ($notes | length) > 0 then [$notes | join("\n")] else [] end)
             | join("\n\n"))}
    else
      ((if $ctxok and ($ctx | length) > 0 then {additionalContext: ($ctx | join("\n\n"))} else {} end)
       + (if ($asks | length) > 0 then {permissionDecision: "ask", permissionDecisionReason: $askr} else {} end)) as $hso
      | {rc: 0,
         err: ((if ($ctxok | not) and ($ctx | length) > 0 then [$ctx | join("\n\n")] else [] end) + $notes | join("\n")),
         out: ((if ($sys | length) > 0 then {systemMessage: ($sys | join("\n"))} else {} end)
               + (if $hso != {} then {hookSpecificOutput: ({hookEventName: $ev} + $hso)} else {} end)
               | if . == {} then "" else tojson end)}
    end
  | @sh "RC=\(.rc) MERGED_ERR=\(.err) MERGED_OUT=\(.out)"' 2>/dev/null) || MERGED=""

if [ -n "$MERGED" ] && eval "$MERGED"; then
  [ -z "$MERGED_ERR" ] || printf '%s\n' "$MERGED_ERR" >&2
  [ -z "$MERGED_OUT" ] || printf '%s\n' "$MERGED_OUT"
  cat "$WORK/notes" >&2
  exit "$RC"
fi
# The merge itself failed: keep the exit-2 blocks rather than fail open on them,
# joined by a blank line as the merge would join them.
blocked=0 text=""
for n in "${!RUN[@]}"; do
  if [ "${RCS[n]}" = 2 ]; then
    blocked=1
    t=$(cat "$WORK/$n.err")
    [ -z "$t" ] || text+="${text:+$'\n\n'}$t"
  fi
done
[ -z "$text" ] || printf '%s\n' "$text" >&2
cat "$WORK/notes" >&2
[ "$blocked" = 0 ] || exit 2
exit 0
