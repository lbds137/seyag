#!/bin/bash
# PreToolUse hook (matcher: Bash): refuse a `long-job run NAME … && tail`
# chain — the tail would run at once, outside the job — wherever bash would
# run it that way: top level, inside eval, inside $( )/backticks/process
# substitution, behind leading reserved words (`if`, `!`, `do`, …). Nothing is
# refused where the text is data: quoted operators, heredoc bodies, single-
# quoted prose. A heredoc body fed to a shell on stdin (`cat <<EOF | bash`)
# counts as code, because the body is that shell's script.
#
# The verdict is bin/long-job-chain-check's, which also runs standalone
# (plain mode exits 3) and behind bin/long-job's own parent-command check;
# the refusal text names the fix (put the chain inside the job). Component:
# long-job-chain — on by default in the `full` and `guards` profiles
# (hooks/components.tsv); a project turns it off with SYG_DISABLE=long-job-chain
# in settings env, or ships its own .claude/hooks/long-job-chain-guard.sh,
# which run.sh prefers over this copy.
#
# Fast path: this runs on every Bash call, so read stdin once and, when the
# text names no runner — `long-job`, or the basename of the first word of
# SYG_LONG_JOB_CMD (lossy-pipe-guard matches the same name) — exit 0 without
# starting python. The fast path forks only cat.
#
# Fail direction: this hook exits 2 only on a real refusal (the checker's rc 2
# with `refusing:` on its stderr); anything else (bad JSON, a non-string
# command, a missing checker or a python startup error, which also exit 2)
# exits 0 and prints nothing.

INPUT=$(cat)

bare=${INPUT//[\'\"\\]/} # quotes and backslashes out: lo''ng-job is bash's long-job
case "$bare" in
  *long-job*) ;;
  *)
    lj=${SYG_LONG_JOB_CMD:-}
    lj=${lj#"${lj%%[![:space:]]*}"} # first word of the runner prefix ...
    lj=${lj%%[[:space:]]*}          # ... basename only, the name the checker builds
    lj=${lj##*/}
    if [ -z "$lj" ]; then
      exit 0
    fi
    case "$bare" in
      *"$lj"*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

# Bytecode: python3 -I ignores PYTHONPYCACHEPREFIX, so run.sh hands the per-user
# cache prefix over as SYG_PY_CACHE_ARG (-Xpycache_prefix=...); a direct run
# falls back to -B (cache caveats: see run.sh). -I also drops the script dir
# from sys.path, so the checker inserts its lib paths explicitly. The captured
# INPUT is re-fed on stdin (the read above consumed the payload); the herestring
# appends one newline, which the JSON parser ignores.
# Not exec'd: python's own rc 2 (missing script, bad cache arg) must not block.
err=$(python3 -I "${SYG_PY_CACHE_ARG:--B}" "$(dirname "${BASH_SOURCE[0]}")/../bin/long-job-chain-check" --hook <<<"$INPUT" 2>&1 >/dev/null)
rc=$?
if [ "$rc" = 2 ] && [[ $err == *"refusing:"* ]]; then
  printf '%s\n' "$err" >&2
  exit 2
fi
exit 0
