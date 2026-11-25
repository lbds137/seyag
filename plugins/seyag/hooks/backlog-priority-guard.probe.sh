#!/bin/bash
# Fixture check for backlog-priority-guard.sh: exit-code table over the backlog CLI
# shapes that matter, run against a fixture backlog.md store (mktemp, trap-removed).
# The payload carries a cwd and the session env SYG_TRACKING_SURFACE=backlog-md.
# Usage: hooks/backlog-priority-guard.probe.sh   (from anywhere)

set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backlog-priority-guard.sh"
# A missing hook is a loud failure, never a vacuous pass.
if [ ! -f "$HOOK" ]; then
  echo "FAIL hook script missing: $HOOK"
  exit 1
fi
fail=0

# Fixture store: config.yml, three task files (priority / none / empty), two
# drafts, a deep subdir; plus a store-less temp dir for the out-of-store cases.
STORE=$(mktemp -d)
NOSTORE=$(mktemp -d)
trap 'rm -rf "$STORE" "$NOSTORE"' EXIT
mkdir -p "$STORE/backlog/tasks" "$STORE/backlog/drafts" "$STORE/sub/deep"
cat >"$STORE/backlog/config.yml" <<'EOF'
project: fixture-app
default_status: "To Do"
task_prefix: "task"
statuses:
  - To Do
  - In Progress
  - Done
  - Deferred
EOF
cat >"$STORE/backlog/tasks/task-1 - has-prio.md" <<'EOF'
---
id: TASK-1
title: Has prio
status: Deferred
assignee: []
created_date: '2026-11-25 10:00'
labels: []
dependencies: []
priority: low
ordinal: 1000
---
EOF
cat >"$STORE/backlog/tasks/task-2 - no-prio.md" <<'EOF'
---
id: TASK-2
title: No prio
status: Deferred
assignee: []
created_date: '2026-11-25 10:00'
labels: []
dependencies: []
ordinal: 1001
---
EOF
cat >"$STORE/backlog/tasks/task-3 - empty-prio.md" <<'EOF'
---
id: TASK-3
title: Empty prio
status: Deferred
assignee: []
created_date: '2026-11-25 10:00'
labels: []
dependencies: []
priority:
ordinal: 1002
---
EOF
cat >"$STORE/backlog/drafts/draft-1 - d.md" <<'EOF'
---
id: DRAFT-1
title: Draft without prio
created_date: '2026-11-25 10:00'
labels: []
dependencies: []
---
EOF
cat >"$STORE/backlog/drafts/draft-2 - e.md" <<'EOF'
---
id: DRAFT-2
title: Draft with prio
created_date: '2026-11-25 10:00'
labels: []
dependencies: []
priority: high
---
EOF

# A task file with a non-UTF-8 byte (0xE9) in its body and no priority.
printf -- '---\nid: TASK-4\ntitle: Latin one\nstatus: Deferred\n---\ncaf\351\n' \
  >"$STORE/backlog/tasks/task-4 - latin1.md"

