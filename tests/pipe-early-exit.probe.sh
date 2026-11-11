#!/bin/bash
# Under pipefail, a reader that exits before EOF (grep -q/-m/-l, head) can kill
# a writer that is still writing with SIGPIPE (exit 141), so a passing check
# reads as failed. Capture first: out=$(cmd) && grep -q PAT <<<"$out".
# Scope: tests/*.sh and plugins/seyag/hooks/*.probe.sh (this file excluded).
# Scan mechanics, and the tradeoffs they pick:
# - Physical lines are joined into one unit while they end in `\` or `|`, so a
#   reader on the far side of a continued pipe is seen. Tradeoff: a unit reports
#   once, at its first line, not once per matching interior line.
# - Comment units (first non-blank character `#`) are skipped. A comment line
#   never starts a unit, and never ends a `|`-continuation (it is consumed —
#   dropped from the matched text, as at unit level — and the join keeps
#   going); it does end a `\`-continuation (backslash-newline elision puts it
#   on the command's own line, where it comments out the rest and the next
#   line is a new command).
# - Quoted spans are stripped before matching: single-quoted spans always (their
#   text is literal; outside quotes a backslash escapes the next character, so
#   the '\'' idiom is three tokens, never one span), double-quoted spans only
#   when they hold no `$` or backtick (a "$(...)" inside double quotes does run,
#   so it stays). A line whose quotes cannot be judged that way (unterminated,
#   $/backtick inside double quotes, or $' ANSI-C quoting) is matched verbatim:
#   such a hit that is quoted fixture text should be rephrased; a real one
#   fixed as above.
# - `printf ... | head -N | ...` is not reported: printf is a bounded builtin
#   write and the idiom is display truncation whose status is discarded. The
#   exemption needs the head's writer to be one simple printf command: once a
#   `;`, `|` or `&` is crossed to reach it, parens end the exemption (earlier
#   writers inside a group are unbounded); with nothing crossed, `$(`-context
#   before printf and one wrapping group `)` stay exempt. A head piping onward
#   from any other writer still reports.
# Usage: tests/pipe-early-exit.probe.sh   (from anywhere)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]##*/}"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# (A) a pipe into a grep (egrep/fgrep included) that stops early (-q, -m, -l,
# --quiet/--silent/--max-count/--files-with-matches), allowing /usr/bin/,
# command, env (bare, or with short options and their args), timeout (-k N
# allowed, plain or unit-suffixed durations like 1m30s), nice, stdbuf, xargs
# and VAR=value prefixes (stackable) before the reader; (B) a head that pipes
# onward.
RE_A='(^|[^|])\|&?[[:space:]]*((/usr/bin/|command[[:space:]]+|env[[:space:]]+(-[A-Za-z0-9=]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*|timeout[[:space:]]+(-k[[:space:]]+[^[:space:]]+[[:space:]]+)*[0-9]+([.][0-9]+)?([a-z]+[0-9]+)*[a-z]*[[:space:]]+|nice[[:space:]]+(-[A-Za-z0-9]+([[:space:]]+[^[:space:]]+)?[[:space:]]+)*|stdbuf[[:space:]]+(-[A-Za-z0-9=]+([[:space:]]+[^[:space:]]+)?[[:space:]]+)*|xargs[[:space:]]+|([[:alpha:]_][[:alnum:]_]*=[^[:space:]\|;&]*[[:space:]]+))*)[ef]?grep[[:space:]]([^|;&]*[[:space:]])?(-[a-zA-Z0-9]*[qml][a-zA-Z0-9]*|--files-with-matches|--quiet|--silent|--max-count(=|[[:space:]]))'
RE_B='(^|[^|])\|[[:space:]]*head([[:space:]][^|]*)?\|[^|]'
seps='*[;|&]'
# RE_P*: the head's writer is one simple printf command. RE_P1 after crossing
# a ; | & (what came before it wrote too, so no parens may remain); RE_P2 when
# nothing was crossed (then ( was stripped for $( or a wrapping group, and one
# trailing ) is allowed).
RE_P1='^[[:space:]]*printf([[:space:]][^;|&()]*)?[[:space:]]*$'
RE_P2='^[[:space:]]*printf([[:space:]][^;|&()]*)?[[:space:]]*\)?[[:space:]]*$'
dl='$'
bt='`'

