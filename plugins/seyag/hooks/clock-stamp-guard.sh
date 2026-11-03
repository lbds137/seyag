#!/bin/bash
# PreToolUse hook (matcher: Edit|Write|MultiEdit). Inert (exit 0) until its paths
# file lists a glob. Blocks a write to a configured file that adds a clock stamp
# nobody read from the clock. Two rules:
#   1. placeholder: a stamp-shaped MM-DD HH:MM with an x or X in an hour, minute or
#      second digit (23:3x, 00:xx, 23:30:xx), anywhere in an added line of a matched file;
#   2. future: a line-leading stamp later than now plus 60 seconds.
#
# Config file: SYG_CLOCK_STAMP_PATHS_FILE, default
# ${XDG_CONFIG_HOME:-$HOME/.config}/seyag/clock-stamp-paths. A missing, unreadable
# or glob-less file turns the hook off (exit 0 before python starts: the [ -r ] test
# forks nothing, and the glob check runs one grep). One path glob per line; # comments and blank lines are ignored;
# surrounding whitespace is trimmed; a leading ~/ (or a bare ~) expands to $HOME,
# and a ~ glob is dropped when HOME is empty. A line `section: NAME` (NAME
# case-sensitive, trimmed) adds a section name instead of a glob. A glob matches
# when fnmatch.fnmatchcase hits the tool's file_path made absolute (a relative path
# resolves against the event cwd) or its realpath. fnmatch's * also matches / (so
# ~/notes/*.md matches files in nested folders).
#
# Stamp form: a date, MM-DD or YYYY-MM-DD, then one space or T, then HH:MM, an
# optional :SS with an optional .fraction, and an optional zone. The zone is Z (with
# either separator) or +-HH:MM. A +-HH:MM is kept after T, and after a space when the
# stamp has seconds (RFC 3339 style); it must be in the range -12:00 to +14:00. In
# any other case (a space with no seconds, or an out-of-range offset) it is not part
# of the stamp: it is trimmed off and the stamp ends at the minutes, or at the seconds.
# Hour, minute and second digits may be x or X (the placeholder rule; a placeholder
# seconds field is only ever a placeholder); a real stamp needs digit seconds 00-59.
# A future check needs real digits in the date and the time.
# Without a zone the stamp is local time (honouring TZ). Line-leading: after
# optional whitespace, optional markup (runs of "- ", "* ", "+ ", "> ", "#+ ", "**",
# "__", "_"), at most one leading word (\S+ then whitespace), then the stamp. An
# inline code span counts as one word. Any other stamp is mid-line: placeholder-
# checked, never future-checked. An impossible date or time (02-30, hour 24, minute
# 60) is not a stamp; an x-bearing time is a stamp only when some fill of its x
# digits is a valid time.
#
# Future rule: a YYYY- stamp uses its year. An MM-DD stamp takes whichever of last
# year, this year and next year puts it nearest to now, so a late-December stamp
# read in early January is past, and an early-January stamp read in late December
# is next year (ahead, so it blocks if it is more than the grace). A stamp whose
# instant cannot be computed is skipped; the other stamps are still judged.
#
# Multiset rule: only added lines are judged. The key of a stamp is (kind, stamp
# text as written), kind being placeholder or leading. Edit: keys in new_string
# minus keys in old_string (replace_all changes nothing). MultiEdit: each edit is
# judged the same way, in order; any blocking edit blocks the call. Write: keys in
# content minus keys in the file on disk (missing or unreadable = empty). For a key
# that survives, every line of the new text that carries it is judged, and any
# violation blocks; a carried-over copy of the same text is judged too.
#
# Section scope (future rule only): with no section: lines the future rule applies
# anywhere in a matched file. With section: lines, a leading stamp is future-checked
# only when its section is one of them. The section is the text of the last "## "
# heading (up to three leading spaces, exactly two hashes, a closing hash run
# stripped; ### does not count, nor a heading inside a fenced block) above the
# stamp's line. Write: in the new content. Edit and MultiEdit: a heading in the new
# text above the line wins; otherwise the last heading before old_string's first
# occurrence in the file on disk. If no section can be found the stamp is judged.
# The placeholder rule ignores sections.
#
# Code exemption: before any scan, old and new text alike are blanked of inline code
# spans (a backtick run up to the next run of the same length, on one line; the span
# becomes letters, so it still counts as one word) and of fenced blocks (a ``` or
# ~~~ fence line through the matching closing fence within the text being scanned;
# an unclosed fence runs to the end of that text). A backtick fence line whose
# info string holds any backtick is an inline span, not a fence. An Edit or MultiEdit
# whose old_string first occurs on disk inside a fenced block starts its new text
# inside that fence: the new text is code until a closing fence line within it.
# The disk file is read only when an Edit or MultiEdit has a non-empty old_string
# (its fence state is needed) or a Write needs it for the subtraction; its section
# scan is built only when a section lookup needs it.
#
# Probe hook: SYG_CLOCK_STAMP_NOW (integer epoch seconds) overrides "now". It exists
# for the probe, and a non-integer value falls back to the real clock.
#
# Hint: SYG_CLOCK_STAMP_HINT, when set and non-empty, is appended to the block
# message on its own line (a project names its own stamping tool there).
#
# Block: exit 2 with one message on stderr naming each stamp, its rule, the current
# local time (YYYY-MM-DD HH:MM:SS TZ) and "Read the time with `date`, or use a tool
# that stamps it.".
#
# FAIL-OPEN: no python3, unparsable JSON, a tool other than Edit, Write or
# MultiEdit, no file_path, or any python exception: exit 0. jq is not needed; the
# python module reads the payload.
#
# KNOWN GAPS (documented, not fixed):
#   - Bash writes (printf >>, sed -i) do not go through Edit or Write.
#   - A guess that lands behind the real time passes; all four real misses were ahead.
#   - A time with no date (a bare 23:05) is not judged.
#   - One leading word is allowed, so a line that starts with a word and then a
#     scheduled date-time is future-checked: an over-block, escaped with a code span.
#   - fnmatch's * crosses /.
#   - A MultiEdit's later edits are matched against the on-disk file, not the file
#     after the earlier edits.
#   - A second stamp joined to the first by a hyphen (11-02 22:10-11-02 2x:30) is
#     not seen.

set -uo pipefail

# Every early exit below runs the builtin drain first. Claude Code writes the payload
# down a pipe that this hook reads; a hook that exits without reading a payload larger
# than the pipe buffer makes the writer fail with SIGPIPE.
CFG=${SYG_CLOCK_STAMP_PATHS_FILE:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/seyag/clock-stamp-paths}
[ -r "$CFG" ] || { IFS= read -r -d '' _ || true; exit 0; }
grep -Evq '^[[:space:]]*(#|section:|$)' -- "$CFG" || { IFS= read -r -d '' _ || true; exit 0; }

command -v python3 >/dev/null 2>&1 || { IFS= read -r -d '' _ || true; exit 0; }
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$DIR/lib/clock_stamp.py"
[ -r "$LIB" ] || { IFS= read -r -d '' _ || true; exit 0; }

SYG_CLOCK_STAMP_PATHS_FILE="$CFG" PYTHONDONTWRITEBYTECODE=1 python3 "$LIB"
RC=$?
[ "$RC" = 2 ] && exit 2
exit 0