run() { # $1 want-rc, $2 command; $3 payload cwd (default: the store); $4 surface
        # value ("unset" removes the env var); $5 SYG_BACKLOG_PRIORITY_STATUSES
        # value ("unset" removes the env var)
  local rc shown=$2 cwd=${3:-$STORE} surf=${4:-backlog-md} statuses=${5:-unset}
  # -u flags come before any VAR=value word: after an assignment, env would
  # read -u as the command name.
  local -a pre=(env -u SYG_TRACKING_SURFACE -u SYG_BACKLOG_PRIORITY_STATUSES)
  if [ "$surf" != unset ]; then pre+=("SYG_TRACKING_SURFACE=$surf"); fi
  if [ "$statuses" != unset ]; then pre+=("SYG_BACKLOG_PRIORITY_STATUSES=$statuses"); fi
  jq -nc --arg c "$2" --arg w "$cwd" '{tool_input: {command: $c}, cwd: $w}' \
    | "${pre[@]}" bash "$HOOK" >/dev/null 2>&1
  # The hook's own exit code: an early exit (surface unset) leaves stdin
  # unread, so jq can take SIGPIPE (141) under load and pipefail reports it.
  rc=${PIPESTATUS[1]}
  [ ${#shown} -gt 200 ] && shown="${shown:0:40}...[${#2} bytes]...${shown: -30}"
  if [ "$rc" = "$1" ]; then echo "ok   [$rc]: $shown"; else echo "FAIL [$rc want $1]: $shown"; fail=1; fi
}

# create: every observed runner form blocks without --priority.
run 2 'npx backlog task create "x"'
run 2 'pnpm -s backlog task create "x"'
run 2 'backlog task create x'
run 2 'pnpm exec backlog task create x'
run 2 'npx --no-install backlog task create x'
run 2 'cd sub/deep && npx backlog task create x'
run 2 "bash -c 'npx backlog task create x'"
run 2 'x="$(npx backlog task create x)"'
run 2 'pnpm -s exec backlog task create x'
run 2 'yarn backlog task create x'
run 2 'node_modules/.bin/backlog task create x'
run 2 'pnpm -C sub/deep backlog task create x'
run 0 'npx backlog task create x --priority high'
run 0 'npx backlog task create x --priority=low'
run 0 'npx backlog task create x --draft'
run 0 'npx backlog task create x -s Deferred'
run 2 'npx backlog task create x -s "in progress"'
run 0 'SYG_ALLOW_NO_PRIORITY=1 npx backlog task create x'
# edit: a required-status move of a file with no (or an empty) priority blocks.
run 2 'npx backlog task edit 2 --status "To Do"'
run 2 'npx backlog task edit TASK-2 -s "to do"'
run 2 'npx backlog task edit task-2 --status=In\ Progress -a me'
run 0 'npx backlog task edit 1 --status "To Do"'
run 2 'npx backlog task edit 3 -s "To Do"'
run 2 'npx backlog task edit 1 2 -s "To Do"'
run 0 'npx backlog task edit 2 -s "To Do" --priority medium'
run 0 'npx backlog task edit 2 -s Done'
run 0 'npx backlog task edit 2 --title y'
run 0 'npx backlog task edit 99 -s "To Do"'
# flag shapes: help never blocks, value-less flags take no value word, npx
# package forms, glued -s, undecodable bytes.
run 0 'backlog task create --help'
run 0 'npx backlog task edit 2 -s "To Do" -h'
run 2 'npx backlog task edit --clear-labels 2 -s "To Do"'
run 2 'npx backlog task edit -s "To Do" --clear-deps 2'
run 0 'npx backlog task edit 2 --clear-labels --priority high -s "To Do"'
run 0 'npx backlog task create x --no-dod-defaults --draft'
run 2 'npx backlog.md task create x'
run 2 'npx -p backlog.md backlog task create x'
run 2 'npx backlog task edit 2 -s"To Do"'
run 0 'git commit -m "npx backlog task create x"'
run 2 'npx backlog task edit 4 -s "To Do"'
# expansion-carried arguments: a word starting with $ may carry --priority, so the
# command is not judged; a $ later in a word, or no expansion at all, still is.
run 0 'c(){ npx backlog task create "$@" --plain; }; c "x" --priority high'
run 0 'A="--priority high"; npx backlog task create x $A'
run 0 'npx backlog task create x "${args[@]}"'
run 0 'npx backlog task edit 2 -s "To Do" "$@"'
run 2 'npx backlog task create x -d "costs $5"'
run 2 'c(){ npx backlog task create --plain; }; c'
# draft: promote lands in To Do; the draft's priority is judged first.
run 2 'npx backlog draft promote DRAFT-1'
run 0 'npx backlog draft promote 2'
run 0 'npx backlog draft create x'
# scope: activation pin, store presence, statuses knob.
run 0 'npx backlog task create x' "$NOSTORE"
run 0 'npx backlog task create x' "" unset
run 0 'echo backlog'
run 0 'npx backlog task create x' "" backlog-md "In Progress"
run 2 'npx backlog task edit 2 -s "in progress"' "" backlog-md "In Progress"
# The store is looked up from the walked cwd (state.cwd), never the payload cwd.
run 2 "cd $STORE && npx backlog task create x" "$NOSTORE"
# fail-open: unparsable payload.
printf 'this is not json' | env SYG_TRACKING_SURFACE=backlog-md bash "$HOOK" >/dev/null 2>&1
if [ $? = 0 ]; then echo "ok   [0]: non-JSON stdin"; else echo "FAIL [want 0]: non-JSON stdin"; fail=1; fi

# A blocked run's stderr names the guard, the fix and the bypass.
msg=$(jq -nc --arg c 'npx backlog task create "x"' --arg w "$STORE" '{tool_input: {command: $c}, cwd: $w}' \
  | env SYG_TRACKING_SURFACE=backlog-md bash "$HOOK" 2>&1 >/dev/null)
for needle in 'BACKLOG PRIORITY GUARD' '--priority' 'SYG_ALLOW_NO_PRIORITY=1'; do
  if grep -qF -- "$needle" <<<"$msg"; then
    echo "ok   message contains: $needle"
  else
    echo "FAIL message missing: $needle"
    fail=1
  fi
done
if [[ "$(sed -n 2p <<<"$msg")" == "  - "* ]]; then
  echo "ok   message: violation line directly under the header"
else
  echo "FAIL message: second line is not a '  - ' violation line"
  fail=1
fi
exit $fail
