#!/usr/bin/env bash
# env-print-guard.sh — PreToolUse Bash guard blocking bulk environment and
# secret file dumps into the session transcript.
#
# Blocks two leak shapes:
#   1. A pipeline segment whose command word (by basename) is `env` (with no
#      target command to execute), argumentless `printenv`, or argumentless
#      `set`, unless a downstream segment in the same pipeline reduces output
#      to variable names or counts via the names-only allowlist (without first
#      teeing to `/dev/stderr`, `/dev/fd/2`, `/dev/stdout`, `/dev/fd/1`, or
#      `/dev/tty`):
#        - `cut -s -d= -f1` (or `--only-delimited` with `-d '=' -f 1`; `-s` is
#          required so continuation lines of multi-line values—which carry no
#          `=`—are dropped instead of passed whole; `sed 's/=.*//'` and
#          `awk -F= '{print $1}'` are not allowlisted for the same reason)
#        - `jq` with `keys` / `keys_unsorted` (stdin mode)
#        - `wc` (flags only, excluding `--files0-from`)
#        - `grep -c` (count-only)
#      Value-preserving filters (`grep`, `head`, `tail`, `sort`, or name-keyed
#      redactions like `sed 's/TOKEN=.*/TOKEN=…/'` or `jq del(...)`) do not
#      satisfy the names-only requirement.
#   2. `jq` reading a `.env`, `.env.*`, `*.env`, or `settings*.json` file
#      (e.g. `settings.json`, `settings.local.json`) with any filter outside
#      the narrow allowlist: (a) final `|`-stage `keys` / `keys_unsorted`, or
#      (b) a pure dotted identifier chain (`.foo.bar.baz`, optionally `?` per
#      stage) that is not `.env` and does not stop at `.env` (`.env` and
#      `.env?` deny; `.env.VAR`, `.model`, `.name` allow), unless stdout is
#      redirected to `/dev/null`.
#
# Accepted gaps: bare `export`, `export -p`, bare `declare`, `declare -x`,
# `declare -p`, `alias`, `typeset -p`, absolute-path `printenv` under a renamed
# binary, and selectors expressed in languages other
# than the allowlist are unseen; the guard models the `jq`/`env`/`set`/`printenv`
# command words only — `cat .env`, `/proc/self/environ`, `/proc/$$/environ`
# (and `/proc/*/environ` siblings), `jq . < settings.json`, and
# `cat settings.json | jq .` are unseen (file-argument analysis is
# cat/grep-shaped and out of scope here); the jq check is an allowlist of
# provably-narrow shapes; aggregation filters (`to_entries`, `{env}`, `..`,
# `del(...)`, comma lists) deny even when their intent looks narrow; a keyed
# reread after a selector (`env | cut -s -d= -f1 | xargs printenv`) prints
# every value and is unseen; `bash -c 'env'` / `sh -c printenv` wrapper strings
# are not descended into by this guard's walker (the lib's shell-quote scanner
# serves the delete-analysis guards; wiring it here is a possible follow-up,
# not done in this PR); `grep -o` patterns cannot be analyzed
# safely for names-only output, so none are allowlisted (the fleet's
# `env $(env | grep -oE '^[A-Z_]*' | …)` launcher pattern needs the bypass
# prefix or a `cut -s -d= -f1` rewrite); intermediate pipeline file sinks
# (`env | tee /tmp/f | cut -s -d= -f1`) are out of scope because the guard's
# scope is transcript output; `env -i` / `env -i CMD` and `printenv NAME` keyed reads
# are allowed by design. Double-quoted command substitutions are not split by
# `lib/shell_quotes.py` (`command_pipelines`) and fail open. Heredoc bodies
# written to a file (`cat > f <<EOF`) are scanned as commands, so guard-shaped
# text inside a written script blocks the writer (observed in replay; lib-level,
# follow-up filed). A bash array initialization like `scrub=(env …)` is parsed
# as a parenthesized subshell, so an array whose literal elements start with
# `env`/`printenv` blocks the assignment (observed on real fleet tooling in
# replay; lib/shell_quotes-level classification, follow-up filed).
#
# Bypass: put `SYG_ALLOW_ENV_PRINT=1` anywhere in the bypassed segment's own
# words when a full environment or secret-file dump is explicitly intended.
#
# Deny channel: delivers via stderr + exit 2, same as the repo's other Bash guards.
# Fail-open on missing jq/python3 or any parse error.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$COMMAND" ] || exit 0

