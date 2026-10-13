#!/bin/bash
# SessionStart hook (seyag plugin) — records session launch configuration.
#
# TRIGGER: every SessionStart source (startup, clear, resume, compact).
# Rewrites the session's launch record on each start/resume/clear/compact event.
#
# CONFIG (all env, read from the session environment):
#   SYG_LAUNCH_RECORD_DIR         target directory for session record files.
#                                 Opt-in: unset or empty disables recording
#                                 (silent exit 0, no file written).
#   SYG_LAUNCH_RECORD_ENV         space-separated list of additional environment
#                                 variable names to record in the `extra` object.
#   SYG_LAUNCH_RECORD_HYBRID_OK   set to 1 to acknowledge a deliberate hybrid
#                                 model provider configuration and suppress warnings.
#
# OUTPUT:
#   Silent exit 0 when configuration is homogeneous or recognized. When model
#   slots mix provider families (or use non-Anthropic models on the default
#   endpoint) without SYG_LAUNCH_RECORD_HYBRID_OK=1, outputs a JSON warning
#   object with systemMessage and hookSpecificOutput.additionalContext.
#   Model aliases (opus, sonnet, haiku, fable, opusplan, default, best) resolve to slot family or anthropic.
#   Never blocks the session: internal errors exit 0.

set -uo pipefail

[ -n "${SYG_LAUNCH_RECORD_DIR:-}" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)

HOOK_PPID="$PPID" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$INPUT" << 'PYEOF' || exit 0
import json
import os
import re
import stat
import sys
import time
from collections import Counter
from datetime import datetime

