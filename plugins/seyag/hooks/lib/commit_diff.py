"""The lines a commit will carry, and the added lines of commits about to be pushed.

temporal-marker-guard.sh judges the lines of the commit being made;
lib/outbound.py hands both sets to session-url-gate.sh and
private-term-guard.sh as outbound text.

LINES THE COMMIT WILL CARRY (`commit_lines`): added lines of the change the
commit will carry, approximated as the union of
  - `git diff --cached` (staged);
  - for each `git add` (or its alias `git stage`) earlier in the same command
    (`parse_add`): `git diff -- <paths>` plus the full content of the
    untracked files among <paths>; `-A`/`--all` with no path widens to every
    tracked change and every untracked file, `-u`/`--update` to every tracked
    change; an add form not understood (`-p`, `-i`, `-e`,
    `--pathspec-from-file`) falls back to a full `git diff`;
  - `git commit -a`/`--all`: `git diff`; `git commit <pathspec>`/`-o`/`--only`:
    `git diff HEAD -- <pathspec>` (`parse_commit`).
Over-approximating (an unstaged line the commit won't carry) is accepted;
under-approximating the staged set is not. A `git add` run in another
repository than the commit's is ignored. Untracked files over 1 MB are not
read.

PUSHED LINES (`pushed_added_lines`): the added lines of every commit in
`git log -p <sources> --not --remotes`, so commits already on any remote are
not read; at most 4 MiB of log output is read.

Every diff call pins diff.relative, diff.srcPrefix, diff.dstPrefix (and the
related prefix and quoting options) so a repo's own config cannot move the
headers the parser reads. Headers are told apart from content by hunk state.

No top-level side effects: importing this module runs nothing.
"""

import os
import subprocess

COMMIT_VAL_SHORT = set("mFcCt")
COMMIT_VAL_LONG = {
    "--message", "--file", "--reuse-message", "--reedit-message", "--fixup",
    "--squash", "--author", "--date", "--template", "--cleanup",
    "--pathspec-from-file", "--trailer",
}
GIT_VAL_GLOBAL = {"-c", "--git-dir", "--work-tree", "--namespace",
                  "--super-prefix", "--config-env", "--attr-source"}
MAX_UNTRACKED_BYTES = 1_000_000
MAX_LOG_BYTES = 4 * 1024 * 1024

DIFF_OPTS = ("--no-color", "--no-ext-diff", "--no-textconv", "-U0")


def join_dir(base, p):
    return os.path.normpath(os.path.join(base, os.path.expanduser(p)))


def parse_git(args, base):
    """(dir, subcommand, rest) after git's global options."""
    d, i = base, 0
    while i < len(args):
        a = args[i]
        if a == "-C" and i + 1 < len(args):
            d = join_dir(d, args[i + 1])
            i += 2
        elif a in GIT_VAL_GLOBAL:
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            return d, a, args[i + 1:]
    return d, None, []


def parse_add(rest):
    paths, all_tracked, untracked, weird, dd = [], False, False, False, False
    for a in rest:
        if dd:
            paths.append(a)
        elif a == "--":
            dd = True
        elif a in ("-A", "--all"):
            all_tracked = untracked = True
        elif a in ("-u", "--update"):
            all_tracked = True
        elif a in ("--patch", "--interactive", "--edit") or a.startswith("--pathspec-from-file"):
            weird = True
        elif a.startswith("--"):
            pass
        elif a.startswith("-") and len(a) > 1:
            for ch in a[1:]:
                if ch == "A":
                    all_tracked = untracked = True
                elif ch == "u":
                    all_tracked = True
                elif ch in "pie":
                    weird = True
        else:
            paths.append(a)
    return {"paths": paths, "all": all_tracked, "untracked": untracked, "weird": weird}


def parse_commit(rest):
    paths, all_, only, dd, i = [], False, False, False, 0
    while i < len(rest):
        a = rest[i]
        if dd:
            paths.append(a)
        elif a == "--":
            dd = True
        elif a == "--all":
            all_ = True
        elif a == "--only":
            only = True
        elif a.startswith("--"):
            if a in COMMIT_VAL_LONG:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                if ch == "a":
                    all_ = True
                elif ch == "o":
                    only = True
                elif ch in COMMIT_VAL_SHORT:
                    if k == len(a) - 2:
                        i += 1
                    break
                elif ch in "uS":
                    break
        else:
            paths.append(a)
        i += 1
    return {"paths": paths, "all": all_, "only": only}


def _git_argv(d, *args):
    return ["git", "-C", d, "-c", "diff.mnemonicprefix=false",
            "-c", "diff.noprefix=false", "-c", "core.quotepath=false",
            "-c", "diff.relative=false", "-c", "diff.srcPrefix=a/",
            "-c", "diff.dstPrefix=b/", *args]


