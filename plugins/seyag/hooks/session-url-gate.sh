#!/bin/bash
# PreToolUse hook (matcher: Bash) — a Claude session link
# (`https://claude.ai/code/session_<id>`) is a secret in any shared history:
# it must not enter a commit, tag, note, PR, issue, release or gist, in any
# project. Tzurot's .husky/commit-msg guards the commit-message path only; this
# hook checks the command text, bodies read from files, the commit MESSAGES of
# a push, and the added file lines of the commit being made and of pushed
# commits (see KNOWN GAPS for what it does not see).
#
# THE ADDED LAYER: git-hooks/pre-push (opt-in, `seyag-git-hooks install
# --global`) also scans what a push from a public repo sends, however bash
# built it. It adds to this hook and replaces nothing: rules 1-4 below run
# as before in every repo.
#
# PRE-PUSH BYPASSES: where that pre-push is in force (lib/prepush_state.py's
# `enforcing`: a public repo, the seyag hooks dir as its effective
# core.hooksPath, no alias that skips it), the ways past it block (exit 2
# naming the token) before any other check; elsewhere they pass.
# lib/outbound.py's `prepush_bypasses` is the list (`git push --no-verify`
# and its prefixes, a push argument holding `$` or a backtick, `HOME=`/`env
# -i` on a push, a `-c`/`--config-env` or `git config` write of
# core.hooksPath, an include, seyag.* or alias.*, `git config --edit`, a
# core/seyag section removal, `git update-ref refs/remotes/…`, `git
# send-pack`, GIT_CONFIG_* assignments; a `--global|--system` config write
# is judged by the global install, a `--file <f>` one by f's repo). This
# hook needs no private-terms file, so they block without one;
# private-term-guard.sh blocks them too when it is on.
# Waived by this hook's BYPASS in the command's own prefix; a GIT_CONFIG_*
# assignment is waived only inside the prefix of the command carrying it
# when that command runs a program (`SYG_ALLOW_SESSION_URL=1
# GIT_CONFIG_GLOBAL=x git push`), never by a BYPASS on another command or
# by text that only looks like one (quoted, a comment, a heredoc body), and
# not for a command led by a shell keyword or grouping (`{`, `if`, `!`,
# `time`, `for … do`) or one after `env -` (fail closed: move the
# assignment onto a plain command). Not seen:
# `.git/config` edited by a non-git tool, an earlier `export HOME=…`, `git
# update-ref --stdin`.
#
# SECRET PATTERN: `claude.ai/code/session_` followed by an id character
# [A-Za-z0-9] (host part case-insensitive, the rest case-sensitive). Prose
# naming the bare prefix, followed by a space, backtick or quote, passes.
# The pattern and its mask live in lib/session_link.py, shared with
# git-hooks/pre-push.
#
# WHAT BLOCKS (the outbound text comes from lib/outbound.py, whose docstring
# is the full list; commands are found with the shared splitter in lib/, the
# same one publish-gate uses: top-level pipelines, wrapper strings such as
# `bash -c '…'`, and command substitutions):
#   1. `git commit`, `git tag`, `git notes` (global options before the
#      subcommand are skipped; `-C <dir>` is honored), or any non-exempt `gh`
#      command (a read-only `gh` command — the read verbs of
#      pr/issue/run/repo/release/gist in GH_READ_SUBCOMMANDS, `gh api` with a
#      GET method — is skipped only under the closed-text rule: no `VAR=`
#      assignment in its prefix, no `--web`/`--hostname`/`-H` flag; see
#      `gh_text_exempt` in lib/outbound.py),
#      when the WHOLE command text matches the pattern. That covers `-m`, heredoc and
#      here-string bodies, `--body`, `--title` and `gh api -f body=…`. A link
#      anywhere in the same text as such a command is an over-arm on purpose
#      (the recoverable direction).
#   2. A body read from a file, whose CONTENTS are matched: `git commit|tag|
#      notes -F <f>` / `--file <f>` / `--file=<f>` (also inside a short
#      cluster such as `-aF f`); for `gh`: `--body-file <f>`, `--notes-file
#      <f>`, `-F <f>` (not on `gh api`), and on `gh api` a `-F`/`--field`
#      value `key=@<f>` or `--input <f>`; `gh gist create|edit`: every
#      positional file and `edit --add <f>`. `-` means stdin, i.e. the command
#      text, already covered by 1. A relative path resolves against the
#      event's cwd, moved by `cd`/`pushd` words earlier in the command
#      (redirections and `-P`/`-L` allowed; `~` expands HOME) and by git's
#      `-C` (`~` expanded too). An unreadable file is not a block.
#   3. `git push`: the messages of the commits being pushed. Sources are the
#      source side of each refspec given (`foo`, `+foo:bar`, `HEAD:refs/…`;
#      a delete `:dst` has none), else HEAD; `--all`/`--mirror` scan every
#      local branch and `--tags` every tag. The scan is
#      `git log <sources> --not --remotes`, so commits already on any remote
#      pass. A refspec with `$`, a backtick or a glob is read as HEAD.
#      `gh repo create … --push` runs the same scan on HEAD in the repo
#      directory (`--source <dir>` if given, else the tracked cwd).
#   4. Added lines in every file: of the commit being made by `git commit`
#      (staged, plus what a same-command `git add`, `commit -a` or a pathspec
#      commit adds, as lib/commit_diff.py computes it), and of each commit a
#      `git push` or `gh repo create --push` sends (same sources as 3).
#
# MESSAGE: names the path that matched (command text, file <f>, commit
# <sha> <subject>, staged <path>, or commit <sha> <path>), masks the id (`claude.ai/code/session_…`; the full link
# is never echoed), and says to remove the link and, for a commit already
# made, amend it before pushing.
#
# BYPASS: `SYG_ALLOW_SESSION_URL=1` as an assignment in the matched command's
# own prefix (`VAR=… git commit …`, `env VAR=… gh …`); a mention elsewhere in
# the text does not count. Only on the owner's word.
#
# KNOWN GAPS (accepted): a body read through a variable or a substitution
# (`-F "$f"`, `--body "$(cat f)"`), a file written earlier by another tool call
# and read by a wrapper script, a `cd` inside a subshell leaking into the
# tracked directory, and `git push` of refs that git log cannot resolve
# (skipped). Stdin redirects: `-F - < f`, `--body-file - < f`, `cat f | gh …
# --body-file -`. Annotated tag messages on push (only commit messages are
# scanned). File CONTENTS inside a commit are read only as lib/commit_diff.py
# approximates them: content written earlier in the same command does not
# exist yet when this PreToolUse hook runs, a merge commit's own changes are
# not read on push (no `-m`), and pushed diffs past 4 MiB of log output are
# not read.
#
# FAIL-OPEN: no jq/python3, unparsable JSON or command, or an internal python
# error → exit 0. Prefilter, in bash, before python spawns: a `gh` word always
# goes through; a `git` word goes through only with a word-bounded `commit`,
# `tag`, `notes`, `push` or `config`, or `hookspath`, `include`, `alias`,
# `update-ref` or `send-pack` in any case, in the text, so `git status` and
# the like never start python.
#
# The command goes to python on fd 3, never through the environment (Linux
# caps one env string at 128 KiB). Python's stderr is discarded.
#
# Fixture check: run hooks/session-url-gate.probe.sh after ANY edit here.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ "$TOOL_NAME" != "Bash" ] && exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

