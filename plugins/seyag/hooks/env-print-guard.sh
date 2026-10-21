#!/usr/bin/env bash
# env-print-guard.sh — PreToolUse Bash guard blocking bulk environment and
# secret file dumps into the session transcript.
#
# Blocks two leak shapes:
#   1. A pipeline segment whose command word (by basename) is `env` (with no
#      target command to execute), argumentless `printenv`, or argumentless
#      `set`, unless a downstream segment in the same pipeline reduces output
#      to variable names or counts via the names-only allowlist (without first
#      teeing to `/dev/stderr`, `/dev/fd/2`, `/dev/stdout`, `/dev/fd/1`,
#      `/dev/tty`, or their transcript aliases below):
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
#      `.env?` deny; `.env.VAR`, `.model`, `.name` allow), unless its stdout
#      ends at a file (see file sinks below).
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
# prefix or a `cut -s -d= -f1` rewrite).
#
# File sinks (allowed by design because the guard's scope is transcript output):
#   - File targets: a dump segment whose stdout ends at a file (`env > f`,
#     `jq . .env > f 2>/dev/null`, `jq . settings.json &> f`, `>/dev/null`) and
#     an intermediate `tee` file (`env | tee /tmp/f | cut -s -d= -f1`) pass when
#     the target is a plain path (optionally after a `~` prefix or a bare
#     `$VAR` / `${VAR}` prefix whose `VAR` is in `_TRUSTED_TARGET_VARS` —
#     `HOME`, `TMPDIR`, `TMP`, `TEMP`, `XDG_CACHE_HOME`, `XDG_RUNTIME_DIR`,
#     `XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `CLAUDE_JOB_DIR`,
#     `CLAUDE_PROJECT_DIR`, plus valid space-separated names from
#     `SYG_EPG_TRUSTED_VARS` — in a single-statement command (`_SINGLE_STATEMENT`)
#     with no `${…=…}` expansion and no assignment of that name (`_ASSIGNED_VARS`))
#     outside `/dev`, `/proc`, `/sys`, or `/dev/null` itself; every other
#     variable target, process substitution, expansions with operators, globs,
#     `..`, and device, proc, or sys paths fail closed. A heredoc opener anywhere
#     in the raw command also disables variable-target and relative-target trust,
#     and the raw-text assignment scan stays unanchored as defense in depth
#     against the lib split disagreeing with bash (it over-denies a word merely
#     containing `read NAME`, e.g. a jq `.thread HOME`).
#   - Redirect parser and fail-closed forms: one redirect parser scans every
#     word of the segment (`int(digits)` on at most 9 digits normalises `01`,
#     `001` to fd 1; a leading digit run longer than 9 fails the redirect match
#     and hits the unparsed `>`/`<` rule); on fd 1, `>|`, `<>`, `<&`, `>&` with
#     a `$`/backtick/`'`/`"` target, `&>`/`&>>` to a non-file target, a dangling
#     redirect with no target word (including `>|` split by the tokenizer), or
#     any word containing `>` or `<` outside the redirect grammar fails closed.
#   - Substitutions and the legacy `> /dev/null` exemption: process substitution
#     (`<(` or `>(`) anywhere in the raw command disables both file-sink and
#     downstream selector allowances, and command substitution (`$(` or
#     backtick) disables general file-sink allowance; for `stdout_sent_off_transcript`,
#     both fall back to the legacy `> /dev/null` exemption
#     (`_stdout_discarded_to_devnull`).
#   - Quoted redirects: raw commands matching `(['"\\])[0-9]*&?>` fail closed
#     in `stdout_sent_off_transcript` (returning False without the `/dev/null`
#     fallback, because quote stripping in `_tokens` cannot distinguish a
#     quoted `'>'` or `'>x'` operand from a redirect).
#   - Relative targets: plain relative targets resolve against the hook input's
#     `.cwd` via `os.path.realpath`, failing closed when `.cwd` is missing, not
#     absolute, or fails resolution, when `command_pipelines` yields more than
#     one pipeline, when the command contains `cd` or `pushd`, when any
#     pipeline segment's command word (by basename, after leading `NAME=value`
#     assignments and unwrapped runners) is `eval`, `source`, or `.`, or when the
#     raw command contains any `<<` (not `<<<`), including arithmetic shifts.
#   - Downstream stdout redirects: downstream selector allowance stops when an
#     earlier downstream segment is a transcript `tee` or carries an fd-1
#     redirect (`>`-family on fd 1, `&>`, or a dangling `>`).
#   - jq stderr: for `jq` file sinks, the allowance applies only when stdout is
#     sent off the transcript AND either the final stdout target is `/dev/null`
#     (the legacy `> /dev/null` exemption, whose accidental-error-text gap stays
#     accepted) or fd 2 is also sent to a file target or `/dev/null` in the
#     same segment (`2>/dev/null`, `2>f`, `&>f`, `>f 2>&1`, tracked
#     last-writer-wins with `2>&1` resolving to wherever fd 1 points at that
#     moment); `jq` filters containing bareword `debug`, `stderr`,
#     `input_filename`, `error`, `halt_error`, `$__loc__`, or `$__prog_args`
#     always skip the file-sink allowance (including `> /dev/null`) because
#     those builtins write values to stderr.
#   - Exception handling: allowance helpers (`is_file_target`,
#     `stdout_sent_off_transcript`, `is_transcript_tee`, `_has_fd1_redirect`,
#     `_has_eval_or_source`), `_SINGLE_STATEMENT`, `_TRUSTED_TARGET_VARS`, and
#     `_ASSIGNED_VARS` fail closed on any exception while the guard core fails
#     open.
#   - Accepted gaps: a trusted directory variable's value set outside the
#     command and a symlinked absolute file target are trusted
#     (`ln -s /dev/stderr /tmp/x; env > /tmp/x`),
#     and a later `cat f` of that file in a separate segment is unseen;
#     `env -i` / `env -i CMD` and `printenv NAME` keyed reads are allowed by
#     design.
# Double-quoted command substitutions are not split by
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
# Fail-open on missing jq/python3 or an unexpected core error (allowance helpers fail closed).

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$COMMAND" ] || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
TRUSTED_VARS="${SYG_EPG_TRUSTED_VARS:-}"

