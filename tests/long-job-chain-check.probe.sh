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
clean "x=\$(long-job run x -- a && b) folds \$(...) into one word (clean)" 'x=$(long-job run x -- a && b)'
clean "long-job run x -- make; echo hi is not refused (control)" 'long-job run x -- make; echo hi'

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

echo "long-job-chain-check probe: $pass passed, $fail failed"
[ "$fail" = 0 ]
