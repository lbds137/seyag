"""Optional config files for seyag's Python bins: the Python twin of
hooks/lib/config-env.sh. Same files, key rule, refusals and warning text, so the
two loaders produce the same environment and the same stderr for the same
input (tests/config-env.probe.sh pins that). The TOML subset is hand-parsed on
purpose: tomllib accepts a different subset and words its errors differently.

Adopt in a bin, before its first knob read:

    sys.path.insert(0, <plugin_root>/lib)
    import config_env
    config_env.syg_config_env(<plugin_root>)

syg_config_env never raises and never blocks: a bad config file warns on stderr
and its bad lines are skipped.

Known divergence limits from the shell loader: whitespace trimming is ASCII-only
(the shell's [[:space:]] follows the locale), and the 40-character name bound
counts code points here but bytes in the shell under a single-byte locale.
"""

import os
import re

_WS = " \t\n\v\f\r"

# Mirrors _SYG_CFG_HARNESS in hooks/lib/config-env.sh (pinned equal by the probe).
_HARNESS = frozenset(
    [
        "ANTHROPIC_ADMIN_API_KEY",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_PLUGIN_REGISTRY",
        "CLAUDE_PROJECTS_DIR",
        "CLAUDE_SESSION_ARCHIVE",
        "CLAUDE_VERSIONS_DIR",
        "SEYAG_KEYS_BIN",
        "SESSION_LEDGER",
    ]
)

# Mirrors _SYG_CFG_PROJECT_EXEC in hooks/lib/config-env.sh (pinned equal by the probe).
_PROJECT_EXEC = frozenset(["SYG_STATUSLINE_ZAI_USAGE"])

# Mirrors _SYG_CFG_PROJECT_SECURE in hooks/lib/config-env.sh (pinned equal by the probe).
_PROJECT_SECURE = frozenset(
    ["SYG_KEYS_NAME", "SYG_KEYS_WITH_KEY", "ZAI_AUTH_TOKEN", "SYG_CREDIT_WHEN", "SYG_CREDIT_ROUTE"]
)

_VALID_PATH = re.compile(r"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*")
_INT_TOKEN = re.compile(r"-?[0-9]+")
_FLOAT_TOKEN = re.compile(r"-?[0-9]+\.[0-9]+")
_NUMBER_FORM = re.compile(r"[+-]?[0-9][0-9a-zA-Z_.+-]*")
_QUOTE_OR_BACKSLASH = re.compile(r'["\\]')


def _warn(text):
    try:
        os.write(2, (text + "\n").encode("utf-8", "surrogateescape"))
    except OSError:
        pass


def _disp(text):
    """Name text for a warning: first 40 characters (+ "..." when cut), controls stripped."""
    shown = text[:40] + "..." if len(text) > 40 else text
    return "".join(c for c in shown if not (ord(c) < 32 or 127 <= ord(c) <= 159))


def _valid_path(text):
    return _VALID_PATH.fullmatch(text) is not None


class _State:
    def __init__(self):
        self.settable = set()
        self.envonly = set()
        self.path = set()
        self.map = {}


def _trailing_ok(rest, key, file, n):
    rest = rest.lstrip(_WS)
    if rest == "" or rest.startswith("#"):
        return True
    _warn(f"seyag config: {file}: line {n}: {key}: unsupported value: trailing content after the value")
    return False


