#!/usr/bin/env bash
# Hermetic probe for plugins/seyag/bin/long-job-chain-check: parser, SYG_LONG_JOB_CMD runner aliases,
# and --hook modes.
# Usage: tests/long-job-chain-check.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$REPO/plugins/seyag/bin/long-job-chain-check"
[ -x "$CHK" ] || { echo "FAIL  $CHK is not executable (chmod +x it)"; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/long-job-chain-check-probe.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }

unset SYG_LONG_JOB_CMD
export XDG_CONFIG_HOME="$tmp/cfg"
export CLAUDE_PROJECT_DIR="$tmp/proj"

refuse() {
  local label=$1 cmd=$2 runner=${3:-long-job} out rc
  out=$(timeout 5 "$CHK" "$cmd" 2>&1); rc=$?
  [ "$rc" = 3 ] && grep -q "^${runner}: refusing: '&& …' after '${runner} run " <<<"$out" \
    && grep -q "Put the chain inside the job: ${runner} run " <<<"$out" \
    && ok "$label" || bad "$label (rc $rc: $out)"
}

clean() {
  local label=$1 cmd=$2 out rc
  out=$(timeout 5 "$CHK" "$cmd" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok "$label" || bad "$label (rc $rc: $out)"
}

warn_only() {
  local label=$1 cmd=$2 needle=$3 out rc
  out=$(timeout 5 "$CHK" "$cmd" 2>&1); rc=$?
  [ "$rc" = 0 ] && grep -q "$needle" <<<"$out" && ! grep -q "refusing:" <<<"$out" \
    && ok "$label" || bad "$label (rc $rc: $out)"
}

out=$(timeout 5 "$CHK" --help 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "^Usage:" <<<"$out" && ok "--help prints usage and exits 0" || bad "--help (rc $rc: $out)"

refuse "long-job run N -- a && b refuses" "long-job run N -- a && b"
clean "long-job run N -- bash -c 'a && b' is clean" "long-job run N -- bash -c 'a && b'"
clean "cd x && long-job run N -- a is clean" "cd x && long-job run N -- a"
clean "preflight && long-job run shape is clean" \
  'prep-tool --lint-only --edit "$(cat spec.md)" && long-job run NAME -- bash -c '\''prep-tool --edit "$(cat "$1")" > "$2" 2> "$3"'\'' _ "$PWD/spec.md" "$PWD/out" "$PWD/err"'
refuse "long-job run N -- a | tee f && b refuses across pipe" "long-job run N -- a | tee f && b"
warn_only "long-job run N -- a || echo x warns only (exit 0)" "long-job run N -- a || echo x" \
  "^long-job: warning: '|| …' after 'long-job run N' runs only if the START fails, not the job; the job's result comes from long-job wait N\."
warn_only "CLAUDE_X=1 long-job run N -- a warns on prefixed CLAUDE_ var" "CLAUDE_X=1 long-job run N -- a" \
  "^long-job: warning: CLAUDE_X is set on long-job's command line but the job never sees it; pass it with --env CLAUDE_X\."
warn_only "SYG_X=1 long-job run N -- a warns on prefixed SYG_ var" "SYG_X=1 long-job run N -- a" \
  "^long-job: warning: SYG_X is set on long-job's command line but the job never sees it; pass it with --env SYG_X\."
clean "CLAUDE_X=1 long-job run N --env CLAUDE_X -- a is clean" "CLAUDE_X=1 long-job run N --env CLAUDE_X -- a"
clean "FOO=1 long-job run N -- a is clean" "FOO=1 long-job run N -- a"
clean "newline separates long-job run N -- a from b && c" "$(printf 'long-job run N -- a\nb && c')"
refuse "/abs/bin/long-job run N -- a && b refuses" "/abs/bin/long-job run N -- a && b"
refuse "time long-job run N -- a && b refuses (prefix word)" "time long-job run N -- a && b"
refuse "sudo -E long-job run N -- a && b refuses (prefix word + option)" "sudo -E long-job run N -- a && b"
refuse "nice -n 10 long-job run x -- a && b refuses (prefix option arg)" "nice -n 10 long-job run x -- a && b"
refuse "sudo -u me long-job run n -- c && d refuses (prefix option arg)" "sudo -u me long-job run n -- c && d"
refuse "timeout 60 long-job run n -- c && d refuses (prefix positional)" "timeout 60 long-job run n -- c && d"
refuse "timeout -s KILL 60 long-job run n -- c && d refuses (prefix option arg + positional)" "timeout -s KILL 60 long-job run n -- c && d"
refuse "stdbuf -oL long-job run n -- c && d refuses (attached option value)" "stdbuf -oL long-job run n -- c && d"
refuse "env FOO=1 long-job run n -- c && d refuses (env assignment)" "env FOO=1 long-job run n -- c && d"
refuse "nice -n 5 timeout 60 long-job run n -- c && d refuses (chained prefixes)" "nice -n 5 timeout 60 long-job run n -- c && d"
warn_only "env CLAUDE_X=1 long-job run n -- c warns on unforwarded CLAUDE_X" "env CLAUDE_X=1 long-job run n -- c" \
  "^long-job: warning: CLAUDE_X is set on long-job's command line but the job never sees it; pass it with --env CLAUDE_X\."
clean "env CLAUDE_X=1 long-job run n --env CLAUDE_X -- c is clean" "env CLAUDE_X=1 long-job run n --env CLAUDE_X -- c"
refuse "backslash-newline before && still refuses" "$(printf 'long-job run N -- a \\\n&& b')"
clean "exec long-job run N -- a && b is clean (nothing runs after exec)" "exec long-job run N -- a && b"

# whitespace_split + operator splitting + brace groups + $(...) folding
refuse "FOO=\$bar long-job run x -- make && echo hi refuses" 'FOO=$bar long-job run x -- make && echo hi'
out=$(timeout 5 "$CHK" 'SYG_X=a:b long-job run x -- make && echo hi' 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q "^long-job: refusing: '&& …' after 'long-job run x'" <<<"$out" \
  && grep -q "^long-job: warning: SYG_X is set on long-job's command line but the job never sees it; pass it with --env SYG_X\." <<<"$out" \
  && ok "SYG_X=a:b long-job run x -- make && echo hi refuses and prints SYG_X warning" \
  || bad "SYG_X=a:b refuse+warn (rc $rc: $out)"
refuse "PATH=/a:/b long-job run x -- make && echo hi refuses" 'PATH=/a:/b long-job run x -- make && echo hi'
warn_only "SYG_TOKEN=\$t long-job run x -- make warns about SYG_TOKEN" 'SYG_TOKEN=$t long-job run x -- make' \
  "^long-job: warning: SYG_TOKEN is set on long-job's command line but the job never sees it; pass it with --env SYG_TOKEN\."
out=$(timeout 5 "$CHK" 'long-job run $N -- make && echo hi' 2>&1); rc=$?
[ "$rc" = 3 ] && grep -qF "long-job: refusing: '&& …' after 'long-job run \$N'" <<<"$out" \
  && grep -qF "Put the chain inside the job: long-job run \$N -- bash -c 'a && b'" <<<"$out" \
  && ok "long-job run \$N -- make && echo hi refuses naming \$N as the job" \
  || bad "long-job run \$N (rc $rc: $out)"
refuse "(long-job run x -- a)&&b refuses (no spaces)" '(long-job run x -- a)&&b'
refuse "{ long-job run x -- foo; } && echo refuses (brace group)" '{ long-job run x -- foo; } && echo'
refuse "x=\$(foo) long-job run x -- a && b refuses (x=\$(...) fold intact)" 'x=$(foo) long-job run x -- a && b'
refuse "x=\$(long-job run x -- a && b) refuses (substitution interior)" 'x=$(long-job run x -- a && b)'
clean "long-job run x -- make; echo hi is not refused (control)" 'long-job run x -- make; echo hi'

# Substitution interiors are shell text of their own, plus the unquoted operators
# after them (the $( ) waits only for the start); single-quoted prose is data.
refuse "echo \"\$(long-job run x -- a && b)\" refuses (quoted substitution)" 'echo "$(long-job run x -- a && b)"'
refuse "echo \`long-job run x -- a && b\` refuses (backtick)" 'echo `long-job run x -- a && b`'
clean "echo '\$(long-job run x -- a && b)' is data (single-quoted prose)" "echo '\$(long-job run x -- a && b)'"
wq="'\"'\"'"
printf -v prose_ok 'source /etc/profile && eval '\''echo %s$(long-job run x -- a && b)%s'\'' && pwd -P >| /tmp/claude-cwd' "$wq" "$wq"
clean "Bash-tool eval wrapper around single-quoted substitution prose is data" "$prose_ok"
refuse "x=\$(long-job run x -- a) && b refuses (\$( ) waits only for the start)" 'x=$(long-job run x -- a) && b'
refuse "cat <(long-job run x -- a && b) refuses (process substitution)" 'cat <(long-job run x -- a && b)'
refuse "cat <(long-job run x -- a) && b refuses (procsub tail)" 'cat <(long-job run x -- a) && b'
clean "cat <(long-job run x -- a; echo b) is clean (seq ends the interior)" 'cat <(long-job run x -- a; echo b)'
clean "echo > >(long-job run x -- a; echo b) is clean (procsub seq)" 'echo > >(long-job run x -- a; echo b)'

# Heredoc bodies are data; a shell reading its script from stdin runs them as code.
clean "cat <<'EOF' body quoting a chain is clean" "$(printf 'cat <<'"'"'EOF'"'"'\nlong-job run x -- a && b\nEOF\n')"
clean "cat <<EOF unquoted-delimiter body is clean" "$(printf 'cat <<EOF\nlong-job run x -- a && b\nEOF\n')"
clean "cat <<-EOF tab-indented terminator body is clean" "$(printf 'cat <<-EOF\n\tlong-job run x -- a && b\n\tEOF\n')"
clean "gh pr create --body-file - <<'EOF' body is clean" "$(printf 'gh pr create --body-file - <<'"'"'EOF'"'"'\nlong-job run x -- a && b\nEOF\n')"
refuse "cat <<EOF | bash runs the body as code (stdin-shell)" "$(printf 'cat <<EOF | bash\nlong-job run x -- a && b\nEOF\n')"
refuse "bash <<EOF runs the body as code (stdin-shell)" "$(printf 'bash <<EOF\nlong-job run x -- a && b\nEOF\n')"
refuse "sh -s <<EOF runs the body as code (stdin-shell)" "$(printf 'sh -s <<EOF\nlong-job run x -- a && b\nEOF\n')"
refuse "&& on the heredoc opener line still refuses" "$(printf "long-job run x -- a && b <<'EOF'\nbody\nEOF\n")"

# Leading reserved words hide argv[0].
refuse "if long-job run x -- a && b; then :; fi refuses" 'if long-job run x -- a && b; then :; fi'
refuse "! long-job run x -- a && b refuses" '! long-job run x -- a && b'
refuse "while long-job run x -- a && b; do :; done refuses" 'while long-job run x -- a && b; do :; done'
refuse "for f in 1; do long-job run \$f -- a && b; done refuses (do)" 'for f in 1; do long-job run $f -- a && b; done'
refuse "until long-job run x -- a && b; do :; done refuses" 'until long-job run x -- a && b; do :; done'
clean "if long-job run x -- a; then b; fi is clean" 'if long-job run x -- a; then b; fi'

# A quoted operator is an ordinary word, never an operator.
clean "long-job run x -- grep \"&&\" f is clean (quoted operator)" 'long-job run x -- grep "&&" f'
clean "long-job run x -- echo '||' ';' is clean (quoted operators)" "long-job run x -- echo '||' ';'"
clean "long-job run x -- grep 'a&&b' f is clean (quoted operator glued to word)" "long-job run x -- grep 'a&&b' f"
refuse "long-job run x -- grep 'a&&b' f && echo c refuses (real && after quoted operator)" \
  "long-job run x -- grep 'a&&b' f && echo c"

# Bash tool eval-wrapper shape: <wrapper> && eval '<user command>' && pwd -P >| /tmp/...
q="'\"'\"'"
printf -v eval_bad 'source /etc/profile && eval '\''long-job run N -- bash -c %secho a%s && echo b'\'' && pwd -P >| /tmp/claude-cwd' "$q" "$q"
printf -v eval_ok  'source /etc/profile && eval '\''long-job run N -- bash -c %secho a && echo b%s'\'' && pwd -P >| /tmp/claude-cwd' "$q" "$q"
refuse "eval-wrapper shape with && tail refuses" "$eval_bad"
clean "eval-wrapper shape without && tail is clean" "$eval_ok"

clean "unbalanced quote exits 0 with no findings" "long-job run N -- 'unbalanced && b"

# --hook mode
out=$(printf '%s' '{"tool_input":{"command":"long-job run N -- a && b"}}' | timeout 5 "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 2 ] && [ -z "$out" ] && grep -q "^long-job: refusing:" <<<"$err" \
  && ok "--hook with refuse JSON exits 2 and prints message on stderr" \
  || bad "--hook refuse (rc $rc, out [$out], err [$err])"

out=$(printf '%s' '{"tool_input":{"command":"long-job run N -- bash -c \"a && b\""}}' | timeout 5 "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$err" ] \
  && ok "--hook with clean JSON exits 0 silently" \
  || bad "--hook clean (rc $rc, out [$out], err [$err])"

out=$(printf '%s' '{"tool_input":{"command":"CLAUDE_X=1 long-job run N -- a || echo x"}}' | timeout 5 "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$err" ] \
  && ok "--hook with warnings only exits 0 silently" \
  || bad "--hook warn (rc $rc, out [$out], err [$err])"

out=$(printf '%s' 'not json at all' | timeout 5 "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$err" ] \
  && ok "--hook with non-JSON stdin exits 0 silently" \
  || bad "--hook non-JSON (rc $rc, out [$out], err [$err])"

out=$(printf '%s' '{"tool_input":{"command":123}}' | timeout 5 "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$err" ] \
  && ok "--hook with non-string command exits 0 silently" \
  || bad "--hook non-string (rc $rc, out [$out], err [$err])"

# --- SYG_LONG_JOB_CMD runner alias cases
out=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" "jobrun run x -- true && echo y" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q "^jobrun: refusing: '&& …' after 'jobrun run x'" <<<"$out" \
  && grep -q "Put the chain inside the job: jobrun run x -- bash -c 'a && b'" <<<"$out" \
  && ok "SYG_LONG_JOB_CMD='jobrun run' refuses 'jobrun run x -- true && echo y' with jobrun: refusing:" \
  || bad "alias refuse (rc $rc: $out)"

clean "without SYG_LONG_JOB_CMD, 'jobrun run x -- true && echo y' is clean" "jobrun run x -- true && echo y"

out=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" "/opt/x/jobrun run x -- a && b" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q "^jobrun: refusing: '&& …' after 'jobrun run x'" <<<"$out" \
  && ok "/opt/x/jobrun run x -- a && b with SYG_LONG_JOB_CMD='jobrun run' refuses (basename match)" \
  || bad "alias basename refuse (rc $rc: $out)"

out=$(timeout 5 env SYG_LONG_JOB_CMD='' "$CHK" "jobrun run x -- true && echo y" 2>&1); rc=$?
out2=$(timeout 5 env SYG_LONG_JOB_CMD='' "$CHK" "long-job run x -- true && echo y" 2>&1); rc2=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$rc2" = 3 ] && grep -q "^long-job: refusing:" <<<"$out2" \
  && ok "SYG_LONG_JOB_CMD='' behaves as unset" \
  || bad "SYG_LONG_JOB_CMD='' (rc=$rc/$rc2, out=[$out], out2=[$out2])"

out=$(printf '%s' '{"tool_input":{"command":"jobrun run x -- true && echo y"}}' | timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" --hook 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" = 2 ] && [ -z "$out" ] && grep -q "^jobrun: refusing:" <<<"$err" \
  && ok "--hook with SYG_LONG_JOB_CMD='jobrun run' and && chain exits 2 with refusal on stderr" \
  || bad "--hook alias refuse (rc $rc, out [$out], err [$err])"

out=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" "jobrun run N -- a || echo x" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "^jobrun: warning: '|| …' after 'jobrun run N' runs only if the START fails, not the job; the job's result comes from jobrun wait N\." <<<"$out" && ! grep -q "refusing:" <<<"$out" \
  && ok "SYG_LONG_JOB_CMD='jobrun run' warns on || tail (exit 0)" \
  || bad "alias || warn (rc $rc: $out)"

out=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" "CLAUDE_X=1 jobrun run N -- a" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "^jobrun: warning: CLAUDE_X is set on jobrun's command line but the job never sees it; pass it with --env CLAUDE_X\." <<<"$out" && ! grep -q "refusing:" <<<"$out" \
  && ok "SYG_LONG_JOB_CMD='jobrun run' warns on unforwarded CLAUDE_ var (exit 0)" \
  || bad "alias CLAUDE_ warn (rc $rc: $out)"

out=$(timeout 5 env SYG_LONG_JOB_CMD='jobrun run' "$CHK" "SYG_X=1 jobrun run N -- a" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "^jobrun: warning: SYG_X is set on jobrun's command line but the job never sees it; pass it with --env SYG_X\." <<<"$out" && ! grep -q "refusing:" <<<"$out" \
  && ok "SYG_LONG_JOB_CMD='jobrun run' warns on unforwarded SYG_ var (exit 0)" \
  || bad "alias SYG_ warn (rc $rc: $out)"

# Config loading: user seyag/config.toml setting syg_long_job_cmd = "jobrun run" refuses when env is unset; env overrides it.
mkdir -p "$tmp/cfg-cc/seyag"
printf 'syg_long_job_cmd = "jobrun run"\n' >"$tmp/cfg-cc/seyag/config.toml"
out=$(timeout 5 env -u SYG_LONG_JOB_CMD XDG_CONFIG_HOME="$tmp/cfg-cc" "$CHK" 'jobrun run N -- a && b' 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q "^jobrun: refusing: '&& …' after 'jobrun run N'" <<<"$out" \
  && ok "config.toml syg_long_job_cmd='jobrun run' with env unset refuses 'jobrun run N -- a && b' (exit 3)" \
  || bad "config.toml syg_long_job_cmd refuse (rc $rc: $out)"

out=$(timeout 5 env SYG_LONG_JOB_CMD='other run' XDG_CONFIG_HOME="$tmp/cfg-cc" "$CHK" 'jobrun run N -- a && b' 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "env SYG_LONG_JOB_CMD='other run' overrides config.toml so jobrun line is not refused" \
  || bad "env overrides config.toml syg_long_job_cmd (rc $rc: $out)"

# Linear in the substitution count: 40 substitutions ahead of the chain must answer inside the timeout.
many=$(printf 'echo $(date) %.0s' $(seq 40))
refuse "40 substitutions then a chained job refuses in time" "$many; long-job run x -- a && b"
clean "40 substitutions then a clean job is silent in time" "$many; long-job run x -- a"

# 640 spans (about 9 KB): spans whose interior names no runner cost nothing.
big=$(printf 'echo $(date) %.0s' $(seq 640))
refuse "640 substitutions then a chained job refuses in time" "$big; long-job run x -- a && b"
clean "640 substitutions then a clean job is silent in time" "$big; long-job run x -- a"
bigq=$(printf 'echo "$(date) $(date)" %.0s' $(seq 640))
refuse "640 quoted double substitutions then a chained job refuses in time" "$bigq; long-job run x -- a && b"

# The refusal names the job as typed, not the quote-mask placeholders.
out=$(timeout 5 "$CHK" "long-job run 'a;b' -- x && y" 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q "long-job run a;b" <<<"$out" \
  && ok "refusal names a quoted job name unmasked (a;b)" || bad "unmasked name (rc $rc: $out)"

# Nesting, substitution tails, groups and reserved words.
refuse 'nested $( ) around a chained job refuses' 'echo $(echo $(long-job run x -- a)) && bar'
refuse 'job then a quoted substitution then && refuses' 'echo $(long-job run x -- a) "$(date)" && b'
refuse 'backtick job then $( ) then && refuses' 'echo `long-job run x -- a` $(date) && b'
clean 'eval of a quoted && inside the job is silent' "eval 'long-job run x -- grep \"&&\" f'"
refuse 'brace group around a chained job refuses' '{ long-job run x -- a && b; }'
refuse 'time long-job run x -- a && b refuses' 'time long-job run x -- a && b'
refuse 'elif condition with a chained job refuses' 'if true; then :; elif long-job run x -- a && b; then :; fi'
refuse "quote-split runner name (lo''ng-job) still refuses" "lo''ng-job run x -- a && b"
refuse 'quote-split runner inside a substitution refuses' "printf %s \"\$(lo''ng-job run x -- a)\" && echo done"

echo "long-job-chain-check probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
