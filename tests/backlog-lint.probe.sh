#!/usr/bin/env bash
# Probe for plugins/seyag/bin/backlog-lint: CLI flags and exit codes, store discovery and walk-up,
# clean store pass, missing/empty/quoted/whitespace/body-only priority findings, quoted/casefolded
# and default_status status forms, frontmatter-less file skip, SYG_BACKLOG_PRIORITY_STATUSES knob,
# summary count, parity with plugins/seyag/hooks/backlog-priority-guard.sh, and live repo store.
# Usage: tests/backlog-lint.probe.sh   (from anywhere)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$REPO/plugins/seyag/bin/backlog-lint"
GUARD="$REPO/plugins/seyag/hooks/backlog-priority-guard.sh"
export PYTHONDONTWRITEBYTECODE=1

fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

if [ ! -f "$LINT" ]; then
  bad "backlog-lint missing: $LINT"
  exit 1
fi

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Hermetic config: no user or project seyag config file and no inherited knob reach the lint.
mkdir -p "$t/xdg" "$t/noproj"
export XDG_CONFIG_HOME="$t/xdg" CLAUDE_PROJECT_DIR="$t/noproj"
unset SYG_BACKLOG_PRIORITY_STATUSES

make_store() {
  local dir=$1
  mkdir -p "$dir/backlog/tasks"
  cat >"$dir/backlog/config.yml" <<'EOF'
project: fixture-app
task_prefix: "task"
default_status: "To Do"
statuses:
  - To Do
  - In Progress
  - Done
  - Deferred
EOF
}

# 1. -h exits 0; unknown option exits 2; --store with no value exits 2.
out=$("$LINT" -h 2>&1); rc=$?
[ "$rc" = 0 ] && [[ $out == *Usage:* ]] \
  && ok "case 1a: -h exits 0 and prints usage" \
  || bad "case 1a: -h (rc=$rc out=$out)"