# strip_quotes LINE: echo LINE with quoted spans replaced by a space, per the
# header rules (outside quotes a backslash escapes the next char, both kept,
# so the '\'' idiom is span, \', span — never one span); a line with a span
# that cannot be judged or closed, or holding $' ANSI-C quoting, is echoed
# unchanged so its pipes stay visible to the patterns.
strip_quotes() {
  local s=$1 out='' i=0 n=${#1} c j closed span
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ "$c" = '\' ]; then  # unquoted escape: both chars are literal
      if [ $((i+1)) -lt "$n" ]; then out+="$c${s:i+1:1}"; i=$((i+2)); else out+=$c; i=$((i+1)); fi
      continue
    fi
    if [ "$c" = "'" ] && [ "$i" -gt 0 ] && [ "${s:i-1:1}" = "$dl" ]; then printf '%s' "$1"; return; fi  # $': ANSI-C, unjudgeable
    if [ "$c" != "'" ] && [ "$c" != '"' ]; then out+=$c; i=$((i+1)); continue; fi
    j=$((i+1)); closed=''
    while [ "$j" -lt "$n" ]; do
      if [ "$c" = "'" ]; then
        if [ "${s:j:1}" = "'" ]; then closed=$j; break; fi  # a ' always closes
        j=$((j+1))
      else
        if [ "${s:j:1}" = '\' ]; then j=$((j+2)); continue; fi  # \" (or \\)
        if [ "${s:j:1}" = '"' ]; then closed=$j; break; fi
        j=$((j+1))
      fi
    done
    [ -n "$closed" ] || { printf '%s' "$1"; return; }
    span=${s:i:closed+1-i}
    if [ "$c" = '"' ] && [[ "$span" == *"$dl"* || "$span" == *"$bt"* ]]; then out+=$span; else out+=' '; fi
    i=$((closed+1))
  done
  printf '%s' "$out"
}

# scan FILE...: print path:firstline for each unit whose quoted-stripped text
# matches (A), or matches (B) with a writer other than printf. Units are joined
# per the header; only units holding both a pipe and a grep/head after it pay
# the strip. Matching itself runs in grep -E (a linear DFA; bash's capturing
# matcher backtracks badly on the prefix alternation), one stripped line per
# candidate unit, the line number carried alongside.
scan() {
  local f first n unit txt idx sn hit rest m pre w
  local -a lines units
  for f in "$@"; do
    mapfile -t lines < "$f"
    idx=0; n=0; units=()
    while [ "$idx" -lt "${#lines[@]}" ]; do
      n=$((n+1)); unit=${lines[idx]}; first=$n; idx=$((idx+1))
      [[ "$unit" =~ ^[[:space:]]*# ]] && continue
      while [ "$idx" -lt "${#lines[@]}" ]; do
        case "$unit" in
          *\\) unit=${unit%\\}; unit+=$' '${lines[idx]}; n=$((n+1)); idx=$((idx+1)) ;;
          *\|) while [ "$idx" -lt "${#lines[@]}" ] && [[ "${lines[idx]}" =~ ^[[:space:]]*# ]]; do
                 n=$((n+1)); idx=$((idx+1))  # comment line: dropped, never ends a pipe
               done
               [ "$idx" -lt "${#lines[@]}" ] || break
               unit+=$' '${lines[idx]}; n=$((n+1)); idx=$((idx+1)) ;;
          *) break ;;
        esac
      done
      case "$unit" in
        *\|*grep*|*\|*head*) txt=$(strip_quotes "$unit"); units+=("$first:$txt") ;;
      esac
    done
    while IFS= read -r hit; do
      sn=${hit%%:*}
      txt=${units[sn-1]#*:}
      if printf '%s\n' "$txt" | grep -qE -e "$RE_A"; then
        echo "$f:${units[sn-1]%%:*}"; continue
      fi
      rest=$txt
      while [[ "$rest" =~ $RE_B ]]; do
        m=${BASH_REMATCH[0]}
        pre=${rest%%"$m"*}
        w=${pre##*$seps}
        if [ "$w" != "$pre" ]; then
          # crossed a ; | &: what came before may have written too, so the
          # tail must be paren-free (RE_P1) to stay exempt
          [[ "$w" =~ $RE_P1 ]] || { echo "$f:${units[sn-1]%%:*}"; break; }
        else
          w=${pre##*'('}
          [[ "$w" =~ $RE_P2 ]] || { echo "$f:${units[sn-1]%%:*}"; break; }
        fi
        rest=${rest#*"$m"}
      done
    done < <(printf '%s\n' "${units[@]}" | grep -nE -e "$RE_A" -e "$RE_B")
  done
}

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Controls: units at fixture lines 1-24, 33, 35, 37, 38, 40-42, 49 and 50-55
# must be flagged (the
# original reader forms plus -l/--files-with-matches, egrep/fgrep, the env
# (incl. -i/-u VAR), timeout (incl. -k N and 1m30s), nice, stdbuf, xargs and
# VAR= prefixes incl. a stack, split-line pipes at 21-22 and
# 23-24, a "$(...)" inside double quotes at 33, a non-printf head piping onward
# at 35, -El at 37, a '\'' idiom unit whose pipe survives the strip at 38, a
# comment inside a pipe continuation at 40-42, and a group holding an
# unbounded writer before printf at 49); lines 25-32, 34, 36, 39, 43-45 and
# 46-48 must not: ||, a here-string, a trailing head in $(), grep -c, a
# comment, && grep, quoted spans stripped (single at 31, double at 32), the
# printf display truncation at 34, a trailing head at 36, the same idiom
# wholly inside quoted fixture text at 39, a comment ending a backslash
# continuation at 43-45, and printf as the head's writer in $()-context, with
# a } in kept args, and wrapped in a single-command group at 46-48.
FX="$TMP/fixture.sh"
cat >"$FX" <<'EOF'
git rev-list --walk-reflogs HEAD 2>/dev/null | grep -qx "$C" \
  | grep -qx 'MM a\.txt'
out | grep -Eq 'x'
cmd | head -n 1 | grep -E x
cmd | grep --quiet x
cmd |& grep -q x
cmd | grep -m1 x
cmd | grep -m 1 x
cmd | command grep -q x
cmd | grep -A1q x
cmd | grep --max-count=1 x
cmd | grep -l x
cmd | grep --files-with-matches x
cmd | egrep -q x
cmd | fgrep -m1 x
cmd | env grep -q x
cmd | timeout 5 grep -q x
cmd | xargs grep -q x
cmd | LC_ALL=C grep -q x
cmd | env LC_ALL=C timeout 3 grep -q x
cmd \
  | grep -q x
cmd |
  grep --silent x
[ -e f ] || grep -q x f
grep -qx "$C" <<<"$out"
v=$(cmd | head -n 1)
cmd | grep -c x
  # a comment naming `cmd | grep -q x` is prose, not a pipe
cmd | grep x && grep -q y f
echo 'cmd | grep -q x' >"$T/f"
expect_allow "env | grep -m 5 -c X" "env | grep -m 5 -c X"
out="$(cmd | grep -q x)"
printf '%s\n' "$OUT" | head -5 | sed 's/^/ /'
cmd | head -5 | sed 's/^/ /'
cmd | head -1
cmd | grep -El x
f 'a'\''b' | grep -q x 'y'\''z'
run check 'a'\''b | grep -q x'
printf '%s' big |
  # a comment never ends a pipe continuation
  grep -q x
printf '%s' big \
  # a comment does end a backslash continuation
  grep -q x
v=$(printf '%s\n' big | head -5 | cut -c1-20)
printf '%s' "a${v}b}" | head -5 | sed 's/x/y/'
( printf '%s' big ) | head -5 | sed 's/x/y/'
( yes x; printf done ) | head -5 | sed 's/x/y/'
cmd | env -i grep -q x
cmd | env -u VAR grep -q x
cmd | timeout -k 2 5 grep -q x
cmd | timeout 1m30s grep -q x
cmd | nice -n 5 grep -q x
cmd | stdbuf -oL grep -q x
EOF
got=""
while IFS= read -r hit; do got+="${hit##*:} "; done < <(scan "$FX")
want='1 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 23 33 35 37 38 40 49 50 51 52 53 54 55 '
[ "$got" = "$want" ] \
  && ok "controls: units 1-24, 33, 35, 37, 38, 40, 49, 50-55 flagged (grep -qx, continuation, -Eq, head onward, --quiet, |&, -m1, -m 1, command grep, -A1q, --max-count, -l, --files-with-matches, egrep, fgrep, env -i/-u, timeout -k/1m30s, nice, stdbuf, xargs/VAR= prefixes and a stack, split-line pipe, split-line --silent, \"\$(cmd | grep -q x)\" in double quotes, non-printf head onward, -El, '\''-idiom pipe, comment in a pipe continuation, unbounded writer before printf in a group) and 25-32, 34, 36, 39, 43-48 (|| grep -q, here-string, head in \$(), grep -c, comment, && grep -q, single/double-quoted spans, printf display truncation, trailing head, '\''-idiom fixture text, comment ends a backslash continuation, printf writer in \$()-context/with } in kept args/in a single-command group) not" \
  || bad "controls: flagged lines '${got% }', expected '${want% }'"

# The tree: no scanned file pipes into an early-exit reader.
files=("$ROOT"/tests/*.sh "$ROOT"/plugins/seyag/hooks/*.probe.sh)
[ -e "$ROOT/tests/keys.probe.sh" ] || bad "no tests/*.sh files found under $ROOT"
[ -e "$ROOT/plugins/seyag/hooks/session-start.probe.sh" ] || bad "no plugins/seyag/hooks/*.probe.sh found under $ROOT"
hits=()
for f in "${files[@]}"; do
  [ "${f##*/}" = "$SELF" ] && continue
  while IFS= read -r h; do hits+=("${h#"$ROOT"/}"); done < <(scan "$f")
done
if [ "${#hits[@]}" -eq 0 ]; then
  ok "no tests/*.sh or plugins/seyag/hooks/*.probe.sh unit pipes into grep -q/-m/-l (egrep/fgrep included) or a head that pipes onward"
else
  bad "early-exit reader on a pipe in tests/*.sh or plugins/seyag/hooks/*.probe.sh (fix: out=\$(cmd) && grep -q PAT <<<\"\$out\"; quoted fixture text the skip cannot judge: rephrase it):"
  printf '      %s\n' "${hits[@]}"
fi

[ "$fail" -eq 0 ]
