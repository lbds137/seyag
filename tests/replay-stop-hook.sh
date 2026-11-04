#!/bin/bash
# tests/replay-stop-hook.sh — replay one Stop hook against the transcript
# windows local sessions would have handed it at every turn end, and report
# what it would have tripped.
#
# SECRETS WARNING: assistant text and hook stderr printed here are pulled
# verbatim from real sessions and can carry tokens, paths, or secrets. Local
# working material only — never paste into a commit, PR, or tracked doc (same
# boundary as tests/replay-hook.sh and the session-mining corpus).
#
# Usage: tests/replay-stop-hook.sh <hook-name> [--since N] [--slug SLUG] [--projects-dir DIR]
#   <hook-name>   any hook registered under Stop in hooks.json (read with jq).
#                 Any other name — unknown, or a PreToolUse hook like
#                 lossy-pipe-guard — is refused: fed Stop payloads it exits 0
#                 everywhere and reads as a false zero.
#   --since N            JSONLs modified in the last N days (default 7).
#   --slug SLUG           only ~/.claude/projects/SLUG/*.jsonl (default: all).
#   --projects-dir DIR   projects root (default $HOME/.claude/projects); lets
#                        a probe point this at a fixture.
#
# Mechanism:
#   Two modes, decided PER FILE before the turn-end pass: RECORDED if the file
#   contains any `stop_hook_summary` system entry, else INFERRED.
#
#   INFERRED (no Stop records in the file — an older session, or one with the
#   Stop hooks unconfigured): a Stop fires just before every USER-AUTHORED
#   entry (type=="user", content a string, or a list with NO tool_result
#   block — includes isMeta entries) and at EOF, PROVIDED a main-lane
#   assistant entry (isSidechain != true) occurred since the previous turn
#   end. A tool_result envelope is Claude Code returning a tool's own output
#   mid-turn, not a Stop.
#
#   RECORDED: the same rule, PLUS a real Stop must be attested — a
#   user-authored entry (or EOF) only ends a turn if a stop_hook_summary was
#   seen since the last main-lane assistant entry, OR the entry itself is a
#   "Stop hook feedback:" entry (string or list-text content). A
#   user-authored entry that fails this is a MID-TURN INJECTION (a Skill-tool
#   content block, a cross-session message, a pasted image, a queued prompt
#   delivered before the model resumes) — measured 2026-09-25 over the last 7
#   days: 1088 turn ends backed by a summary all ended on text, while 101
#   user-authored entries followed an assistant entry with no Stop between
#   them (58 Skill-directory injections, 8 cross-session messages, 6 pasted
#   images, 4 queued prompts) were counted as turn ends by the INFERRED rule;
#   69 of the 101 ended on a tool_use and so tripped turn-end-shape-gate. An
#   injection is skipped (not a turn end); the pending assistant entry carries
#   forward to the next candidate. Interrupts are not a contributor (3 in the
#   week).
#
#   Known RECORDED-mode undercount: turns before a file's first
#   stop_hook_summary are treated as injections (no summary has been seen
#   yet, by construction). Measured 2026-09-26: 35 candidates across 19 of 60
#   RECORDED files, mostly a single first-turn entry per file.
#
#   Either mode: system/attachment/queue-operation/progress entries never
#   start or end a turn; they ride along in whichever window they land.
#
#   Cut rule: the byte offset of the ending user-authored entry (exclusive),
#   or file size at EOF — unchanged by which entry a mode skips. A
#   stop_hook_summary between the final text and the next prompt lands INSIDE
#   the window — harmless, since the hooks ignore system entries; keeps the
#   rule simple.
#
#   Window (not the whole prefix — 200 MB x 300 turn ends would write 30 GB to
#   tmpfs): max(0, min(cut - 8_000_000, offset_of_line(cut_line - 4000))) to
#   cut — at least the last 8 MB and last 4000 lines (malformed/empty lines
#   count toward the 4000; they still occupy a line and byte offset). EXACT
#   for the three hooks as written today: TAIL_BYTES = 4_000_000 in
#   promise-ledger-check.sh / blocking-question-channel-check.sh, `tail -n
#   2000` in turn-end-shape-gate.sh — a hook reading further back needs the
#   cap raised here. One scratch file under a mktemp -d dir, trap-cleaned;
#   overwritten per turn end.
#
#   stop_hook_active mirrors Claude Code (set true) when the user-authored entry
#   that ended the PREVIOUS turn end here was a "Stop hook feedback:" entry
#   (Claude Code retries without a new user turn, and that retry's Stop
#   carries stop_hook_active: true; every hook here honours it and exits 0),
#   so mirroring it avoids double-counting a live block as a trip.
#
#   Live blocks: counted per file, independent of the replay itself and of
#   the mode — a user-authored entry (string or list-text content) starting
#   "Stop hook feedback:" whose bracketed command names THIS hook (matches
#   the run.sh bracket and a project override's bracket).
#
#   Fed to the hook DIRECTLY (`bash plugins/seyag/hooks/<hook>.sh`, not
#   run.sh — a project's own `.claude/hooks/<name>.sh` override would make
#   run.sh exit 0 for everything), with `env -u CLAUDE_PROJECT_DIR -u
#   SYG_LEDGER_PATH_RE -u SYG_PR_MONITOR_SEEN_FILE -u SYG_PR_BODY_ACK_FILE`: the
#   hook runs with ITS OWN defaults, not whatever the recorded project's
#   environment happened to set. Hooks also run with a fresh
#   XDG_STATE_HOME, XDG_RUNTIME_DIR and SYG_STATE_DIR (all in the run's scratch
#   dir, fresh per JSONL file — see below), so a replay never reads or writes
#   the caller's state through those
#   paths, and two replays (base vs tree) start equal. The state and runtime
#   dirs are fresh per JSONL file — each session gets its own subdir under the
#   scratch dir, created before its spawn — so two sessions in one replay start
#   equal and one session's ack never masks a later session's identical block;
#   within one file the state persists across that file's turn ends, as it did
#   live; the next file starts empty. NOT isolated: hooks that write a
#   hardcoded /tmp/claude-$(id -u) path (dispatch-posture-gate,
#   queued-message-receipt, context-size-reminder) still use the caller's /tmp
#   state.
#
#   A trip is a non-zero exit. Output: one section per tripped turn end (last
#   main-lane assistant text before the cut, first 200 chars; slug/file:line;
#   which mode decided this turn end; the hook's stdout+stderr, first 3
#   lines), then exactly one summary line, the LAST line of output:
#     replay-stop-hook: <hook>: <tripped>/<total> turn ends tripped across <files> files (<t_inf>/<n_inf> inferred in <f_inf> files without Stop records); <live> live blocks in the logs
#   <t_inf>/<n_inf>/<f_inf> count only INFERRED-mode files; <tripped>/<total>/
#   <files> and <live> are both modes combined. Nothing else on stdout. Exit 0
#   even with trips — a report, not a gate.
#
#   Inert switches: a hook that exits 0 unless a switch is set trips nothing in
#   a run without it, so its header may carry `# REPLAY-ARMED-BY: VAR [VAR...]`.
#   The field names only the variables, not every condition, so an armed replay
#   that trips nothing is not proof by itself. Before the replay, each named VAR
#   that is unset or empty in this environment gets a stderr line
#   (`replay-stop-hook: warning: <hook> is inert without <VAR> (unset or empty
#   here); export it for this run`), and the summary line gains
#   ` (INERT: <VAR> unset or empty)` for each one; tokens that are not shell
#   identifiers are skipped. The field
#   is for gates only: a hook with side effects (one that writes files or state)
#   must not carry it, or a replay would run it for real.
#
#   Runtime observed 2026-09-26: `--since 7` against
#   blocking-question-channel-check over 87 local session-log files (2510
#   turn ends, 1316 INFERRED across 27 files) took 4m28s wall — ~107
#   ms/turn-end. turn-end-shape-gate, measured 2026-09-25/26 over a nearby
#   window: 78/2492 tripped, 78/1316 of those INFERRED — 0 of 1176
#   RECORDED-mode turn ends tripped.
#
# Exit codes: 2 on a bad hook name or bad argument; 1 if a per-file replay
# crashes (the failing file and python's exit code are named on stderr; no
# summary line prints — partial counts never print as a total); 0 otherwise
# (a report, not a gate, even when every turn end tripped).

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOOKS_DIR="$REPO/plugins/seyag/hooks"
HOOKS_JSON="$HOOKS_DIR/hooks.json"

