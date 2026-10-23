#!/usr/bin/env bash
# Probe for env-print-guard.sh.
# Exercises bulk env/printenv/set dumps, downstream names-only selector
# allowlist, value-preserving filter rejections, pure-transform intermediate
# segments, jq bulk vs specific/keys reads on .env and settings.json,
# SYG_ALLOW_ENV_PRINT=1 bypass, and fail-open behavior on shapes outside
# command_pipelines.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/env-print-guard.sh"

pass=0
fail=0

payload_for() {
  jq -nc --arg cmd "$1" '{tool_name:"Bash",cwd:"/tmp/proj",tool_input:{command:$cmd}}'
}

expect_allow() {
  local label="$1" cmd="$2" out err rc tmp_err
  tmp_err=$(mktemp)
  out=$(payload_for "$cmd" | env -i PATH="$PATH" HOME="$HOME" SYG_EPG_TRUSTED_VARS="${SYG_EPG_TRUSTED_VARS:-}" bash "$HOOK" 2>"$tmp_err")
  rc=$?
  err=$(cat "$tmp_err")
  rm -f "$tmp_err"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected allow (rc=0, silent), got rc=$rc stdout=$out stderr=$err" >&2
    fail=$((fail + 1))
  fi
}

expect_deny() {
  local label="$1" cmd="$2" reason_sub="$3" out err rc tmp_err
  tmp_err=$(mktemp)
  out=$(payload_for "$cmd" | env -i PATH="$PATH" HOME="$HOME" SYG_EPG_TRUSTED_VARS="${SYG_EPG_TRUSTED_VARS:-}" bash "$HOOK" 2>"$tmp_err")
  rc=$?
  err=$(cat "$tmp_err")
  rm -f "$tmp_err"
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "ENV-PRINT BLOCKED" && printf '%s' "$err" | grep -qF -- "$reason_sub" && ! printf '%s' "$out" | grep -q "permissionDecision"; then
    pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected deny (rc=2, ENV-PRINT BLOCKED + '$reason_sub' on stderr, no permissionDecision in stdout), got rc=$rc stdout=$out stderr=$err" >&2
    fail=$((fail + 1))
  fi
}

expect_deny_payload() {
  local label="$1" payload="$2" reason_sub="$3" out err rc tmp_err
  tmp_err=$(mktemp)
  out=$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>"$tmp_err")
  rc=$?
  err=$(cat "$tmp_err")
  rm -f "$tmp_err"
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "ENV-PRINT BLOCKED" && printf '%s' "$err" | grep -qF -- "$reason_sub" && ! printf '%s' "$out" | grep -q "permissionDecision"; then
    pass=$((pass + 1))
  else
    echo "FAIL [$label]: expected deny (rc=2, ENV-PRINT BLOCKED + '$reason_sub' on stderr, no permissionDecision in stdout), got rc=$rc stdout=$out stderr=$err" >&2
    fail=$((fail + 1))
  fi
}

# --- Denies: direct & non-names-only pipelines ---
expect_deny "bare env" "env" "bulk environment dump via"
expect_deny "/usr/bin/env" "/usr/bin/env" "bulk environment dump via"
expect_deny "bare printenv" "printenv" "bulk environment dump via"
expect_deny "printenv -0" "printenv -0" "bulk environment dump via"
expect_deny "printenv --null" "printenv --null" "bulk environment dump via"
expect_deny "bare set" "set" "bulk environment dump via"
expect_deny "env | sort" "env | sort" "bulk environment dump via"
expect_deny "env | head -20" "env | head -20" "bulk environment dump via"
expect_deny "env | grep SECRET" "env | grep SECRET" "bulk environment dump via"
expect_deny "env | grep -oE '^.{0,3}'" "env | grep -oE '^.{0,3}'" "bulk environment dump via"
expect_deny "env | grep -o '^[^#]*'" "env | grep -o '^[^#]*'" "bulk environment dump via"
expect_deny "env | grep -oE '^[^=]+='" "env | grep -oE '^[^=]+='" "bulk environment dump via"
expect_deny "env | grep -oE '^(CLAUDE|ANTHROPIC)[A-Za-z0-9_]*'" "env | grep -oE '^(CLAUDE|ANTHROPIC)[A-Za-z0-9_]*'" "bulk environment dump via"
expect_deny "env | grep -oE '^[A-Za-z0-9_]*'" "env | grep -oE '^[A-Za-z0-9_]*'" "bulk environment dump via"
expect_deny "env | grep -oE '^X|[A-Za-z0-9_]+$'" "env | grep -oE '^X|[A-Za-z0-9_]+$'" "bulk environment dump via"
expect_deny "printenv | tr" "printenv | tr '\n' ' '" "bulk environment dump via"
expect_deny "env FOO=1 no cmd" "env FOO=1" "bulk environment dump via"
expect_deny "env with redaction sed" "env | sed 's/TOKEN=.*/TOKEN=…/'" "bulk environment dump via"
expect_deny "env with jq del" "env | jq 'del(.SECRET)'" "bulk environment dump via"
expect_deny "VAR=x env" "VAR=x env" "bulk environment dump via"
# A redirect word does not count as an argument (set stays argless); stdout to a file passes (file sinks).
expect_deny "set 2> /tmp/env-dump-fixture" "set 2> /tmp/env-dump-fixture" "bulk environment dump via"
expect_allow "set > /tmp/env-dump-fixture" "set > /tmp/env-dump-fixture"
expect_deny "env -i printenv" "env -i printenv" "bulk environment dump via"
expect_deny "env -S printenv" "env -S 'printenv'" "bulk environment dump via"
expect_deny "bypass token in commit msg does not unlock chain" 'git commit -m "doc SYG_ALLOW_ENV_PRINT=1 SYG_X=1" && env' "bulk environment dump via"
expect_deny "env | cut -d= -f1 (missing -s)" "env | cut -d= -f1" "bulk environment dump via"
expect_deny "env | sed s/=.*//" "env | sed 's/=.*//'" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env | awk -F= print 1" 'env | awk -F= '\''{print $1}'\''' "bulk environment dump via"
expect_deny "env | tee /dev/stderr | wc -l" "env | tee /dev/stderr | wc -l" "bulk environment dump via"
expect_deny "env -0 | wc --files0-from=-" "env -0 | wc --files0-from=-" "bulk environment dump via"

