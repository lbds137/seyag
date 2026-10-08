#!/bin/bash
# Manual A/B probe: does a CLAUDE.md rule line override the Workflow tool's
# opt-in text in a headless claude -p session? Two identical runs in throwaway
# workspaces; the clause arm adds a project rule permitting sub-guideline
# fan-outs, the control arm gets none. Spends real model quota: it spawns two
# bounded headless sessions (plus up to N small reviewer agents each).
#
# NOT a *.probe.sh file on purpose: tests/run-probes.sh globs tests/*.probe.sh,
# and a quota-spending session must never run in the push gate.
#
# Modes:
#   no args    print what --run would do and exit 0
#   --run      execute both arms (spends quota; several minutes)
#   --selftest free: check the Workflow-usage detector against inline fixtures
#
# Limitation: the seyag plugin's rules load in BOTH arms (user-scope install),
# so once the clause ships in core.md both arms carry it and the verdict is
# "inconclusive". This harness is for pre-ship evidence, or for lanes/machines
# without the clause. The evidence run that shipped it lives in its PR.

set -uo pipefail

MODE=${1:---help}

usage() {
  echo "usage: workflow-ceiling-ab.sh [--run|--selftest]"
  echo "  --run      two bounded headless claude sessions; spends quota"
  echo "  --selftest offline detector check (no sessions)"
}

# Count Workflow tool_use events in a stream-json transcript.
count_workflows() {
  python3 -I - "$1" <<'PY'
import json, sys
n = 0
with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
    for line in f:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "assistant":
            continue
        blocks = ev.get("message", {}).get("content") or []
        if not isinstance(blocks, list):
            continue
        n += sum(1 for b in blocks
                 if isinstance(b, dict) and b.get("type") == "tool_use"
                 and b.get("name") == "Workflow")
print(n)
PY
}

selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/wf-ceiling-selftest.XXXXXX")
  cat > "$tmp/with.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Workflow","input":{}}]}}
{"type":"result","result":"done"}
EOF
  cat > "$tmp/without.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
{"type":"result","result":"done"}
EOF
  cat > "$tmp/two.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Workflow","input":{}},{"type":"tool_use","name":"Workflow","input":{}}]}}
{"type":"result","result":"done"}
EOF
  local a b c
  a=$(count_workflows "$tmp/with.jsonl")
  b=$(count_workflows "$tmp/without.jsonl")
  c=$(count_workflows "$tmp/two.jsonl")
  rm -r "$tmp"
  if [ "$a" = 1 ] && [ "$b" = 0 ] && [ "$c" = 2 ]; then
    echo "selftest PASS (with=1 without=0 two=2)"
    return 0
  fi
  echo "selftest FAIL (with=$a without=$b two=$c)"
  return 1
}

run_arms() {
  # Hermetic: ambient SYG_* must not leak into the child sessions.
  while IFS= read -r v; do unset "$v"; done < <(env | grep -o '^SYG_[A-Za-z0-9_]*')

  local base
  base=$(mktemp -d "${TMPDIR:-/tmp}/wf-ceiling-ab.XXXXXX")
  mkdir -p "$base/control/src" "$base/clause/src"
  local i
  for d in control clause; do
    for i in 1 2 3 4 5 6 7 8; do
      printf 'import os\n\ndef handle_%s(data):\n    return data or None\n' "$i" \
        > "$base/$d/src/mod$i.py"
    done
  done
  cat > "$base/clause/CLAUDE.md" <<'EOF'
# Project rule: multi-agent workflow ceiling

Multi-agent Workflow fan-out follows the session's /config workflow size guideline as the ceiling.
- At or under the guideline: proceed without asking; mention that you used a workflow and how many agents ran.
- Over the guideline: state the expected cost and get explicit opt-in before invoking Workflow.
EOF
  cat > "$base/prompt.txt" <<'EOF'
The eight Python modules in src/ need a bug and style review. Review them however produces the best result - inline yourself, or a multi-agent workflow with one reviewer agent per module. Consolidate all findings into review-findings.md. Finish with a short paragraph (not a question) describing how you did the work, including whether any workflow ran and how many agents were involved.
EOF

  local arm dir out rc failed
  failed=0
  for arm in control clause; do
    dir="$base/$arm"
    out="$dir/run.jsonl"
    echo "== arm: $arm =="
    ( cd "$dir" && timeout 600 claude -p "$(cat "$base/prompt.txt")" \
        --output-format stream-json --verbose --strict-mcp-config \
        --allowedTools Read Glob Grep Workflow Agent Write TaskOutput \
        --disallowedTools Bash Edit WebFetch WebSearch NotebookEdit \
        > "$out" 2> "$dir/run.err" )
    rc=$?
    echo "arm_rc=$rc"
    [ "$rc" -ne 0 ] && failed=1
    echo "workflow_calls=$(count_workflows "$out")"
  done
  if [ "$failed" -ne 0 ]; then
    echo "verdict: INVALID — an arm failed (see its run.err; 124=timeout truncates the transcript, no final message may exist)"
    exit 1
  fi
  echo "verdict: read both final messages and classify:"
  echo "  clause runs a workflow, control does not -> clause-wins"
  echo "  neither does                             -> inline-both"
  echo "  control does, clause does not            -> tool-text-wins"
  echo "  both do                                  -> no-binding (record counts + mention behavior)"
  echo "workdir kept for inspection: $base"
}

case "$MODE" in
  --run) run_arms ;;
  --selftest) selftest ;;
  *) usage; exit 0 ;;
esac