try:
    try:
        with open(3, "r", encoding="utf-8", errors="replace") as f:
            raw_input = f.read()
    except Exception:
        raw_input = ""

    try:
        event = json.loads(raw_input) if raw_input.strip() else {}
    except Exception:
        event = {}

    session_id = str(event.get("session_id") or "")
    if not session_id or not re.match(r"^[A-Za-z0-9_-]+$", session_id):
        sys.exit(0)

    record_dir = os.environ.get("SYG_LAUNCH_RECORD_DIR", "")
    if not record_dir:
        sys.exit(0)

    if not os.path.exists(record_dir):
        os.makedirs(record_dir, mode=0o700, exist_ok=True)
        try:
            os.chmod(record_dir, 0o700)
        except OSError:
            pass

    source = str(event.get("source") or "")
    cwd = event.get("cwd") or os.environ.get("PWD") or os.getcwd()
    recorded_at = datetime.now().astimezone().isoformat(timespec="seconds")

    parent_pid_str = os.environ.get("HOOK_PPID", "")
    try:
        start_pid = int(parent_pid_str) if parent_pid_str else os.getppid()
    except (ValueError, TypeError):
        start_pid = None

    claude_pid = None
    curr = start_pid
    for _ in range(10):
        if curr is None or curr <= 1:
            break

        exe_matches = False
        try:
            exe_target = os.readlink(f"/proc/{curr}/exe")
            if "/claude/versions/" in exe_target:
                exe_matches = True
        except OSError:
            pass

        comm_matches = False
        try:
            with open(f"/proc/{curr}/comm", "r", encoding="utf-8", errors="replace") as f:
                if f.read().strip() == "claude":
                    comm_matches = True
        except OSError:
            pass

        if exe_matches or comm_matches:
            claude_pid = curr
            break

        next_pid = None
        try:
            with open(f"/proc/{curr}/stat", "r", encoding="utf-8", errors="replace") as f:
                stat_content = f.read()
            rparen = stat_content.rfind(")")
            if rparen != -1:
                fields = stat_content[rparen + 1:].split()
                if len(fields) >= 2:
                    next_pid = int(fields[1])
        except (OSError, ValueError):
            break

        curr = next_pid

    SLOT_DEFS = [
        ("model", "ANTHROPIC_MODEL"),
        ("opus", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
        ("sonnet", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
        ("haiku", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
        ("fable", "ANTHROPIC_DEFAULT_FABLE_MODEL"),
        ("subagent", "CLAUDE_CODE_SUBAGENT_MODEL"),
        ("small_fast", "ANTHROPIC_SMALL_FAST_MODEL"),
    ]
    slots = {}
    for slot_name, env_var in SLOT_DEFS:
        val = os.environ.get(env_var)
        if val:
            slots[slot_name] = val

    base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
    if not base_url:
        base_host = ""
    else:
        u = base_url
        if "://" in u:
            u = u.split("://", 1)[1]
        m = re.split(r"[/?#]", u, maxsplit=1)
        authority = m[0]
        if "@" in authority:
            authority = authority.split("@")[-1]
        base_host = authority

    auto_mode_server = os.environ.get("CLAUDE_CODE_AUTO_MODE_SERVER", "")

    extra = {}
    extra_names = os.environ.get("SYG_LAUNCH_RECORD_ENV", "").split()
    for name in extra_names:
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
            extra[name] = os.environ.get(name, "")

    ALIASES = {"opus", "sonnet", "haiku", "fable"}

    def family_of(slot_name, _allow_alias=True):
        model_id = slots.get(slot_name, "")
        if not model_id:
            return "unknown"
        if "/" in model_id:
            part = model_id.split("/", 1)[0]
            if part.startswith("~"):
                part = part[1:]
            return part
        clean = re.sub(r"\[[^\]]*\]$", "", model_id)
        if clean.startswith("claude-"):
            return "anthropic"
        low = clean.lower()
        if _allow_alias:
            target_slot = "opus" if low == "opusplan" else low
            if target_slot in ALIASES:
                if target_slot in slots:
                    fam = family_of(target_slot, _allow_alias=False)
                    if fam is not None:
                        return fam
                return "anthropic"
            if low in ("default", "best"):
                return "anthropic"
        elif low in ALIASES or low == "opusplan" or low in ("default", "best"):
            return None
        return "unknown"

    families = {slot_name: family_of(slot_name) for slot_name in slots}

    if not slots:
        hybrid = False
        hybrid_why = []
    else:
        fam_values = list(families.values())
        fam_set = set(fam_values)
        has_multi = len(fam_set) > 1
        has_default_endpoint_non_anthropic = (base_host == "" and any(f != "anthropic" for f in fam_values))

        hybrid = bool(has_multi or has_default_endpoint_non_anthropic)

        if not hybrid:
            hybrid_why = []
        else:
            if (not has_multi) and has_default_endpoint_non_anthropic:
                hybrid_why = sorted(slots.keys())
            else:
                counts = Counter(fam_values)
                max_cnt = max(counts.values())
                top_candidates = [fam for fam, cnt in counts.items() if cnt == max_cnt]
                if len(top_candidates) == 1:
                    majority = top_candidates[0]
                elif "anthropic" in top_candidates:
                    majority = "anthropic"
                else:
                    majority = sorted(top_candidates)[0]
                hybrid_why = sorted([s for s, fam in families.items() if fam != majority])

    record = {
        "v": 1,
        "session_id": session_id,
        "source": source,
        "cwd": cwd,
        "recorded_at": recorded_at,
        "pid": claude_pid,
        "slots": slots,
        "base_host": base_host,
        "auto_mode_server": auto_mode_server,
        "extra": extra,
        "families": families,
        "hybrid": hybrid,
        "hybrid_why": hybrid_why,
    }

    target_file = os.path.join(record_dir, f"{session_id}.json")
    tmp_file = os.path.join(record_dir, f".{session_id}.{os.getpid()}.{time.time()}.tmp")

    try:
        fd = os.open(tmp_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.chmod(tmp_file, 0o600)
        except OSError:
            pass
        with open(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
            f.write("\n")
        os.replace(tmp_file, target_file)
    except Exception:
        try:
            os.unlink(tmp_file)
        except OSError:
            pass
        raise

    cutoff = time.time() - (14 * 86400)
    try:
        for fname in os.listdir(record_dir):
            if fname.endswith(".json"):
                fpath = os.path.join(record_dir, fname)
                try:
                    st = os.lstat(fpath)
                    if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                        os.unlink(fpath)
                except OSError:
                    pass
    except OSError:
        pass

    hybrid_ok = os.environ.get("SYG_LAUNCH_RECORD_HYBRID_OK") == "1"
    if hybrid and not hybrid_ok:
        slots_desc = ", ".join(f"{s} ({families.get(s, 'unknown')})" for s in hybrid_why)
        msg = (
            f"This session's model slots mix provider families: {slots_desc}. "
            "If this was not intended, check the launch configuration. "
            "Set SYG_LAUNCH_RECORD_HYBRID_OK=1 to mark a deliberate mix."
        )
        out = {
            "systemMessage": msg,
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": msg,
            },
        }
        print(json.dumps(out))

except Exception as exc:
    sys.stderr.write(f"launch-record internal error: {exc}\n")
    sys.exit(0)
PYEOF

exit 0
