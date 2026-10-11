"""The scan behind git-hooks/pre-push: what a push to a public repo would
publish (the gaps are in git-hooks/pre-push's header), matched against the
private terms (lib/private_terms.py) and the session-link pattern
(lib/session_link.py), the same sources and matching as
hooks/private-term-guard.sh and hooks/session-url-gate.sh.

`scan(stdin_bytes, remote, terms_file)` returns `(hits, notice)`: up to
MAX_HITS printable hit lines, and a notice line naming the lowest term hit
(None when there is none). Any git failure raises ScanError and a tree or
blob push raises Refusal; the caller fails closed on both.

WHAT IS SCANNED, for each stdin line `<local ref> <local sha> <remote ref>
<remote sha>` whose local sha is not the zero sha (a delete sends nothing):
  - the commits `git rev-list <local sha> --not --remotes=<remote>`, minus
    the remote sha's history when this repo has that object (the remote
    holds it already): with no remote-tracking refs, every commit reachable
    from the local sha. Each commit is read once, by the first ref that
    reaches it. Per commit:
      - `message`: the full message (`git cat-file --batch`), plus any extra
        header (`encoding`, `mergetag`, `gpgsig`: a mergetag embeds a tag);
      - `author` / `committer`: the identity lines' name and email;
      - `path`: every path the commit adds or renames (`git diff-tree --stdin
        -r --cc --name-only --diff-filter=AR -M --root -z`; `--cc` adds a
        merge's own new paths, those new against every parent);
      - `added line`: every added line (`git diff-tree --stdin -r --cc -p -M
        --root`, with lib/commit_diff.py's pinned prefixes and DIFF_OPTS); a
        merge's lines are the ones new against every parent. A pushed
        `refs/notes/*` ref labels them `note`: a notes commit adds a note as
        a blob, so its added lines are the note text.
  - `tag`: when the local sha is an annotated tag object, `git cat-file -p`
    of it, and of each tag it points to in turn.

Every git call runs with GIT_NO_REPLACE_OBJECTS=1 (a replace ref cannot
hand the scan a clean stand-in), and the line diff uses `-a`, so a file git
calls binary (by content or a `-diff`/`binary` attribute) is read as text.
A pushed local sha that peels to a tree or blob raises Refusal: that is not
scanned, so it is not sent.

NOT SCANNED (accepted): a commit whose `encoding` header is not UTF-8 is
decoded as UTF-8 with replacement. git-hooks/pre-push's header has the
install-level gaps.

No top-level side effects: importing this module runs nothing.
"""

import os
import re
import signal
import subprocess
import threading

import commit_diff
import private_terms
import session_link

MAX_HITS = 5
MAX_LINE = 160
MATCH_SECONDS = 5
ZERO = re.compile(r"^0+$")


class ScanError(Exception):
    pass


class Refusal(Exception):
    """A push the scan refuses without an internal error (a tree or blob)."""


class MatchTimeout(Exception):
    pass


def _on_alarm(_signum, _frame):
    raise MatchTimeout()


# Every git call reads the real objects: a replace ref must not show the scan
# a clean stand-in for the commit git actually sends.
GIT_ENV = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"}


def _run(args, stdin=b""):
    try:
        r = subprocess.run(commit_diff._git_argv(".", *args), input=stdin,
                           capture_output=True, timeout=300, env=GIT_ENV)
    except (OSError, subprocess.SubprocessError) as e:
        raise ScanError(f"git {args[0]}: {e}") from e
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip().splitlines()
        raise ScanError(f"git {' '.join(args[:2])} failed: {err[-1] if err else r.returncode}")
    return r.stdout


def _ok(args):
    try:
        return subprocess.run(["git", *args], capture_output=True, timeout=30,
                              env=GIT_ENV).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _decode(data):
    return data.decode("utf-8", "replace")


