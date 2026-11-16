#!/bin/bash
# Fixture check for plugins/seyag/bin/gate-run: step execution, per-step logs, failure continuation,
# zero-step exit 7, relative --out with --cd, and error exit codes.
# Usage: tests/gate-run.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GR="$REPO/plugins/seyag/bin/gate-run"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

# 1. All pass -> exit 0 and per-step logs under an absolute out dir
out=$("$GR" --out "$t/abs-out" 'lint:echo lint-ok' 'test:echo test-out; echo test-err >&2' 2>&1); rc=$?
[ "$rc" = 0 ] \
  && grep -qx "lint exit 0" <<<"$out" \
  && grep -qx "test exit 0" <<<"$out" \
  && [ "$(tail -n 1 <<<"$out")" = "gate-run: 2 of 2 steps passed" ] \
  && [ "$(cat "$t/abs-out/lint.log" 2>/dev/null)" = "lint-ok" ] \
  && grep -qx "test-out" "$t/abs-out/test.log" 2>/dev/null \
  && grep -qx "test-err" "$t/abs-out/test.log" 2>/dev/null \
  && ok "all pass: exit 0, per-step logs written under absolute out dir, summary line printed" \
  || bad "all pass (rc $rc: $out)"

# 2. One failing step -> exit 1, later steps still ran
out=$("$GR" --out "$t/fail-out" 'first:echo one; exit 3' 'second:echo two' 2>&1); rc=$?
[ "$rc" = 1 ] \
  && grep -qx "first exit 3" <<<"$out" \
  && grep -qx "second exit 0" <<<"$out" \
  && [ "$(tail -n 1 <<<"$out")" = "gate-run: 1 of 2 steps passed" ] \
  && [ "$(cat "$t/fail-out/first.log" 2>/dev/null)" = "one" ] \
  && [ "$(cat "$t/fail-out/second.log" 2>/dev/null)" = "two" ] \
  && ok "one failing step: exit 1, later steps still ran and logged" \
  || bad "one failing step (rc $rc: $out)"

# 3. Zero steps -> exit 7 with "gate-run: no step ran"
out=$("$GR" --out "$t/zero-out" 2>&1); rc=$?
[ "$rc" = 7 ] && grep -q "gate-run: no step ran" <<<"$out" \
  && ok "zero steps: exit 7 with 'gate-run: no step ran'" \
  || bad "zero steps (rc $rc: $out)"

# 4. Relative --out with --cd elsewhere -> logs land under caller's cwd, not the cd dir
mkdir -p "$t/caller" "$t/worktree"
out=$(cd "$t/caller" && "$GR" --out rel-logs --cd "$t/worktree" 'pwd-step:pwd' 2>&1); rc=$?
[ "$rc" = 0 ] \
  && [ -f "$t/caller/rel-logs/pwd-step.log" ] \
  && [ ! -e "$t/worktree/rel-logs" ] \
  && [ "$(cat "$t/caller/rel-logs/pwd-step.log" 2>/dev/null)" = "$t/worktree" ] \
  && ok "relative --out with --cd: logs land under caller cwd while step runs in --cd dir" \
  || bad "relative --out with --cd (rc $rc: $out)"

# 5. Bad STEP shapes and usage errors -> exit 2
for bad_args in \
  "--out $t/u1 nocmd" \
  "--out $t/u1 :echo" \
  "--out $t/u1 bad/name:echo" \
  "--out $t/u1 empty:" \
  "lint:true" \
  "--out" \
  "--out $t/u1 --cd" \
  "--out $t/u1 --bogus lint:true"; do
  # shellcheck disable=SC2086
  "$GR" $bad_args >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "usage error '$bad_args' exits 2" || bad "usage error '$bad_args' (got $rc, want 2)"
done

# 6. --out mkdir failure -> exit 8
touch "$t/regular-file"
"$GR" --out "$t/regular-file/sub" 'a:true' >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && ok "--out under a regular file exits 8" || bad "--out failure (got $rc, want 8)"

# 7. --cd failure -> exit 9
"$GR" --out "$t/cd-out" --cd "$t/no-such-dir" 'a:true' >/dev/null 2>&1; rc=$?
[ "$rc" = 9 ] && ok "--cd to missing dir exits 9" || bad "--cd failure (got $rc, want 9)"

# 9. duplicate step names would overwrite each other's log -> usage error, nothing runs
"$GR" --out "$t/dup-out" 'dup:echo 1' 'dup:echo 2' >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$t/dup-out/dup.log" ] && ok "duplicate step name exits 2 and runs nothing" || bad "duplicate step name (got $rc, want 2, no log)"

# 10. steps get /dev/null on stdin, so a reading step can't eat the caller's input
out=$(echo caller-input | "$GR" --out "$t/stdin-out" 'rd:cat' 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$t/stdin-out/rd.log" ] && ok "a step reads /dev/null, not the caller's stdin" || bad "step stdin (rc $rc, log: $(cat "$t/stdin-out/rd.log" 2>/dev/null))"

# 8. --help / -h -> exit 0
out=$("$GR" --help 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q "gate-run" <<<"$out" && ok "--help prints usage and exits 0" || bad "--help (rc $rc: $out)"

exit $fail
