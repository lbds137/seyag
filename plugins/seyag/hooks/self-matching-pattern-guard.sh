#!/bin/bash
# PreToolUse hook: block a `pgrep -f` / `pkill -f` whose pattern is not the
# bracket form.
#
# `pgrep -f` / `pkill -f` matches against the FULL command line of every
# process, including the shell that is running the pgrep/pkill invocation
# itself. That shell's own cmdline contains the pattern text verbatim, so an
# unguarded pattern matches its own invocation. In a `while pgrep -f ... ; do
# sleep; done` wait loop the condition never goes false and the loop runs
# forever; with `pkill -f` it kills the session issuing the command. The
# bracket idiom (`pgrep -f '[p]attern'`) defeats this: the literal `[p]attern`
# text in the invoking shell's own cmdline does not match the regex
# `[p]attern`, because the character class consumes the leading letter.
#
# Detection is a pure-bash word scan (no python/jq body): split the command on
# whitespace and group the words into pgrep/pkill INVOCATIONS — a command word
# plus every word that follows it up to the next command separator. Each
# invocation is then tested as a SET, not a sequence: it blocks when it
# carries a full-cmdline flag (`-f`, `--full`, or a combined short-flag form
# like `-af`) AND none of its argument words contain a bracket class that
# cannot itself match a bracket character (no ^, [ or ] inside the class; a
# word carrying alternation or a class-optionalizing quantifier never earns
# the credit).
# Because the test is set membership, not position, ordering never matters —
# a value-taking option (`-u root`, `--signal TERM`) before or after the
# flag, an end-of-options `--`, and a `;` glued to the pattern word are all
# resolved by the same test. The bracket test runs on every raw argument word
# (the unanchored `=~` finds the class through quotes), not just "the one
# right after the flag" — safe because pgrep/pkill accept exactly one pattern
# (`pgrep foo bar` errors "only one pattern can be provided", exit 2), so a
# word carrying a bracket class is the pattern itself (or an option's value;
# see KNOWN UNDER-BLOCK below).
#
# KNOWN OVER-BLOCK, accepted: this is a WORD scan, not a shell parse, so a
# `pgrep -f` appearing inside an `echo`, a quoted string, or a heredoc body is
# scanned exactly like a real invocation and blocks; the retry costs one turn.
# Stripping heredoc bodies first (lib/shell_quotes.py, as lossy-pipe-guard
# does) was built and RULED OUT on 2026-09-25: a body fed to cat/tee still
# executes via `cat <<'EOF' | bash`, via `cat > run.sh <<'EOF' …; bash
# run.sh`, and via implicit discovery (`pytest`, `make`, `source`) later in
# the same command, while the tool shell's cmdline holds the body text
# throughout, so the self-match is real there and no lexical rule bounds
# "executed later". Measured over 13,399 real commands (7 days): 283 blocks,
# 3 of them prose in a cat-written heredoc. Three retries a week do not buy a
# bypass class.
#
# KNOWN UNDER-BLOCK, accepted: a bracket class inside an option's value
# credits the whole invocation (a word scan cannot tell pattern from value),
# so an unguarded pattern beside such a value passes; one wasted retry,
# accepted.
#
# Tokenization: a substitution form ($(...), a backtick, a subshell paren, or
# a leading assignment) is recognized as an invocation start, and the word
# that closes it (a matching ) or backtick) closes the invocation the same way
# a trailing `;` does. A line boundary is a separator, splitting one invocation
# per line; a trailing backslash continuation joins the next line first, so
# `pgrep -f \` + newline + `'[p]attern'` still reads as one open invocation.
# A redirect operator (`>`, `2>`, `&>`, ...) also ends the argument set:
# everything after it names a file or heredoc delimiter, never the pattern.
#
# Fixture check: run hooks/self-matching-pattern-guard.probe.sh after ANY edit.

set -uo pipefail

INPUT=$(cat)

# Raw-payload fast path: only decode JSON for a payload that could possibly
# carry a pgrep/pkill invocation. Mirrors the sibling guards' cheap-check-first
# ordering — the overwhelming majority of Bash calls exit here.
case "$INPUT" in
  *pgrep*|*pkill*) ;;
  *) exit 0 ;;
esac

TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

GUARD_CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$GUARD_CMD" ] && exit 0

