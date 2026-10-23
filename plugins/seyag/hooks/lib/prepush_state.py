"""Is the seyag git pre-push hook (plugins/seyag/git-hooks/pre-push) the one
git runs for a repository, and is it in force there? One resolution, shared
by the outbound guards (which block the ways past the hook only where it is
in force) and bin/seyag-git-hooks status.

`hooks_state(d)` returns a dict:
  - `repo`: `d` is inside a git repository (`git rev-parse --git-dir`).
  - `value`, `scope`: the effective `core.hooksPath` for `d` and the config
    scope that set it (`git config --show-scope --type=path --get`, so a
    repo-local value overrides the global one, as git itself resolves it);
    both "" when unset.
  - `resolved`: `value` made absolute the way git reads it (a relative path
    is relative to the directory hooks run in: the work tree's top level, or
    the git dir of a bare repo); "" when unset.
  - `active`: `seyag_prepush(resolved)`: `resolved` is this plugin's
    git-hooks directory (`HOOKS_DIR`), or a dispatcher dir (MARKER, written
    by bin/seyag-git-hooks install) whose `plugin-root` holds an executable
    git-hooks/pre-push.
  - `public`: `public_flag(d)`: `git config --type=bool --get
    seyag.publicRepo` prints `true`, or the value is set but is not a
    boolean (fail closed, as git-hooks/pre-push reads it).
  - `bad_aliases`: `alias.<name> <value>` lines of `git config --get-regexp
    '^alias\\.'` whose value holds `--no-v`, `hooksPath`, `HOME=` (so
    `XDG_CONFIG_HOME=` too) or `GIT_CONFIG` (any case), or an `env` word
    followed by any option word (`env -i`, `env -`, `env -u HOME`,
    `env --unset HOME`, …; BAD_ALIAS_ENV): an alias that can push past the
    hook.
  - `enforcing`: `active` and `public` and no `bad_aliases`; the pre-push
    checks only a public repo, so this is when it really guards a push.

Any git failure reads as "not set", so a doubt never reads as enforcing.

`text_owner_judge(event_cwd, terms_file)`: enforcing AND the global
`seyag.privateTermsFile` names that terms file, so the pre-push checks
pushes of that repo with the same terms wherever they come from — the
condition under which private-term-guard hands its commit-text item over.

No top-level side effects: importing this module runs nothing.
"""

import os
import re
import subprocess

HOOKS_DIR = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "git-hooks"))
MARKER = ".seyag-git-hooks"  # in a dispatcher dir bin/seyag-git-hooks wrote
# Alias values that can push past the hook. BAD_ALIAS_PARTS are lowercased
# substrings: `--no-v` (`--no-verify` and its prefixes), `hookspath`,
# `home=` (also `xdg_config_home=`) and `git_config` (GIT_CONFIG_*).
# BAD_ALIAS_ENV covers the env shapes lib/outbound.py's `_push_env_tokens`
# blocks on a push (`env -i`, `env -`, `--ignore-environment` and any
# abbreviation down to `--i`: unambiguous on coreutils before 9.1, while from
# 9.1 the forms shorter than `--ignore-e` are ambiguous and rejected, matched
# there anyway, fail closed; `env -u HOME`, `--unset[=]HOME`
# and its `--u…` abbreviations): `env` (also as the end of a
# longer word, such as `/usr/bin/env`; quotes or a backslash after it
# allowed) followed, after any whitespace, by any option word (`-…`). Any
# env option counts, not only those (fail closed).
BAD_ALIAS_PARTS = ("--no-v", "hookspath", "home=", "git_config")
BAD_ALIAS_ENV = re.compile(r"env[\\'\"]*\s+[\\'\"]*-")


def stable_dir():
    """The dispatcher dir install writes: `$XDG_DATA_HOME` (when absolute,
    else `~/.local/share`) + `/seyag/git-hooks`. bin/seyag-git-hooks computes
    the same path."""
    base = os.environ.get("XDG_DATA_HOME", "")
    if not os.path.isabs(base):
        base = os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "seyag", "git-hooks")


