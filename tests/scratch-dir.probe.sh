#!/bin/bash
# Fixture check for bin/scratch-dir: job mode, session mode, and every refusal.
# Usage: tests/scratch-dir.probe.sh   (from anywhere)

set -uo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugins/seyag/bin/scratch-dir"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Every case sets the three inputs explicitly so the caller's own session never leaks in.
sd() { # $1 job dir, $2 session id, $3 scratch root, rest: args
  local j=$1 s=$2 r=$3
  shift 3
  SYG_CONFIG=0 CLAUDE_JOB_DIR="$j" CLAUDE_CODE_SESSION_ID="$s" SYG_SCRATCH_ROOT="$r" "$SD" "$@"
}
mode() { stat -c %a "$1"; }

# Job mode: the job's tmp dir, no further checks.
mkdir -p "$T/job/tmp"
out=$(sd "$T/job" "" "" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "$T/job/tmp" ] && ok "job mode prints the job tmp" || bad "job mode: rc=$rc out=$out"
out=$(sd "$T/job" "" "" unit-1 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "$T/job/tmp/unit-1" ] && [ "$(mode "$T/job/tmp/unit-1")" = 700 ] \
  && ok "job mode NAME creates 700" || bad "job mode NAME: rc=$rc out=$out"
# A job dir without tmp falls through to session mode (which then needs a session id).
mkdir -p "$T/job2"
sd "$T/job2" "" "$T/r0" >/dev/null 2>&1; [ $? = 1 ] && ok "job without tmp needs a session id" || bad "job without tmp"

# Session mode.
R="$T/root"
out=$(sd "" sess-1 "$R" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "$R/sess-1" ] && [ "$(mode "$R")" = 700 ] && [ "$(mode "$R/sess-1")" = 700 ] \
  && ok "session mode makes root and sid dirs 700" || bad "session mode: rc=$rc out=$out"
out=$(sd "" sess-1 "$R" scratch.v-2_x 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "$R/sess-1/scratch.v-2_x" ] && [ "$(mode "$out")" = 700 ] \
  && ok "NAME dir created 700" || bad "NAME dir: rc=$rc out=$out"
out2=$(sd "" sess-1 "$R" scratch.v-2_x 2>&1); rc=$?
[ $rc = 0 ] && [ "$out2" = "$out" ] && ok "second call is idempotent" || bad "idempotent: rc=$rc out=$out2"

# Refusals and usage errors.
for n in '' . .. 'a b' 'a/b' "$(printf 'x%.0s' $(seq 101))"; do
  sd "" sess-1 "$R" "$n" >/dev/null 2>&1; rc=$?
  [ $rc = 2 ] && ok "bad NAME '${n:0:12}' exits 2" || bad "bad NAME '${n:0:12}' rc=$rc"
done
msg=$(sd "" sess-1 "$R" 'a b' 2>&1)
[ "$msg" = "scratch-dir: bad NAME (letters, digits, . _ -)" ] && ok "bad NAME message" || bad "bad NAME message: $msg"
sd "" sess-1 "$R" a b >/dev/null 2>&1; [ $? = 2 ] && ok "two arguments exit 2" || bad "two arguments"
sd "" sess-1 "$R" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option exits 2" || bad "unknown option"
sd "" sess-1 "$R" -h >/dev/null 2>&1; [ $? = 0 ] && ok "-h exits 0" || bad "-h"
out=$(sd "" sess-1 "$R" --help 2>&1); [ $? = 0 ] && case "$out" in 'scratch-dir - '*) true ;; *) false ;; esac \
  && case "$out" in *'Exit 2 on a bad option, a bad NAME or more than one argument.') true ;; *) false ;; esac \
  && ok "--help prints the whole usage header" || bad "--help: $out"
for s in '' 'bad sid' 'a/b' '..' "$(printf 'x%.0s' $(seq 129))"; do
  msg=$(sd "" "$s" "$T/r1" 2>&1); rc=$?
  [ $rc = 1 ] && [ "$msg" = "scratch-dir: no usable session id (CLAUDE_CODE_SESSION_ID)" ] && [ ! -e "$T/r1" ] \
    && ok "sid '${s:0:12}' refused exit 1, nothing created" || bad "sid '${s:0:12}' rc=$rc msg=$msg"