class Matcher:
    def __init__(self, compiled):
        self.compiled = compiled or []
        self.hits = []
        self.terms_hit = set()

    def full(self):
        return len(self.hits) >= MAX_HITS

    def check(self, kind, sha, text):
        """Record a hit line when `text` holds a term or a session link."""
        if self.full() or not text:
            return
        signal.alarm(MATCH_SECONDS)
        try:
            found = private_terms.spans(self.compiled, text)
            link = session_link.SECRET.search(text) is not None
        finally:
            signal.alarm(0)
        if not found and not link:
            return
        what = []
        if found:
            nums = {n for _s, _e, n in found}
            self.terms_hit |= nums
            what.append(f"private term #{min(nums)}")
        if link:
            what.append("a session link")
        shown = session_link.mask(private_terms.masked(text, found)) if found \
            else session_link.mask(text)
        line = private_terms.context_line(shown) if found else _link_line(shown)
        self.hits.append(f"  {kind} of {sha[:12]} ({', '.join(what)}): {line}"[:MAX_LINE])


def _link_line(text):
    lines = text.split("\n")
    return next((ln for ln in lines if "session_…" in ln), lines[0]).strip()


def _parse_stdin(data):
    out = []
    for raw in _decode(data).splitlines():
        parts = raw.split()
        if not parts:
            continue
        if len(parts) != 4:
            raise ScanError(f"unexpected pre-push input line: {raw[:80]!r}")
        out.append(parts)
    return out


def _object_type(sha):
    return _decode(_run(["cat-file", "-t", sha])).strip()


def _scan_tags(m, sha):
    seen = set()
    while sha not in seen and not m.full():
        seen.add(sha)
        body = _decode(_run(["cat-file", "-p", sha]))
        m.check("tag", sha, body)
        target = re.match(r"object (\S+)\ntype (\S+)", body)
        if not target or target.group(2) != "tag":
            return
        sha = target.group(1)


def _peeled_type(sha):
    """The type of `sha` with tags peeled (`<sha>^{}`)."""
    peeled = _decode(_run(["rev-parse", "--verify", "-q", f"{sha}^{{}}"])).strip()
    return _object_type(peeled)


def _commits(local_sha, remote, remote_sha):
    args = ["rev-list", local_sha, "--not", f"--remotes={remote}"]
    if not ZERO.match(remote_sha) and _ok(["cat-file", "-e", f"{remote_sha}^{{commit}}"]):
        args.append(remote_sha)
    return _decode(_run(args)).split()


def _scan_objects(m, commits):
    """message, author and committer of each commit, via one cat-file --batch."""
    data = _run(["cat-file", "--batch"], ("\n".join(commits) + "\n").encode())
    pos = 0
    for sha in commits:
        nl = data.index(b"\n", pos)
        head = _decode(data[pos:nl]).split()
        if len(head) != 3 or head[1] != "commit":
            raise ScanError(f"cat-file --batch: unexpected header for {sha}")
        size = int(head[2])
        body = data[nl + 1: nl + 1 + size]
        pos = nl + 1 + size + 1
        headers, _, message = _decode(body).partition("\n\n")
        extra = []
        for line in re.split(r"\n(?! )", headers):
            key, _, value = line.partition(" ")
            if key in ("author", "committer"):
                ident = re.sub(r"\s+\d+\s+[-+]\d{4}$", "", value)
                m.check(key, sha, ident)
            elif key not in ("tree", "parent"):
                extra.append(line)
        m.check("message", sha, message + ("\n" + "\n".join(extra) if extra else ""))
        if m.full():
            return


def _scan_paths(m, commits):
    data = _run(["diff-tree", "--stdin", "-r", "--cc", "--name-only", "--diff-filter=AR",
                 "-M", "--root", "-z"], ("\n".join(commits) + "\n").encode())
    known = set(commits)
    sha = None
    for tok in _decode(data).split("\0"):
        if not tok:
            continue
        if tok in known:
            sha = tok
            continue
        if sha is None:
            raise ScanError("diff-tree: a path before any commit")
        m.check("path", sha, tok)
        if m.full():
            return