printf '%s\n' "$COMMAND" | grep -qE '(^|[^A-Za-z0-9_])(env|printenv|set|jq)([^A-Za-z0-9_]|$)' || exit 0

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

REASON=$(SYG_LIB_DIR="$LIB_DIR" python3 - 3<<<"$COMMAND" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

sys.path.insert(0, os.environ["SYG_LIB_DIR"])
from shell_quotes import command_pipelines, strip_redirections, unwrap_runners  # noqa: E402

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")

_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_NON_ENV_RUNNERS = frozenset({
    "sudo", "command", "builtin", "nohup", "setsid",
    "unbuffer", "time", "exec", "nice", "timeout", "stdbuf",
})
_ENV_ARG_FLAGS = frozenset({
    "-u", "--unset", "-C", "--chdir",
})
_INFO_FLAGS = frozenset({
    "--version", "-V", "--help", "-h",
})
_JQ_1ARG_FLAGS = frozenset({
    "-L", "--library-path", "-f", "--from-file", "--indent",
})
_JQ_2ARG_FLAGS = frozenset({
    "--arg", "--argjson", "--slurpfile", "--rawfile",
})
_GREP_1ARG_FLAGS = frozenset({
    "-m", "--max-count", "-A", "--after-context", "-B", "--before-context",
    "-C", "--context", "-D", "--devices", "-d", "--directories",
    "--binary-files", "--color", "--colour", "--label",
    "--exclude", "--exclude-from", "--exclude-dir", "--include",
})


def unwrap_non_env_runners(tokens: list[str]) -> list[str]:
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        base = os.path.basename(tok)
        if base not in _NON_ENV_RUNNERS:
            break
        i += 1
        while i < n and tokens[i].startswith("-"):
            flag = tokens[i]
            i += 1
            if flag == "--":
                break
            if base == "sudo" and flag in ("-u", "-g", "-C", "-D", "-R", "-T", "-h", "-p"):
                if i < n:
                    i += 1
            elif base == "timeout" and flag in ("-k", "-s", "--kill-after", "--signal"):
                if i < n:
                    i += 1
            elif base == "nice" and flag in ("-n", "--adjustment"):
                if i < n:
                    i += 1
            elif base == "stdbuf" and flag in ("-i", "-o", "-e"):
                if i < n:
                    i += 1
        if base == "timeout" and i < n and re.match(r"^[0-9]+(\.[0-9]+)?[smhd]?$", tokens[i]):
            i += 1
    return tokens[i:]


def _split_env_s(val: str) -> list[str]:
    try:
        return shlex.split(val)
    except ValueError:
        return val.split()


def detect_env_dump_command(seg: list[str]) -> str | None:
    if "SYG_ALLOW_ENV_PRINT=1" in seg:
        return None
    words = strip_redirections(seg)
    while words:
        if "SYG_ALLOW_ENV_PRINT=1" in words:
            return None
        words = unwrap_non_env_runners(words)
        if not words:
            return None
        if "SYG_ALLOW_ENV_PRINT=1" in words:
            return None
        base = os.path.basename(words[0])
        rest = words[1:]
        if base == "env":
            # Check if env has a target command or only assignments/flags.
            ignore_env = False
            j = 0
            while j < len(rest):
                tok = rest[j]
                if tok == "--":
                    j += 1
                    break
                if tok in ("-S", "--split-string"):
                    if j + 1 < len(rest):
                        rest = rest[:j] + _split_env_s(rest[j + 1]) + rest[j + 2:]
                        continue
                    j += 1
                    continue
                if tok.startswith("--split-string="):
                    rest = rest[:j] + _split_env_s(tok.split("=", 1)[1]) + rest[j + 1:]
                    continue
                if tok.startswith("-S") and len(tok) > 2:
                    rest = rest[:j] + _split_env_s(tok[2:]) + rest[j + 1:]
                    continue
                if tok in _ENV_ARG_FLAGS and j + 1 < len(rest):
                    j += 2
                    continue
                if tok in _INFO_FLAGS:
                    return None
                if tok in ("-i", "--ignore-environment", "-") or (
                    tok.startswith("-")
                    and not tok.startswith(("--", "-u", "-C"))
                    and "i" in tok[1:]
                ):
                    ignore_env = True
                    j += 1
                    continue
                if tok.startswith("-") or _ASSIGN_RE.match(tok):
                    j += 1
                    continue
                break
            if j >= len(rest):
                return None if ignore_env else "env"
            # env is executing rest[j:]; inspect that target command.
            words = rest[j:]
            continue
        if base == "printenv":
            if any(t in _INFO_FLAGS for t in rest):
                return None
            non_flags = [t for t in rest if not t.startswith("-")]
            return "printenv" if len(non_flags) == 0 else None
        if base == "set":
            return "set" if len(rest) == 0 else None
        return None
    return None


def is_cut_names_only(args: list[str]) -> bool:
    delim = None
    fields = None
    only_delim = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-d" or a == "--delimiter":
            if i + 1 >= len(args):
                return False
            delim = args[i + 1]
            i += 2
        elif a.startswith("-d") and len(a) > 2:
            delim = a[2:]
            i += 1
        elif a.startswith("--delimiter="):
            delim = a.split("=", 1)[1]
            i += 1
        elif a == "-f" or a == "--fields":
            if i + 1 >= len(args):
                return False
            fields = args[i + 1]
            i += 2
        elif a.startswith("-f") and len(a) > 2:
            fields = a[2:]
            i += 1
        elif a.startswith("--fields="):
            fields = a.split("=", 1)[1]
            i += 1
        elif a in ("-s", "--only-delimited"):
            only_delim = True
            i += 1
        elif a in ("-z", "--zero-terminated"):
            i += 1
        else:
            return False
    return delim == "=" and fields == "1" and only_delim


def parse_jq_invocation(args: list[str]) -> tuple[str | None, list[str]] | None:
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a in ("--args", "--jsonargs"):
            break
        if a in _JQ_1ARG_FLAGS:
            if i + 1 >= len(args):
                return None
            if a in ("-f", "--from-file"):
                return None
            i += 2
            continue
        if a in _JQ_2ARG_FLAGS:
            if i + 2 >= len(args):
                return None
            i += 3
            continue
        if a.startswith("-"):
            i += 1
            continue
        pos.append(a)
        i += 1
    if not pos:
        return ("", [])
    return (pos[0], pos[1:])


def is_jq_keys_filter(expr: str) -> bool:
    stages = [p.strip() for p in expr.strip().split("|") if p.strip()]
    if not stages:
        return False
    # All stages except the last may only navigate (e.g. `.` or `.env`),
    # and the final stage must be `keys` or `keys_unsorted` (optionally `[]`).
    last = stages[-1]
    if last not in ("keys", "keys_unsorted", "keys[]", "keys_unsorted[]"):
        return False
    for prev in stages[:-1]:
        if not re.match(r'^(\.([A-Za-z_][A-Za-z0-9_]*)?|\.\["[A-Za-z_][A-Za-z0-9_]*"\])\??$', prev):
            return False
    return True


def is_wc_names_only(args: list[str]) -> bool:
    return all(a.startswith("-") and not a.startswith("--files0-from") for a in args)


def is_grep_names_only(args: list[str]) -> bool:
    has_c = False
    has_f = False
    patterns: list[str] = []
    pos: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a in ("-e", "--regexp"):
            if i + 1 >= len(args):
                return False
            patterns.append(args[i + 1])
            i += 2
            continue
        if a.startswith("--regexp="):
            patterns.append(a.split("=", 1)[1])
            i += 1
            continue
        if a in ("-f", "--file") or a.startswith("--file="):
            has_f = True
            if a in ("-f", "--file"):
                if i + 1 >= len(args):
                    return False
                i += 2
            else:
                i += 1
            continue
        if a in _GREP_1ARG_FLAGS:
            if i + 1 >= len(args):
                return False
            i += 2
            continue
        if a.startswith("--"):
            if a == "--count":
                has_c = True
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            flags = a[1:]
            if "e" in flags:
                idx = flags.index("e")
                before_e = flags[:idx]
                after_e = flags[idx + 1:]
                if "c" in before_e:
                    has_c = True
                if "f" in before_e:
                    has_f = True
                if after_e:
                    patterns.append(after_e)
                    i += 1
                else:
                    if i + 1 >= len(args):
                        return False
                    patterns.append(args[i + 1])
                    i += 2
                continue
            if "c" in flags:
                has_c = True
            if "f" in flags:
                has_f = True
            i += 1
            continue
        pos.append(a)
        i += 1
    if not patterns and not has_f:
        if not pos:
            return False
        patterns.append(pos[0])
    if has_c:
        return True
    return False


def is_names_only_selector(seg: list[str]) -> bool:
    words, _ = unwrap_runners(strip_redirections(seg))
    if not words:
        return False
    base = os.path.basename(words[0])
    args = words[1:]
    if base == "cut":
        return is_cut_names_only(args)
    if base == "jq":
        parsed = parse_jq_invocation(args)
        if parsed is None:
            return False
        filt, files = parsed
        return len(files) == 0 and filt is not None and is_jq_keys_filter(filt)
    if base == "wc":
        return is_wc_names_only(args)
    if base == "grep":
        return is_grep_names_only(args)
    return False


_TRANSCRIPT_TEE_PATHS = frozenset({
    "/dev/stderr", "/dev/fd/2", "/dev/stdout", "/dev/fd/1", "/dev/tty",
})


def is_transcript_tee(seg: list[str]) -> bool:
    words, _ = unwrap_runners(strip_redirections(seg))
    if not words or os.path.basename(words[0]) != "tee":
        return False
    return any(a in _TRANSCRIPT_TEE_PATHS for a in words[1:])


def has_downstream_names_only_selector(downstream: list[list[str]]) -> bool:
    for s in downstream:
        if is_transcript_tee(s):
            return False
        if is_names_only_selector(s):
            return True
    return False


def is_sensitive_env_file(path: str) -> str | None:
    base = os.path.basename(path)
    if base.startswith("settings") and base.endswith(".json"):
        return base
    if base == ".env" or base.startswith(".env.") or base.endswith(".env"):
        return base
    return None


_DOTTED_IDENT_CHAIN_RE = re.compile(r"^(\.[A-Za-z_][A-Za-z0-9_]*\??)+$")


def is_bulk_jq_filter(filt: str, file_kind: str = "") -> bool:
    norm = re.sub(r"\s+", "", filt)
    if is_jq_keys_filter(filt):
        return False
    if _DOTTED_IDENT_CHAIN_RE.match(norm) and not re.search(r"\.env\??$", norm):
        return False
    return True


def stdout_discarded_to_devnull(seg: list[str]) -> bool:
    for idx, w in enumerate(seg):
        if w in (">/dev/null", ">>/dev/null", "1>/dev/null", "1>>/dev/null", "&>/dev/null", "&>>/dev/null"):
            return True
        if w in (">", ">>", "1>", "1>>", "&>", "&>>") and idx + 1 < len(seg) and seg[idx + 1] == "/dev/null":
            return True
    return False


def detect_jq_bulk_file_dump(seg: list[str]) -> tuple[str, str] | None:
    if "SYG_ALLOW_ENV_PRINT=1" in seg:
        return None
    if stdout_discarded_to_devnull(seg):
        return None
    words, _ = unwrap_runners(strip_redirections(seg))
    if not words or os.path.basename(words[0]) != "jq":
        return None
    parsed = parse_jq_invocation(words[1:])
    if parsed is None:
        return None
    filt, files = parsed
    for fpath in files:
        kind = is_sensitive_env_file(fpath)
        if kind is not None and is_bulk_jq_filter(filt or "", kind):
            return (filt or "", fpath)
    return None


try:
    pipelines = command_pipelines(cmd)
except Exception:
    sys.exit(0)

for pipeline in pipelines:
    for idx, seg in enumerate(pipeline):
        dump_cmd = detect_env_dump_command(seg)
        if dump_cmd is not None:
            downstream = pipeline[idx + 1:]
            if not has_downstream_names_only_selector(downstream):
                print(
                    f"ENV-PRINT BLOCKED: bulk environment dump via '{dump_cmd}' without a "
                    "names-only selector exposes secret values in the transcript. "
                    "Use a names-only selector downstream (e.g. `env | cut -s -d= -f1` "
                    "or `env | wc -l`), read a single variable by name (`printenv VAR_NAME`), "
                    "or prefix with `SYG_ALLOW_ENV_PRINT=1` if intentional."
                )
                sys.exit(0)
        jq_hit = detect_jq_bulk_file_dump(seg)
        if jq_hit is not None:
            downstream = pipeline[idx + 1:]
            if not has_downstream_names_only_selector(downstream):
                filt, fpath = jq_hit
                shown_filt = filt if filt else "<empty>"
                print(
                    f"ENV-PRINT BLOCKED: bulk jq filter '{shown_filt}' on '{fpath}' "
                    "exposes secret/environment values in the transcript. "
                    "Query only variable names (`jq 'keys'` / `jq '.env | keys'`) or a "
                    "specific field path (e.g. `jq -r '.env.VAR_NAME'`), "
                    "or prefix with `SYG_ALLOW_ENV_PRINT=1` if intentional."
                )
                sys.exit(0)
PY
) || exit 0

if [ -n "$REASON" ]; then
  printf '%s\n' "$REASON" >&2
  exit 2
fi

exit 0
