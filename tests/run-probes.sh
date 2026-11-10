#!/bin/bash
# Run every probe (plugins/seyag/hooks/*.probe.sh and tests/*.probe.sh).
# Prints PASS/FAIL per probe in suite order; exits non-zero if any probe fails.
# On failure the probe's own output is shown.
#
# Usage: tests/run-probes.sh [-j N | --jobs N] [--shard I/N] [--durations-out FILE]   (from anywhere)
#   -j N, --jobs N         run N probes at once (default 1; 0 = nproc)
#   --shard I/N            run only shard I of N (1 <= I <= N). Probes are split by
#                          the per-probe seconds in tests/probe-durations.tsv (a probe
#                          without a row counts as 10 s): sorted longest first, ties by
#                          repo-relative path, each given to the shard with the smallest
#                          running total, ties to the lowest shard number. The split
#                          depends only on the probe files and the table.
#   --durations-out FILE   after the run, write FILE in the probe-durations.tsv format:
#                          one row per probe that ran, in suite order, wall seconds
#                          (one decimal) from launch to result.
#                          Rules: with --shard it is a usage error (a shard's file would
#                          hold only that shard's rows); when any probe failed the file is
#                          not written and stderr says so.
# Probes always start longest-first (by the same table); output stays in suite order.

set -uo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "run-probes: needs bash >= 5.1 (found $BASH_VERSION)" >&2
  exit 2
fi

usage() {
  echo "Usage: tests/run-probes.sh [-j N | --jobs N] [--shard I/N] [--durations-out FILE]" >&2
  exit 2
}

JOBS=1
SHARD=""
SHARD_SET=""
DUR_OUT=""
DUR_OUT_SET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --shard)
      [ $# -ge 2 ] || usage
      SHARD="$2"
      SHARD_SET=1
      shift 2
      ;;
    --shard=*)
      SHARD="${1#--shard=}"
      SHARD_SET=1
      shift
      ;;
    --durations-out)
      [ $# -ge 2 ] || usage
      DUR_OUT="$2"
      DUR_OUT_SET=1
      shift 2
      ;;
    --durations-out=*)
      DUR_OUT="${1#--durations-out=}"
      DUR_OUT_SET=1
      shift
      ;;
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