printf '%s\n' "$COMMAND" | grep -qE '(^|[^A-Za-z0-9_])(env|printenv|set|jq)([^A-Za-z0-9_]|$)' || exit 0

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

REASON=$(SYG_LIB_DIR="$LIB_DIR" SYG_EPG_CWD="$CWD" SYG_EPG_TRUSTED_VARS="$TRUSTED_VARS" python3 - 3<<<"$COMMAND" <<'PY' 2>/dev/null
import os
import re
import shlex
import sys

sys.path.insert(0, os.environ["SYG_LIB_DIR"])
from shell_quotes import (  # noqa: E402
    command_pipelines,
    strip_redirections as _lib_strip_redirections,
    unwrap_runners,
)

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
_REDIRECT_PARSE_RE = re.compile(
    r"^([0-9]{0,9})(&>>|&>|>>|>\||>&|>|<>|<&|<<<|<<|<)(.*)$"
)
_QUOTED_REDIRECT_RE = re.compile(r"""(['"\\])[0-9]*&?>""")
_BARE_AMP_REDIRECT_RE = re.compile(r"^\d*[<>]&$")
_FD_DUP_TARGET_RE = re.compile(r"^[0-9]+-?$")
_VAR_PREFIX_RE = re.compile(r"^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})")
_VALID_VAR_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_FILE_REM_RE = re.compile(r"^[A-Za-z0-9._/+@%,=-]*$")
_CHDIR_RE = re.compile(r"(^|[;&|(\s])(cd|pushd)(\s|$)")
_DEFAULT_ASSIGN_EXP_RE = re.compile(r"\$\{[^}]*=")
_CMD_ASSIGN_RE = re.compile(
    r"(^|[;&|()\s])(?:export\s+|declare\s+(?:-\S+\s+)*|local\s+(?:-\S+\s+)*|typeset\s+(?:-\S+\s+)*|readonly\s+(?:-\S+\s+)*)?([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?="
)
_READ_ASSIGN_RE = re.compile(
    r"read(?:\s+(?:-[A-Za-z]*[adinNptu]\s+\S+|-\S+))*\s+([A-Za-z_][A-Za-z0-9_ ]*)"
)
_FOR_ASSIGN_RE = re.compile(
    r"(?:for|select)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s+in\b|\s*;|\s+do\b)"
)
_PRINTF_V_RE = re.compile(r"printf\s+-v\s*([A-Za-z_][A-Za-z0-9_]*)")
_MAPFILE_RE = re.compile(
    r"(?:mapfile|readarray)(?:\s+(?:-[dnosuCc]\s+\S+|-\S+))*(?:\s+([A-Za-z_][A-Za-z0-9_ ]*))?"
)
_GETOPTS_RE = re.compile(r"getopts\s+\S+\s+([A-Za-z_][A-Za-z0-9_]*)")
# Defense-in-depth raw check: matches any `<<` (not `<<<`), including arithmetic shifts.
_RAW_HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)")
_JQ_STDERR_BUILTIN_RE = re.compile(
    r"(^|[^A-Za-z0-9_$.])(debug|stderr|input_filename|error|halt_error|halt_error\(|\$__loc__|\$__prog_args)([^A-Za-z0-9_]|$)"
)
try:
    _TRUSTED_TARGET_VARS: frozenset[str] = frozenset({
        "HOME", "TMPDIR", "TMP", "TEMP",
        "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME",
        "XDG_DATA_HOME", "XDG_CONFIG_HOME",
        "CLAUDE_JOB_DIR", "CLAUDE_PROJECT_DIR",
    } | {
        v
        for v in os.environ.get("SYG_EPG_TRUSTED_VARS", "").split()
        if _VALID_VAR_NAME_RE.match(v)
    })
