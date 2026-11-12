#!/bin/bash
# Under pipefail, a reader that exits before EOF (grep -q/-m/-l/-L, head) can
# kill a writer that is still writing with SIGPIPE (exit 141), so a passing
# check reads as failed. Capture first: out=$(cmd) && grep -q PAT <<<"$out".
# Scope: tests/*.sh and plugins/seyag/hooks/*.probe.sh (this file excluded).
# Scan mechanics, and the tradeoffs they pick:
# - Physical lines are joined into one unit while they end in `\` or `|`/`|&`,
#   so a reader on the far side of a continued pipe is seen. The `|`/`|&` end
#   test runs on the unit's normalized form (quoted spans stripped, a trailing
#   unquoted comment cut where the strip reports the first unquoted word-start
#   `#` — a `#` inside a judged span or right after an escape pair is literal,
#   never a comment — and dropped, trailing whitespace trimmed); a form the
#   strip cannot judge is tested verbatim (conservative no-join on odd
#   shapes). The `\` end test runs on the raw ending: a `\` joins only on an
#   odd trailing-backslash run (`echo a\\` is an escaped backslash, not a
#   continuation; a `\` inside a judged span still joins — loud, not silent).
#   Tradeoff: a unit reports once, at its first line, not once per matching
#   interior line.
# - Comment units (first non-blank character `#`) are skipped. A comment line
#   never starts a unit, and never ends a `|`-continuation (it is consumed —
#   dropped from the matched text, as at unit level — and the join keeps
#   going); it does end a `\`-continuation (backslash-newline elision puts it
#   on the command's own line, where it comments out the rest and the next
#   line is a new command — the line is dropped and the join stops).
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
# -L, --quiet/--silent/--max-count/--files-with-matches/--files-without-match),
# with an optional opening group `(`, `[` or `{` right after the pipe, allowing
# /usr/bin/, command, env (bare, or with short options and their args), timeout
# (-k N allowed, plain or unit-suffixed durations like 1m30s), nice, stdbuf and
# VAR=value prefixes (stackable) before the reader — xargs is not a prefix
# worth flagging: it drains stdin to EOF, so its grep cannot SIGPIPE the
# writer; out of scope: timeout -s KILL / --foreground, env --, sudo, and the
# zgrep/rg/ugrep readers; (B) a head that pipes onward (|& accepted before
# it; the optional group form stays (A)-only).
RE_A='(^|[^|])\|&?[[:space:]]*([({][[:space:]]*)?((/usr/bin/|command[[:space:]]+|env[[:space:]]+(-[A-Za-z0-9=]+([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+)*|timeout[[:space:]]+(-k[[:space:]]+[^[:space:]]+[[:space:]]+)*[0-9]+([.][0-9]+)?([a-z]+[0-9]+)*[a-z]*[[:space:]]+|nice[[:space:]]+(-[A-Za-z0-9]+([[:space:]]+[^[:space:]]+)?[[:space:]]+)*|stdbuf[[:space:]]+(-[A-Za-z0-9=]+([[:space:]]+[^[:space:]]+)?[[:space:]]+)*|([[:alpha:]_][[:alnum:]_]*=[^[:space:]\|;&]*[[:space:]]+))*)[ef]?grep[[:space:]]([^|;&]*[[:space:]])?(-[a-zA-Z0-9]*[qmlL][a-zA-Z0-9]*|--files-with-matches|--files-without-match|--quiet|--silent|--max-count(=|[[:space:]]))'
RE_B='(^|[^|])\|&?[[:space:]]*head([[:space:]][^|;&)]*)?\|[^|]'
seps='*[;|&]'
# RE_P*: the head's writer is one simple printf command. RE_P1 after crossing
# a ; | & (what came before it wrote too, so no parens may remain); RE_P2 when
# nothing was crossed (then ( was stripped for $( or a wrapping group, and one
# trailing ) is allowed). The exemption assumes printf's output stays under
# the pipe buffer (~64 KiB): a larger write can still SIGPIPE the writer.
# Conservative forms that fail loudly and stay: `2>&1` before the pipe (the
# writer class splits at `&`, so it reads `1 `, not printf, and the unit
# reports), and `do`/`then`/`{`/`!` heads before printf (the writer text then
# starts with the head, not printf). Rare: a quote opened on one physical
# line and closed on the next is judged per line and can invert pairing; the
# verbatim fallback covers it.
RE_P1='^[[:space:]]*printf([[:space:]][^;|&()]*)?[[:space:]]*$'
RE_P2='^[[:space:]]*printf([[:space:]][^;|&()]*)?[[:space:]]*\)?[[:space:]]*$'
dl='$'
bt='`'

