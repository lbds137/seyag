#!/bin/bash
# Python isolation: no shipped inline python run by a hook or bin can import a
# module from the process cwd. Three parts:
#   A. lint: every inline python3 site under plugins/ passes -I (a positive
#      control over fixture strings runs first).
#   B. runtime: four hooks, one per invocation form, run from a directory that
#      plants re.py/json.py/shlex.py/subprocess.py; none may import a plant,
#      and every python3 spawn must carry -I. Then recursive-rm-guard once more
#      through run.sh with a pycache prefix: the prefix argument must reach the
#      hook's python3 and bytecode must land under it.
#   C. no bytecode lands in the plugin tree.
# Usage: tests/python-isolation.probe.sh   (from anywhere)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_PY3=$(command -v python3) || { bad "python3 not on PATH"; exit 1; }

PYC_BEFORE=$(find "$REPO/plugins" -name __pycache__ 2>/dev/null | sort)

# --- A. Lint ------------------------------------------------------------------
LINT_OUT=$("$REAL_PY3" -I -B - "$REPO" <<'PYEOF'
import re
import subprocess
import sys

repo = sys.argv[1]
PY3 = re.compile(r"(?<![\w./-])python3(?![\w.])")
SKIP_BEFORE = ("command -v ", "type ", "which ")
CACHE_TOKEN = '"${SYG_PY_CACHE_ARG:--B}"'


def violations(line):
    """Return True when the line holds an inline python3 call without -I."""
    if line.lstrip().startswith("#"):
        return False
    for m in PY3.finditer(line):
        before = line[: m.start()]
        if before.endswith(SKIP_BEFORE):
            continue
        toks = line[m.end():].split()
        saw_i = False
        i = 0
        inline = False
        while True:
            if i >= len(toks):
                inline = True
                break
            t = toks[i]
            if t == "-c":
                inline = True
                break
            if t == CACHE_TOKEN:
                i += 1
                continue
            if t in ("-X", "-W"):
                i += 2
                continue
            if re.fullmatch(r"-[A-Za-z]+", t):
                if "I" in t:
                    saw_i = True
                i += 1
                continue
            inline = (t == "-" or t.startswith("<") or t == "\\"
                      or re.match(r"\d<", t) is not None)
            break
        if inline and not saw_i:
            return True
    return False


MUST_FLAG = [
    "python3 -c 'x'",
    "X=$(python3 - 3<<<\"$C\" <<'E'",
    "python3 << 'E'",
    "python3 3<<<\"$C\" << 'E'",
    "} | python3 -c '",
    "exec python3 -",
    "python3 -B - <<E",
    "python3",
    "python3 \"${SYG_PY_CACHE_ARG:--B}\" -c x",
]
MUST_NOT = [
    "python3 -I -c x",
    "python3 -I \"${SYG_PY_CACHE_ARG:--B}\" - <<E",
    "python3 -I -B - <<E",
    "python3 \"$LIB\"",
    "command -v python3 >/dev/null",
    "exec python3 \"$(dirname x)/y\"",
    "python3 -IB -c x",
    "# python3 -c in a comment",
]
control_bad = [s for s in MUST_FLAG if not violations(s)]
control_bad += [s for s in MUST_NOT if violations(s)]
if control_bad:
    for s in control_bad:
        print("CONTROL " + s)
    sys.exit(3)

files = subprocess.run(
    ["git", "-C", repo, "ls-files", "-z", "--", "plugins/"],
    capture_output=True, check=True,
).stdout.decode().split("\0")
n_files = 0
found = []
for path in files:
    if not path or path.endswith((".probe.sh", ".md")):
        continue
    try:
        with open(repo + "/" + path, "rb") as fh:
            text = fh.read().decode("utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    n_files += 1
    for lineno, line in enumerate(text.split("\n"), 1):
        if violations(line):
            found.append(f"{path}:{lineno}: {line.strip()}")
for v in found:
    print("VIOLATION " + v)
print(f"SCANNED {n_files}")
sys.exit(1 if found else 0)
PYEOF
)
LINT_RC=$?
if [ "$LINT_RC" = 3 ]; then
  bad "lint positive control misclassified fixtures:"
  printf '%s\n' "$LINT_OUT" | sed 's/^/        /'
elif [ "$LINT_RC" != 0 ]; then
  bad "lint: inline python3 without -I (use python3 -I \"\${SYG_PY_CACHE_ARG:--B}\" in hooks, python3 -I -B in bin):"
  printf '%s\n' "$LINT_OUT" | grep -v '^SCANNED' | sed 's/^/        /'
else
  ok "lint: every inline python3 site passes -I ($(printf '%s' "$LINT_OUT" | sed -n 's/^SCANNED //p') files scanned)"
fi

# --- B. Runtime rows ------------------------------------------------------------
PLANT="$TMP/plant"
SHIM="$TMP/shim"
LOG="$TMP/shim.log"
mkdir -p "$PLANT" "$SHIM"
# shlex.py/subprocess.py are a broad net for future hooks; today's rows import re (all) and json (promise-ledger-check).
for m in re json shlex subprocess; do
  printf 'open(r"%s/marker-%s", "w").close()\n' "$TMP" "$m" >"$PLANT/$m.py"
done
# One log line per spawn: an inline -c script's own newlines become spaces.
printf '#!/bin/bash\n{ printf "%%s" "$*" | tr "\\n" " "; echo; } >>"%s"\nexec "%s" "$@"\n' "$LOG" "$REAL_PY3" >"$SHIM/python3"
chmod +x "$SHIM/python3"

clear_state() { rm -f "$TMP"/marker-* "$LOG"; : >"$LOG"; }
markers() { find "$TMP" -maxdepth 1 -name 'marker-*' -printf '%f '; }

# Positive control: the plant must work for a plain `python3 -c` from PLANT.
clear_state
(cd "$PLANT" && PYTHONDONTWRITEBYTECODE=1 "$REAL_PY3" -c 'import re, json, shlex, subprocess' >/dev/null 2>&1)
if [ -n "$(markers)" ]; then
  ok "plant control: python3 -c from the plant dir imports a planted module ($(markers))"
else
  bad "plant control: no planted module was imported without -I (the plant is broken)"
fi

row() { # $1 label, $2 hook file, $3 payload
  local label=$1 hook=$2 payload=$3 lines
  clear_state
  (cd "$PLANT" && printf '%s' "$payload" | env -u SYG_PY_CACHE_ARG CLAUDE_JOB_DIR= \
    PATH="$SHIM:$PATH" PYTHONDONTWRITEBYTECODE=1 bash "$REPO/plugins/seyag/hooks/$hook" >/dev/null 2>&1)
  lines=$(grep -c . "$LOG")
  if [ "$lines" -lt 1 ]; then
    bad "$label: python step not reached (shim.log empty)"
  elif grep -qvE '(^| )-I( |$)' "$LOG"; then
    bad "$label: a python3 spawn lacks -I: $(grep -vE '(^| )-I( |$)' "$LOG" | head -1)"
  elif [ -n "$(markers)" ]; then
    bad "$label: a planted module in the cwd was imported: $(markers)"
  else
    ok "$label: $lines python3 spawn(s), all -I, no planted module imported"
  fi
}

row "recursive-rm-guard.sh (python3 - 3<<<)" recursive-rm-guard.sh \
  '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
row "lossy-pipe-guard.sh (python3 3<<<)" lossy-pipe-guard.sh \
  '{"tool_name":"Bash","tool_input":{"command":"git push | tail"}}'
row "grep-escaped-dollar-guard.sh (python3 -c)" grep-escaped-dollar-guard.sh \
  '{"tool_name":"Bash","tool_input":{"command":"cat <<'"'"'E'"'"'\nhello\nE"}}'

printf '%s\n' \
  '{"type":"user","isMeta":null,"message":{"content":"go"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Filed the export nit. I'"'"'ll add the sync gate later once the schema settles."}]}}' \
  >"$TMP/transcript.jsonl"
row "promise-ledger-check.sh (python3 <<)" promise-ledger-check.sh \
  "{\"stop_hook_active\":false,\"transcript_path\":\"$TMP/transcript.jsonl\"}"

# recursive-rm-guard through run.sh (single-hook mode), with a pycache prefix: run.sh
# exports SYG_PY_CACHE_ARG=-Xpycache_prefix=<dir> when PYTHONPYCACHEPREFIX is set and
# PYTHONDONTWRITEBYTECODE is not, so the hook's `python3 -I` must carry that argument
# and write its bytecode under the prefix. Same plant, shim and payload as the row above.
RUN_PC="$TMP/pc"
RUN_PROJ="$TMP/proj"
mkdir -p "$RUN_PROJ"
clear_state
(cd "$PLANT" && printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | env \
  -u SYG_PY_CACHE_ARG -u PYTHONDONTWRITEBYTECODE -u CLAUDE_CODE_ENTRYPOINT -u SYG_PROFILE -u SYG_ENABLE -u SYG_DISABLE \
  CLAUDE_JOB_DIR= CLAUDE_PROJECT_DIR="$RUN_PROJ" XDG_CACHE_HOME="$TMP/xdg-cache" \
  PATH="$SHIM:$PATH" PYTHONPYCACHEPREFIX="$RUN_PC" bash "$REPO/plugins/seyag/hooks/run.sh" recursive-rm-guard >/dev/null 2>&1)
lines=$(grep -c . "$LOG")
spawn_bad=0
re_spawn='(^| )-I( |$)'
while IFS= read -r line; do
  if ! [[ $line =~ $re_spawn ]] || [[ $line != *"-Xpycache_prefix=$RUN_PC"* ]]; then
    spawn_bad=$((spawn_bad + 1))
  fi
done <"$LOG"
if [ "$lines" -lt 1 ]; then
  bad "run.sh recursive-rm-guard (pycache prefix): python step not reached (shim.log empty)"
elif [ "$spawn_bad" -gt 0 ]; then
  bad "run.sh recursive-rm-guard (pycache prefix): $spawn_bad python3 spawn(s) lack standalone -I or -Xpycache_prefix=$RUN_PC: $(head -1 "$LOG")"
elif [ -n "$(markers)" ]; then
  bad "run.sh recursive-rm-guard (pycache prefix): a planted module in the cwd was imported: $(markers)"
elif [ -z "$(find "$RUN_PC" -name '*.pyc' -print -quit 2>/dev/null)" ]; then
  bad "run.sh recursive-rm-guard (pycache prefix): no bytecode written under $RUN_PC"
else
  ok "run.sh recursive-rm-guard (pycache prefix): $lines python3 spawn(s), all -I with the prefix argument, no planted module, bytecode under the prefix"
fi

# --- C. No bytecode in the plugin tree ------------------------------------------
PYC_AFTER=$(find "$REPO/plugins" -name __pycache__ 2>/dev/null | sort)
if [ "$PYC_BEFORE" = "$PYC_AFTER" ]; then
  ok "no new __pycache__ under plugins/"
else
  bad "new __pycache__ under plugins/: $(comm -13 <(printf '%s\n' "$PYC_BEFORE") <(printf '%s\n' "$PYC_AFTER") | tr '\n' ' ')"
fi

exit "$fail"