HOOK_NAME="${1:-}"
if [ -z "$HOOK_NAME" ] || [[ "$HOOK_NAME" == --* ]]; then
  echo "replay-stop-hook: usage: replay-stop-hook.sh <hook-name> [--since N] [--slug SLUG] [--projects-dir DIR]" >&2
  exit 2
fi
shift

mapfile -t STOP_HOOKS < <(jq -r '.hooks.Stop[]?.hooks[]?.command' "$HOOKS_JSON" 2>/dev/null | grep -oE '[^ ]+$')
known=0
for h in "${STOP_HOOKS[@]}"; do
  if [ "$h" = "$HOOK_NAME" ]; then
    known=1
    break
  fi
done
if [ "$known" -ne 1 ]; then
  echo "replay-stop-hook: '$HOOK_NAME' is not a Stop hook in hooks.json" >&2
  exit 2
fi

SINCE=7
SLUG=""
PROJECTS_DIR="$HOME/.claude/projects"

need_value() { [ $# -ge 2 ] || { echo "replay-stop-hook: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --since) need_value "$@"; SINCE="$2"; shift 2 ;;
    --slug) need_value "$@"; SLUG="$2"; shift 2 ;;
    --projects-dir) need_value "$@"; PROJECTS_DIR="$2"; shift 2 ;;
    *) echo "replay-stop-hook: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ "$SINCE" =~ ^[0-9]+$ ]] || { echo "replay-stop-hook: --since needs a whole number of days" >&2; exit 2; }

