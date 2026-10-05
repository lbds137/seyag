#!/bin/bash
# Component resolver for seyag hooks. Sourced (by run.sh and session-start.sh),
# never executed. Defines:
#   syg_enabled <hook-or-component>   exit 0 = enabled, 1 = disabled
#
# Reads components.tsv (next to run.sh) once; pure bash, no jq or python, because
# run.sh fires on every tool call. Order: SYG_PROFILE picks the base set (unset,
# empty or unknown = full); SYG_ENABLE adds components or hook names; SYG_DISABLE
# removes them and wins over ENABLE; both are whitespace- or comma-separated and
# ignore unknown names. The `session` component cannot be disabled. In a headless
# run (CLAUDE_CODE_ENTRYPOINT=sdk-*) the components in SYG_HEADLESS_OFF are removed
# last, so SYG_ENABLE cannot bring them back. A missing or unreadable registry, a
# registry with no `full` line, a name it does not list (or lists with an empty
# component) and a component that `full` does not list (`full` defines the
# universe) all mean enabled, SYG_DISABLE unconsulted: fail toward the
# guards being on. The one exception is headless: there SYG_HEADLESS_OFF_HOOKS (the
# hooks of the SYG_HEADLESS_OFF components, pinned equal to the registry by
# tests/hook-wiring.probe.sh) stay off even when the registry cannot be used.
# SYG_PROFILE is trimmed of surrounding whitespace; a trailing CR on a registry
# line (CRLF file) is stripped. Sourcing this file must not change shell options.

SYG_HEADLESS_OFF="turn-shape context"
SYG_HEADLESS_OFF_HOOKS="blocking-question-channel-check turn-end-shape-gate promise-ledger-check queued-message-receipt bare-token-binding-reminder context-size-reminder"
# No subshell or dirname here (each is a fork on every tool call); a source path
# without a slash resolves against the cwd, and a miss just means "all enabled".
case "${BASH_SOURCE[0]}" in
  */*) SYG_COMPONENTS_TSV="${BASH_SOURCE[0]%/*}/../components.tsv" ;;
  *) SYG_COMPONENTS_TSV="../components.tsv" ;;
esac

# _syg_has "<list>" name: is name in a whitespace/comma separated list?
_syg_has() {
  local list=" ${1//[$',\t\n']/ } " # comma, tab and newline each become a space
  case "$list" in *" $2 "*) return 0 ;; esac
  return 1
}

# _syg_open name: the answer when the registry cannot decide. Enabled, except a
# hook of the headless-off components in a headless run.
# On these registry-can't-decide paths SYG_DISABLE is not consulted.
_syg_open() {
  if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == sdk-* ]] && _syg_has "$SYG_HEADLESS_OFF_HOOKS" "$1"; then
    return 1
  fi
  return 0
}

syg_enabled() {
  local q=$1 tsv=$SYG_COMPONENTS_TSV prof=${SYG_PROFILE:-}
  local kind a b comp="" sel="" full="" have_sel=0 have_full=0 listed=0
  [ -n "$q" ] || return 0
  [ "$q" = session ] || [ "$q" = session-start ] && return 0
  prof=${prof#"${prof%%[![:space:]]*}"}
  prof=${prof%"${prof##*[![:space:]]}"}
  [ -r "$tsv" ] || { _syg_open "$q"; return; }

  while IFS=$'\t' read -r kind a b || [ -n "$kind" ]; do
    kind=${kind%$'\r'} a=${a%$'\r'} b=${b%$'\r'}
    case "$kind" in
      '' | '#'*) continue ;;
      @profile)
        [ "$a" = full ] && { full=$b; have_full=1; }
        [ -n "$prof" ] && [ "$a" = "$prof" ] && { sel=$b; have_sel=1; }
        ;;
      "$q") listed=1; [ -n "$a" ] && comp=$a ;;
    esac
  done <"$tsv"

  [ "$have_full" = 1 ] || { _syg_open "$q"; return; }
  [ "$have_sel" = 1 ] || sel=$full
  # q is a hook (its component came from the registry) or a component name.
  if [ -z "$comp" ]; then
    # A hook line with an empty component column counts as unlisted.
    [ "$listed" = 1 ] && { _syg_open "$q"; return; }
    _syg_has "$full" "$q" || { _syg_open "$q"; return; }
    comp=$q
  fi
  [ "$comp" = session ] && return 0
  # `full` defines the universe: a component it does not list is enabled, and
  # SYG_DISABLE is not consulted (tsv-off-full in tests/hook-wiring.probe.sh keeps
  # this path unreachable for real hooks).
  _syg_has "$full" "$comp" || { _syg_open "$q"; return; }

  local on=1
  _syg_has "$sel" "$comp" || on=0
  if [ "$on" = 0 ]; then
    { _syg_has "${SYG_ENABLE:-}" "$comp" || _syg_has "${SYG_ENABLE:-}" "$q"; } && on=1
  fi
  if _syg_has "${SYG_DISABLE:-}" "$comp" || _syg_has "${SYG_DISABLE:-}" "$q"; then on=0; fi
  if [[ "${CLAUDE_CODE_ENTRYPOINT:-}" == sdk-* ]] && _syg_has "$SYG_HEADLESS_OFF" "$comp"; then on=0; fi
  [ "$on" = 1 ]
}