def dispatcher_root(d):
    """The plugin root a dispatcher dir `d` points at (its `plugin-root`
    file), or None when `d` is not a dispatcher dir (no MARKER)."""
    if not os.path.isfile(os.path.join(d, MARKER)):
        return None
    try:
        with open(os.path.join(d, "plugin-root"), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def seyag_prepush(d):
    """True when hooks dir `d` runs a seyag pre-push: `d` is this plugin's
    git-hooks dir, or a dispatcher dir whose plugin root has an executable
    git-hooks/pre-push."""
    if os.path.realpath(d) == HOOKS_DIR:
        return os.access(os.path.join(HOOKS_DIR, "pre-push"), os.X_OK)
    root = dispatcher_root(d)
    return bool(root) and os.access(os.path.join(root, "git-hooks", "pre-push"), os.X_OK)


def _git(d, *args):
    try:
        r = subprocess.run(["git", "-C", d, *args], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace").rstrip("\n")


def public_flag(d):
    """True when `d`'s repo is marked public: `seyag.publicRepo` parses as a
    true boolean, or it is set but is not a boolean (fail closed, as
    git-hooks/pre-push and the dispatcher's pre-push stub judge it). Unset,
    or a valid false: False."""
    if _git(d, "config", "--get", "seyag.publicRepo") is None:
        return False
    parsed = _git(d, "config", "--type=bool", "--get", "seyag.publicRepo")
    return parsed is None or parsed == "true"


def bad_aliases(d):
    out = _git(d, "config", "--get-regexp", r"^alias\.") or ""
    bad = []
    for line in out.splitlines():
        value = line.partition(" ")[2].lower()
        if any(part in value for part in BAD_ALIAS_PARTS) or BAD_ALIAS_ENV.search(value):
            bad.append(line)
    return bad


def hooks_state(d):
    state = {"repo": False, "value": "", "scope": "", "resolved": "", "active": False,
             "public": False, "bad_aliases": [], "enforcing": False}
    if _git(d, "rev-parse", "--git-dir") is None:
        return state
    state["repo"] = True
    state["public"] = public_flag(d)
    state["bad_aliases"] = bad_aliases(d)
    out = _git(d, "config", "--show-scope", "--type=path", "--get", "core.hooksPath")
    if not out:
        return state
    scope, _, value = out.partition("\t")
    state["scope"], state["value"] = scope, value
    if not value:
        return state
    if os.path.isabs(value):
        resolved = value
    else:
        base = _git(d, "rev-parse", "--show-toplevel") or _git(d, "rev-parse", "--absolute-git-dir")
        if not base:
            return state
        resolved = os.path.join(base, value)
    state["resolved"] = os.path.normpath(resolved)
    state["active"] = seyag_prepush(resolved)
    state["enforcing"] = state["active"] and state["public"] and not state["bad_aliases"]
    return state


def _inside(d):
    return (_git(d, "rev-parse", "--is-inside-work-tree") or "").strip() == "true"


def public_judge(event_cwd):
    """A cached `is_public(d)`: `public_flag(d)`; a `d` outside any git work
    tree is judged by `event_cwd`'s repo (fail closed on a directory-tracking
    miss). Used by private-term-guard.sh."""
    verdicts = {}

    def is_public(d):
        if d not in verdicts:
            verdicts[d] = public_flag(d) if _inside(d) else public_flag(event_cwd)
        return verdicts[d]

    return is_public


def enforcing_judge(event_cwd):
    """A cached `in_force(d)`: `enforcing(d)`; a `d` outside any git work tree
    is judged by `event_cwd`'s repo, as `public_judge` does. Both outbound
    guards pass it to `prepush_bypasses`."""
    verdicts = {}

    def in_force(d):
        if d not in verdicts:
            verdicts[d] = enforcing(d) if _inside(d) else enforcing(event_cwd)
        return verdicts[d]

    return in_force


_global_terms = []


def _global_terms_is(terms_file):
    """True when the GLOBAL `seyag.privateTermsFile` — besides its env, the
    pre-push's only terms source, and the only one that covers a push from a
    terminal — names `terms_file` (realpaths equal). Cached per process."""
    if not _global_terms:
        want = os.path.realpath(terms_file) if terms_file else ""
        got = _git("/", "config", "--global", "--type=path", "--get",
                   "seyag.privateTermsFile") or ""
        _global_terms.append(bool(want and got)
                             and os.path.realpath(got) == want)
    return _global_terms[0]


def text_owner_judge(event_cwd, terms_file):
    """A cached `owns(d)` for private-term-guard's commit-text hand-over:
    the pre-push ENFORCES for `d` (`enforcing_judge`) and resolves the SAME
    terms the guard read (`_global_terms_is`), so every push of `d`'s commits
    — from a terminal too — is checked with these terms. Only then does the
    guard let the pre-push own the text of a `git commit|tag|notes` there."""
    verdicts = {}
    in_force = enforcing_judge(event_cwd)

    def owns(d):
        if d not in verdicts:
            verdicts[d] = in_force(d) and _global_terms_is(terms_file)
        return verdicts[d]

    return owns


_global = []


def global_install_present():
    """True when the GLOBAL core.hooksPath runs a seyag pre-push: it resolves
    to the stable dispatcher dir (or straight to this plugin's git-hooks dir)
    and `seyag_prepush` holds there. Cached per process. The guards judge
    `git config --global|--system` writes by it, whatever the cwd."""
    if not _global:
        value = _git("/", "config", "--global", "--type=path", "--get", "core.hooksPath") or ""
        _global.append(bool(value) and os.path.isabs(value)
                       and os.path.realpath(value) in (os.path.realpath(stable_dir()), HOOKS_DIR)
                       and seyag_prepush(value))
    return _global[0]


_cache = {}


def enforcing(d):
    """`hooks_state(d)["enforcing"]`, cached per directory."""
    if d not in _cache:
        _cache[d] = hooks_state(d)["enforcing"]
    return _cache[d]
