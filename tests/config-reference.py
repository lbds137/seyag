#!/usr/bin/env python3
"""Generate and check docs/config.md against plugins/seyag/config/knobs.tsv and plugin code."""

import argparse
import os
import re
import stat
import sys
from pathlib import Path

# Add any new environment variable prefix or exact name scanned in plugins/ here.
# Not scanned: variables that the Claude Code harness, gh, the shell or XDG define and
# seyag only reads (CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_ROOT, CLAUDE_JOB_DIR, CLAUDE_CODE_*,
# ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY, GH_*, XDG_*, HOME). The exact
# names above that come from those systems are listed because seyag honours them as overrides.
# A name must appear literally somewhere in a scanned file; a name built at runtime ("SYG_ALLOW_$x", prefix + k) needs a literal mention (a comment is enough) or it escapes the parity check.
SCAN_PREFIXES = (
    "SYG_",
    "CLAUDE_USAGE_",
    "ZAI_",
    "PLUGIN_RELEASE_",
    "PRICE_TABLE_",
    "SECURITY_SWEEP_",
    "RAILWAY_OPS_",
    "CONTEXT_AUDIT_",
    "LINES_CHECK_",
    "OPENROUTER_",
    "CC_ROUTE_",
    "PR_CI_WAIT_",
    "TZUROT_ALLOW_",
)
SCAN_EXACT_NAMES = (
    "CLAUDE_PROJECTS_DIR",
    "CLAUDE_SESSION_ARCHIVE",
    "SESSION_LEDGER",
    "SEYAG_KEYS_BIN",
    "CLAUDE_VERSIONS_DIR",
    "CLAUDE_PLUGIN_REGISTRY",
    "ANTHROPIC_ADMIN_API_KEY",
    "CLAUDE_CONFIG_DIR",
)

GROUPS = (
    "guards",
    "stop-gates",
    "session",
    "statusline",
    "usage",
    "credit",
    "pr",
    "worktrees",
    "release",
    "routing",
    "misc",
)
SCOPES = ("user", "internal")
MAX_DESCRIPTION_LEN = 220
# A knobs.tsv default with this prefix is plain prose: rendered unbackticked, prefix dropped.
PROSE_PREFIX = "prose:"

NAME_RE = re.compile(
    r"\b(?:"
    + "|".join(re.escape(p) for p in SCAN_PREFIXES)
    + r")[A-Z0-9_]*[A-Z0-9]\b|\b(?:"
    + "|".join(re.escape(n) for n in SCAN_EXACT_NAMES)
    + r")\b"
)


def scan_plugins(root: Path) -> dict[str, set[str]]:
    plugins_dir = root / "plugins"
    seyag_dir = plugins_dir / "seyag"
    knobs_path = (seyag_dir / "config" / "knobs.tsv").resolve()
    readers: dict[str, set[str]] = {}
    if not plugins_dir.is_dir():
        return readers

    for dirpath, dirnames, filenames in os.walk(plugins_dir, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        for fname in sorted(filenames):
            if fname.endswith(".md") or fname.endswith(".probe.sh"):
                continue
            fpath = Path(dirpath) / fname
            try:
                st = fpath.lstat()
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if fpath.resolve() == knobs_path:
                continue
            try:
                raw = fpath.read_bytes()
            except OSError:
                continue

            try:
                rel = fpath.relative_to(seyag_dir).as_posix()
            except ValueError:
                rel = fpath.relative_to(plugins_dir).as_posix()

            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                # Names are ASCII, so replacement characters still leave every name findable.
                print(
                    f"config-reference: warning: {rel} is not valid UTF-8; scanned with replacement characters",
                    file=sys.stderr,
                )
                text = raw.decode("utf-8", errors="replace")

            for match in NAME_RE.finditer(text):
                name = match.group(0)
                readers.setdefault(name, set()).add(rel)

    return readers


def load_and_validate_knobs(
    knobs_path: Path, scanned: dict[str, set[str]]
) -> tuple[dict[str, dict[str, str]], list[str]]:
    errors: list[str] = []
    rows: dict[str, dict[str, str]] = {}

    if not knobs_path.is_file():
        errors.append(f"config-reference: missing knobs file {knobs_path}")
        return rows, errors

    try:
        lines = knobs_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"config-reference: cannot read {knobs_path}: {exc}")
        return rows, errors

    for lineno, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 5:
            row_id = parts[0].strip() if parts and parts[0].strip() else f"line {lineno}"
            errors.append(
                f"config-reference: {row_id} in knobs.tsv:{lineno} has {len(parts)} fields (expected 5)"
            )
            continue
        name, scope, group, default, description = (p.strip() for p in parts)
        if not name:
            errors.append(f"config-reference: line {lineno} in knobs.tsv has empty name")
            continue
        if name in rows:
            errors.append(f"config-reference: {name} has duplicate row in knobs.tsv:{lineno}")
            continue
        if scope not in SCOPES:
            errors.append(
                f"config-reference: {name} in knobs.tsv:{lineno} has invalid scope {scope!r} (expected user or internal)"
            )
        if group not in GROUPS:
            errors.append(
                f"config-reference: {name} in knobs.tsv:{lineno} has invalid group {group!r} (expected one of {', '.join(GROUPS)})"
            )
        if not default:
            errors.append(f"config-reference: {name} in knobs.tsv:{lineno} has empty default")
        if default.startswith(PROSE_PREFIX) and not default[len(PROSE_PREFIX):].strip():
            errors.append(f"config-reference: {name} in knobs.tsv:{lineno} has empty prose default")
        if not description:
            errors.append(f"config-reference: {name} in knobs.tsv:{lineno} has empty description")
        elif len(description) > MAX_DESCRIPTION_LEN:
            errors.append(
                f"config-reference: {name} in knobs.tsv:{lineno} description is {len(description)} chars (max {MAX_DESCRIPTION_LEN})"
            )

        rows[name] = {
            "name": name,
            "scope": scope,
            "group": group,
            "default": default,
            "description": description,
        }

    for name in sorted(scanned):
        if name not in rows:
            by = ", ".join(sorted(scanned[name]))
            errors.append(f"config-reference: {name} read by {by} has no knobs.tsv row")

    for name in sorted(rows):
        if name not in scanned:
            errors.append(
                f"config-reference: {name} in knobs.tsv is stale (not read by any scanned file in plugins/)"
            )

    return rows, errors