def git(d, *args):
    try:
        r = subprocess.run(_git_argv(d, *args), capture_output=True, timeout=30)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", errors="replace")


_top = {}


def toplevel(d):
    if d not in _top:
        out = git(d, "rev-parse", "--show-toplevel")
        _top[d] = out.strip() if out and out.strip() else None
    return _top[d]


def added_lines(diff_text):
    """(path, line) for each added line; headers are told apart from content
    by hunk state, so an added line that reads `++ x` is not a header."""
    out, path, in_header = [], None, False
    for ln in diff_text.split("\n"):
        if ln.startswith("diff --git "):
            in_header, path = True, None
        elif in_header and ln.startswith("+++ "):
            p = ln[4:].split("\t")[0]
            path = p[2:] if p.startswith("b/") else None
        elif ln.startswith("@@"):
            in_header = False
        elif not in_header and path and ln.startswith("+"):
            out.append((path, ln[1:]))
    return out


def untracked_files(d, top, paths):
    args = ["ls-files", "--others", "--exclude-standard", "--full-name"]
    if paths:
        args += ["--", *paths]
    out = git(d, *args)
    res = []
    for p in (out or "").split("\n"):
        if not p:
            continue
        try:
            with open(os.path.join(top, p), "rb") as fh:
                data = fh.read(MAX_UNTRACKED_BYTES + 1)
        except OSError:
            continue
        if len(data) > MAX_UNTRACKED_BYTES:
            continue
        for line in data.decode("utf-8", errors="replace").split("\n"):
            res.append((p, line))
    return res


def commit_lines(d, spec, adds):
    """(path, line) for each line the commit run in `d` will carry. `spec` is
    `parse_commit`'s result; `adds` the `parse_add` results of earlier
    `git add`s in the same command, each with its "dir"."""
    top = toplevel(d)
    if not top:
        return []
    found = []
    staged = git(d, "diff", "--cached", *DIFF_OPTS)
    found += added_lines(staged or "")
    for ad in adds:
        if toplevel(ad["dir"]) != top:
            continue
        if ad["weird"] or (ad["all"] and not ad["paths"]):
            found += added_lines(git(d, "diff", *DIFF_OPTS) or "")
            if ad["untracked"] or ad["weird"]:
                found += untracked_files(d, top, [])
        else:
            if ad["paths"]:
                found += added_lines(git(
                    ad["dir"], "diff", *DIFF_OPTS, "--", *ad["paths"]) or "")
                found += untracked_files(ad["dir"], top, ad["paths"])
    if spec["all"]:
        found += added_lines(git(d, "diff", *DIFF_OPTS) or "")
    if spec["paths"] or spec["only"]:
        if spec["paths"]:
            found += added_lines(git(
                d, "diff", "HEAD", *DIFF_OPTS, "--", *spec["paths"]) or "")
    return found


def _log_patch(d, src):
    """At most MAX_LOG_BYTES of `git log -p <src> --not --remotes`, or ""."""
    try:
        p = subprocess.Popen(
            _git_argv(d, "log", "-p", "--format=%x01%h%x02%s", *DIFF_OPTS,
                      src, "--not", "--remotes"),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return ""
    try:
        data = p.stdout.read(MAX_LOG_BYTES)
    finally:
        if p.poll() is None:
            p.kill()
        p.stdout.close()
        try:
            p.wait(timeout=5)
        except subprocess.SubprocessError:
            pass
    return data.decode("utf-8", errors="replace")


def pushed_added_lines(directory, sources):
    """(sha_short, subject, path, line) for each added line of every commit
    reachable from `sources` and on no remote; a commit reached from several
    sources is read once."""
    out, seen = [], set()
    for src in dict.fromkeys(sources):
        sha = subject = path = None
        skip, in_header = False, False
        for ln in _log_patch(directory, src).split("\n"):
            if ln.startswith("\x01"):
                parts = ln[1:].split("\x02", 1)
                sha = parts[0]
                subject = parts[1] if len(parts) > 1 else ""
                skip = sha in seen
                seen.add(sha)
                path, in_header = None, False
            elif skip or sha is None:
                continue
            elif ln.startswith("diff --git "):
                in_header, path = True, None
            elif in_header and ln.startswith("+++ "):
                p = ln[4:].split("\t")[0]
                path = p[2:] if p.startswith("b/") else None
            elif ln.startswith("@@"):
                in_header = False
            elif not in_header and path and ln.startswith("+"):
                out.append((sha, subject, path, ln[1:]))
    return out