# --- Denies: bulk jq on .env / .env.* / *.env / settings*.json ---
expect_deny "jq . settings.json" "jq . settings.json" "bulk jq filter"
expect_deny "jq empty filter settings.json" "jq '' settings.json" "bulk jq filter"
expect_deny "jq . ~/.claude/settings.json" "jq . ~/.claude/settings.json" "bulk jq filter"
expect_deny "jq .env ~/.claude/settings.json" "jq .env ~/.claude/settings.json" "bulk jq filter"
expect_deny "jq .env|.[] settings.json" "jq '.env|.[]' settings.json" "bulk jq filter"
expect_deny "jq .[\"env\"] settings.json" 'jq '\''.["env"]'\'' settings.json' "bulk jq filter"
expect_deny "jq .env|to_entries settings.json" "jq '.env|to_entries' settings.json" "bulk jq filter"
expect_deny "jq .env|tostring settings.json" "jq '.env|tostring' settings.json" "bulk jq filter"
expect_deny "jq to_entries settings.json" "jq 'to_entries' settings.json" "bulk jq filter"
expect_deny "jq {env} settings.json" "jq '{env}' settings.json" "bulk jq filter"
expect_deny "jq .. settings.json" "jq '..' settings.json" "bulk jq filter"
expect_deny "jq del(.permissions) settings.json" "jq 'del(.permissions)' settings.json" "bulk jq filter"
expect_deny "jq .env, .model settings.json" "jq '.env, .model' settings.json" "bulk jq filter"
expect_deny "jq . .env" "jq . .env" "bulk jq filter"
expect_deny "jq .[] .env.local" "jq '.[]' .env.local" "bulk jq filter"
expect_deny "jq . prod.env" "jq . /etc/app/prod.env" "bulk jq filter"

