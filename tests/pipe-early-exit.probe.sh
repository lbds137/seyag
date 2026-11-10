#!/bin/bash
# Under pipefail, a reader that exits before EOF (grep -q, head) can kill a writer
# that is still writing with SIGPIPE (exit 141), so a passing check reads as failed.
# Capture first: out=$(cmd) && grep -q PAT <<<"$out".
# Usage: tests/pipe-early-exit.probe.sh   (from anywhere)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]##*/}"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# (A) a pipe into a quiet grep; (B) a head that pipes onward.
RE_A='(^|[^|])\|[[:space:]]*(/usr/bin/)?grep[[:space:]]([^|]*[[:space:]])?(-[a-zA-Z]*q[a-zA-Z]*|--quiet|--silent)([[:space:]]|$)'
RE_B='(^|[^|])\|[[:space:]]*head([[:space:]][^|]*)?\|[^|]'

# scan FILE...: print path:line for each line either pattern matches; comment lines
# (first non-blank character `#`) are skipped.
scan() {
  local f n line
  for f in "$@"; do
    while IFS=: read -r n line; do
      [[ $line =~ ^[[:space:]]*# ]] && continue
      echo "$f:$n"
    done < <(grep -nE -e "$RE_A" -e "$RE_B" "$f")
  done
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Controls: the first five fixture lines must be flagged, the last five must not.
FX="$TMP/fixture.sh"
cat >"$FX" <<'EOF'
git rev-list --walk-reflogs HEAD 2>/dev/null | grep -qx "$C" \
  | grep -qx 'MM a\.txt' \
out | grep -Eq 'x'
cmd | head -n 1 | grep -E x
cmd | grep --quiet x
[ -e f ] || grep -q x f
grep -qx "$C" <<<"$out"
v=$(cmd | head -n 1)
cmd | grep -c x
  # a comment naming `cmd | grep -q x` is prose, not a pipe
EOF
got=""
while IFS= read -r hit; do got+="${hit##*:} "; done < <(scan "$FX")
[ "$got" = "1 2 3 4 5 " ] \
  && ok "controls: lines 1-5 (grep -qx, continuation, -Eq, head onward, --quiet) flagged and 6-10 (|| grep -q, here-string, head in \$(), grep -c, comment) not" \
  || bad "controls: flagged lines '${got% }', expected '1 2 3 4 5'"

# The tree: no tests/*.sh file pipes into an early-exit reader.
files=("$ROOT"/tests/*.sh)
[ "${#files[@]}" -gt 0 ] && [ -e "${files[0]}" ] || bad "no tests/*.sh files found under $ROOT"
hits=()
for f in "${files[@]}"; do
  [ "${f##*/}" = "$SELF" ] && continue
  while IFS= read -r h; do hits+=("${h#"$ROOT"/}"); done < <(scan "$f")
done
if [ "${#hits[@]}" -eq 0 ]; then
  ok "no tests/*.sh line pipes into grep -q or a head that pipes onward"
else
  bad "early-exit reader on a pipe (fix: out=\$(cmd) && grep -q PAT <<<\"\$out\"):"
  printf '      %s\n' "${hits[@]}"
fi

[ "$fail" -eq 0 ]