except Exception:
    _TRUSTED_TARGET_VARS = frozenset()
_RAW_CWD = os.environ.get("SYG_EPG_CWD", "")
try:
    _CWD = (
        os.path.realpath(_RAW_CWD)
        if _RAW_CWD.startswith("/") and not _RAW_CWD.startswith("//")
        else ""
    )
except Exception:
    _CWD = ""
try:
    pipelines = command_pipelines(cmd)
except Exception:
    sys.exit(0)
_HAS_PROCSUB = ">(" in cmd or "<(" in cmd
_HAS_CMDSUB = "$(" in cmd or "`" in cmd
_HAS_CHDIR = bool(_CHDIR_RE.search(cmd))
try:
    _assigned: set[str] = {m.group(2) for m in _CMD_ASSIGN_RE.finditer(cmd)}
    for _m in _READ_ASSIGN_RE.finditer(cmd):
        _assigned.update(_m.group(1).split())
    for _m in _MAPFILE_RE.finditer(cmd):
        _names = (_m.group(1) or "").split()
        _assigned.update(_names if _names else ("MAPFILE",))
    for _rx in (_FOR_ASSIGN_RE, _PRINTF_V_RE, _GETOPTS_RE):
        for _m in _rx.finditer(cmd):
            _assigned.add(_m.group(1))
    _ASSIGNED_VARS: frozenset[str] | str = frozenset(_assigned)
except Exception:
    _ASSIGNED_VARS = "ALL"


def _fail_closed(default: bool):
    def _wrap(fn):
        def _inner(*args, **kwargs):
            try:
                return fn(*args, **kwargs)
            except Exception:
                return default
        return _inner
    return _wrap


def strip_redirections(args: list[str]) -> list[str]:
    return _lib_strip_redirections(
        ["&>" if _BARE_AMP_REDIRECT_RE.match(w) else w for w in args]
    )


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


@_fail_closed(True)
def _has_eval_or_source(pls: list[list[list[str]]] = pipelines) -> bool:
    for pipeline in pls:
        for seg in pipeline:
            words = strip_redirections(seg)
            while words:
                prev = words
                words = unwrap_non_env_runners(words)
                words, _ = unwrap_runners(words)
                if words == prev:
                    break
            if words and os.path.basename(words[0]) in ("eval", "source", "."):
                return True
    return False


try:
    _SINGLE_STATEMENT = (
        len(pipelines) == 1
        and not _has_eval_or_source(pipelines)
        and not _RAW_HEREDOC_RE.search(cmd)
    )
