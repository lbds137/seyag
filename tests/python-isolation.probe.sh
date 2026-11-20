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

# Sorted "relative-path size" lines for every *.pyc under $1. Files, not directory
# names: a new .pyc in a __pycache__ that already exists is the case to catch.
pyc_files() {
  (cd "$1" && find . -name '*.pyc' -printf '%p %s\n' 2>/dev/null | sort)
}
PYC_BEFORE=$(pyc_files "$REPO/plugins")

# --- A. Lint ------------------------------------------------------------------
LINT_OUT=$("$REAL_PY3" -I -B - "$REPO" <<'PYEOF'
import re
import subprocess
import sys

repo = sys.argv[1]
# Known limit: a call through a variable ("$PY" -c) is not linted.
PY3 = re.compile(r"(?<![\w.-])python(?:3(?:\.\d+t?)?)?(?![\w.-])")
SKIP_BEFORE = ("command -v ", "type ", "which ")


CACHE_MARK = "SYG_PY_CACHE_ARG"
PRE_PREFIX = "pycache_prefix="


def call_flags(toks):
    """Walk python3's argument tokens: (inline, flags). inline is False when a
    script path runs instead of stdin or -c. flags: I (-I seen), B (-B seen),
    C (a bytecode prefix: SYG_PY_CACHE_ARG reference or -Xpycache_prefix=)."""
    flags = set()
    i = 0
    while i < len(toks):
        t = toks[i]
        i += 1
        if CACHE_MARK in t:
            flags.add("C")
            continue
        # A long option is value-taking unless it carries '=': skip it and its value, so an
        # option's letters (--check-hash-based-pycs has a c) never read as python flags.
        if t.startswith("--") and t != "--":
            if "=" not in t and i < len(toks):
                i += 1
            continue
        if t == "-" or t == "\\" or t.startswith("<") or re.match(r"\d<", t):
            return True, flags
        if t == "--":
            return i >= len(toks), flags
        if not t.startswith("-"):
            return False, flags
        j = 1
        while j < len(t):
            ch = t[j]
            if ch in "c<":
                return True, flags
            if ch == "m":
                return False, flags
            if ch in "XW":
                rest = t[j + 1:]
                if rest == "":
                    rest = toks[i] if i < len(toks) else ""
                    i += 1
                if ch == "X" and rest.startswith(PRE_PREFIX):
                    flags.add("C")
                break
            if ch == "I":
                flags.add("I")
            elif ch == "B":
                flags.add("B")
            j += 1
    return True, flags


def problems(line):
    """Missing guard classes for the first inline python3 call on the line that lacks any; [] when clean."""
    if line.lstrip().startswith("#"):
        return []
    for m in PY3.finditer(line):
        if line[: m.start()].endswith(SKIP_BEFORE):
            continue
        inline, flags = call_flags(line[m.end():].split())
        if not inline:
            continue
        missing = []
        if "I" not in flags:
            missing.append("missing -I")
        if not flags & {"B", "C"}:
            missing.append("missing bytecode guard (-B, -Xpycache_prefix=, or SYG_PY_CACHE_ARG)")
        if missing:
            return missing
    return []


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
    "/usr/bin/python3 -c x",
    "python -c x",
    "python3.12 - <<E",
    "python3.12t -c x",
    "env python3 -c x",
    "python3 -I -c x",
    "python3 -I - <<E",
    "python3 -I<<E",
    "python3 -Bc 'x'",
    "python3 -B<<E",
    "python3 -uc 'x'",
    "python3 -Xutf8 -c 'x'",
    "python3 -Xpycache_prefix=/t -c x",
    "python3 -Wignore::DeprecationWarning -c 'x'",
    "python3 -WI -c x",
    "python3 -X utf8 -c x",
    "python3 --check-hash-based-pycs default -I -c x",
]
MUST_NOT = [
    "python3 -I -B -c x",
    "/usr/bin/python3 -I -B -c x",
    "python3.12 -I -B -c x",
    "python3.12t -I -B -c x",
    "python3 -I \"${SYG_PY_CACHE_ARG:--B}\" - <<E",
    "python3 -I -B - <<E",
    "python3 -I -Xpycache_prefix=/t -c x",
    "python3 -IBc 'x'",
    "python3 -IB -c x",
    "python3 -IB<<E",
    "python3 \"$LIB\"",
    "command -v python3 >/dev/null",
    "exec python3 \"$(dirname x)/y\"",
    "python3 -I -B script.py",
    "python3 -I -B --check-hash-based-pycs default -c x",
    "# python3 -c in a comment",
]
control_bad = [s for s in MUST_FLAG if not problems(s)]
control_bad += [s for s in MUST_NOT if problems(s)]
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
        missing = problems(line)
        if missing:
            found.append(f"{path}:{lineno}: {'; '.join(missing)}: {line.strip()}")
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
  bad "lint: inline python3 call without -I or without a bytecode guard (use python3 -I \"\${SYG_PY_CACHE_ARG:--B}\" in hooks, python3 -I -B in bin):"
  printf '%s\n' "$LINT_OUT" | grep -v '^SCANNED' | sed 's/^/        /'