def _parse_value(val, key, file, n):
    """Parse the text after '=' into a value. Returns (True, value) or (False, None) after warning."""
    key = _disp(key)
    val = val.lstrip(_WS)
    if val == "":
        _warn(f"seyag config: {file}: line {n}: {key}: malformed value: missing value")
        return False, None
    if val.startswith("{"):
        _warn(f"seyag config: {file}: line {n}: {key}: unsupported value: inline tables are not supported")
        return False, None
    if val.startswith("["):
        _warn(f"seyag config: {file}: line {n}: {key}: unsupported value: arrays are not supported")
        return False, None
    if val.startswith('"'):
        rest = val[1:]
        out = []
        while rest:
            m = _QUOTE_OR_BACKSLASH.search(rest)
            if m is None:
                out.append(rest)
                rest = ""
                break
            if m.start():
                out.append(rest[: m.start()])
                rest = rest[m.start() :]
            if rest[0] == '"':
                if not _trailing_ok(rest[1:], key, file, n):
                    return False, None
                return True, "".join(out)
            escaped = rest[1:2]
            if escaped == "\\":
                out.append("\\")
            elif escaped == '"':
                out.append('"')
            elif escaped == "t":
                out.append("\t")
            elif escaped == "n":
                out.append("\n")
            else:
                _warn(f"seyag config: {file}: line {n}: {key}: malformed value: unsupported escape")
                return False, None
            rest = rest[2:]
        _warn(f"seyag config: {file}: line {n}: {key}: malformed value: unterminated string")
        return False, None
    if val.startswith("'"):
        rest = val[1:]
        if "'" not in rest:
            _warn(f"seyag config: {file}: line {n}: {key}: malformed value: unterminated string")
            return False, None
        cut = rest.index("'")
        if not _trailing_ok(rest[cut + 1 :], key, file, n):
            return False, None
        return True, rest[:cut]
    tok = val
    for i, c in enumerate(val):
        if c in _WS or c == "#":
            tok = val[:i]
            if not _trailing_ok(val[i:], key, file, n):
                return False, None
            break
    if tok == "":
        _warn(f"seyag config: {file}: line {n}: {key}: malformed value: missing value")
        return False, None
    if tok == "true":
        return True, "1"
    if tok == "false":
        return True, "0"
    if _INT_TOKEN.fullmatch(tok) or _FLOAT_TOKEN.fullmatch(tok):
        return True, tok
    if _NUMBER_FORM.fullmatch(tok):
        _warn(
            f"seyag config: {file}: line {n}: {key}: unsupported value: "
            "number form not supported (use plain digits or a quoted string)"
        )
        return False, None
    _warn(f"seyag config: {file}: line {n}: {key}: malformed value: strings and paths must be quoted")
    return False, None


def _parse_file(path, scope, foreign, st):
    """One config file into st.map; warns per offending line and skips it."""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", "surrogateescape")
    except OSError:
        _warn(f"seyag config: cannot read {path}: skipped")
        return
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    seen = set()
    secpath = ""
    skip_delim = ""
    n = 0
    for raw in lines:
        n += 1
        if "\x00" in raw:
            raw = raw[: raw.index("\x00")]
        line = raw[:-1] if raw.endswith("\r") else raw
        if skip_delim:
            if skip_delim in line:
                skip_delim = ""
            continue
        line = line.strip(_WS)
        if line == "" or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            key = line[1:-1]
            if not _valid_path(key):
                _warn(f"seyag config: {path}: line {n}: malformed section: invalid name")
                secpath = ""
                continue
            if ("s:" + key) in seen:
                if foreign:
                    _warn(
                        f"seyag config: {path}: line {n}: duplicate section: keys merge, first value per key wins"
                    )
                else:
                    _warn(
                        f"seyag config: {path}: line {n}: [{_disp(key)}]: "
                        "duplicate section: keys merge, first value per key wins"
                    )
            seen.add("s:" + key)
            secpath = key
            continue
        if "=" not in line:
            _warn(f"seyag config: {path}: line {n}: malformed line: expected 'key = value' or a [section] header")
            continue
        key, val = line.split("=", 1)
        key = key.rstrip(_WS)
        vstrip = val.lstrip(_WS)
        if vstrip.startswith('"""') or vstrip.startswith("'''"):
            skip_delim = vstrip[:3]
            if skip_delim in vstrip[3:]:
                skip_delim = ""
            if foreign:
                _warn(f"seyag config: {path}: line {n}: unsupported value: multiline strings are not supported")
            else:
                _warn(
                    f"seyag config: {path}: line {n}: {_disp(key)}: "
                    "unsupported value: multiline strings are not supported"
                )
            continue
        if key == "" or not _valid_path(key):
            _warn(f"seyag config: {path}: line {n}: malformed key: invalid name")
            continue
        dotted = secpath + ("." if secpath else "") + key
        name = dotted.replace(".", "_").upper()
        if name in _HARNESS:
            if foreign:
                _warn(
                    f"seyag config: {path}: line {n}: unknown key (not a settable seyag knob; see docs/config.md)"
                )
            else:
                _warn(
                    f"seyag config: {path}: line {n}: unknown key '{_disp(dotted)}' "
                    "(not a settable seyag knob; see docs/config.md)"
                )
            continue
        if name in st.envonly:
            if foreign:
                _warn(f"seyag config: {path}: line {n}: a knob is environment only (not settable from a config file)")
            else:
                _warn(
                    f"seyag config: {path}: line {n}: '{_disp(name)}' is environment only "
                    "(not settable from a config file)"
                )
            continue
        if name not in st.settable:
            if foreign:
                _warn(
                    f"seyag config: {path}: line {n}: unknown key (not a settable seyag knob; see docs/config.md)"
                )
            else:
                _warn(
                    f"seyag config: {path}: line {n}: unknown key '{_disp(dotted)}' "
                    "(not a settable seyag knob; see docs/config.md)"
                )
            continue
        is_exec = name.endswith("_CMD") or name in _PROJECT_EXEC
        if scope == "project" and is_exec:
            if foreign:
                _warn(
                    f"seyag config: {path}: line {n}: a knob cannot be set from project scope "
                    "(command-execution knob)"
                )
            else:
                _warn(
                    f"seyag config: {path}: line {n}: '{_disp(name)}' cannot be set from project scope "
                    "(command-execution knob)"
                )
            continue
        if scope == "project" and name in _PROJECT_SECURE:
            if foreign:
                _warn(
                    f"seyag config: {path}: line {n}: a knob cannot be set from project scope "
                    "(security-material knob)"
                )
            else:
                _warn(
                    f"seyag config: {path}: line {n}: '{_disp(name)}' cannot be set from project scope "
                    "(security-material knob)"
                )
            continue
        if scope == "project" and name in st.path:
            if foreign:
                _warn(f"seyag config: {path}: line {n}: a knob cannot be set from project scope (path knob)")
            else:
                _warn(
                    f"seyag config: {path}: line {n}: '{_disp(name)}' cannot be set from project scope (path knob)"
                )
            continue
        if ("n:" + name) in seen:
            if foreign:
                _warn(f"seyag config: {path}: line {n}: duplicate key: first value wins")
            else:
                _warn(f"seyag config: {path}: line {n}: {_disp(key)}: duplicate key: first value wins")
            continue
        ok, value = _parse_value(val, "key" if foreign else key, path, n)
        if not ok:
            continue
        seen.add("n:" + name)
        st.map[name] = value
    if skip_delim:
        _warn(f"seyag config: {path}: line {n}: unterminated multiline string: rest of file skipped")


