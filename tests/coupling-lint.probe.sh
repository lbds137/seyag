#!/bin/bash
# Machine-coupling lint: this repo must not quietly grow references to this
# machine (personal paths, the owner's name, dev-docs tools). Every allowed
# reference is licensed by a line in tests/coupling-allowlist.txt; the probe
# fails on a NEW reference with no entry, and on an entry whose reference
# died. Usage: tests/coupling-lint.probe.sh   (from anywhere)
# A machine's own home path is guarded machine-side (a staged-content terms
# list), not by a hardcoded token here; TOKENS below are the portable ones.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW="tests/coupling-allowlist.txt"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TOKENS=('gdrive' 'lbds137' 'Lila' 'claude-role' \
  'deck-sessions' 'deck-doctor' 'claude-attach-cmd')
PATHSPEC=(':(exclude)tests/coupling-lint.probe.sh' ":(exclude)$ALLOW")
SEP=$'\x1f'   # token/path key separator; never occurs in a repo path

declare -A HITS SEEN FILES   # HITS["tok<SEP>path"]=matching-line count
total=0 n_new=0 n_stale=0 grep_failed=0

# Measured hits per token across TRACKED files only: git grep -F, fixed
# strings, excludes via pathspec. git grep's exit 1 just means "no matches"
# for that token — a zero-hit token simply needs no allowlist entries.
for tok in "${TOKENS[@]}"; do
  out="$(git -C "$REPO" -c core.quotePath=false grep -F -c "$tok" -- "${PATHSPEC[@]}")"
  rc=$?
  if [ "$rc" -ge 2 ]; then
    bad "git grep failed for $tok (rc=$rc)"
    grep_failed=1
    continue
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    HITS["$tok$SEP${row%:*}"]="${row##*:}"
  done <<< "$out"
done

# Read the allowlist: license entries, flag stale/malformed/duplicate ones.
if [ ! -f "$REPO/$ALLOW" ]; then
  bad "allowlist missing: $ALLOW"
else
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    tok="${line%%:*}"; path="${line#*:}"
    if [ "$path" = "$line" ] || [ -z "$tok" ] || [ -z "$path" ]; then
      bad "MALFORMED ALLOWLIST LINE $n: $line"
      continue
    fi
    key="$tok$SEP$path"
    if [ -n "${SEEN[$key]+x}" ]; then
      bad "MALFORMED ALLOWLIST LINE $n: $line (duplicate of an earlier entry)"
      continue
    fi
    SEEN[$key]=1
    c="${HITS[$key]:-0}"
    # A broken grep means zero hits everywhere is a measurement gap, not
    # rot: skip the STALE verdict (the grep failure already fails the run).
    if [ "$c" -eq 0 ] && [ "$grep_failed" -eq 0 ]; then
      n_stale=$((n_stale + 1))
      bad "STALE ENTRY: $tok in $path (0 hits) — remove it; the list may only shrink"
    else
      total=$((total + c)); FILES[$path]=1
    fi
  done < "$REPO/$ALLOW"
fi

# Anything with hits and no entry is new coupling.
for tok in "${TOKENS[@]}"; do
  for key in "${!HITS[@]}"; do
    case "$key" in "$tok$SEP"*) ;; *) continue ;; esac
    [ -n "${SEEN[$key]+x}" ] && continue
    n_new=$((n_new + 1))
    bad "NEW COUPLING: $tok in ${key#"$tok$SEP"} (${HITS[$key]} hits)"
  done
done

if [ "$fail" -ne 0 ]; then exit 1; fi
ok "coupling lint: $total allowlisted references across ${#FILES[@]} files, $n_new new, $n_stale stale"
