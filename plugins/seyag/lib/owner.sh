# shellcheck shell=bash
# lib/owner.sh — owner-tracking helpers sourced by seyag bin watchers (sourced, not run).

# Owner tracking for long-running watchers: a watcher started by a Claude session should exit when
# that session dies instead of polling on as an orphan.
#   owner_default        print the PID of the nearest Claude session process above this shell
#                        (a claude binary that isn't the daemon or a pty host), or nothing when the
#                        caller is a plain terminal
#   owner_init PID       remember PID (and its start time, so a reused PID doesn't count) as owner;
#                        an empty PID means no owner
#   owner_alive          true while the owner runs, or always when there is none; false at once
#                        for a PID that wasn't running at owner_init
#   owner_or_exit        exit 3 with a stderr line once the owner is gone (3, not 0: for a waiter,
#                        0 means "the condition happened")
#   caller_label [NAME]  print NAME, else the basename of CLAUDE_JOB_DIR, else the basename of the cwd
# A watcher takes `--owner PID` (default: owner_default) and calls owner_or_exit after each sleep.
# /proc/PID/stat fields after the ")" that closes comm (comm may hold spaces): $1 state, $2 ppid,
# $20 start time.
_stat() { local s; s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; printf '%s\n' "${s##*) }"; }
owner_default() {
  local p=$PPID exe sub
  while [ "${p:-0}" -gt 1 ]; do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
      */claude/versions/*|*/bin/claude)
        # argv[1] alone: a session's prompt text may contain "daemon" too
        sub=$(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | sed -n 2p)
        case "$sub" in daemon|bg-pty-host) ;; *) echo "$p"; return ;; esac ;;
    esac
    p=$(_stat "$p" | awk '{print $2}')
  done
}
owner_init() {
  OWNER=${1:-}; OWNER_START=""
  case "$OWNER" in *[!0-9]*) echo "$(basename "$0"): --owner needs a PID, got '$OWNER'" >&2; exit 2 ;; esac
  [ -n "$OWNER" ] && OWNER_START=$(_stat "$OWNER" | awk '{print $20}')
  return 0
}
owner_alive() {
  [ -z "$OWNER" ] && return 0
  # A zombie still has its /proc entry and start time: state Z counts as gone.
  [ -n "$OWNER_START" ] && [ "$(_stat "$OWNER" | awk '$1 != "Z" {print $20}')" = "$OWNER_START" ]
}
owner_or_exit() {
  owner_alive && return 0
  echo "$(basename "$0"): owner $OWNER is gone, exiting" >&2
  exit 3
}

# Who a long-job unit is for: caller_label [NAME] prints NAME when given, else the basename of
# CLAUDE_JOB_DIR, else the basename of the cwd. A name, never a secret.
caller_label() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"
  elif [ -n "${CLAUDE_JOB_DIR:-}" ]; then basename "$CLAUDE_JOB_DIR"
  else basename "$PWD"; fi
}
