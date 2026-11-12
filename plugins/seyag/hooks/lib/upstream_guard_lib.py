"""Target and owner resolution for upstream-submission-guard.sh.

The hook's python heredoc and its `--check` preflight both import this
module, so there is exactly one definition of each piece: `parse_repo_value`
(a -R/--repo/GH_REPO value in every form gh 2.101.0 accepts),
`parse_github_remote_url` (a remote URL to (owner, repo) for a GitHub
candidate host; userinfo, which can carry a token, is discarded and never
returned or logged), `load_own_owners` (the hosts.yml `user:` under
github.com, read with a line scan, unioned with SYG_OWN_OWNERS), the git
reading helpers (`git_argv`, `git_run`, `git_config`, `git_remote_get_url`)
and `git_remotes_targets` (the directory's GitHub candidates with
`remote.<name>.gh-resolved` priority, memoized per process — a fresh python
process per invocation, so the memo never outlives a run). `git_run` keeps
its load-bearing failure posture: a 5 s timeout, errors="replace" decoding
and exception -> None, so a non-UTF-8 byte in a remote URL or a wedged git
can never leak a traceback into a caller's output. Pinned end-to-end by
hooks/upstream-submission-guard.probe.sh (hook cases) and its --check cases.
"""

import os
import re
import subprocess


def parse_repo_value(value):
    """(owner, repo) from a -R/--repo/GH_REPO value in any form gh 2.101.0
    accepts — `OWNER/REPO`, `HOST/OWNER/REPO`, a `scheme://[user@]host/o/r`
    URL (https, ssh, …; `.git` optional) or scp `[user@]host:o/r(.git)` —
    else None."""
    if "://" in value:
        m = re.match(
            r"^[A-Za-z][\w+.-]*://(?:[^@/]+@)?[^/:]+(?::\d+)?/([^/]+)/([^/]+?)(?:\.git)?/?$",
            value,
        )
        return (m.group(1), m.group(2)) if m else None
    m = re.match(r"^(?:[^@/:]+@)?[^/:]+:([^/]+)/([^/]+?)(?:\.git)?/?$", value)
    if m:
        return (m.group(1), m.group(2))
    parts = value.split("/")
    if len(parts) in (2, 3) and all(parts):
        return (parts[-2], parts[-1])
    return None


def parse_github_remote_url(url):
    """Parse a git remote URL into (owner, repo) if its host is a GitHub
    candidate (contains "github", case-insensitive, after stripping a
    leading www./ssh.), else None. Userinfo (a token) is discarded, never
    returned or logged."""
    try:
        if "://" in url:
            m = re.match(r"^\w+://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$", url)
            if not m:
                return None
            host, path = m.group(1), m.group(2)
        else:
            m = re.match(r"^(?:[^@/]+@)?([^:/]+):(.+)$", url)
            if not m:
                return None
            host, path = m.group(1), m.group(2)
        host = host.lower()
        host = re.sub(r"^(www\.|ssh\.)", "", host)
        if "github" not in host:
            return None
        path = path.rstrip("/")
        if path.endswith(".git"):
            path = path[: -len(".git")]
        parts = path.split("/")
        if len(parts) != 2 or not parts[0] or not parts[1]:
            return None
        return (parts[0], parts[1])
    except Exception:
        return None


def git_argv(dir_, git_dir, work_tree):
    """`git -C DIR [--git-dir=…] [--work-tree=…]`: a GIT_DIR/GIT_WORK_TREE
    the gh command would inherit points the remote reading at that repo; a
    relative value resolves against DIR, as git's own `-C` then `--git-dir`
    order does."""
    argv = ["git", "-C", dir_]
    if git_dir:
        argv.append(f"--git-dir={git_dir}")
    if work_tree:
        argv.append(f"--work-tree={work_tree}")
    return argv


def git_run(base, *args):
    try:
        r = subprocess.run(
            base + list(args),
            capture_output=True, text=True, errors="replace", timeout=5,
        )
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def git_config(base, key):
    out = git_run(base, "config", "--get", key)
    return out.strip() if out is not None else None


def git_remote_get_url(base, name):
    out = git_run(base, "remote", "get-url", name)
    return out.strip() if out is not None else None


# The remote reading per (directory, GIT_DIR, GIT_WORK_TREE), kept for the
# hook process: a walk with many worlds in one directory asks git once. A
# failed `git remote` is cached as [] for the run too (upstream reads [] as no
# non-own target, so it passes; not fail-closed like publish-gate).
_REMOTES_MEMO = {}


def git_remotes_targets(effective_dir, git_dir=None, work_tree=None):
    key = (effective_dir, git_dir, work_tree)
    if key not in _REMOTES_MEMO:
        _REMOTES_MEMO[key] = _read_git_remotes_targets(effective_dir, git_dir, work_tree)
    return list(_REMOTES_MEMO[key])


def _read_git_remotes_targets(effective_dir, git_dir=None, work_tree=None):
    base = git_argv(effective_dir, git_dir, work_tree)
    out = git_run(base, "remote")
    if out is None:
        return []
    names = [line.strip() for line in out.splitlines() if line.strip()]
    candidates = []
    resolved = []
    for name in names:
        url = git_remote_get_url(base, name)
        parsed = parse_github_remote_url(url) if url else None
        if parsed:
            candidates.append(parsed)
        gh_resolved = git_config(base, f"remote.{name}.gh-resolved")
        if gh_resolved == "base":
            if parsed:
                resolved.append(parsed)
        elif gh_resolved:
            m = re.match(r"^([^/\s]+)/([^/\s]+)$", gh_resolved)
            if m:
                resolved.append((m.group(1), m.group(2)))
    if resolved:
        seen = []
        for t in resolved:
            if t not in seen:
                seen.append(t)
        return seen
    return candidates


def load_own_owners():
    owners = set()
    gh_config_dir = os.environ.get("GH_CONFIG_DIR") or os.path.join(
        os.environ.get("HOME", ""), ".config", "gh"
    )
    hosts_path = os.path.join(gh_config_dir, "hosts.yml")
    try:
        with open(hosts_path, "r", encoding="utf-8", errors="replace") as fh:
            in_github_host = False
            for line in fh:
                line = line.rstrip("\n")
                if re.match(r"^github\.com:\s*$", line):
                    in_github_host = True
                    continue
                if not in_github_host:
                    continue
                if re.match(r"^\S", line):
                    break  # dedented back out of the github.com: block
                m = re.match(r"^\s+user:\s*(\S+)", line)
                if m:
                    owners.add(m.group(1).strip().lower())
                    break
    except OSError:
        pass
    raw = os.environ.get("SYG_OWN_OWNERS", "").strip()
    if raw:
        owners |= {p.lower() for p in re.split(r"[\s,]+", raw) if p}
    return owners
