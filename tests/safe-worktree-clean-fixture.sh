# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced fixture: the two safe-worktree-clean probes read these globals by name
# Shared fixture and helpers for tests/safe-worktree-clean.probe.sh and
# tests/safe-worktree-clean-apply-hold.probe.sh, sourced at their top (EXIT trap, hermetic env, cd into $T).
set -uo pipefail
# Hooks run here directly, not via run.sh: keep bytecode out of hooks/lib.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/plugins/seyag/bin/safe-worktree-clean"
HOOKS="$ROOT/plugins/seyag/hooks"
T=$(mktemp -d)
PIDS=()
cleanup() { [ ${#PIDS[@]} -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Hermetic: no ambient SYG_* knob, no user or system git config.
while read -r v; do unset "$v"; done < <(compgen -v SYG_)
export SYG_WORKTREE_BACKUP_ALLOW_VOLATILE=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export XDG_CONFIG_HOME="$T/xdg-config" CLAUDE_PROJECT_DIR="$T/judge"
mkdir -p "$XDG_CONFIG_HOME"
cd "$T" || exit 1

# A repo with origin/main = c2; c1 is its parent. c1: a.txt=v1. c2: a.txt=v2, b.txt=b.
mk_repo() { # $1 name
  local r="$T/$1"
  git init -q --bare -b main "$T/$1-origin.git"
  git clone -q "$T/$1-origin.git" "$r" 2>/dev/null
  printf '*.log\n__pycache__/\n' > "$r/.gitignore"
  echo v1 > "$r/a.txt"
  git -C "$r" add . && git -C "$r" commit -qm first
  echo v2 > "$r/a.txt"; echo b > "$r/b.txt"
  git -C "$r" add . && git -C "$r" commit -qm second
  git -C "$r" push -q origin main 2>/dev/null
  git -C "$r" remote set-head origin main
  echo .claude/ >> "$r/.git/info/exclude"
  C1=$(git -C "$r" rev-parse HEAD~1)
}
add_tree() { # $1 repo, $2 tree name, $3 start point (default origin/main), $4 branch (default worktree-agent-<name>)
  git -C "$T/$1" worktree add -q -b "${4:-worktree-agent-$2}" "$T/$1/.claude/worktrees/$2" "${3:-origin/main}" 2>/dev/null
}
dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }
verdict() { # $1 json, $2 tree name -> "SAFE" or "HOLD:code,code"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["verdict"] if t["verdict"] == "SAFE" else
              "HOLD:" + ",".join(r["code"] for r in t["reasons"]))
' "$1" "$2"
}
expect() { # $1 json, $2 tree, $3 want, $4 label
  local got; got=$(verdict "$1" "$2")
  if [ "$got" = "$3" ]; then ok "$2: $3 ($4)"; else bad "$2: got '$got', want '$3' ($4)"; fi
}
reason_msg() { # $1 json, $2 tree name -> first reason detail
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["reasons"][0]["detail"] if t["reasons"] else "")
' "$1" "$2"
}
plant_repo() { # $1=dir $2=hook
  mkdir -p "$1/objects" "$1/refs/heads"
  printf 'ref: refs/heads/main\n' > "$1/HEAD"
  : > "$1/objects/.keep"
  : > "$1/refs/heads/.keep"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = ..\n\tfsmonitor = %s\n' "$2" > "$1/config"
}
approvable_of() { # $1 json, $2 tree name -> "True" or "False"
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for t in d["worktrees"]:
    if t["path"].endswith("/" + sys.argv[2]):
        print(t["approvable"])
' "$1" "$2"
}
ref_plan_p33b() {
  local p h rc_b state head reasons
  state=$(
    {
      printf '\001atrisk=%s\0' 0
      git -C "$WT33B" status --porcelain=v1 -z --ignored --untracked-files=all; rc_b=$?
      printf '\001status=%s\0' "$rc_b"
      git -C "$WT33B" diff --binary HEAD; rc_b=$?
      printf '\001diff=%s\0' "$rc_b"
      git -C "$WT33B" diff --binary --cached HEAD; rc_b=$?
      printf '\001diffcached=%s\0' "$rc_b"
      printf '\001batch=%s\0' "0:0"   # the batch holds only `a`; the quoted name is hashed per file
      for p in '"a"' a; do
        rc_b=0
        h=$(git -C "$WT33B" hash-object --no-filters -- "$p") || rc_b=$?
        printf '%s\0%s\0' "$p" "${h:-}"
        printf '\001hash=%s\0' "$rc_b"
      done
      git -C "$WT33B" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc_b=$?
      printf '\001foreachref=%s\0' "$rc_b"
    } | sha256sum | cut -d' ' -f1
  )
  head=$(git -C "$WT33B" rev-parse HEAD)
  reasons=$(printf '%s\n' \
    $'untracked-new\t"a" is untracked and not on origin/main' \
    $'untracked-new\ta is untracked and not on origin/main' \
    | LC_ALL=C sort)
  printf '%s\0%s\0%s\0%s\0%s\0' "$WT33B" "worktree-agent-wt33b" "$head" "$reasons" "$state" | sha256sum | cut -c1-12
}
ref_plan_p38() { # $1 = the batch sentinel the tool must fold in ("0:0" healthy, "1:1" seam)
  local p h rc38 state head reasons
  state=$(
    {
      printf '\001atrisk=%s\0' 0
      git -C "$WT38" status --porcelain=v1 -z --ignored --untracked-files=all; rc38=$?
      printf '\001status=%s\0' "$rc38"
      git -C "$WT38" diff --binary HEAD; rc38=$?
      printf '\001diff=%s\0' "$rc38"
      git -C "$WT38" diff --binary --cached HEAD; rc38=$?
      printf '\001diffcached=%s\0' "$rc38"
      printf '\001batch=%s\0' "$1"
      for p in u1.txt u2.txt; do
        rc38=0
        h=$(git -C "$WT38" hash-object --no-filters -- "$p") || rc38=$?
        printf '%s\0%s\0' "$p" "${h:-}"
        printf '\001hash=%s\0' "$rc38"
      done
      git -C "$WT38" for-each-ref --format='%(objectname) %(refname)' refs/worktree/ refs/bisect/ refs/rewritten/; rc38=$?
      printf '\001foreachref=%s\0' "$rc38"
    } | sha256sum | cut -d' ' -f1
  )
  head=$(git -C "$WT38" rev-parse HEAD)
  reasons=$(printf '%s\n' \
    $'untracked-new\tu1.txt is untracked and not on origin/main' \
    $'untracked-new\tu2.txt is untracked and not on origin/main' \
    | LC_ALL=C sort)
  printf '%s\0%s\0%s\0%s\0%s\0' "$WT38" "worktree-agent-wt38" "$head" "$reasons" "$state" | sha256sum | cut -c1-12
}
fail_plan() { # $1 = match fragment -> that poisoned run's hold plan id
  SHIM38B_MATCH=$1 PATH="$T/shim38b:$PATH" "$TOOL" --repo "$SW38B" --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["hold_plan"] or "")'
}
check38b() { # $1 label, $2 match fragment: the poisoned plan must differ from the healthy id
  local plan
  plan=$(fail_plan "$2")
  if [ -n "$plan" ] && [ "$plan" != "$PLAN_38B_OK" ]; then
    ok "P38b: $1 child failing (rc 42, real output intact) changes the hold plan id"
  else
    bad "P38b: $1 (plan='$plan', healthy='$PLAN_38B_OK')"
  fi
}