else
  ok "lint: every inline python3 site passes -I and a bytecode guard ($(printf '%s' "$LINT_OUT" | sed -n 's/^SCANNED //p') files scanned)"
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

row() { # $1 label, $2 hook file, $3 payload, $4 optional extra env (NAME=value)
  local label=$1 hook=$2 payload=$3 extra_env=${4:-} lines
  clear_state
  (cd "$PLANT" && printf '%s' "$payload" | env -u SYG_PY_CACHE_ARG CLAUDE_JOB_DIR= ${extra_env:+"$extra_env"} \
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
# live-checkout-guard reaches its python3 -c judge only for a git command with the
# cwd inside a live root: a plant git repo named in SYG_LIVE_CHECKOUTS.
LIVE="$TMP/live"
mkdir -p "$LIVE" && git -C "$LIVE" init -q
row "live-checkout-guard.sh (python3 -c live_checkout judge)" live-checkout-guard.sh \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git switch -c scratch\"},\"cwd\":\"$LIVE\"}" \
  "SYG_LIVE_CHECKOUTS=$LIVE"

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
# Known limit: the path+size pair cannot see an in-place same-size pyc overwrite; accepted (hostile-input-only).
PYC_AFTER=$(pyc_files "$REPO/plugins")
if [ "$PYC_BEFORE" = "$PYC_AFTER" ]; then
  ok "no new *.pyc under plugins/"
else
  bad "new *.pyc under plugins/: $(comm -13 <(printf '%s\n' "$PYC_BEFORE") <(printf '%s\n' "$PYC_AFTER") | tr '\n' ' ')"
fi

# C2. The file-level check catches a new .pyc written into a __pycache__ that
# already exists (the dir-name check passed this case vacuously). The fixture
# imports the way claude-role does (-I, sys.path insert, no -B) and must leave
# a .pyc that the diff reports.
C2="$TMP/pycfix/plugins/seyag/lib"
mkdir -p "$C2/__pycache__"
printf 'VALUE = 1\n' >"$C2/pyc_probe_mod.py"
C2_BEFORE=$(pyc_files "$TMP/pycfix/plugins")
(cd "$TMP" && env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX "$REAL_PY3" -I -c \
  'import sys; sys.path.insert(0, sys.argv[1]); import pyc_probe_mod' "$C2" >/dev/null 2>&1)
C2_AFTER=$(pyc_files "$TMP/pycfix/plugins")
C2_NEW=$(comm -13 <(printf '%s\n' "$C2_BEFORE") <(printf '%s\n' "$C2_AFTER"))
if [ -n "$C2_NEW" ]; then
  ok "C2: file check reports a new .pyc in a pre-existing __pycache__ ($C2_NEW)"
else
  bad "C2: the fixture import left no new .pyc for the file check to report"
fi

exit "$fail"