def _pwd():
    """Bash's $PWD: an inherited PWD counts only while it names the working directory."""
    inherited = os.environ.get("PWD", "")
    try:
        if inherited.startswith("/") and os.path.samefile(inherited, "."):
            return inherited
    except OSError:
        pass
    return os.getcwd()


def _load(plugin_dir, st):
    env = os.environ
    xdg = env.get("XDG_CONFIG_HOME", "")
    home = env.get("HOME", "")
    if xdg:
        ufile = xdg + "/seyag/config.toml"
    elif home:
        ufile = home + "/.config/seyag/config.toml"
    else:
        ufile = ""
    pdir = env.get("CLAUDE_PROJECT_DIR", "") or _pwd()
    pfile = pdir + "/.claude/seyag.toml"
    if not os.path.isfile(ufile) and not os.path.isfile(pfile):
        return

    knobs = plugin_dir + "/config/knobs.tsv"
    try:
        with open(knobs, "rb") as fh:
            text = fh.read().decode("utf-8", "surrogateescape")
    except OSError:
        _warn(f"seyag config: cannot read {knobs}: skipped")
        return
    rows = text.split("\n")
    if rows and rows[-1] == "":
        rows.pop()
    for n, row in enumerate(rows, 1):
        if "\x00" in row:
            row = row[: row.index("\x00")]
        if row.endswith("\r"):
            row = row[:-1]
        stripped = row.lstrip(_WS)
        if stripped == "" or stripped.startswith("#"):
            continue
        if "\t" not in row:
            _warn(f"seyag config: {knobs}: line {n}: malformed row: skipped")
            continue
        name, rest = row.split("\t", 1)
        fields = rest.split("\t")
        if fields[0] != "user":
            continue
        if name == "" or name.startswith("#"):
            continue
        flags = ""
        if len(fields) >= 5:
            flags = fields[4]
        elif len(fields) == 4:
            _warn(
                f"seyag config: {knobs}: line {n}: {name}: "
                "no flags column: path/envonly refusals disabled for this row"
            )
        padded = f" {flags} "
        if " path " in padded:
            st.path.add(name)
        if " envonly " in padded:
            st.envonly.add(name)
        else:
            st.settable.add(name)

    foreign = False
    if os.path.islink(pfile):
        foreign = True
    elif os.path.isfile(pfile):
        try:
            rpfile = os.path.realpath(pfile, strict=True)
            rpdir = os.path.realpath(pdir, strict=True)
            foreign = not rpfile.startswith(rpdir + "/")
        except OSError:
            foreign = True

    if os.path.isfile(ufile):
        _parse_file(ufile, "user", False, st)
    if os.path.isfile(pfile):
        _parse_file(pfile, "project", foreign, st)


def syg_config_env(plugin_dir):
    """Export every mapped knob whose env name is unset. Fail-open: never raises."""
    try:
        if os.environ.get("SYG_CONFIG", "") == "0":
            return
        st = _State()
        _load(plugin_dir, st)
        for name, value in st.map.items():
            if name not in os.environ:
                try:
                    os.environ[name] = value
                except Exception:
                    continue
    except Exception:
        return
