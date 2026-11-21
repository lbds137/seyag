"""Pure argv parser for `git worktree add`.

Shared by `hooks/lib/live_checkout.py` (to record a new linked worktree path created
earlier in the same Bash command) and `hooks/lib/worktree_branch.py` (to judge the
branch a `git worktree add` under `.claude/worktrees/` creates).

No top-level side effects, no git calls, no globals.
"""


def parse_worktree_add(rest):
    """Parse git argv after the `worktree` subcommand word.

    Returns None unless the first non-option word is `add`, or when `-h` or
    `--help` appears anywhere in `rest`. Otherwise returns a dict with keys:
      - `path`: first positional after `add`, or the word after `--`; None if absent
      - `commitish`: positional after `path`, or None
      - `new_branch`: value of the last `-b` / `-B`, or None
      - `detach`: bool, True for `-d` or `--detach` (including `d` in a short cluster)
      - `orphan`: bool, True for `--orphan`
    """
    if "-h" in rest or "--help" in rest:
        return None
    add_idx = None
    for idx, w in enumerate(rest):
        if w == "--":
            break
        if w.startswith("-") and w != "-":
            continue
        if w == "add":
            add_idx = idx
        break
    if add_idx is None:
        return None

    positionals = []
    new_branch = None
    detach = False
    orphan = False
    dd = False
    j = add_idx + 1
    while j < len(rest):
        w = rest[j]
        if dd:
            positionals.append(w)
            j += 1
            continue
        if w == "--":
            dd = True
            j += 1
            continue
        if w.startswith("--"):
            name, eq, _ = w.partition("=")
            if name == "--detach":
                detach = True
            elif name == "--orphan":
                orphan = True
            if name == "--reason" and not eq:
                j += 2
            else:
                j += 1
            continue
        if w.startswith("-") and w != "-":
            shorts = w[1:]
            for s_idx, ch in enumerate(shorts):
                if ch == "d":
                    detach = True
                elif ch in ("b", "B"):
                    if s_idx == len(shorts) - 1:
                        new_branch = rest[j + 1] if j + 1 < len(rest) else None
                        j += 1
                    else:
                        new_branch = shorts[s_idx + 1 :]
                    break
            j += 1
            continue
        positionals.append(w)
        j += 1

    path = positionals[0] if len(positionals) >= 1 else None
    commitish = positionals[1] if len(positionals) >= 2 else None
    return {
        "path": path,
        "commitish": commitish,
        "new_branch": new_branch,
        "detach": detach,
        "orphan": orphan,
    }