# --- Allows: downstream names-only selectors ---
expect_allow "env | cut -s -d= -f1" "env | cut -s -d= -f1"
expect_allow "env | tee /tmp/f | cut -s -d= -f1" "env | tee /tmp/f | cut -s -d= -f1"
expect_allow "env | wc -l" "env | wc -l"
expect_allow "env | jq keys_unsorted" "env | jq keys_unsorted"
expect_allow "printenv | wc -l" "printenv | wc -l"
expect_allow "env | grep -c CLAUDE" "env | grep -c CLAUDE"
# Round 7 §13: a side-channel transform between the dump and the selector kills
# the allowance — sed's `w` writes to a file or /dev/stderr, perl/python run
# arbitrary code. Shape-based, not semantic: the plain s/x/y/ sed denies too,
# because guessing which sed programs are harmless is the leak this guards.
expect_deny "env | sed w /dev/stderr | cut" "env | sed -n 'w /dev/stderr' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sed s/x/y/ | cut (shape-based deny)" "env | sed -n 's/x/y/' | cut -s -d= -f1" "bulk environment dump via"
# Review round 1: awk is unconditionally a side channel — any program can
# redirect, pipe to a command, call system, or read with getline, so no program
# inspection (gawk/mawk/nawk and busybox awk included; shape only). The
# `print | "tee /dev/stderr"` row was allowed before this fix.
# shellcheck disable=SC2016
expect_deny "env | awk print | tee /dev/stderr | cut" 'env | awk '\''{print | "tee /dev/stderr"}'\'' | cut -s -d= -f1' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env | gawk system(logger) | cut" 'env | gawk '\''{system("logger " $0)}'\'' | cut -s -d= -f1' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env | awk system(touch) | cut" 'env | awk '\''{system("touch /tmp/x")}'\'' | cut -s -d= -f1' "bulk environment dump via"
expect_deny "env | perl -pe 1 | cut" "env | perl -pe 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | python3 -c pass | cut" "env | python3 -c 'pass' | cut -s -d= -f1" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env | busybox awk | cut" 'env | busybox awk -F= '\''{print $1}'\'' | cut -s -d= -f1' "bulk environment dump via"
# Review round 2: the side-channel denylist extends to same-class movers —
# gsed and busybox sed (sed's sibling spellings), dd (of= writes through),
# xargs (runs its stdin as commands, also behind runners), the ruby/node/lua/
# pypy* interpreters, and sh/bash -c wrapper scripts. All shape-based, like
# sed itself.
expect_deny "env | gsed s/x/y/ | cut" "env | gsed -n 's/x/y/' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | busybox sed | cut" "env | busybox sed -n 's/x/y/' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | dd of=/dev/stderr | cut" "env | dd of=/dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | dd of=/tmp/x | cut" "env | dd of=/tmp/x | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | ruby -e 1 | cut" "env | ruby -e 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | node -e 0 | cut" "env | node -e 0 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | lua -e 1 | cut" "env | lua -e 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | pypy -c pass | cut" "env | pypy -c pass | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | pypy3 -c pass | cut" "env | pypy3 -c pass | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sh -c tr | cut" "env | sh -c 'tr a-z A-Z' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | bash -c tr | cut" "env | bash -c 'tr a-z A-Z' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | xargs printenv | cut" "env | xargs printenv | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | timeout 5 xargs printenv | cut" "env | timeout 5 xargs printenv | cut -s -d= -f1" "bulk environment dump via"
# Review round 3: shells are a side channel in ANY form — no `-c` word needed
# (bundled `-ec`/`-xc` flags; a plain `env | bash` runs the dump's lines as a
# script). parallel joins xargs on the stripped-runner list, and the
# interpreter set widens: `perl*` prefix (perl5.x), `node*` prefix (nodejs),
# php/deno/bun/tclsh/Rscript, and the busybox sh/dd applet pairs.
expect_deny "env | bash -ec cat>&2 | cut" "env | bash -ec 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sh -xc cat>&2 | cut" "env | sh -xc 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | zsh -c cat>&2 | cut" "env | zsh -c 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | dash -c cat>&2 | cut" "env | dash -c 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | plain bash | cut" "env | bash | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | parallel echo >&2 | cut" "env | parallel echo '{}' '>&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | perl5.36 -pe 1 | cut" "env | perl5.36 -pe 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | nodejs -e 0 | cut" "env | nodejs -e 0 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | php -r 1 | cut" "env | php -r 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | deno eval 1 | cut" "env | deno eval 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | bun -e 1 | cut" "env | bun -e 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | tclsh | cut" "env | tclsh | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | Rscript -e 1 | cut" "env | Rscript -e 1 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | busybox sh -c cat>&2 | cut" "env | busybox sh -c 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | busybox dd of=/dev/stderr | cut" "env | busybox dd of=/dev/stderr | cut -s -d= -f1" "bulk environment dump via"
# Review round 5 (round 4's findings, owner ruling: allowlist): the
# side-channel denylist is now `_is_pure_transform`'s pure-transform
# ALLOWLIST — every segment between the dump and the selector must be pure,
# and anything else kills the allowance. Round-4 finding 1 first: a middle
# jq stage leaks via its stderr builtins (both shapes were allowed on the
# denylist, driver runtime-confirmed on 1d2718d).
expect_deny "env | jq -R debug | cut" "env | jq -R debug | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | jq -R . | cut" "env | jq -R . | cut -s -d= -f1" "bulk environment dump via"
# Round-4 finding 2's same-class movers, each now denied by not being in the
# set: output-writing flags and operands, runner-shaped copies, unlisted
# shells, and busybox applets beyond the pure set (busybox tee escapes
# is_transcript_tee's first-word match).
expect_deny "env | sort -o /dev/stderr | cut" "env | sort -o /dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sort --output=/dev/stderr | cut" "env | sort --output=/dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | uniq - /dev/stderr | cut" "env | uniq - /dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | cp /dev/stdin /dev/stderr | cut" "env | cp /dev/stdin /dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | split --filter='cat >&2' | cut" "env | split --filter='cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | ed | cut" "env | ed | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | ex | cut" "env | ex | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | ash -c cat>&2 | cut" "env | ash -c 'cat >&2' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | fish | cut" "env | fish | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | csh | cut" "env | csh | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | tcsh | cut" "env | tcsh | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | busybox tee /dev/stderr | cut" "env | busybox tee /dev/stderr | cut -s -d= -f1" "bulk environment dump via"
# The set's option boundaries as allows: the plain transforms, and a runner
# prefix over a pure one.
expect_allow "env | sort | cut" "env | sort | cut -s -d= -f1"
expect_allow "env | sort -n | cut" "env | sort -n | cut -s -d= -f1"
expect_allow "env | uniq | cut" "env | uniq | cut -s -d= -f1"
expect_allow "env | uniq -f 1 | cut" "env | uniq -f 1 | cut -s -d= -f1"
expect_allow "env | cat | cut" "env | cat | cut -s -d= -f1"
expect_allow "env | cat /etc/hostname | cut" "env | cat /etc/hostname | cut -s -d= -f1"
expect_allow "env | tail -n 5 | cut" "env | tail -n 5 | cut -s -d= -f1"
expect_allow "env | sort --numeric-sort | cut" "env | sort --numeric-sort | cut -s -d= -f1"
expect_allow "env | sort --parallel 2 | cut" "env | sort --parallel 2 | cut -s -d= -f1"
# Review round 6, finding 1: delimiter-reshaping transforms leave the set.
# rev reverses lines (NAME=VAL becomes LAV=EMAN, so field 1 is the value),
# a tr set carrying `=` or a newline (tr "=\n" "\n=" swaps the cut delimiter
# in place) moves it, and head/tail -c cut mid-line — each makes the
# selector print value slices. The three r5 allow rows flip deny.
expect_deny "env | rev | cut" "env | rev | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | tr a-z A-Z | cut" "env | tr a-z A-Z | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | timeout 5 tr a-z A-Z | cut" "env | timeout 5 tr a-z A-Z | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | tr eq-nl swap | cut" 'env | tr "=\n" "\n=" | cut -s -d= -f1' "bulk environment dump via"
expect_deny "env | tr -d eq | cut" "env | tr -d '=' | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | tail -c +10 | cut" "env | tail -c +10 | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | head -c 5 | cut" "env | head -c 5 | cut -s -d= -f1" "bulk environment dump via"
# Review round 6, finding 2: sort long options are an exact allowlist —
# `--output`'s unambiguous abbreviations and `--compress-program` are not on
# it; a spaced value (--parallel 2, -S 1K) stays an inert operand word.
expect_deny "env | sort --out=/dev/stderr | cut" "env | sort --out=/dev/stderr | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sort --o=x | cut" "env | sort --o=x | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | sort -S 1K --compress-program=cp | cut" "env | sort -S 1K --compress-program=cp | cut -s -d= -f1" "bulk environment dump via"
# Review round 7: the delimiter-reshaping sweep finishes. cut leaves the
# intermediate set entirely — `cut -d= -f2-` prints value text, `cut -c5-`
# cuts mid-line, and no arg shape proves the selector stays names-only (the
# final-segment cut selector is is_names_only_selector, not this set) — and
# intermediate grep denies -o/--only-matching in any form (bundled short or
# a GNU abbreviation): -o prints each pattern match, so
# `grep -oP '(?<==).*'` feeds the selector value text.
expect_deny "env | cut -d= -f2- | cut" "env | cut -d= -f2- | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | cut -c5- | cut" "env | cut -c5- | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | grep -o . | cut" "env | grep -o . | cut -s -d= -f1" "bulk environment dump via"
expect_deny "env | grep -oP '(?<==).*' | cut" "env | grep -oP '(?<==).*' | cut -s -d= -f1" "bulk environment dump via"
# The remaining in-set members as intermediates, pinned so a later tightening
# cannot break them unseen: the most common real shape (grep without -o), a
# file tee (documented design), a pure busybox applet.
expect_allow "env | grep CLAUDE | cut" "env | grep CLAUDE | cut -s -d= -f1"
expect_allow "env | tee /tmp/x | cut" "env | tee /tmp/x | cut -s -d= -f1"
expect_allow "env | busybox sort | cut" "env | busybox sort | cut -s -d= -f1"
# Review round 8: GNU tail's traditional `+N[bcl]` first operand (default
# _POSIX2_VERSION) is a non-dash word `_no_bytes_flag` never sees, so
# `tail +10c` starts at byte 10 like the denied `tail -c +10`; `+5`/`+5l`
# (lines) stay in the set.
expect_deny "env | tail +10c | cut" "env | tail +10c | cut -s -d= -f1" "bulk environment dump via"
expect_allow "env | tail +5 | cut" "env | tail +5 | cut -s -d= -f1"