except Exception:
    _SINGLE_STATEMENT = False


def _strip_outer_quotes(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


@_fail_closed(False)
def is_file_target(t: str) -> bool:
    t = _strip_outer_quotes(t)
    if not t:
        return False
    if t == "/dev/null":
        return True
    has_var = False
    has_tilde = False
    m = _VAR_PREFIX_RE.match(t)
    if m:
        has_var = True
        rem = t[m.end():]
    elif t == "~" or t.startswith("~/"):
        has_tilde = True
        rem = t[1:]
    else:
        rem = t
    if not _FILE_REM_RE.match(rem):
        return False
    if ".." in rem.split("/"):
        return False
    if has_var:
        var_name = m.group(0)[1:].strip("{}")
        if (
            not _SINGLE_STATEMENT
            or var_name not in _TRUSTED_TARGET_VARS
            or _ASSIGNED_VARS == "ALL"
            or var_name in _ASSIGNED_VARS
            or _DEFAULT_ASSIGN_EXP_RE.search(cmd)
        ):
            return False
        if rem and not rem.startswith("/"):
            return False
        if any(p in rem for p in ("/dev/", "/proc/", "/sys/")):
            return False
    elif not has_tilde:
        if t.startswith("/"):
            if t.startswith("//"):
                return False
            norm = os.path.normpath(t)
        else:
            if not _SINGLE_STATEMENT or _HAS_CHDIR or not _CWD.startswith("/"):
                return False
            norm = os.path.normpath(os.path.join(_CWD, t))
        if (
            norm.startswith("//")
            or norm in ("/dev", "/proc", "/sys")
            or norm.startswith(("/dev/", "/proc/", "/sys/"))
        ):
            return False
    return True


def _stdout_discarded_to_devnull(seg: list[str]) -> bool:
    """The legacy `> /dev/null` exemption, kept for commands with a substitution:
    true only when stdout goes to /dev/null and every other redirect is stderr to
    /dev/null or a `2>&1` after it."""
    null_ops = (">", ">>", "1>", "1>>", "&>", "&>>")
    seen_null = False
    i = 0
    while i < len(seg):
        w = seg[i]
        if w in null_ops and i + 1 < len(seg) and seg[i + 1] == "/dev/null":
            seen_null, i = True, i + 2
            continue
        if w in tuple(op + "/dev/null" for op in null_ops):
            seen_null = True
        elif w == "2>/dev/null" or (w == "2>&1" and seen_null):
            pass
        elif w == "2>" and i + 1 < len(seg) and seg[i + 1] == "/dev/null":
            i += 1
        elif ">" in w or "<" in w:
            return False
        i += 1
    return seen_null


@_fail_closed(False)
def stdout_sent_off_transcript(
    seg: list[str], raw_cmd: str = cmd, *, require_stderr_sink: bool = False
) -> bool:
    if _QUOTED_REDIRECT_RE.search(raw_cmd):
        return False
    if _HAS_PROCSUB or _HAS_CMDSUB:
        return _stdout_discarded_to_devnull(seg)   # the legacy `> /dev/null` exemption; nothing to read back
    off_transcript = False
    fd1_target: str | None = None
    fd2_off_transcript = False
    i = 0
    n = len(seg)
    while i < n:
        w = seg[i]
        m = _REDIRECT_PARSE_RE.match(w)
        if m is None:
            if ">" in w or "<" in w:
                return False
            i += 1
            continue
        digits, op, rem = m.groups()
        if rem:
            target = rem
            i += 1
        else:
            if i + 1 >= n:
                return False
            target = seg[i + 1]
            i += 2
        if digits:
            if op in ("&>", "&>>"):
                return False
            fd = int(digits)
        elif op.startswith((">", "&")):
            fd = 1
        else:
            fd = 0
        if op in ("<", "<<", "<<<"):
            continue
        if fd == 2:
            if op in (">", ">>"):
                fd2_off_transcript = is_file_target(target)
            elif op == ">&" and target and target[0] not in ("$", "`", "'", '"'):
                t2 = _strip_outer_quotes(target)
                if t2 in ("1", "&1"):
                    fd2_off_transcript = fd1_target is not None
                elif t2 not in ("2", "&2"):
                    fd2_off_transcript = False
            else:
                fd2_off_transcript = False
            continue
        if fd != 1:
            continue
        if op in (">|", "<>", "<&"):
            return False
        if op in ("&>", "&>>"):
            if not is_file_target(target):
                return False
            off_transcript = True
            fd1_target = _strip_outer_quotes(target)
            fd2_off_transcript = True
            continue
        if op in (">", ">>"):
            off_transcript = is_file_target(target)
            fd1_target = _strip_outer_quotes(target) if off_transcript else None
            continue
        if not target or target[0] in ("$", "`", "'", '"'):
            return False
        target = _strip_outer_quotes(target)
        if not target:
            off_transcript = False
            fd1_target = None
            continue
        if target in ("-", "&-"):
            off_transcript = True
            fd1_target = None
            continue
        if target in ("1", "&1"):
            continue
        if _FD_DUP_TARGET_RE.match(target) or target.startswith("&") or digits:
            off_transcript = False
            fd1_target = None
            continue
        off_transcript = is_file_target(target)
        fd1_target = target if off_transcript else None
        fd2_off_transcript = off_transcript
    if not off_transcript:
        return False
    if require_stderr_sink:
        return fd1_target == "/dev/null" or fd2_off_transcript
    return True


def _split_env_s(val: str) -> list[str]:
    try:
        return shlex.split(val)
    except ValueError:
        return val.split()


def detect_env_dump_command(seg: list[str]) -> str | None:
    if "SYG_ALLOW_ENV_PRINT=1" in seg:
        return None
    if stdout_sent_off_transcript(seg):
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
                if tok.startswith("-") or _ASSIGN_RE.match(tok) or _DEFAULT_ASSIGN_EXP_RE.search(tok):
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


@_fail_closed(True)
def is_transcript_tee(seg: list[str]) -> bool:
    words, _ = unwrap_runners(strip_redirections(seg))
    if not words or os.path.basename(words[0]) != "tee":
        return False
    args: list[str] = []
    opts = True
    for a in words[1:]:
        if opts and a == "--":
            opts = False
            continue
        if opts and a.startswith("-") and len(a) > 1:
            continue
        args.append(a)
    return any(not is_file_target(a) for a in args)


@_fail_closed(True)
def _has_fd1_redirect(seg: list[str]) -> bool:
    i = 0
    n = len(seg)
    while i < n:
        w = seg[i]
        m = _REDIRECT_PARSE_RE.match(w)
        if m is None:
            if ">" in w or "<" in w:
                return True
            i += 1
            continue
        digits, op, rem = m.groups()
        if rem:
            i += 1
        else:
            if i + 1 >= n:
                return True
            i += 2
        if digits:
            fd = int(digits)
        elif op.startswith((">", "&")):
            fd = 1
        else:
            fd = 0
        if (fd == 1 and op not in ("<", "<<", "<<<")) or op in ("&>", "&>>"):
            return True
    return False


def has_downstream_names_only_selector(downstream: list[list[str]]) -> bool:
    if _HAS_PROCSUB:
        return False
    for s in downstream:
        if is_transcript_tee(s):
            return False
        if is_names_only_selector(s):
            return True
        if _has_fd1_redirect(s):
            return False
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


def detect_jq_bulk_file_dump(seg: list[str]) -> tuple[str, str] | None:
    if "SYG_ALLOW_ENV_PRINT=1" in seg:
        return None
    words, _ = unwrap_runners(strip_redirections(seg))
    if not words or os.path.basename(words[0]) != "jq":
        return None
    parsed = parse_jq_invocation(words[1:])
    if parsed is None:
        return None
    filt, files = parsed
    if not _JQ_STDERR_BUILTIN_RE.search(filt or "") and stdout_sent_off_transcript(
        seg, require_stderr_sink=True
    ):
        return None
    for fpath in files:
        kind = is_sensitive_env_file(fpath)
        if kind is not None and is_bulk_jq_filter(filt or "", kind):
            return (filt or "", fpath)
    return None


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