# `read -ra` consumes a single line, so a multi-line command needs its
# newlines turned into separators the word loop understands — collapsing to a
# bare space would splice line 2's words onto an invocation still open from
# line 1, letting a bracket word on line 2 rescue an unguarded pattern above.
# Join a trailing-backslash continuation first (keeps the invocation open
# across it), THEN turn every remaining newline into a `;` separator token.
GUARD_CMD="${GUARD_CMD//\\$'\n'/ }"
read -ra WORDS <<< "${GUARD_CMD//$'\n'/ ; }"

blocked=0
inv_open=0
declare -a inv=()
redirect_re='^([0-9]*[<>]|&>)'

# True if $1, after stripping the longest prefix ending in a separator,
# subshell paren, command-substitution '$('/backtick, or an assignment ('='),
# is a pgrep/pkill command word (';pgrep', 'PID=$(pgrep', '`pgrep', etc).
is_start_word() {
  local sw="$1"
  sw="${sw##*[\$(\`;=]}"
  case "$sw" in
    pgrep|pkill|*/pgrep|*/pkill) return 0 ;;
    *) return 1 ;;
  esac
}

# Evaluates one closed invocation's argument words (the command word itself
# is never passed in) as a SET: blocks when a full-cmdline flag is present
# and none of the argument words contain a bracket class that cannot itself
# match a bracket character (no ^, [ or ] inside the class; a word carrying
# alternation or a class-optionalizing quantifier never earns the credit).
evaluate_invocation() {
  local w p has_f=0 has_bracket=0
  for w in "$@"; do
    if [ "$has_f" -eq 0 ]; then
      if [ "$w" = "--full" ] || [[ "$w" =~ ^-[a-zA-Z]*f[a-zA-Z]*$ ]]; then
        has_f=1
      fi
    fi
    p="$w"
    if [[ "$p" =~ \[[^][^]+\] ]] && ! [[ "$p" =~ \| ]] && ! [[ "$p" =~ \][?*{] ]]; then has_bracket=1; fi
  done
  [ "$has_f" -eq 1 ] && [ "$has_bracket" -eq 0 ] && blocked=1
}

for w in "${WORDS[@]}"; do
  # A redirect operator closes the invocation, same as a separator token.
  is_sep=0
  case "$w" in
    ';'|'&&'|'||'|'|'|'&') is_sep=1 ;;
    *) [[ "$w" =~ $redirect_re ]] && is_sep=1 ;;
  esac
  if [ "$is_sep" -eq 1 ]; then
    if [ "$inv_open" -eq 1 ]; then
      evaluate_invocation "${inv[@]}"
      [ "$blocked" -eq 1 ] && break
      inv_open=0
      inv=()
    fi
    continue
  fi

  # A trailing ';' closes an invocation like a separator token; a trailing
  # ')' or backtick closes one opened by a substitution/subshell start word.
  # Strip ';' first, then check the remainder, so "node);" and "node)" both close.
  trail=0
  if [[ "$w" == *';' ]]; then
    w="${w%;}"
    trail=1
  fi
  if [[ "$w" == *')' ]]; then
    w="${w%)}"
    trail=1
  elif [[ "$w" == *'`' ]]; then
    w="${w%\`}"
    trail=1
  fi

  if is_start_word "$w"; then
    if [ "$inv_open" -eq 1 ]; then
      evaluate_invocation "${inv[@]}"
      [ "$blocked" -eq 1 ] && break
    fi
    inv_open=1
    inv=()
  elif [ "$inv_open" -eq 1 ]; then
    inv+=("$w")
  fi

  if [ "$trail" -eq 1 ] && [ "$inv_open" -eq 1 ]; then
    evaluate_invocation "${inv[@]}"
    [ "$blocked" -eq 1 ] && break
    inv_open=0
    inv=()
  fi
done

if [ "$blocked" -ne 1 ] && [ "$inv_open" -eq 1 ]; then
  evaluate_invocation "${inv[@]}"
fi

if [ "$blocked" -ne 1 ]; then
  exit 0
fi

cat >&2 << 'MSG'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SELF-MATCHING PATTERN GUARD — pgrep -f / pkill -f matches this shell
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
`pgrep -f` / `pkill -f` matches the shell running THIS command: its own
cmdline contains the pattern. In a wait loop that never exits (two
waiters in the mined corpus ran 7.5h and 18.6h dead); with pkill it
kills the session.

Use the bracket form — `pgrep -f '[p]attern'` (the literal `[p]attern`
in your cmdline does not match the regex) — or list PIDs first and act
by PID, or wait on a PID file.
(the class can sit anywhere in the pattern: `pgrep -f 'cc-rou[t]e'`)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MSG
exit 2