# --- Allows: keyed reads, command execution, shell options, specific jq ---
expect_allow "printenv HOME" "printenv HOME"
expect_allow "env -i" "env -i"
expect_allow "env FOO=1 cmd" "env FOO=1 cmd"
expect_allow "env -i PATH=/usr/bin cmd" "env -i PATH=/usr/bin cmd"
expect_allow "env -S echo hi" "env -S 'echo hi'"
expect_allow "env --version | head -1" "env --version | head -1"
expect_allow "env --help" "env --help"
expect_allow "printenv --version" "printenv --version"
expect_allow "set -euo pipefail" "set -euo pipefail"
expect_allow "jq '.env | keys' ~/.claude/settings.json" "jq '.env | keys' ~/.claude/settings.json"
expect_allow "jq -r '.env.ANTHROPIC_MODEL' settings.json" "jq -r '.env.ANTHROPIC_MODEL' settings.json"
expect_allow "jq -r '.model' settings.json" "jq -r '.model' settings.json"
expect_allow "jq '.env?.x' settings.local.json" "jq '.env?.x' settings.local.json"
expect_allow "cat cfg.json | jq -r '.env.ANTHROPIC_MODEL'" "cat cfg.json | jq -r '.env.ANTHROPIC_MODEL'"
# invalid jq program, errors, nothing printed
expect_allow "jq settings.json" "jq settings.json"
expect_allow "echo '{}' | jq .env" "echo '{}' | jq .env"
# Round 7 §10: a stdout-only `> /dev/null` no longer covers a jq sink — error
# text from a deliberate runtime failure reaches the transcript on fd 2.
expect_deny "jq -e . settings.json >/dev/null (fd 2 on transcript)" "jq -e . ~/.claude/settings.json >/dev/null" "bulk jq filter"
expect_allow "env > /tmp/envsnap.txt" "env > /tmp/envsnap.txt"
expect_allow "env >/tmp/e 2>&1" "env >/tmp/e 2>&1"
# shellcheck disable=SC2016
expect_allow 'printenv > "$CLAUDE_JOB_DIR/tmp/e"' 'printenv > "$CLAUDE_JOB_DIR/tmp/e"'
expect_allow "env >/dev/null" "env >/dev/null"
expect_allow "env &>/tmp/e" "env &>/tmp/e"
expect_deny "jq . ~/.claude/settings.json > /tmp/x.json" "jq . ~/.claude/settings.json > /tmp/x.json" "bulk jq filter"
expect_allow "jq . ~/.claude/settings.json > /tmp/x.json 2>/dev/null" "jq . ~/.claude/settings.json > /tmp/x.json 2>/dev/null"
expect_allow "env 1>>/tmp/e" "env 1>>/tmp/e"
expect_allow "env >&-" "env >&-"
expect_deny "env >&2" "env >&2" "bulk environment dump via"
expect_deny "env 1>&2" "env 1>&2" "bulk environment dump via"
expect_deny "env >/tmp/f >&2" "env >/tmp/f >&2" "bulk environment dump via"
expect_deny "env > /dev/stderr" "env > /dev/stderr" "bulk environment dump via"
expect_deny "env >/dev/tty" "env >/dev/tty" "bulk environment dump via"
expect_deny "env 2>/tmp/e" "env 2>/tmp/e" "bulk environment dump via"
expect_deny "jq . settings.json >&2" "jq . settings.json >&2" "bulk jq filter"
expect_deny "jq . .env > /dev/stdout" "jq . .env > /dev/stdout" "bulk jq filter"
expect_deny "jq . .env '>x'" "jq . .env '>x'" "bulk jq filter"
expect_deny 'jq . .env "1>x"' 'jq . .env "1>x"' "bulk jq filter"
expect_deny 'jq . settings.json \>x' 'jq . settings.json \>x' "bulk jq filter"
expect_deny "printenv '>x'" "printenv '>x'" "bulk environment dump via"
expect_deny "env >/dev/./stderr" "env >/dev/./stderr" "bulk environment dump via"
expect_deny "env >/proc/self/fd/2" "env >/proc/self/fd/2" "bulk environment dump via"
expect_deny "env >/dev/pts/0" "env >/dev/pts/0" "bulk environment dump via"
expect_deny "env >/dev/fd/0" "env >/dev/fd/0" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env > $(echo /dev/stderr)' 'env > $(echo /dev/stderr)' "bulk environment dump via"
expect_deny "env >& /dev/stderr" "env >& /dev/stderr" "bulk environment dump via"
expect_deny "env >&/dev/stderr" "env >&/dev/stderr" "bulk environment dump via"
expect_allow "env >& /tmp/e" "env >& /tmp/e"
expect_allow "env >/tmp/./e" "env >/tmp/./e"
expect_deny "env > >(cat)" "env > >(cat)" "bulk environment dump via"
expect_deny "env &> >(cat)" "env &> >(cat)" "bulk environment dump via"
expect_deny "jq . .env > >(cat)" "jq . .env > >(cat)" "bulk jq filter"
expect_deny "env >//dev/stderr" "env >//dev/stderr" "bulk environment dump via"
expect_deny "env > /proc/self/task/1/fd/2" "env > /proc/self/task/1/fd/2" "bulk environment dump via"
expect_deny "env > /proc/self/root/dev/stderr" "env > /proc/self/root/dev/stderr" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env > ${X:-/dev/stderr}' 'env > ${X:-/dev/stderr}' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env > $X/../dev/stderr' 'env > $X/../dev/stderr' "bulk environment dump via"
expect_deny "env > /dev/stder?" "env > /dev/stder?" "bulk environment dump via"
expect_deny "env | tee //dev/stderr | wc -l" "env | tee //dev/stderr | wc -l" "bulk environment dump via"
expect_deny "env | tee >(cat) | wc -l" "env | tee >(cat) | wc -l" "bulk environment dump via"
expect_allow "env > out.txt" "env > out.txt"
expect_allow "env > ./snap/env.txt" "env > ./snap/env.txt"
expect_allow "env > ~/snap.txt" "env > ~/snap.txt"
# shellcheck disable=SC2016
expect_deny 'env > ${OUT}' 'env > ${OUT}' "bulk environment dump via"
# shellcheck disable=SC2016
SYG_EPG_TRUSTED_VARS=OUT expect_allow 'env > ${OUT} (SYG_EPG_TRUSTED_VARS=OUT)' 'env > ${OUT}'
expect_allow "env > build/dev/out.txt" "env > build/dev/out.txt"
ANSI_C_PROCSUB_CMD=$(cat <<'PROBE_EOF'
echo $'a\' <(' ; env | cat ; echo ')'
PROBE_EOF
)
expect_deny "echo \$'a\\' <(' ; env | cat ; echo ')'" "$ANSI_C_PROCSUB_CMD" "bulk environment dump via"
expect_deny "cd / && env > dev/stderr" "cd / && env > dev/stderr" "bulk environment dump via"
expect_deny "cd /proc/self/fd && env > 1" "cd /proc/self/fd && env > 1" "bulk environment dump via"
expect_allow "diff <(sort a) <(sort b)" "diff <(sort a) <(sort b)"
HEREDOC_PROCSUB_CMD=$(cat <<'PROBE_EOF'
cat <<'EOT' > s.sh
diff <(env) <(b)
EOT
PROBE_EOF
)
expect_allow "cat <<'EOT' > s.sh with diff <(env) <(b) body" "$HEREDOC_PROCSUB_CMD"
# shellcheck disable=SC2016
expect_allow "rewritten delegation skill command" 'for v in $(env | cut -s -d= -f1 | grep '\''^ANTHROPIC_DEFAULT_.*_MODEL$'\''); do printf '\''%s=%s\n'\'' "$v" "$(printenv "$v")"; done'
expect_deny "env >/tmp/x >| /dev/stderr" "env >/tmp/x >| /dev/stderr" "bulk environment dump via"
expect_deny "env >/tmp/x 1<>/dev/stderr" "env >/tmp/x 1<>/dev/stderr" "bulk environment dump via"
expect_deny "env >/tmp/x 1<&2" "env >/tmp/x 1<&2" "bulk environment dump via"
expect_deny "env >/tmp/x 01>&2" "env >/tmp/x 01>&2" "bulk environment dump via"
expect_deny "env >/tmp/x 001>/dev/stderr" "env >/tmp/x 001>/dev/stderr" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env >/tmp/x >&$X' 'env >/tmp/x >&$X' "bulk environment dump via"
expect_deny "jq debug .env > /tmp/x" "jq debug .env > /tmp/x" "bulk jq filter"
expect_deny "jq 'stderr' .env > /dev/null" "jq 'stderr' .env > /dev/null" "bulk jq filter"
# shellcheck disable=SC2016
expect_deny 'echo $(env > /tmp/x; cat /tmp/x)' 'echo $(env > /tmp/x; cat /tmp/x)' "bulk environment dump via"
expect_deny "env | tee /tmp/f >&2 | cut -s -d= -f1" "env | tee /tmp/f >&2 | cut -s -d= -f1" "bulk environment dump via"
expect_deny_payload "env > stderr (cwd /dev)" "$(jq -nc --arg cmd 'env > stderr' '{tool_name:"Bash",cwd:"/dev",tool_input:{command:$cmd}}')" "bulk environment dump via"
expect_deny_payload "env > out.txt (no cwd)" "$(jq -nc --arg cmd 'env > out.txt' '{tool_name:"Bash",tool_input:{command:$cmd}}')" "bulk environment dump via"
expect_allow "env > /tmp/x 2>&1" "env > /tmp/x 2>&1"
expect_allow "env 2>&1 >/tmp/x" "env 2>&1 >/tmp/x"
expect_allow "env &> /tmp/x" "env &> /tmp/x"
expect_allow "env >/tmp/x 2>/dev/stdout" "env >/tmp/x 2>/dev/stdout"
expect_deny '\cd /dev; env > stderr' '\cd /dev; env > stderr' "bulk environment dump via"
expect_deny "'cd' /dev; env > stderr" "'cd' /dev; env > stderr" "bulk environment dump via"
expect_deny '"cd" /dev; env > stderr' '"cd" /dev; env > stderr' "bulk environment dump via"
expect_deny 'c\d /dev; env > stderr' 'c\d /dev; env > stderr' "bulk environment dump via"
expect_deny 'eval "cd /dev"; env > stderr' 'eval "cd /dev"; env > stderr' "bulk environment dump via"
expect_deny "source ./x; env > out.txt" "source ./x; env > out.txt" "bulk environment dump via"
expect_deny "true; env > out.txt" "true; env > out.txt" "bulk environment dump via"
expect_deny "jq '.K|halt_error' .env >/tmp/x" "jq '.K|halt_error' .env >/tmp/x" "bulk jq filter"
expect_deny "jq 'halt_error(1)' .env >/tmp/x" "jq 'halt_error(1)' .env >/tmp/x" "bulk jq filter"
expect_deny "jq '.a|error' .env >/tmp/x" "jq '.a|error' .env >/tmp/x" "bulk jq filter"
expect_deny "jq '.[]|error(.)' .env >/tmp/x" "jq '.[]|error(.)' .env >/tmp/x" "bulk jq filter"
expect_allow "env > /tmp/x; true" "env > /tmp/x; true"
expect_allow "jq '.error' .env > /dev/null" "jq '.error' .env > /dev/null"
expect_allow "jq '.error' .env > /tmp/x" "jq '.error' .env > /tmp/x"
# shellcheck disable=SC2046
BIG=$(printf '9%.0s' $(seq 5000))
expect_deny "env >/tmp/x \${BIG}>&2; env" "env >/tmp/x ${BIG}>&2; env" "bulk environment dump via"
expect_deny "env \${BIG}>/tmp/x" "env ${BIG}>/tmp/x" "bulk environment dump via"
expect_deny "jq . .env > /tmp/x \${BIG}>&2" "jq . .env > /tmp/x ${BIG}>&2" "bulk jq filter"
expect_deny "jq '.K|tonumber' .env >/tmp/x" "jq '.K|tonumber' .env >/tmp/x" "bulk jq filter"
expect_deny "jq . .env > /tmp/x (stderr on transcript)" "jq . .env > /tmp/x" "bulk jq filter"
expect_deny "jq . .env 2>&1 > /tmp/x" "jq . .env 2>&1 > /tmp/x" "bulk jq filter"
# Round 7 §10: same closure with the legacy /dev/null target; non-jq keeps it.
# The deny pins the "sink both fds" clause in the jq message text (round 3:
# the clause is shown only for filters outside the stderr-builtin class).
expect_deny "jq . .env > /dev/null (fd 2 on transcript)" "jq . .env > /dev/null" 'or sink both fds (`>/dev/null 2>&1`)'
# Review round 3, finding 4: that clause is advice, and it is wrong advice for
# a stderr-builtin filter — those deny even with both fds sunk. Pin that the
# clause is absent there (expect_deny cannot assert absence itself).
tmp_err=$(mktemp)
out=$(payload_for "jq 'stderr' .env > /dev/null" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>"$tmp_err")
rc=$?
err=$(cat "$tmp_err")
rm -f "$tmp_err"
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q "ENV-PRINT BLOCKED" && ! printf '%s' "$err" | grep -qF 'sink both fds'; then
  pass=$((pass + 1))
