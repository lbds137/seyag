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

# A substitution elsewhere keeps the legacy jq `> /dev/null` exemption, only in its plain form.
expect_allow 'jq -e . s.json >/dev/null && for i in $(seq 3); do :; done' 'jq -e . ~/.claude/settings.json >/dev/null && for i in $(seq 3); do :; done'
expect_allow 'jq . .env > /dev/null 2>&1; x=$(date)' 'jq . .env > /dev/null 2>&1; x=$(date)'
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
