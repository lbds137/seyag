#!/bin/bash
# Run every probe (plugins/seyag/hooks/*.probe.sh and tests/*.probe.sh).
# Prints PASS/FAIL per probe in suite order; exits non-zero if any probe fails.
# On failure the probe's own output is shown.
#
# Usage: tests/run-probes.sh [-j N | --jobs N]   (from anywhere)
#   -j N, --jobs N   run N probes at once (default 1; 0 = nproc)

set -uo pipefail

usage() {
  echo "Usage: tests/run-probes.sh [-j N | --jobs N]" >&2
  exit 2
}

JOBS=1
while [ $# -gt 0 ]; do
  case "$1" in
    -j | --jobs)
      [ $# -ge 2 ] || usage
      JOBS="$2"
      shift 2
      ;;
    -j?*)
      JOBS="${1#-j}"
      shift
      ;;
    --jobs=*)
      JOBS="${1#--jobs=}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$JOBS" =~ ^[0-9]+$ ]] || usage
JOBS=$((10#$JOBS))
if [ "$JOBS" -eq 0 ]; then
  JOBS=$(nproc 2>/dev/null || echo 1)
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=1
fi

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOKS="$REPO/plugins/seyag/hooks"
export PYTHONDONTWRITEBYTECODE=1

shopt -s nullglob
PROBES=("$HOOKS"/*.probe.sh "$REPO"/tests/*.probe.sh)
if [ ${#PROBES[@]} -eq 0 ]; then
  echo "no probes found under $HOOKS" >&2
  exit 1
fi

TMP=$(mktemp -d) || exit 1
# PID -> probe index of jobs still running; a finished job leaves this set at
# once, so the trap never signals a PID the system may already have reused.
declare -A live=()
cleanup() {
  local rc=$?
  if [ ${#live[@]} -gt 0 ]; then
    kill "${!live[@]}" 2>/dev/null || true
    wait "${!live[@]}" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0
failed=()
next=0

flush_ready() {
  local name out rc
  while [ "$next" -lt "${#PROBES[@]}" ] && [ -s "$TMP/$next.rc" ]; do
    name=$(basename "${PROBES[$next]}" .probe.sh)
    rc=$(<"$TMP/$next.rc")
    if [ "$rc" -eq 0 ]; then
      echo "PASS  $name"
      pass=$((pass + 1))
    else
      out=$(<"$TMP/$next.out")
      echo "FAIL  $name (exit $rc)"
      printf '%s\n' "$out" | sed 's/^/      /'
      failed+=("$name")
    fi
    next=$((next + 1))
  done
}

# Wait for any one probe job (bash >= 5.1 for -p), drop it from `live`, then
# print whatever is now ready in suite order. A job that died before writing
# its .rc (killed, OOM) gets its wait status recorded instead, never 0, so it
# reads as FAIL rather than vanishing from the summary.
reap_one() {
  local fin="" st idx
  wait -n -p fin "${!live[@]}" 2>/dev/null
  st=$?
  if [ -z "$fin" ]; then
    echo "run-probes: wait returned no job (status $st); aborting" >&2
    exit 1
  fi
  idx=${live[$fin]}
  unset "live[$fin]"
  if [ ! -s "$TMP/$idx.rc" ]; then
    [ "$st" -ne 0 ] || st=1
    echo "$st" >"$TMP/$idx.rc"
  fi
  flush_ready
}

for i in "${!PROBES[@]}"; do
  p="${PROBES[$i]}"
  (
    child=""
    trap 'if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 143' TERM INT
    bash "$p" </dev/null >"$TMP/$i.out" 2>&1 &
    child=$!
    wait "$child"
    echo "$?" >"$TMP/$i.rc"
  ) &
  live[$!]=$i
  if [ ${#live[@]} -ge "$JOBS" ]; then
    reap_one
  fi
done

while [ ${#live[@]} -gt 0 ]; do
  reap_one
done
flush_ready
# Belt and braces: any probe still unprinted has no result, which is a FAIL.
while [ "$next" -lt "${#PROBES[@]}" ]; do
  name=$(basename "${PROBES[$next]}" .probe.sh)
  echo "FAIL  $name (no result)"
  failed+=("$name")
  next=$((next + 1))
done

echo "---"
echo "$pass passed, ${#failed[@]} failed (of ${#PROBES[@]})"
[ ${#failed[@]} -eq 0 ]
