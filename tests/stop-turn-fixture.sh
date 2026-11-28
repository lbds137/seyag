#!/bin/bash
# tests/stop-turn-fixture.sh — sourced by the Stop-hook probes (TASK-262 rows).
# Builds a transcript from explicit turn-shape tokens: mkseq OUT TOKEN...
# tokens: u:TEXT (genuine user), a:TEXT (assistant text), tool (Bash tool_use +
# its tool_result), ask:QUESTION (AskUserQuestion + tool_result), est (a
# closing recorded only as signed-empty thinking).
mkseq() {
  python3 -I -B - "$@" <<'PY'
import json, sys
out, toks = sys.argv[1], sys.argv[2:]
rows = []
for i, tok in enumerate(toks):
    kind, _, arg = tok.partition(":")
    if kind == "u":
        rows.append({"type": "user", "message": {"content": arg}})
    elif kind == "a":
        rows.append({"type": "assistant", "message": {"content": [{"type": "text", "text": arg}]}})
    elif kind in ("tool", "ask"):
        if kind == "tool":
            use = {"type": "tool_use", "id": f"t{i}", "name": "Bash", "input": {"command": "ls"}}
        else:
            use = {"type": "tool_use", "id": f"a{i}", "name": "AskUserQuestion",
                   "input": {"questions": [{"question": arg, "options": []}]}}
        rows.append({"type": "assistant", "message": {"content": [use]}})
        rows.append({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": use["id"], "content": "ok"}]}})
    elif kind == "est":
        rows.append({"type": "assistant", "message": {"content": [
            {"type": "thinking", "thinking": "", "signature": "sig"}]}})
    else:
        sys.exit(f"mkseq: unknown token {tok!r}")
with open(out, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}