done

mkdir "$T/realroot"; ln -s "$T/realroot" "$T/linkroot"
msg=$(sd "" sess-1 "$T/linkroot" 2>&1); rc=$?
[ $rc = 1 ] && case "$msg" in *"refusing $T/linkroot: it is a symlink") true ;; *) false ;; esac \
  && [ -z "$(ls -A "$T/realroot")" ] && ok "a symlinked root is refused" || bad "symlink root: rc=$rc msg=$msg"
mkdir -m 755 "$T/openroot"; chmod 755 "$T/openroot"
msg=$(sd "" sess-1 "$T/openroot" 2>&1); rc=$?
[ $rc = 1 ] && case "$msg" in *"refusing $T/openroot: mode is not 700") true ;; *) false ;; esac \
  && ok "a mode-755 root is refused" || bad "mode root: rc=$rc msg=$msg"
mkdir -m 700 "$T/okroot"; mkdir -m 755 "$T/okroot/sess-1"; chmod 755 "$T/okroot/sess-1"
sd "" sess-1 "$T/okroot" >/dev/null 2>&1; [ $? = 1 ] && ok "a mode-755 sid dir is refused" || bad "mode sid dir"
mkdir -m 700 "$T/lroot"; ln -s "$T/realroot" "$T/lroot/sess-1"
sd "" sess-1 "$T/lroot" >/dev/null 2>&1; [ $? = 1 ] && ok "a symlinked sid dir is refused" || bad "symlink sid dir"
sd "" sess-1 "$T/no/parent/root" >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && [ ! -e "$T/no" ] && ok "a root without a parent is not made with -p" || bad "root parent: rc=$rc"
ln -s "$T/realroot" "$R/sess-1/linked"
msg=$(sd "" sess-1 "$R" linked 2>&1); rc=$?
[ $rc = 1 ] && case "$msg" in *"refusing $R/sess-1/linked: it is a symlink") true ;; *) false ;; esac \
  && ok "an existing NAME symlink is refused" || bad "NAME symlink: rc=$rc msg=$msg"
mkdir -m 755 "$R/sess-1/open"; chmod 755 "$R/sess-1/open"
msg=$(sd "" sess-1 "$R" open 2>&1); rc=$?
[ $rc = 1 ] && case "$msg" in *"refusing $R/sess-1/open: mode is not 700") true ;; *) false ;; esac \
  && ok "an existing mode-755 NAME dir is refused" || bad "NAME mode: rc=$rc msg=$msg"
msg=$(sd "" sess-1 "relative/root" 2>&1); rc=$?
[ $rc = 1 ] && case "$msg" in *"refusing relative/root: SYG_SCRATCH_ROOT is not an absolute path") true ;; *) false ;; esac \
  && [ ! -e relative ] && ok "a relative root is refused" || bad "relative root: rc=$rc msg=$msg"
# The config.toml loader supplies the root when the environment leaves it unset; the environment wins.
mkdir -p "$T/xdg/seyag"
printf 'syg_scratch_root = "%s/cfgroot"\n' "$T" > "$T/xdg/seyag/config.toml"
out=$(env -u SYG_SCRATCH_ROOT -u SYG_CONFIG XDG_CONFIG_HOME="$T/xdg" CLAUDE_PROJECT_DIR="$T" CLAUDE_JOB_DIR="" CLAUDE_CODE_SESSION_ID=sess-1 "$SD" 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = "$T/cfgroot/sess-1" ] && [ -d "$T/cfgroot/sess-1" ] \
  && ok "the config.toml root is honored" || bad "config root: rc=$rc out=$out"
out=$(env -u SYG_CONFIG XDG_CONFIG_HOME="$T/xdg" CLAUDE_PROJECT_DIR="$T" SYG_SCRATCH_ROOT="$R" CLAUDE_JOB_DIR="" CLAUDE_CODE_SESSION_ID=sess-1 "$SD" 2>&1)
[ "$out" = "$R/sess-1" ] && ok "the environment root beats config.toml" || bad "env beats config: $out"
: > "$R/sess-1/afile"
sd "" sess-1 "$R" afile >/dev/null 2>&1; [ $? = 1 ] && ok "an existing NAME file is refused" || bad "NAME file"
exit $fail
