#!/bin/bash
# Single enumeration of the repo's shell and Python files, shared by
# tests/shell-syntax.probe.sh and the CI shellcheck step.
#
# Usage: tests/shell-files.sh            shell files, one path per line
#        tests/shell-files.sh --python   Python files, one path per line
# Paths are relative to the repo root (or to ROOT when set).

set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT" || exit 1
shopt -s nullglob

mode=shell
[ "${1:-}" = "--python" ] && mode=python

shebang_kind() {
  case "$(head -n 1 "$1" 2>/dev/null)" in
    '#!'*bash* | '#!/bin/sh'* | '#!/usr/bin/env sh'*) echo shell ;;
    '#!'*python*) echo python ;;
  esac
}

if [ "$mode" = shell ]; then
  for f in plugins/seyag/hooks/*.sh plugins/seyag/hooks/lib/*.sh tests/*.sh; do
    printf '%s\n' "$f"
  done
  for f in plugins/seyag/bin/*; do
    [ -f "$f" ] && [ "$(shebang_kind "$f")" = shell ] && printf '%s\n' "$f"
  done
else
  for f in plugins/seyag/hooks/lib/*.py tests/*.py; do
    printf '%s\n' "$f"
  done
  for f in plugins/seyag/bin/*; do
    [ -f "$f" ] && [ "$(shebang_kind "$f")" = python ] && printf '%s\n' "$f"
  done
fi
exit 0