def _reap(p):
    """Kill `p`, close its output pipes and wait for it, ignoring errors (the
    caller is already raising)."""
    for step in (p.kill, p.stdout.close, p.stderr.close, lambda: p.wait(timeout=30)):
        try:
            step()
        except (OSError, subprocess.SubprocessError, ValueError):
            pass


def _scan_lines(m, commits, notes):
    """Added lines of each commit, streamed; a line of a hunk is never dropped
    for an unparsable header (commit_diff's parsers skip those)."""
    # -a: a `-diff`/`binary` attribute must not turn a file's lines into
    # "Binary files differ".
    args = commit_diff._git_argv(".", "diff-tree", "--stdin", "-r", "--cc", "-M", "--root",
                                 "-a", *commit_diff.DIFF_OPTS)
    try:
        p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, env=GIT_ENV)
    except OSError as e:
        raise ScanError(f"git diff-tree: {e}") from e
    known = set(commits)

    def feed():  # a thread, so a long commit list cannot deadlock on full pipes
        try:
            p.stdin.write(("\n".join(commits) + "\n").encode())
            p.stdin.close()
        except OSError:
            pass  # diff-tree exited early (killed at MAX_HITS, or failed: rc says)

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    try:
        sha, width, in_hunk = None, 1, False
        for raw in p.stdout:
            ln = _decode(raw.rstrip(b"\n"))
            if ln in known:
                sha, in_hunk = ln, False
            elif ln.startswith("diff --git ") or ln.startswith("diff --cc ") \
                    or ln.startswith("diff --combined "):
                in_hunk = False
            elif ln.startswith("@@"):
                width = len(ln) - len(ln.lstrip("@")) - 1
                in_hunk = True
            elif in_hunk and sha and ln[:width] == "+" * width:
                m.check("note" if sha in notes else "added line", sha, ln[width:])
                if m.full():
                    break
        if m.full():
            p.kill()
        p.stdout.close()
        err = p.stderr.read()
        rc = p.wait(timeout=30)
    except (OSError, subprocess.SubprocessError, ValueError) as e:
        _reap(p)
        raise ScanError(f"git diff-tree: {e}") from e
    except BaseException:  # MatchTimeout and the like: reap, then re-raise
        _reap(p)
        raise
    if rc != 0 and not m.full():
        tail = _decode(err).strip().splitlines()
        raise ScanError(f"git diff-tree failed: {tail[-1] if tail else rc}")


def scan(stdin_bytes, remote, terms_file):
    notice = None
    compiled = []
    if terms_file:
        terms = private_terms.read_terms(terms_file)
        if terms:
            compiled, bad = private_terms.compile_terms(terms)
            if compiled is None:
                raise ScanError(f"{terms_file} line {bad} is not a valid regex; fix it")
    m = Matcher(compiled)
    signal.signal(signal.SIGALRM, _on_alarm)
    order, notes, seen = [], set(), set()
    try:
        for local_ref, local_sha, _remote_ref, remote_sha in _parse_stdin(stdin_bytes):
            if ZERO.match(local_sha):
                continue
            if _object_type(local_sha) == "tag":
                _scan_tags(m, local_sha)
            kind = _peeled_type(local_sha)
            if kind in ("tree", "blob"):
                raise Refusal(f"{local_ref} is a {kind}: pushing a tree/blob directly "
                              "is not scanned")
            for c in _commits(local_sha, remote, remote_sha):
                if c in seen:
                    continue
                seen.add(c)
                order.append(c)
                if local_ref.startswith("refs/notes/"):
                    notes.add(c)
        if order and not m.full():
            _scan_objects(m, order)
        if order and not m.full():
            _scan_paths(m, order)
        if order and not m.full():
            _scan_lines(m, order, notes)
    except MatchTimeout:
        raise ScanError(f"matching the terms took over {MATCH_SECONDS} s; "
                        f"simplify the patterns in {terms_file}") from None
    if m.terms_hit:
        notice = f"#{min(m.terms_hit)} in $SYG_PRIVATE_TERMS_FILE"
    return m.hits, notice