def escape_cell(text: str) -> str:
    return text.replace("|", r"\|")


def format_default(default: str) -> str:
    if default == "unset":
        return "unset"
    if default.startswith(PROSE_PREFIX):
        return escape_cell(default[len(PROSE_PREFIX):].strip())
    return f"`{escape_cell(default)}`"


def format_readers(paths: set[str]) -> str:
    return ", ".join(f"`{escape_cell(p)}`" for p in sorted(paths))


def render_doc(rows: dict[str, dict[str, str]], scanned: dict[str, set[str]]) -> str:
    prefixes_list = ", ".join(f"`{p}*`" for p in SCAN_PREFIXES)
    exact_list = ", ".join(f"`{n}`" for n in SCAN_EXACT_NAMES)

    out: list[str] = [
        "# Configuration Reference",
        "",
        "Generated by `tests/config-reference.py --write` from `plugins/seyag/config/knobs.tsv`; do not edit by hand.",
        "",
        "## Scope",
        "",
        f"Every environment variable with prefix {prefixes_list}, plus {exact_list}, found in files under `plugins/` other than `*.md` and `*.probe.sh`. Not listed: variables that the Claude Code harness, `gh`, the shell or XDG define and seyag only reads (for example `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_JOB_DIR`, `CLAUDE_CODE_*`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `GH_*`, `XDG_*`, `HOME`); the listed names from those systems are ones seyag honours as overrides. `Found in` lists every such file that mentions the name, comments included.",
        "",
        "## How to set a value",
        "",
        "Set user variables in the `env` block of a Claude Code `settings.json` (`~/.claude/settings.json` for user scope, `.claude/settings.json` for project scope, or `.claude/settings.local.json` for local scope; the more specific scope wins):",
        "",
        "```json",
        "{",
        '  "env": {',
        '    "SYG_PROFILE": "full"',
        "  }",
        "}",
        "```",
        "",
        "Exception: the per-command `SYG_ALLOW_*` bypasses of the shell guards are written into the command itself (for example `SYG_ALLOW_RM=1 rm -r build`), not into settings; each row says so. `SYG_ALLOW_LIVE_CHECKOUT` is the one also read from the environment.",
    ]

    for group in GROUPS:
        group_rows = [
            rows[name]
            for name in sorted(rows)
            if rows[name]["scope"] == "user" and rows[name]["group"] == group
        ]
        if not group_rows:
            continue
        out.extend(
            [
                "",
                f"## {group}",
                "",
                "| Name | Default | What it does | Found in |",
                "| --- | --- | --- | --- |",
            ]
        )
        for r in group_rows:
            name_cell = f"`{escape_cell(r['name'])}`"
            default_cell = format_default(r["default"])
            desc_cell = escape_cell(r["description"])
            read_by_cell = format_readers(scanned[r["name"]])
            out.append(f"| {name_cell} | {default_cell} | {desc_cell} | {read_by_cell} |")

    internal_rows = [
        rows[name] for name in sorted(rows) if rows[name]["scope"] == "internal"
    ]
    if internal_rows:
        out.extend(
            [
                "",
                "## Internal names",
                "",
                "| Name | Found in | Note |",
                "| --- | --- | --- |",
            ]
        )
        for r in internal_rows:
            name_cell = f"`{escape_cell(r['name'])}`"
            read_by_cell = format_readers(scanned[r["name"]])
            note_cell = escape_cell(r["description"])
            out.append(f"| {name_cell} | {read_by_cell} | {note_cell} |")

    out.append("")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Generate or check docs/config.md from plugins/seyag/config/knobs.tsv."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=default_root,
        help="Repository root directory (default: parent of tests/).",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--write",
        action="store_true",
        help="Write docs/config.md when knobs.tsv is valid.",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="Validate knobs.tsv and check that docs/config.md is up to date.",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    knobs_path = root / "plugins" / "seyag" / "config" / "knobs.tsv"
    doc_path = root / "docs" / "config.md"

    scanned = scan_plugins(root)
    rows, errors = load_and_validate_knobs(knobs_path, scanned)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1

    rendered = render_doc(rows, scanned)

    if args.write:
        doc_path.parent.mkdir(parents=True, exist_ok=True)
        doc_path.write_bytes(rendered.encode("utf-8"))
        return 0

    if not doc_path.is_file():
        print(
            "config-reference: docs/config.md is missing; regenerate with python3 tests/config-reference.py --write",
            file=sys.stderr,
        )
        return 1

    try:
        mismatch = doc_path.read_bytes() != rendered.encode("utf-8")
    except OSError as exc:
        print(f"config-reference: cannot read docs/config.md: {exc}", file=sys.stderr)
        return 1

    if mismatch:
        print(
            "config-reference: docs/config.md is out of date with plugins/seyag/config/knobs.tsv; regenerate with python3 tests/config-reference.py --write",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