read -r GH_WRAPPER_FIRST _ <<<"${SYG_GH_WRAPPERS:-}"
GH_WRAPPER_FIRST=${GH_WRAPPER_FIRST##*/}
if [[ "$CMD" =~ (^|[^[:alnum:]_.-])gh([^[:alnum:]_-]|$) ]]; then
  :
elif [ -n "$GH_WRAPPER_FIRST" ] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_.-])"$GH_WRAPPER_FIRST"([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "$CMD" =~ (^|[^[:alnum:]_-])(commit|tag|notes|push)([^[:alnum:]_-]|$) ]]; then
  :
elif [[ "$CMD" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$) ]] \
  && [[ "${CMD,,}" =~ hookspath|include|alias|update-ref|send-pack|(^|[^[:alnum:]_-])config([^[:alnum:]_-]|$) ]]; then
  :
else
  exit 0
fi

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
RESULT=$(CWD="$CWD" HOOK_LIB="$HOOK_LIB" PYTHONDONTWRITEBYTECODE=1 python3 - 3<<<"$CMD" <<'PYEOF' 2>/dev/null
import os
import sys

# An import failure exits non-zero, which the caller treats as allow (fail-open).
sys.path.insert(0, os.environ["HOOK_LIB"])
from outbound import bypass_block_message, outbound_items, prepush_bypasses
from prepush_state import enforcing_judge, global_install_present
from session_link import SECRET, mask

cmd = os.fsdecode(open(3, "rb").read()).removesuffix("\n")
payload_cwd = os.environ.get("CWD") or "."

BYPASS = "SYG_ALLOW_SESSION_URL=1"

# The pre-push bypass shapes, where that hook is in force (this hook needs no
# private-terms file, so they block with or without one).
bypass_tokens = prepush_bypasses(cmd, payload_cwd, BYPASS,
                                 dir_filter=enforcing_judge(payload_cwd),
                                 global_filter=global_install_present)
if bypass_tokens:
    print(bypass_block_message(bypass_tokens, BYPASS))
    sys.exit(0)


findings = [mask(item.label) for item in outbound_items(cmd, payload_cwd, BYPASS)
            if SECRET.search(item.text)]

if findings:
    uniq = list(dict.fromkeys(findings))
    print("blocked: a Claude session link (claude.ai/code/session_…) would go out; matched in: "
          + "; ".join(uniq) + ".")
    print("Session links are secrets in shared history. Remove the link (relay session links "
          "in chat only). For a commit already made, `git commit --amend` (or reword it "
          "without an interactive editor) before pushing.")
    print("Only on the owner's word: prefix the command itself with SYG_ALLOW_SESSION_URL=1.")
PYEOF
)
[ -z "$RESULT" ] && exit 0
printf '%s\n' "$RESULT" >&2
exit 2