SHARD_I=0
SHARD_N=0
if [ -n "$SHARD_SET" ]; then
  [[ "$SHARD" =~ ^([0-9]+)/([0-9]+)$ ]] || usage
  SHARD_I="${BASH_REMATCH[1]}"
  SHARD_N="${BASH_REMATCH[2]}"
  # Drop leading zeros, then cap at 9 digits so the arithmetic below cannot overflow.
  while [[ "$SHARD_I" == 0?* ]]; do SHARD_I="${SHARD_I#0}"; done
  while [[ "$SHARD_N" == 0?* ]]; do SHARD_N="${SHARD_N#0}"; done
  [ "${#SHARD_I}" -le 9 ] && [ "${#SHARD_N}" -le 9 ] || usage
  SHARD_I=$((10#$SHARD_I))
  SHARD_N=$((10#$SHARD_N))
  [ "$SHARD_N" -ge 1 ] && [ "$SHARD_I" -ge 1 ] && [ "$SHARD_I" -le "$SHARD_N" ] || usage
fi
[ -z "$DUR_OUT_SET" ] || [ -n "$DUR_OUT" ] || usage
[ -z "$DUR_OUT_SET" ] || [ -z "$SHARD_SET" ] || usage

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOKS="$REPO/plugins/seyag/hooks"
export PYTHONDONTWRITEBYTECODE=1

shopt -s nullglob
PROBES=("$HOOKS"/*.probe.sh "$REPO"/tests/*.probe.sh)
if [ ${#PROBES[@]} -eq 0 ]; then
  echo "no probes found under $HOOKS" >&2
  exit 1
fi

# Per-probe duration in tenths of a second, from tests/probe-durations.tsv
# (repo-relative path TAB seconds; blank and # lines skipped; a probe without a
# valid row counts as 10 s; rows for absent probes are ignored). The decimal is
# parsed as text in plain bash, so no floating point (and no tool beyond sort) is
# involved. ORDER ends up holding the probe indices longest first, ties by
# repo-relative path (C locale).
TAB=$'\t'
TOTAL=${#PROBES[@]}
REL=()
for p in "${PROBES[@]}"; do
  REL+=("${p#"$REPO"/}")
done
declare -A KNOWN=()
if [ -r "$REPO/tests/probe-durations.tsv" ]; then
  while IFS="$TAB" read -r key val _ || [ -n "$key" ]; do
    key=${key%$'\r'}
    val=${val%$'\r'}
    case "$key" in '' | '#'*) continue ;; esac
    [[ "$val" =~ ^([0-9]+)(\.([0-9]+))?$ ]] || continue
    ip="${BASH_REMATCH[1]}"
    fp="${BASH_REMATCH[3]}00"
    [ "${#ip}" -le 9 ] || continue
    KNOWN["$key"]=$((10#$ip * 10 + 10#${fp:0:1} + (10#${fp:1:1} >= 5 ? 1 : 0)))
  done <"$REPO/tests/probe-durations.tsv"
fi
ORDER=()
declare -A DT=()
while IFS="$TAB" read -r t _ idx; do
  ORDER+=("$idx")
  DT[$idx]=$t
done < <(
  for idx in "${!REL[@]}"; do
    r="${REL[$idx]}"
    printf '%s\t%s\t%s\n' "${KNOWN[$r]-100}" "$r" "$idx"
  done | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2
)
if [ "${#ORDER[@]}" -ne "$TOTAL" ]; then
  echo "run-probes: could not order the probes by duration" >&2
  exit 1
fi

# Keep[idx]=1 for each probe this run executes. Without --shard that is all of
# them; with it, walk the longest-first order and give each probe to the shard
# with the smallest running total (ties to the lowest shard number). Only the
# first TOTAL shards can ever receive a probe, so the scan is capped there.
declare -A KEEP=()
if [ -n "$SHARD_SET" ]; then
  scan=$SHARD_N
  [ "$scan" -le "$TOTAL" ] || scan=$TOTAL
  sums=()
  for ((s = 1; s <= scan; s++)); do sums[s]=0; done
  for idx in "${ORDER[@]}"; do
    best=1
    for ((s = 2; s <= scan; s++)); do
      [ "${sums[s]}" -ge "${sums[best]}" ] || best=$s
    done
    sums[best]=$((sums[best] + DT[$idx]))
    [ "$best" -ne "$SHARD_I" ] || KEEP[$idx]=1
  done
else
  for idx in "${!PROBES[@]}"; do KEEP[$idx]=1; done
fi

# Rebuild PROBES as the selected probes in suite order; LAUNCH lists their new
# indices in start order (longest first).
ALL_PROBES=("${PROBES[@]}")
PROBES=()
RELS=()
declare -A NEWIDX=()
for idx in "${!ALL_PROBES[@]}"; do
  [ -n "${KEEP[$idx]+x}" ] || continue
  NEWIDX[$idx]=${#PROBES[@]}
  PROBES+=("${ALL_PROBES[$idx]}")
  RELS+=("${REL[$idx]}")
done
LAUNCH=()
for idx in "${ORDER[@]}"; do
  [ -n "${KEEP[$idx]+x}" ] || continue
  LAUNCH+=("${NEWIDX[$idx]}")
done
if [ -n "$SHARD_SET" ]; then
  echo "run-probes: shard $SHARD_I/$SHARD_N: ${#PROBES[@]} of $TOTAL probes" >&2
fi

# Default ceiling: generous multiple (>=5x) of the slowest probe re-measured under parallel CI conditions, floor honored.
DEFAULT_PROBE_TIMEOUT=600
PT_SOURCE=default
if [ -z "${SYG_PROBE_TIMEOUT+x}" ]; then
  PT=$DEFAULT_PROBE_TIMEOUT
elif [[ "$SYG_PROBE_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$((10#$SYG_PROBE_TIMEOUT))" -gt 0 ]; then
  PT=$((10#$SYG_PROBE_TIMEOUT))
  PT_SOURCE=SYG_PROBE_TIMEOUT
else
  echo "run-probes: invalid SYG_PROBE_TIMEOUT='${SYG_PROBE_TIMEOUT}' (must be a positive integer); falling back to default ${DEFAULT_PROBE_TIMEOUT}s" >&2
  PT=$DEFAULT_PROBE_TIMEOUT
fi

TO=()
if command -v timeout >/dev/null 2>&1; then
  TO=(timeout -k 5 "$PT")
  echo "run-probes: probe timeout: ${PT}s per probe (${PT_SOURCE})" >&2
else
  echo "run-probes: no timeout binary on PATH; probes run without a per-probe limit" >&2
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
      if { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && [ "${#TO[@]}" -gt 0 ]; then
        echo "      (SIGTERM/SIGKILL after the ${PT}s per-probe ceiling — usually the timeout, but an external cancel looks the same; the probe's own output follows)"
      fi
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

for i in ${LAUNCH[@]+"${LAUNCH[@]}"}; do
  p="${PROBES[$i]}"
  (
    set -m
    t0=${EPOCHREALTIME//[.,]/}
    got_sig=""
    trap 'got_sig=1' TERM INT
    "${TO[@]+"${TO[@]}"}" bash "$p" </dev/null >"$TMP/$i.out" 2>&1 &
    child=$!
    trap 'kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM INT
    if [ -n "$got_sig" ]; then
      kill -TERM -- "-$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      exit 143
    fi
    wait "$child" 2>/dev/null
    rc=$?
    kill -TERM -- "-$child" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 -- "-$child" 2>/dev/null || break
      sleep 0.02
    done
    if kill -0 -- "-$child" 2>/dev/null; then
      kill -KILL -- "-$child" 2>/dev/null || true
    fi
    t1=${EPOCHREALTIME//[.,]/}
    # Wall time in tenths of a second (EPOCHREALTIME is microseconds; its radix
    # character follows the locale, hence the [.,] strip), written before the rc
    # because the rc file is what marks the probe as finished.
    d=$(((10#$t1 - 10#$t0 + 50000) / 100000))
    echo "$((d / 10)).$((d % 10))" >"$TMP/$i.dur"
    echo "$rc" >"$TMP/$i.rc"
  ) 2>/dev/null &
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

if [ -n "$DUR_OUT" ] && [ ${#failed[@]} -gt 0 ]; then
  echo "run-probes: not writing $DUR_OUT: ${#failed[@]} probe(s) failed" >&2
elif [ -n "$DUR_OUT" ]; then
  {
    echo "# Probe wall times in seconds (written by run-probes --durations-out). run-probes --shard balances on these;"
    echo "# a probe missing here counts as 10 s. Refresh: bash tests/run-probes.sh -j 1 --durations-out tests/probe-durations.tsv"
    for i in "${!PROBES[@]}"; do
      [ -s "$TMP/$i.dur" ] || continue
      printf '%s\t%s\n' "${RELS[$i]}" "$(<"$TMP/$i.dur")"
    done
  } >"$DUR_OUT" || echo "run-probes: could not write $DUR_OUT" >&2
fi

echo "---"
echo "$pass passed, ${#failed[@]} failed (of ${#PROBES[@]})"
[ ${#failed[@]} -eq 0 ]