else
  echo "FAIL [jq stderr-builtin deny without the sink-both-fds clause]: expected rc=2 + ENV-PRINT BLOCKED + no 'sink both fds' on stderr, got rc=$rc stdout=$out stderr=$err" >&2
  fail=$((fail + 1))
fi
expect_allow "jq . .env > /dev/null 2>/dev/null" "jq . .env > /dev/null 2>/dev/null"
# Review round 2: the remedy the deny message advises (`>/dev/null 2>&1`),
# allowed on the main path — spaced, and compact in a && chain.
expect_allow "jq . .env > /dev/null 2>&1" "jq . .env > /dev/null 2>&1"
expect_allow "jq -e . .env >/dev/null 2>&1 && echo valid" "jq -e . .env >/dev/null 2>&1 && echo valid"
# A real non-jq dump through stdout_sent_off_transcript WITHOUT
# require_stderr_sink: the stdout-only /dev/null sink still allows it (same
# legacy exemption as the `env >/dev/null` row earlier in this file).
expect_allow "printenv > /dev/null (non-jq)" "printenv > /dev/null"
# Review round 3, finding 5: the same default pinned on the substitution path —
# a command substitution takes stdout_sent_off_transcript down the legacy
# `_stdout_discarded_to_devnull` walk, still without a stderr-sink requirement
# (measured allow before pinning).
expect_allow 'printenv > /dev/null; x=$(date) (non-jq)' 'printenv > /dev/null; x=$(date)'
expect_allow "jq . .env > /tmp/x 2>/dev/null" "jq . .env > /tmp/x 2>/dev/null"
expect_allow "jq . .env &> /tmp/x" "jq . .env &> /tmp/x"
expect_allow "jq . .env > /tmp/x 2>&1" "jq . .env > /tmp/x 2>&1"
expect_allow "jq . .env > /tmp/x 2>/tmp/err" "jq . .env > /tmp/x 2>/tmp/err"