# strip_quotes LINE: set SQ_OUT to LINE with quoted spans replaced by a space,
# per the header rules (outside quotes a backslash escapes the next char, both
# kept, so the '\'' idiom is span, \', span — never one span); a line with a
# span that cannot be judged or closed, or holding $' ANSI-C quoting, is
# returned unchanged (SQ_OUT = LINE) so its pipes stay visible to the patterns.
# Returns via a variable, not stdout: the join loop and the match gate both
# call it per unit, and a $(...) there would fork per call.
strip_quotes() {
  SQ_OUT=$1
  SQ_CMT=-1; SQ_CMT_N=-1
  local s=$1 out='' i=0 n=${#1} c j closed span ra rb rq d len h base rel k
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ "$c" = '\' ]; then  # unquoted escape: both chars are literal
      if [ $((i+1)) -lt "$n" ]; then out+="$c${s:i+1:1}"; i=$((i+2)); else out+=$c; i=$((i+1)); fi
      continue
    fi
    if [ "$c" = "'" ] && [ "$i" -gt 0 ] && [ "${s:i-1:1}" = "$dl" ]; then return; fi  # $': ANSI-C, unjudgeable
    if [ "$c" != "'" ] && [ "$c" != '"' ]; then
      # batch the ordinary run up to the next ', " or \ (first-occurrence
      # scans; each equals its input length when its char is absent, and the
      # run starts on an ordinary char so d is never 0). Within the run, the
      # first word-start # begins a comment (bash: unquoted, and either at the
      # line start or after an unquoted space/tab — a # right after a span or
      # an escape pair continues a word; a run never starts right after an
      # ordinary char since consecutive ordinary chars batch into one run, so
      # only a line-start # qualifies at a run's first position):
      # record its raw offset (SQ_CMT) and normalized offset (SQ_CMT_N).
      ra=${s:i}; ra=${ra%%\'*}
      rb=${s:i}; rb=${rb%%\\*}
      rq=${s:i}; rq=${rq%%\"*}
      d=${#ra}; [ "${#rb}" -lt "$d" ] && d=${#rb}; [ "${#rq}" -lt "$d" ] && d=${#rq}
      if [ "$SQ_CMT" -lt 0 ] && [[ ${s:i:d} == *#* ]]; then
        h=${s:i:d}; base=0
        while [[ $h == *#* ]]; do
          rel=${h%%#*}; rel=${#rel}
          k=$((i + base + rel))
          if { [ "$rel" -eq 0 ] && [ "$i" -eq 0 ]; } || \
             { [ "$rel" -gt 0 ] && [[ "${s:k-1:1}" == [[:space:]] ]]; }; then
            SQ_CMT=$k; SQ_CMT_N=$(( ${#out} + base + rel ))
            break
          fi
          base=$((base + rel + 1)); h=${h:rel+1}
        done
      fi
      out+=${s:i:d}; i=$((i+d))
      continue
    fi
    j=$((i+1)); closed=''
    if [ "$c" = "'" ]; then
      ra=${s:j}; ra=${ra%%\'*}  # a ' always closes; no escapes inside
      closed=$((j+${#ra}))
      [ "${s:closed:1}" = "'" ] || return  # unterminated
    else
      while [ "$j" -lt "$n" ]; do
        rq=${s:j}; rq=${rq%%\"*}
        rb=${s:j}; rb=${rb%%\\*}
        len=$((n-j))
        if [ "${#rq}" -eq "$len" ] && [ "${#rb}" -eq "$len" ]; then return; fi
        if [ "${#rb}" -lt "${#rq}" ] && [ "${#rb}" -lt "$len" ]; then j=$((j+${#rb}+2)); continue; fi  # \" (or \\)
        closed=$((j+${#rq})); break  # the " comes first (or no \ remains)
      done
    fi
    [ -n "$closed" ] || return
    span=${s:i:closed+1-i}
    if [ "$c" = '"' ] && [[ "$span" == *"$dl"* || "$span" == *"$bt"* ]]; then out+=$span; else out+=' '; fi
    i=$((closed+1))
  done
  SQ_OUT=$out
}

# scan FILE...: print path:firstline for each unit whose quoted-stripped text
# matches (A), or matches (B) with a writer other than printf. Units are joined
# per the header; only units holding both a pipe and a grep/head after it pay
# the strip. Matching itself runs in grep -E (a linear DFA; bash's capturing
# matcher backtracks badly on the prefix alternation), one stripped line per
# candidate unit, the line number carried alongside.
scan() {
  local f first n unit txt idx sn hit rest m pre w ntest bstr
  local -a lines units
  for f in "$@"; do
    mapfile -t lines < "$f"
    idx=0; n=0; units=()
    while [ "$idx" -lt "${#lines[@]}" ]; do
      n=$((n+1)); unit=${lines[idx]}; first=$n; idx=$((idx+1))
      [[ "$unit" =~ ^[[:space:]]*# ]] && continue
      while [ "$idx" -lt "${#lines[@]}" ]; do
        # Cheap pre-filter before the per-unit strip: a continuation needs the
        # normalized form to END in |, |& or \, so the raw unit must hold a |
        # or \ at all and end with one of |, &, \, whitespace, or a possible
        # trailing comment (# elsewhere cannot expose an ending pipe). A raw
        # ending that is neither (a closing quote after a pipe, say) is a
        # conservative no-join even when stripping would end in |.
        case "$unit" in
          *\|*|*\\*)
            case "$unit" in
              *\||*"&"|*\\|*[[:space:]]|*\#*) ;;
              *) break ;;
            esac ;;
          *) break ;;
        esac
        # Judge the unit for continuation on one normalized form: quoted spans
        # stripped (strip_quotes), a trailing unquoted comment cut at the raw
        # offset strip_quotes reports (SQ_CMT: only a genuinely unquoted
        # word-start #; a # inside a judged span or right after an escape pair
        # never cuts) and dropped from the stored unit, and trailing whitespace
        # trimmed. A form strip_quotes cannot judge is returned unchanged with
        # SQ_CMT = -1, so its verbatim text decides (conservative no-join on
        # odd shapes).
        strip_quotes "$unit"; ntest=$SQ_OUT
        if [ "$SQ_CMT" -ge 0 ]; then
          unit=${unit:0:SQ_CMT}
          ntest=${SQ_OUT:0:SQ_CMT_N}
        fi
        ntest="${ntest%${ntest##*[![:space:]]}}"
        case "$unit" in
          *\\) # a backslash joins only on an odd trailing-backslash run
            bstr=${unit##*[!\\]}
            [ $(( ${#bstr} % 2 )) -eq 0 ] && break
            unit=${unit%\\}
            if [[ "${lines[idx]}" =~ ^[[:space:]]*# ]]; then
              # a comment after \ lands on the command's own line and comments
              # out the rest: drop it and stop joining
              n=$((n+1)); idx=$((idx+1)); break
            fi
            unit+=$' '${lines[idx]}; n=$((n+1)); idx=$((idx+1)) ;;
          *) case "$ntest" in
               *"|&"|*\|) while [ "$idx" -lt "${#lines[@]}" ] && [[ "${lines[idx]}" =~ ^[[:space:]]*# ]]; do
                            n=$((n+1)); idx=$((idx+1))  # comment line: dropped, never ends a pipe
                          done
                          [ "$idx" -lt "${#lines[@]}" ] || break
                          unit+=$' '${lines[idx]}; n=$((n+1)); idx=$((idx+1)) ;;
               *) break ;;
             esac ;;
        esac
      done
      case "$unit" in
        *\|*grep*|*\|*head*) strip_quotes "$unit"; units+=("$first:$SQ_OUT") ;;
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

# Controls: units starting at fixture lines 1-17, 19-21, 23, 33, 35, 37, 38,
# 40, 49-56, 59, 61, 63, 64, 70-72 must be flagged (the original reader forms
# plus -l/-L/--files-with-matches/--files-without-match, egrep/fgrep, the env
# (incl. -i/-u VAR), timeout (incl. -k N and 1m30s), nice, stdbuf and VAR=
# prefixes incl. a stack, split-line pipes at 21-22 and 23-24, the
# trailing-space pipe at 72-73, a trailing comment at 59-60, a split |& at
# 61-62, a "$(...)" inside double quotes at 33, a non-printf head piping
# onward at 35 and its |& form at 56, -El at 37, a '\'' idiom unit whose pipe
# survives the strip at 38, a comment inside a pipe continuation at 40-42, an
# unbounded writer before printf in a group at 49, and the post-pipe { / (
# group forms at 70-71); lines 18, 22, 24, 25-32, 34, 36, 39, 43-48, 57-58,
# 60, 62, 65-69 and 73 must not: the xargs reader at 18 (it drains stdin to
# EOF, so its grep cannot SIGPIPE the writer), the joined second lines 22,
# 24, 60, 62, 73 (a unit reports at its first line), ||, a here-string, a
# trailing head in $(), grep -c, a comment, && grep, quoted spans stripped
# (single at 31, double at 32), the printf display truncation at 34, a
# trailing head at 36, the same idiom wholly inside quoted fixture text at
# 39, a comment ending a backslash continuation at 43-45 and 67-69, the
# escaped-backslash pair at 65-66, head args stopping at ; and ) at 57-58,
# and printf as the head's writer in $()-context, with a } in kept args, and
# wrapped in a single-command group at 46-48.
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
cmd |& head -1 | tr a b
x=$(cmd | head -1); echo "$x" | tr a b
cmd | head -5; echo x | tr a b
cmd | # note
  grep -q nc
cmd |&
  grep -q am
cmd | grep -L x
cmd | grep --files-without-match x
echo a\\
grep -q x
cmd \
  # a comment after a backslash continuation
grep -q x
cmd | { grep -q x; }
cmd | (grep -q x)
f 'g #h' | grep -m1 y 't'
echo "a #b" | grep -q y "c #d"
run ' #x' | grep -q y # c
sed 's/ #/x/' f | grep -q pat # TODO
echo \ #x | grep -q x
true
EOF
# fixture lines 78-79: the trailing-space pipe form, appended by printf because
# a line-final space cannot be carried through an edit of this file
printf 'cmd | \n  grep -q sp\n' >>"$FX"
got=""
while IFS= read -r hit; do got+="${hit##*:} "; done < <(scan "$FX")
want='1 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 19 20 21 23 33 35 37 38 40 49 50 51 52 53 54 55 56 59 61 63 64 70 71 72 73 74 75 76 78 '
[ "$got" = "$want" ] \
  && ok "controls: units 1-17, 19-21, 23, 33, 35, 37, 38, 40, 49-56, 59, 61, 63, 64, 70-76, 78 flagged (grep -qx, continuations, -Eq, head onward incl. the |& form, --quiet, |&, -m1, -m 1, command grep, -A1q, --max-count, -l, --files-with-matches, -L, --files-without-match, egrep, fgrep, env -i/-u, timeout -k/1m30s, nice, stdbuf, VAR= prefixes and a stack, split-line/trailing-space/trailing-comment/|& pipe joins, \"\$(cmd | grep -q x)\" in double quotes, non-printf head onward, -El, '\''-idiom pipe, comment in a pipe continuation, unbounded writer before printf in a group, post-pipe { /( group forms, quoted-# spans stay literal inside reported units at 72-76) and 18, 22, 24, 25-32, 34, 36, 39, 43-48, 57-58, 60, 62, 65-69, 77 not (xargs drains stdin; joined seconds report at their first line; || grep -q, here-string, head in \$(), grep -c, comment, && grep -q, single/double-quoted spans, printf display truncation, trailing head, '\''-idiom fixture text, comment ends a backslash continuation, escaped-backslash pair, head args stop at ; and ), printf writer in \$()-context/with } in kept args/in a single-command group)" \
  || bad "controls: flagged lines '${got% }', expected '${want% }'"

# The tree: no scanned file pipes into an early-exit reader. nullglob keeps an
# unmatched glob from leaving a literal pattern in files (the sentinel checks
# below still catch an empty scan).
shopt -s nullglob
files=("$ROOT"/tests/*.sh "$ROOT"/plugins/seyag/hooks/*.probe.sh)
shopt -u nullglob
[ -e "$ROOT/tests/keys.probe.sh" ] || bad "no tests/*.sh files found under $ROOT"
[ -e "$ROOT/plugins/seyag/hooks/session-start.probe.sh" ] || bad "no plugins/seyag/hooks/*.probe.sh found under $ROOT"
hits=()
for f in "${files[@]}"; do
  [ "${f##*/}" = "$SELF" ] && continue
  while IFS= read -r h; do hits+=("${h#"$ROOT"/}"); done < <(scan "$f")
done
if [ "${#hits[@]}" -eq 0 ]; then
  ok "no tests/*.sh or plugins/seyag/hooks/*.probe.sh unit pipes into grep -q/-m/-l/-L (egrep/fgrep included) or a head that pipes onward"
else
  bad "early-exit reader on a pipe in tests/*.sh or plugins/seyag/hooks/*.probe.sh (fix: out=\$(cmd) && grep -q PAT <<<\"\$out\"; quoted fixture text the skip cannot judge: rephrase it):"
  printf '      %s\n' "${hits[@]}"
fi

[ "$fail" -eq 0 ]