if [ -n "$SLUG" ]; then
  SEARCH_ROOT="$PROJECTS_DIR/$SLUG"
  MAXDEPTH=1
else
  SEARCH_ROOT="$PROJECTS_DIR"
  MAXDEPTH=2
fi
[ -d "$SEARCH_ROOT" ] || { echo "replay-stop-hook: no such directory: $SEARCH_ROOT" >&2; exit 2; }

# REPLAY-ARMED-BY (see the header): a switch the hook needs to act, unset or empty here.
INERT_SUFFIX=""
ARMED_LINE=$(grep -m1 '^# REPLAY-ARMED-BY:' "$HOOKS_DIR/$HOOK_NAME.sh" 2>/dev/null || true)
if [ -n "$ARMED_LINE" ]; then
  read -r -a ARMED_VARS <<<"${ARMED_LINE#*REPLAY-ARMED-BY:}"
  for armed_var in ${ARMED_VARS[@]+"${ARMED_VARS[@]}"}; do
    [[ "$armed_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [ -z "${!armed_var:-}" ]; then
      echo "replay-stop-hook: warning: $HOOK_NAME is inert without $armed_var (unset or empty here); export it for this run" >&2
      INERT_SUFFIX="$INERT_SUFFIX (INERT: $armed_var unset or empty)"
    fi
  done
fi

SCRATCH_DIR=$(mktemp -d) || { echo "replay-stop-hook: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$SCRATCH_DIR"' EXIT
# Hook state (see the header): one state and one runtime dir PER SESSION —
# a fresh subdir per JSONL file under these, created before its spawn.
mkdir -p "$SCRATCH_DIR/state" "$SCRATCH_DIR/runtime"
chmod 700 "$SCRATCH_DIR/runtime"
SCRATCH_WINDOW="$SCRATCH_DIR/window.jsonl"
RESULTS="$SCRATCH_DIR/results"

TOTAL=0
TRIPPED=0
FILES=0
LIVE=0
TOTAL_INF=0
TRIPPED_INF=0
FILES_INF=0

# Epoch cutoff, not `find -mtime`: -mtime's day-bucket semantics differ across
# find implementations. --since 0 means "modified after right now" — no
# existing file can satisfy that, so it deterministically yields 0 files.
CUTOFF=$(( $(date +%s) - SINCE * 86400 ))
# Subagent transcripts are NOT walked here (unlike replay-hook.sh): Stop
# hooks do not fire in subagents — 0 subagent logs carry a
# "subtype":"stop_hook_summary" record, while main logs do (checked
# 2026-09-27); hooks.json registers Stop, not SubagentStop.
FILE_LIST=$(find "$SEARCH_ROOT" -maxdepth "$MAXDEPTH" -type f -name '*.jsonl' 2>/dev/null)

while IFS= read -r f; do
  [ -z "$f" ] && continue
  mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
  [ "$mtime" -gt "$CUTOFF" ] || continue
  FILES=$((FILES + 1))
  slug_name=$(basename "$(dirname "$f")")

  # Fresh state for this session (see the header): its own state and runtime
  # subdir, so one session's ack never masks a later session's identical block.
  sess_id=$(basename "$f"); sess_id=${sess_id%.jsonl}
  HOOK_STATE="$SCRATCH_DIR/state/$slug_name/$sess_id"
  HOOK_RUNTIME="$SCRATCH_DIR/runtime/$slug_name/$sess_id"
  rm -rf "$HOOK_STATE" "$HOOK_RUNTIME"
  mkdir -p "$HOOK_STATE" "$HOOK_RUNTIME"
  chmod 700 "$HOOK_RUNTIME"

  rm -f "$RESULTS"
  python3 - "$f" "$HOOK_NAME" "$HOOKS_DIR/$HOOK_NAME.sh" "$SCRATCH_WINDOW" "$RESULTS" "$slug_name" "$HOOK_STATE" "$HOOK_RUNTIME" <<'PYEOF'
import sys, os, re, json, subprocess
from collections import deque

file_path, hook_name, hook_script, scratch_path, results_path, slug_name, hook_state, hook_runtime = sys.argv[1:9]
MIN_WINDOW_BYTES = 8_000_000
TAIL_LINES = 4000
FEEDBACK_PREFIX = "Stop hook feedback:"
HOME = os.environ.get("HOME", "")
# Anchored to a bracket at line start, with a separator (space, "/", or a
# quote) before the name: matches `[bash ".../run.sh" <hook>]:` and
# `[cd ... && .../<hook>.sh]:`, but not a `[.../old-<hook>.sh]:` false hit
# where the name is only a suffix of a longer token. re.M because the bracket
# line is the SECOND line of the feedback text (after "Stop hook feedback:\n").
live_re = re.compile(r'^\[[^\]\n]*[\s/"]' + re.escape(hook_name) + r"(\.sh)?\]:", re.M)
SUMMARY_RE = re.compile(rb'"subtype"\s*:\s*"stop_hook_summary"')


def is_user_authored(entry):
    if entry.get("type") != "user":
        return False
    if entry.get("isSidechain") is True:
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def is_main_assistant(entry):
    return entry.get("type") == "assistant" and entry.get("isSidechain") is not True


def is_summary(entry):
    return entry.get("type") == "system" and entry.get("subtype") == "stop_hook_summary"


def feedback_text(entry):
    # The text of a "Stop hook feedback:" entry, string or list-text content;
    # None if this entry isn't one.
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content if content.startswith(FEEDBACK_PREFIX) else None
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text.startswith(FEEDBACK_PREFIX):
                    return text
    return None


def tail_offset(line_no):
    # offset_of_line(line_no - TAIL_LINES); 0 if that line doesn't exist yet.
    return offsets[0][1] if line_no - TAIL_LINES >= 1 else 0


mode = "inferred"
with open(file_path, "rb") as rf:
    for probe_line in rf:
        if SUMMARY_RE.search(probe_line):
            mode = "recorded"
            break

basename = os.path.basename(file_path)
session_id = basename[:-6] if basename.endswith(".jsonl") else basename
offsets = deque()  # (line_no, start_offset); bounded to the last TAIL_LINES+1
tripped = total = live = 0
have_assistant = False
have_summary_since_last_assistant = False
prev_ending_is_feedback = False
last_main_text = ""
last_main_cwd = None


def run_turn_end(cut_offset, cut_line_display, window_start, stop_hook_active):
    global tripped, total
    with open(file_path, "rb") as rf:
        rf.seek(window_start)
        data = rf.read(cut_offset - window_start)
    with open(scratch_path, "wb") as wf:
        wf.write(data)
    stdin_obj = {
        "session_id": session_id,
        "transcript_path": scratch_path,
        "cwd": last_main_cwd or HOME,
        "hook_event_name": "Stop",
        "stop_hook_active": stop_hook_active,
    }
    proc = subprocess.run(
        ["env", "-u", "CLAUDE_PROJECT_DIR", "-u", "SYG_LEDGER_PATH_RE", "-u", "SYG_PR_MONITOR_SEEN_FILE",
         "-u", "SYG_PR_BODY_ACK_FILE", f"SYG_STATE_DIR={hook_state}", f"XDG_STATE_HOME={hook_state}",
         f"XDG_RUNTIME_DIR={hook_runtime}", "bash", hook_script],
        input=json.dumps(stdin_obj).encode("utf-8"),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    total += 1
    if proc.returncode != 0:
        tripped += 1
        txt = last_main_text.replace("\n", " ").replace("\t", " ")[:200]
        out_lines = proc.stdout.decode("utf-8", "replace").splitlines()
        print("--- tripped ---")
        print(f"text: {txt}")
        print(f"entry: {slug_name}/{basename}:{cut_line_display}")
        print(f"mode: {mode}")
        for ln in out_lines[:3]:
            print(ln)
        print()


with open(file_path, "rb") as f:
    line_no = 0
    while True:
        start = f.tell()
        raw = f.readline()
        if not raw:
            break
        line_no += 1
        offsets.append((line_no, start))
        while len(offsets) > TAIL_LINES + 1:
            offsets.popleft()
        try:
            entry = json.loads(raw.decode("utf-8", "replace").strip())
        except (json.JSONDecodeError, ValueError):
            entry = None
        if not isinstance(entry, dict):
            continue

        if is_main_assistant(entry):
            have_assistant = True
            have_summary_since_last_assistant = False
            if "cwd" in entry:
                last_main_cwd = entry.get("cwd")
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        last_main_text = block.get("text", "")
            continue

        if is_summary(entry):
            have_summary_since_last_assistant = True
            continue

        if is_user_authored(entry):
            fb_text = feedback_text(entry)
            if fb_text is not None and live_re.search(fb_text):
                live += 1
            if not have_assistant:
                continue
            if mode == "recorded" and not (have_summary_since_last_assistant or fb_text is not None):
                continue  # mid-turn injection: skip, keep have_assistant pending
            window_start = max(0, min(start - MIN_WINDOW_BYTES, tail_offset(line_no)))
            run_turn_end(start, line_no, window_start, prev_ending_is_feedback)
            prev_ending_is_feedback = fb_text is not None
            have_assistant = False

    file_size = f.tell()
    if have_assistant and (mode == "inferred" or have_summary_since_last_assistant):
        window_start = max(0, min(file_size - MIN_WINDOW_BYTES, tail_offset(line_no)))
        run_turn_end(file_size, "EOF", window_start, prev_ending_is_feedback)

with open(results_path, "w") as rf:
    rf.write(f"{tripped} {total} {live} {1 if mode == 'inferred' else 0}\n")
PYEOF
  py_rc=$?
  if [ "$py_rc" -ne 0 ] || [ ! -f "$RESULTS" ]; then
    echo "replay-stop-hook: replay failed on $f (python exit $py_rc)" >&2
    exit 1
  fi

  read -r file_tripped file_total file_live file_inferred < "$RESULTS"
  TRIPPED=$((TRIPPED + file_tripped))
  TOTAL=$((TOTAL + file_total))
  LIVE=$((LIVE + file_live))
  if [ "$file_inferred" = "1" ]; then
    TRIPPED_INF=$((TRIPPED_INF + file_tripped))
    TOTAL_INF=$((TOTAL_INF + file_total))
    FILES_INF=$((FILES_INF + 1))
  fi
done <<<"$FILE_LIST"

echo "replay-stop-hook: $HOOK_NAME: $TRIPPED/$TOTAL turn ends tripped across $FILES files ($TRIPPED_INF/$TOTAL_INF inferred in $FILES_INF files without Stop records); $LIVE live blocks in the logs$INERT_SUFFIX"
exit 0