out=$("$LINT" --unknown-flag 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [[ $out == *Usage:* ]] \
  && ok "case 1b: unknown option exits 2 with usage on stderr" \
  || bad "case 1b: unknown option (rc=$rc err=$out)"

out=$("$LINT" --store 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [[ $out == *Usage:* ]] \
  && ok "case 1c: --store with no value exits 2 with usage on stderr" \
  || bad "case 1c: --store with no value (rc=$rc err=$out)"

out=$("$LINT" --store -h 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [[ $out == *Usage:* ]] \
  && ok "case 1d: --store -h is a missing --store value (exit 2), not help" \
  || bad "case 1d: --store -h (rc=$rc err=$out)"

# 2. No store (empty dir) -> exit 2, stderr names the dir.
mkdir -p "$t/empty"
out=$(cd "$t/empty" && "$LINT" 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [[ $out == *"no backlog/config.yml at or above $t/empty"* ]] \
  && ok "case 2a: no store from empty cwd exits 2 and names the dir" \
  || bad "case 2a: no store cwd (rc=$rc err=$out)"

out=$("$LINT" --store "$t/empty" 2>&1 >/dev/null); rc=$?
[ "$rc" = 2 ] && [[ $out == *"no backlog/config.yml in --store $t/empty"* ]] \
  && ok "case 2b: --store on empty dir exits 2 and names the dir" \
  || bad "case 2b: --store empty dir (rc=$rc err=$out)"

# 3. Clean store (To Do + high, In Progress + low, Done without priority, Deferred without priority)
#    -> exit 0, empty stdout.
s3="$t/store-clean"
make_store "$s3"
cat >"$s3/backlog/tasks/task-1 - todo-high.md" <<'EOF'
---
id: TASK-1
title: To Do with high priority
status: To Do
priority: high
---
EOF
cat >"$s3/backlog/tasks/task-2 - inprog-low.md" <<'EOF'
---
id: TASK-2
title: In Progress with low priority
status: In Progress
priority: low
---
EOF
cat >"$s3/backlog/tasks/task-3 - done-noprio.md" <<'EOF'
---
id: TASK-3
title: Done without priority
status: Done
---
EOF
cat >"$s3/backlog/tasks/task-4 - deferred-noprio.md" <<'EOF'
---
id: TASK-4
title: Deferred without priority
status: Deferred
---
EOF

out=$("$LINT" --store "$s3" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "case 3: clean store exits 0 with empty stdout" \
  || bad "case 3: clean store (rc=$rc out=$out)"

# 4. Each of these To Do files is a finding (exit 1, its name on stdout):
#    no priority key, priority: empty, priority: '', priority: "", priority:    (spaces only),
#    and a priority: high line that sits only in the body after the closing ---.
s4="$t/store-findings"
make_store "$s4"
cat >"$s4/backlog/tasks/task-1 - no-key.md" <<'EOF'
---
id: TASK-1
title: No priority key
status: To Do
---
EOF
cat >"$s4/backlog/tasks/task-2 - empty-val.md" <<'EOF'
---
id: TASK-2
title: Empty priority value
status: To Do
priority:
---
EOF
cat >"$s4/backlog/tasks/task-3 - single-quotes.md" <<'EOF'
---
id: TASK-3
title: Single-quoted empty priority
status: To Do
priority: ''
---
EOF
cat >"$s4/backlog/tasks/task-4 - double-quotes.md" <<'EOF'
---
id: TASK-4
title: Double-quoted empty priority
status: To Do
priority: ""
---
EOF
printf -- '---\nid: TASK-5\ntitle: Spaces only priority\nstatus: To Do\npriority:    \n---\n' \
  >"$s4/backlog/tasks/task-5 - spaces-only.md"
cat >"$s4/backlog/tasks/task-6 - body-only.md" <<'EOF'
---
id: TASK-6
title: Priority only in body
status: To Do
---
priority: high
EOF

out4=$("$LINT" --store "$s4"); rc4=$?
if [ "$rc4" = 1 ]; then
  ok "case 4: priority-less To Do store exits 1"
else
  bad "case 4: expected exit 1, got $rc4 ($out4)"
fi
for f in \
  "task-1 - no-key.md" \
  "task-2 - empty-val.md" \
  "task-3 - single-quotes.md" \
  "task-4 - double-quotes.md" \
  "task-5 - spaces-only.md" \
  "task-6 - body-only.md"; do
  if grep -qF "backlog-lint: backlog/tasks/$f: status \"To Do\" has no priority" <<<"$out4"; then
    ok "case 4: finding reported for $f"
  else
    bad "case 4: missing finding for $f in output: $out4"
  fi
done

# 5. Status forms judged: status: 'In Progress', status: "to do" (case-insensitive),
#    and a file with no status: line (falls to default_status To Do) — each a finding without priority.
s5="$t/store-statuses"
make_store "$s5"
cat >"$s5/backlog/tasks/task-1 - single-inprog.md" <<'EOF'
---
id: TASK-1
title: Single-quoted In Progress
status: 'In Progress'
---
EOF
cat >"$s5/backlog/tasks/task-2 - double-todo-lower.md" <<'EOF'
---
id: TASK-2
title: Double-quoted lowercase to do
status: "to do"
---
EOF
cat >"$s5/backlog/tasks/task-3 - missing-status.md" <<'EOF'
---
id: TASK-3
title: Missing status falls back to default_status
---
EOF

out5=$("$LINT" --store "$s5"); rc5=$?
[ "$rc5" = 1 ] \
  && grep -qF 'backlog-lint: backlog/tasks/task-1 - single-inprog.md: status "In Progress" has no priority' <<<"$out5" \
  && grep -qF 'backlog-lint: backlog/tasks/task-2 - double-todo-lower.md: status "to do" has no priority' <<<"$out5" \
  && grep -qF 'backlog-lint: backlog/tasks/task-3 - missing-status.md: status "To Do" has no priority' <<<"$out5" \
  && ok "case 5: quoted, case-insensitive, and default_status forms are findings without priority" \
  || bad "case 5: status forms failed (rc=$rc5 out=$out5)"

# 6. A file with no frontmatter at all -> not a finding.
s6="$t/store-nofm"
make_store "$s6"
cat >"$s6/backlog/tasks/notes.md" <<'EOF'
# Just a markdown file with no YAML frontmatter
status: To Do
EOF
out6=$("$LINT" --store "$s6" 2>&1); rc6=$?
[ "$rc6" = 0 ] && [ -z "$out6" ] \
  && ok "case 6: file with no frontmatter is not a finding" \
  || bad "case 6: no frontmatter (rc=$rc6 out=$out6)"

# 7. SYG_BACKLOG_PRIORITY_STATUSES=Deferred: a Deferred file without priority is a finding and a
#    To Do file without priority is not.
s7="$t/store-env"
make_store "$s7"
cat >"$s7/backlog/tasks/task-1 - deferred-noprio.md" <<'EOF'
---
id: TASK-1
title: Deferred without priority
status: Deferred
---
EOF
cat >"$s7/backlog/tasks/task-2 - todo-noprio.md" <<'EOF'
---
id: TASK-2
title: To Do without priority
status: To Do
---
EOF
out7=$(SYG_BACKLOG_PRIORITY_STATUSES=Deferred "$LINT" --store "$s7"); rc7=$?
[ "$rc7" = 1 ] \
  && grep -qF 'backlog-lint: backlog/tasks/task-1 - deferred-noprio.md: status "Deferred" has no priority' <<<"$out7" \
  && ! grep -qF 'task-2 - todo-noprio.md' <<<"$out7" \
  && ok "case 7: SYG_BACKLOG_PRIORITY_STATUSES=Deferred flags Deferred and skips To Do" \
  || bad "case 7: custom required statuses (rc=$rc7 out=$out7)"

# 7b. The same knob from a project config file (.claude/seyag.toml under CLAUDE_PROJECT_DIR), as
#     hooks/run.sh hands it to the guard; and the environment wins over the file.
mkdir -p "$t/proj7/.claude"
printf 'syg_backlog_priority_statuses = "Deferred"\n' >"$t/proj7/.claude/seyag.toml"
out7b=$(CLAUDE_PROJECT_DIR="$t/proj7" "$LINT" --store "$s7"); rc7b=$?
[ "$rc7b" = 1 ] \
  && grep -qF 'task-1 - deferred-noprio.md' <<<"$out7b" \
  && ! grep -qF 'task-2 - todo-noprio.md' <<<"$out7b" \
  && ok "case 7b: knob from project .claude/seyag.toml flags Deferred and skips To Do" \
  || bad "case 7b: config-file knob (rc=$rc7b out=$out7b)"
out7c=$(CLAUDE_PROJECT_DIR="$t/proj7" SYG_BACKLOG_PRIORITY_STATUSES="To Do" "$LINT" --store "$s7"); rc7c=$?
[ "$rc7c" = 1 ] \
  && grep -qF 'task-2 - todo-noprio.md' <<<"$out7c" \
  && ! grep -qF 'task-1 - deferred-noprio.md' <<<"$out7c" \
  && ok "case 7c: environment knob wins over the config file" \
  || bad "case 7c: env over config (rc=$rc7c out=$out7c)"

# 8. Walk-up: run from <store>/backlog/tasks with no --store -> finds the store.
out8=$(cd "$s3/backlog/tasks" && "$LINT" 2>&1); rc8=$?
[ "$rc8" = 0 ] && [ -z "$out8" ] \
  && ok "case 8a: walk-up from clean <store>/backlog/tasks exits 0" \
  || bad "case 8a: walk-up clean (rc=$rc8 out=$out8)"

out8b=$(cd "$s5/backlog/tasks" && "$LINT"); rc8b=$?
[ "$rc8b" = 1 ] && grep -qF 'backlog-lint: 3 task file(s) need a priority:' <<<"$out8b" \
  && ok "case 8b: walk-up from dirty <store>/backlog/tasks finds the store and reports findings" \
  || bad "case 8b: walk-up dirty (rc=$rc8b out=$out8b)"

# 9. Final summary line count N matches the number of finding lines.
finding_lines4=$(grep -c '^backlog-lint: backlog/tasks/' <<<"$out4")
finding_lines5=$(grep -c '^backlog-lint: backlog/tasks/' <<<"$out5")
[ "$finding_lines4" = 6 ] \
  && grep -qF "backlog-lint: 6 task file(s) need a priority: backlog task edit <ID> --priority high|medium|low" <<<"$out4" \
  && [ "$finding_lines5" = 3 ] \
  && grep -qF "backlog-lint: 3 task file(s) need a priority: backlog task edit <ID> --priority high|medium|low" <<<"$out5" \
  && ok "case 9: final summary line count N matches the number of finding lines (6 and 3)" \
  || bad "case 9: summary count mismatch (c4=$finding_lines4 c5=$finding_lines5)"

# 10. Parity with the guard: for every fixture file from cases 3-5 (in one store with distinct N,
#     with status: To Do where needed so every file is in a required status), run
#     plugins/seyag/hooks/backlog-priority-guard.sh with SYG_TRACKING_SURFACE=backlog-md and
#     stdin {"tool_input":{"command":"backlog task edit <N> -s \"To Do\""},"cwd":"<store>"}
#     and assert: guard exit 2 <=> lint lists that file.
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  ok "skipped: case 10 parity with guard (jq or python3 missing)"
else
  sp="$t/store-parity"
  make_store "$sp"
  idx=0
  for src in \
    "$s3/backlog/tasks/task-1 - todo-high.md" \
    "$s3/backlog/tasks/task-2 - inprog-low.md" \
    "$s3/backlog/tasks/task-3 - done-noprio.md" \
    "$s3/backlog/tasks/task-4 - deferred-noprio.md" \
    "$s4/backlog/tasks/task-1 - no-key.md" \
    "$s4/backlog/tasks/task-2 - empty-val.md" \
    "$s4/backlog/tasks/task-3 - single-quotes.md" \
    "$s4/backlog/tasks/task-4 - double-quotes.md" \
    "$s4/backlog/tasks/task-5 - spaces-only.md" \
    "$s4/backlog/tasks/task-6 - body-only.md" \
    "$s5/backlog/tasks/task-1 - single-inprog.md" \
    "$s5/backlog/tasks/task-2 - double-todo-lower.md" \
    "$s5/backlog/tasks/task-3 - missing-status.md"; do
    idx=$((idx + 1))
    dst="$sp/backlog/tasks/task-$idx - x.md"
    sed 's/^status: Done$/status: To Do/; s/^status: Deferred$/status: To Do/' "$src" >"$dst"
  done
  lint_out=$("$LINT" --store "$sp")
  parity_bad=0
  for n in $(seq 1 "$idx"); do
    fname="task-$n - x.md"
    if grep -qF "backlog-lint: backlog/tasks/$fname:" <<<"$lint_out"; then
      in_lint=1
    else
      in_lint=0
    fi
    jq -nc --arg c "backlog task edit $n -s \"To Do\"" --arg w "$sp" \
      '{tool_input: {command: $c}, cwd: $w}' \
      | env -u SYG_BACKLOG_PRIORITY_STATUSES SYG_TRACKING_SURFACE=backlog-md bash "$GUARD" >/dev/null 2>&1
    g_rc=${PIPESTATUS[1]}
    if [ "$g_rc" = 2 ]; then
      in_guard=1
    elif [ "$g_rc" = 0 ]; then
      in_guard=0
    else
      bad "case 10: unexpected guard rc=$g_rc on task-$n"
      parity_bad=1
      continue
    fi
    if [ "$in_lint" != "$in_guard" ]; then
      bad "case 10: parity mismatch on $fname (lint=$in_lint guard_rc=$g_rc)"
      parity_bad=1
    fi
  done
  [ "$parity_bad" = 0 ] \
    && ok "case 10: guard exit 2 <=> lint lists file across all $idx fixture files from cases 3-5"
fi

# 11. This repo's own store passes: backlog-lint --store "$REPO" exits 0.
out11=$("$LINT" --store "$REPO" 2>&1); rc11=$?
[ "$rc11" = 0 ] && [ -z "$out11" ] \
  && ok "case 11: repo store passes backlog-lint --store \"\$REPO\" (exit 0)" \
  || bad "case 11: repo store failed (rc=$rc11 out=$out11)"

# 12. An unreadable task file (a directory named *.md) is a finding with its own summary line,
#     not counted as needing a priority.
s12="$t/store-unreadable"
make_store "$s12"
mkdir "$s12/backlog/tasks/task-1 - dir.md"
out12=$("$LINT" --store "$s12"); rc12=$?
[ "$rc12" = 1 ] \
  && grep -qF 'backlog-lint: backlog/tasks/task-1 - dir.md: cannot read' <<<"$out12" \
  && grep -qxF 'backlog-lint: 1 task file(s) could not be read' <<<"$out12" \
  && ! grep -qF 'need a priority' <<<"$out12" \
  && ok "case 12: unreadable file reported with its own summary, no priority advice" \
  || bad "case 12: unreadable file (rc=$rc12 out=$out12)"

exit "$fail"