# --- Bypass: SYG_ALLOW_ENV_PRINT=1 ---
expect_allow "SYG_ALLOW_ENV_PRINT=1 env" "SYG_ALLOW_ENV_PRINT=1 env"
expect_allow "(SYG_ALLOW_ENV_PRINT=1 env)" "(SYG_ALLOW_ENV_PRINT=1 env)"
expect_allow "SYG_ALLOW_ENV_PRINT=1 jq . .env" "SYG_ALLOW_ENV_PRINT=1 jq . .env"

# --- Pinned fail-open: double-quoted command substitution is not split by
# lib/shell_quotes.py command_pipelines, so the hook stays silent. ---
# shellcheck disable=SC2016
expect_allow "double-quoted command substitution (unsplit by command_pipelines)" 'echo "$(env)"'

# Round 7 §10: under a substitution the legacy `/dev/null` walk still governs,
# but jq sinks now demand an explicit fd-2 sink there too — the plain
# stdout-only form denies; `2>&1` after the null still sinks fd 2.
expect_deny 'jq -e . s.json >/dev/null && for i in $(seq 3); do :; done' 'jq -e . ~/.claude/settings.json >/dev/null && for i in $(seq 3); do :; done' "bulk jq filter"
expect_allow 'jq . .env > /dev/null 2>&1; x=$(date)' 'jq . .env > /dev/null 2>&1; x=$(date)'
# Review round 2: one allow row per remaining seen_fd2 branch of the legacy
# /dev/null walk — `&>` compact and spaced, `2>` compact and spaced.
expect_allow 'jq . .env &>/dev/null; x=$(date)' 'jq . .env &>/dev/null; x=$(date)'
expect_allow 'jq . .env &> /dev/null; x=$(date)' 'jq . .env &> /dev/null; x=$(date)'
expect_allow 'jq . .env > /dev/null 2>/dev/null; x=$(date)' 'jq . .env > /dev/null 2>/dev/null; x=$(date)'
expect_allow 'jq . .env > /dev/null 2> /dev/null; x=$(date)' 'jq . .env > /dev/null 2> /dev/null; x=$(date)'
expect_deny 'jq . .env >/dev/null >&2; echo $(date)' 'jq . .env >/dev/null >&2; echo $(date)' "bulk jq filter"
expect_deny "jq . .env '>' /dev/null" "jq . .env '>' /dev/null" "bulk jq filter"
expect_deny 'jq . .env \> /dev/null' 'jq . .env \> /dev/null' "bulk jq filter"
expect_deny 'jq . .env ">/dev/null"' 'jq . .env ">/dev/null"' "bulk jq filter"
expect_allow "jq . .env > out.txt 2>/dev/null" "jq . .env > out.txt 2>/dev/null"
expect_deny ". ./x; env > out.txt" ". ./x; env > out.txt" "bulk environment dump via"
expect_deny "source ./x && env > out.txt" "source ./x && env > out.txt" "bulk environment dump via"
expect_deny "FOO=1 eval true; env > out.txt" "FOO=1 eval true; env > out.txt" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'X=/dev/stderr; env > $X' 'X=/dev/stderr; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'X=/dev/stderr; env > ${X}/x' 'X=/dev/stderr; env > ${X}/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'export X=/dev/stderr && env > $X' 'export X=/dev/stderr && env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read X < f; env > $X' 'read X < f; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'for X in /dev/stderr; do env > $X; done' 'for X in /dev/stderr; do env > $X; done' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'X=/dev/stderr; jq . .env > /tmp/x 2>$X' 'X=/dev/stderr; jq . .env > /tmp/x 2>$X' "bulk jq filter"
# shellcheck disable=SC2016
expect_deny 'printf -v X /dev/stderr; env > $X' 'printf -v X /dev/stderr; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read -n 100 X <<< /dev/stderr; env > $X' 'read -n 100 X <<< /dev/stderr; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read <<< /dev/stderr; env > $REPLY' 'read <<< /dev/stderr; env > $REPLY' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny ': ${X:=/dev/stderr}; env > $X' ': ${X:=/dev/stderr}; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'eval "X=/dev/stderr"; env > $X' 'eval "X=/dev/stderr"; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'set -- /dev/stderr; for X; do env > $X; done' 'set -- /dev/stderr; for X; do env > $X; done' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'printf -vX /dev/stderr; env > $X' 'printf -vX /dev/stderr; env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'true /dev/stderr; env > $_' 'true /dev/stderr; env > $_' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'cd /dev; env > $PWD/stderr' 'cd /dev; env > $PWD/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env > $OPTARG' 'env > $OPTARG' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env > $X' 'env > $X' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny ': ${HOME:=/dev}; env > $HOME/stderr' ': ${HOME:=/dev}; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'eval true; env > $HOME/x' 'eval true; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'HOME=/dev; env > $HOME/stderr' 'HOME=/dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'export "HOME=/dev"; env > $HOME/stderr' 'export "HOME=/dev"; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'declare -n R=HOME; R=/dev; env > $HOME/stderr' 'declare -n R=HOME; R=/dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'export H"OME"=/dev; env > $HOME/stderr' 'export H"OME"=/dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'declare H\OME=/dev; env > $HOME/stderr' 'declare H\OME=/dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'printf -v "HOME" %s /dev; env > $HOME/stderr' 'printf -v "HOME" %s /dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read H\OME <<< /dev; env > $HOME/stderr' 'read H\OME <<< /dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'mapfile -t "HOME" <<< /dev; env > $HOME/stderr' 'mapfile -t "HOME" <<< /dev; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'unset HOME; : ${HOME[0]:=/dev}; env > $HOME/stderr' 'unset HOME; : ${HOME[0]:=/dev}; env > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'env ${HOME[0]:=/dev} > $HOME/stderr' 'env ${HOME[0]:=/dev} > $HOME/stderr' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'HOME=/dev env > $HOME/x' 'HOME=/dev env > $HOME/x' "bulk environment dump via"
# Non-prefix assignment forms (read, for/select, printf -v, mapfile/readarray,
# getopts) across separate statements are denied by the single-statement rule.
# shellcheck disable=SC2016
expect_deny 'read HOME <<< /dev; env > $HOME/x' 'read HOME <<< /dev; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read HOME <<< /dev NEWLINE env > $HOME/x' $'read HOME <<< /dev\nenv > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'for HOME in /dev; do env > $HOME/x; done' 'for HOME in /dev; do env > $HOME/x; done' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'for HOME in /dev NEWLINE do NEWLINE env > $HOME/x NEWLINE done' $'for HOME in /dev\ndo\nenv > $HOME/x\ndone' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'select HOME in /dev; do env > $HOME/x; done' 'select HOME in /dev; do env > $HOME/x; done' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'printf -v HOME /dev; env > $HOME/x' 'printf -v HOME /dev; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'mapfile HOME < f; env > $HOME/x' 'mapfile HOME < f; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'readarray -t HOME < f; env > $HOME/x' 'readarray -t HOME < f; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'getopts a HOME; env > $HOME/x' 'getopts a HOME; env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'getopts a HOME NEWLINE env > $HOME/x' $'getopts a HOME\nenv > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'while read HOME; do env > $HOME/x; done < f' 'while read HOME; do env > $HOME/x; done < f' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'while read HOME NEWLINE do NEWLINE env > $HOME/x NEWLINE done < f' $'while read HOME\ndo\nenv > $HOME/x\ndone < f' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read HOME <<< /dev && env > $HOME/x' 'read HOME <<< /dev && env > $HOME/x' "bulk environment dump via"
# A pipeline segment runs in a subshell, but the raw-text assignment scan reads
# the whole command and over-denies both prefix assignments and `read` there.
# shellcheck disable=SC2016
expect_deny 'export HOME=/dev | env > $HOME/x' 'export HOME=/dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'read HOME <<< /dev | env > $HOME/x' 'read HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# A single pipeline per case, so only the raw-text assignment scan can deny them.
# shellcheck disable=SC2016
expect_deny 'for HOME in /dev | env > $HOME/x' 'for HOME in /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'printf -v HOME /dev | env > $HOME/x' 'printf -v HOME /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'mapfile HOME < f | env > $HOME/x' 'mapfile HOME < f | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'getopts a HOME | env > $HOME/x' 'getopts a HOME | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '\read HOME <<< /dev | env > $HOME/x' '\read HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '\printf -v HOME /dev | env > $HOME/x' '\printf -v HOME /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "''read HOME <<< /dev | env > \$HOME/x" "''read HOME <<< /dev | env > \$HOME/x" "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '${e}read HOME <<< /dev | env > $HOME/x' '${e}read HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '$@read HOME <<< /dev | env > $HOME/x' '$@read HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '$1read HOME <<< /dev | env > $HOME/x' '$1read HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'select HOME in /dev | env > $HOME/x' 'select HOME in /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'readarray HOME < f | env > $HOME/x' 'readarray HOME < f | env > $HOME/x' "bulk environment dump via"
# Accepted over-deny of the unanchored scan.
# shellcheck disable=SC2016
expect_deny 'xread HOME <<< /dev | env > $HOME/x' 'xread HOME <<< /dev | env > $HOME/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '# <<true NEWLINE read HOME <<< /dev/stdout NEWLINE true NEWLINE env > $HOME' $'# <<true\nread HOME <<< /dev/stdout\ntrue\nenv > $HOME' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '# <<true NEWLINE printf -v HOME /dev/stdout NEWLINE true NEWLINE env > $HOME' $'# <<true\nprintf -v HOME /dev/stdout\ntrue\nenv > $HOME' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny '# <<true NEWLINE eval x NEWLINE true NEWLINE env > $HOME' $'# <<true\neval x\ntrue\nenv > $HOME' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'echo "<<true" NEWLINE read HOME <<< /dev/stdout NEWLINE true NEWLINE env > $HOME' $'echo "<<true"\nread HOME <<< /dev/stdout\ntrue\nenv > $HOME' "bulk environment dump via"
# A bare `$VAR` target with no path after it.
# shellcheck disable=SC2016
expect_allow 'env > $HOME' 'env > $HOME'
# accepted over-deny: the unanchored scan reads `read HOME` inside `.thread HOME`
# shellcheck disable=SC2016
expect_deny "jq '.[] | .thread HOME' .env > \$HOME/out 2>/dev/null" "jq '.[] | .thread HOME' .env > \$HOME/out 2>/dev/null" "bulk jq filter"
# shellcheck disable=SC2016
expect_allow 'env > $HOME/x # note' 'env > $HOME/x # note'
# A here-string (`<<<`) is not a heredoc opener and keeps trust; a heredoc ends relative-target trust.
# shellcheck disable=SC2016
expect_allow 'env > $HOME/x <<< foo' 'env > $HOME/x <<< foo'
expect_deny "env > out.txt <<'E' NEWLINE x NEWLINE E" $'env > out.txt <<\'E\'\nx\nE' "bulk environment dump via"
expect_deny "env > out.txt <<-E NEWLINE x NEWLINE E" $'env > out.txt <<-E\nx\nE' "bulk environment dump via"
expect_deny "env > out.txt <<E NEWLINE x NEWLINE E" $'env > out.txt <<E\nx\nE' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env > \$TMPDIR/x <<'E' NEWLINE x NEWLINE E" $'env > $TMPDIR/x <<\'E\'\nx\nE' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env > \$TMPDIR/x <<-E NEWLINE x NEWLINE E" $'env > $TMPDIR/x <<-E\nx\nE' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "env > \$TMPDIR/x <<E NEWLINE x NEWLINE E" $'env > $TMPDIR/x <<E\nx\nE' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'echo $((1<<4)) | env > $TMPDIR/x (accepted over-deny)' 'echo $((1<<4)) | env > $TMPDIR/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny "read -rp 'x' HOME <<< /dev | env > \$HOME/x" "read -rp 'x' HOME <<< /dev | env > \$HOME/x" "bulk environment dump via"
expect_deny '# <<x NEWLINE env NEWLINE x' $'# <<x\nenv\nx' "bulk environment dump via"
expect_deny 'echo "<<x" NEWLINE env NEWLINE x' $'echo "<<x"\nenv\nx' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'echo $(true)#; env' 'echo $(true)#; env' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'echo ${a:- #}; env' 'echo ${a:- #}; env' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'echo `echo hi #`; env' 'echo `echo hi #`; env' "bulk environment dump via"
expect_allow '(true)#; env' '(true)#; env'
expect_deny 'H1: stray quote inside "$(cat <<EOF …)" body before env; echo "x"' $'git commit -m "$(cat <<\'EOF\'\nSupport 27" monitors\nEOF\n)"\nenv; echo "x"' "bulk environment dump via"
expect_deny "H2a: ((1))# it's NEWLINE env" $'((1))# it\'s\nenv' "bulk environment dump via"
expect_deny "H2b: case x in *)# it's NEWLINE env;; esac" $'case x in *)# it\'s\nenv;; esac' "bulk environment dump via"
# shellcheck disable=SC2016
expect_deny 'H3: echo `#\``#; env' 'echo `#\``#; env' "bulk environment dump via"
expect_deny "M1: echo \${x:-\$(cat <<A ...)} NEWLINE env; echo 'x'" $'echo ${x:-$(cat <<A\nit\'s\nA\n)}\nenv; echo \'x\'' "bulk environment dump via"
expect_deny 'M2: cat <<A `: <<B` NEWLINE a NEWLINE A NEWLINE env NEWLINE B' $'cat <<A `: <<B`\na\nA\nenv\nB' "bulk environment dump via"
# Round 3: these pin regressions found in earlier rounds of this rewrite, which main did not have.
expect_deny "BT1: x=\`cat <<EOF NEWLINE it's NEWLINE EOF NEWLINE \` NEWLINE env; echo 'done'" $'x=`cat <<EOF\nit\'s\nEOF\n`\nenv; echo \'done\'' "bulk environment dump via"
expect_deny "BT3: x=\`case a in a) cat <<'EOF' NEWLINE it's NEWLINE EOF NEWLINE ;; esac\` NEWLINE env; echo 'done'" $'x=`case a in a) cat <<\'EOF\'\nit\'s\nEOF\n;; esac`\nenv; echo \'done\'' "bulk environment dump via"
expect_deny "AR1: ((echo a) ; echo b # it's NEWLINE env # don't NEWLINE )" $'((echo a) ; echo b # it\'s\nenv # don\'t\n)' "bulk environment dump via"
expect_deny "CS1: x=\"\$(case a in a) cat <<'EOF' NEWLINE it's 27\" wide NEWLINE EOF NEWLINE ;; esac)\" NEWLINE env; echo \"done\"" $'x="$(case a in a) cat <<\'EOF\'\nit\'s 27" wide\nEOF\n;; esac)"\nenv; echo "done"' "bulk environment dump via"
# shellcheck disable=SC2016
expect_allow 'env > $TMPDIR/x' 'env > $TMPDIR/x'
# shellcheck disable=SC2016
expect_deny 'Y=1; env > $TMPDIR/x' 'Y=1; env > $TMPDIR/x' "bulk environment dump via"
# shellcheck disable=SC2016
expect_allow 'env > $HOME/x' 'env > $HOME/x'
# shellcheck disable=SC2016
expect_allow 'env > ${TMPDIR}/x' 'env > ${TMPDIR}/x'
# shellcheck disable=SC2016
expect_allow 'env > $CLAUDE_JOB_DIR/tmp/e' 'env > $CLAUDE_JOB_DIR/tmp/e'
# shellcheck disable=SC2016
SYG_EPG_TRUSTED_VARS=MYDIR expect_allow 'env > $MYDIR/x (SYG_EPG_TRUSTED_VARS=MYDIR)' 'env > $MYDIR/x'
# shellcheck disable=SC2016
SYG_EPG_TRUSTED_VARS='A-B OUT' expect_allow "env > \${OUT} (SYG_EPG_TRUSTED_VARS='A-B OUT')" 'env > ${OUT}'
# shellcheck disable=SC2016
SYG_EPG_TRUSTED_VARS='A-B OUT' expect_deny "env > \$AB/x (SYG_EPG_TRUSTED_VARS='A-B OUT')" 'env > $AB/x' "bulk environment dump via"

# --- Fail-open on malformed JSON ---
out=$(printf 'not json {' | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass=$((pass + 1))
else
  echo "FAIL [malformed JSON]: expected rc=0 + silent, got rc=$rc out=$out" >&2
  fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: env-print-guard ($pass cases)"
