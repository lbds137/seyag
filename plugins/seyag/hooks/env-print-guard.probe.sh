#!/usr/bin/env bash
# Probe for env-print-guard.sh.
# Exercises bulk env/printenv/set dumps, downstream names-only selector
# allowlist, value-preserving filter rejections, jq bulk vs specific/keys
# reads on .env and settings.json, SYG_ALLOW_ENV_PRINT=1 bypass, and
# fail-open behavior on shapes outside command_pipelines.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/env-print-guard.sh"

pass=0
fail=0

payload_for() {
  jq -nc --arg cmd "$1" '{tool_name:"Bash",tool_input:{command:$cmd}}'
}

expect_allow() {
  local label="$1" cmd="$2" out err rc tmp_err
  tmp_err=$(mktemp)
  out=$(payload_for "$cmd" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>"$tmp_err")
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
  out=$(payload_for "$cmd" | env -i PATH="$PATH" HOME="$HOME" bash "$HOOK" 2>"$tmp_err")
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
expect_deny "set > /tmp/env-dump-fixture" "set > /tmp/env-dump-fixture" "bulk environment dump via"
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
expect_allow "jq -e . ~/.claude/settings.json >/dev/null" "jq -e . ~/.claude/settings.json >/dev/null"
# shellcheck disable=SC2016
expect_allow "rewritten delegation skill command" 'for v in $(env | cut -s -d= -f1 | grep '\''^ANTHROPIC_DEFAULT_.*_MODEL$'\''); do printf '\''%s=%s\n'\'' "$v" "$(printenv "$v")"; done'

# --- Bypass: SYG_ALLOW_ENV_PRINT=1 ---
expect_allow "SYG_ALLOW_ENV_PRINT=1 env" "SYG_ALLOW_ENV_PRINT=1 env"
expect_allow "(SYG_ALLOW_ENV_PRINT=1 env)" "(SYG_ALLOW_ENV_PRINT=1 env)"
expect_allow "SYG_ALLOW_ENV_PRINT=1 jq . .env" "SYG_ALLOW_ENV_PRINT=1 jq . .env"

# --- Pinned fail-open: double-quoted command substitution is not split by
# lib/shell_quotes.py command_pipelines, so the hook stays silent. ---
# shellcheck disable=SC2016
expect_allow "double-quoted command substitution (unsplit by command_pipelines)" 'echo "$(env)"'

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
