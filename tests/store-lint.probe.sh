#!/usr/bin/env bash
# Probe for tests/store-lint.sh (the backlog-only direct path's store lint): clean store passes
# silently, a coupling token in a committed task body fails with coupling-lint's output, a
# priority-less To Do task fails with backlog-lint's output, and the live repo store passes.
# Usage: tests/store-lint.probe.sh   (from anywhere)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Hermetic config: no user or project seyag config file reaches the lint.
mkdir -p "$t/xdg" "$t/noproj"
export XDG_CONFIG_HOME="$t/xdg" CLAUDE_PROJECT_DIR="$t/noproj"
unset SYG_BACKLOG_PRIORITY_STATUSES

fx="$t/repo"
mkdir -p "$fx/tests" "$fx/plugins/seyag/bin" "$fx/plugins/seyag/lib" "$fx/backlog/tasks"
cp "$REPO/tests/store-lint.sh" "$REPO/tests/coupling-lint.probe.sh" "$fx/tests/"
# One licensed hit (token built at runtime), so the clean case exercises the allowlist;
# case e covers the empty allowlist.
tok="Li""la"
echo "owner: $tok" >"$fx/notes.txt"
echo "$tok:notes.txt" >"$fx/tests/coupling-allowlist.txt"
cp "$REPO/plugins/seyag/bin/backlog-lint" "$fx/plugins/seyag/bin/"
cp "$REPO/plugins/seyag/lib/config_env.py" "$fx/plugins/seyag/lib/"
cat >"$fx/backlog/config.yml" <<'CFG'
project: fixture-app
task_prefix: "task"
default_status: "To Do"
statuses:
  - To Do
  - Done
CFG
cat >"$fx/backlog/tasks/task-1 - fine.md" <<'TASK'
---
id: task-1
title: fine
status: To Do
priority: medium
---

A plain body.
TASK
git -C "$fx" init -q
git -C "$fx" config user.name probe
git -C "$fx" config user.email probe@example.invalid
git -C "$fx" add -A
git -C "$fx" commit -q -m fixture

# a. clean store -> exit 0, no output.
out=$(bash "$fx/tests/store-lint.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "case a: clean store exits 0 with no output" \
  || bad "case a: clean store (rc=$rc out=$out)"

# b. a committed task body carrying a coupling token (built above) -> coupling-lint failure.
cat >"$fx/backlog/tasks/task-2 - coupled.md" <<TASK
---
id: task-2
title: coupled
status: To Do
priority: low
---

Ask $tok about this.
TASK
git -C "$fx" add -A
git -C "$fx" commit -q -m coupled
out=$(bash "$fx/tests/store-lint.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"NEW COUPLING"* ]] && [[ $out == *"task-2 - coupled.md"* ]] \
  && [[ $out == *"store-lint: coupling-lint failed"* ]] \
  && ok "case b: coupling token fails with coupling-lint output and the task path" \
  || bad "case b: coupling token (rc=$rc out=$out)"
git -C "$fx" reset -q --hard HEAD~1

# c. a To Do task with no priority (no token) -> backlog-lint failure.
cat >"$fx/backlog/tasks/task-3 - unprioritized.md" <<'TASK'
---
id: task-3
title: unprioritized
status: To Do
---

No priority here.
TASK
git -C "$fx" add -A
git -C "$fx" commit -q -m unprioritized
out=$(bash "$fx/tests/store-lint.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"has no priority"* ]] \
  && [[ $out == *"store-lint: backlog-lint failed"* ]] \
  && ok "case c: priority-less task fails with backlog-lint output" \
  || bad "case c: priority-less task (rc=$rc out=$out)"

git -C "$fx" reset -q --hard HEAD~1

# e. an empty allowlist with no hits passes silently (coupling-lint once died on `set -u` here).
git -C "$fx" rm -q notes.txt
: >"$fx/tests/coupling-allowlist.txt"
git -C "$fx" add -A
git -C "$fx" commit -q -m empty-allowlist
out=$(bash "$fx/tests/store-lint.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "case e: empty allowlist, no hits: exits 0 with no output" \
  || bad "case e: empty allowlist (rc=$rc out=$out)"

# d. the live repo store passes silently.
out=$(bash "$REPO/tests/store-lint.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "case d: live repo store exits 0 with no output" \
  || bad "case d: live repo store (rc=$rc out=$out)"

exit "$fail"
