#!/bin/bash
# Optional config files for seyag. Sourced (by hooks/run.sh and bin/claude-usage),
# never executed. Defines:
#   syg_config_env <plugin_dir>   fill in unset env knobs from the config files
#
# Scope: user file ${XDG_CONFIG_HOME:-$HOME/.config}/seyag/config.toml, then
# project file ${CLAUDE_PROJECT_DIR:-$PWD}/.claude/seyag.toml; a project key
# overwrites a user key between the two files. The environment wins over both,
# even when set to the empty string: an entry exports only while its env name is
# unset. Values export verbatim — the loader does no semantic validation, every
# reader keeps its own (which is why adopting it needs no reader changes).
#
# Key rule (mechanical, no map): the env name is the key path uppercased with the
# path separators turned into underscores — top-level `claude_usage_week_reserve`
# -> CLAUDE_USAGE_WEEK_RESERVE, and `[claude_usage]` + `week_reserve` -> the same
# name, a dotted key `a.b` joining the path like a section. Config keys thus build
# SYG_-prefixed (and other registry) names at runtime; a key applies iff its env
# name is a scope=user row of <plugin_dir>/config/knobs.tsv and not one of the
# harness-owned names below (Claude Code or the machine reads those before seyag
# runs; a config file must not fake them). Everything else is an unknown key.
#
# Accepted subset, per line: blank, full-line `#` comment, `[section]` / `[a.b]`
# header, or `key = value` with a quoted string (basic `"`, escapes \\ \" \t \n
# only, or literal `'`, no escapes), an integer, a float, or true/false (exported
# as 1/0). Strings and paths must be quoted; arrays, inline tables, multiline
# strings and trailing content after the value are unsupported. Each offending
# line warns once on stderr and is skipped: a bad file never blocks a hook or a
# bin, and because the loader runs per call, a bad file warns on every call (loud
# beats silent). Duplicate keys warn (first value wins); duplicate sections
# warn too, and their keys merge (again first value per key). Names ending
# _CMD, and the binary-path knobs in _SYG_CFG_PROJECT_EXEC below, cannot be
# set from the project file: a repo must not choose the executables this
# machine runs. SYG_CONFIG=0 disables the loader entirely.

# Harness-owned names (see the header): never settable from a config file. Kept
# equal to the user-scope rows of SCAN_EXACT_NAMES in tests/config-reference.py
# by tests/config-env.probe.sh, which parses both files.
_SYG_CFG_HARNESS=(
  ANTHROPIC_ADMIN_API_KEY
  CLAUDE_CONFIG_DIR
  CLAUDE_PLUGIN_REGISTRY
  CLAUDE_PROJECTS_DIR
  CLAUDE_SESSION_ARCHIVE
  CLAUDE_VERSIONS_DIR
  SEYAG_KEYS_BIN
  SESSION_LEDGER
)

# _syg_cfg_is_harness <NAME>: is NAME harness-owned (refused everywhere)?
_syg_cfg_is_harness() {
  local n
  for n in "${_SYG_CFG_HARNESS[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# Knobs whose value is a binary seyag invokes, without carrying the _CMD
# suffix: refused from project scope like _CMD (same reason — a repo must not
# choose the executables this machine runs). tests/config-env.probe.sh (o5)
# pins that this list plus the _CMD suffix covers every knobs.tsv user row
# whose description names a binary "invoked by" seyag.
_SYG_CFG_PROJECT_EXEC=(
  SYG_STATUSLINE_ZAI_USAGE
)

# _syg_cfg_in_project_exec <NAME>: is NAME a binary-path knob without the _CMD
# suffix (refused from project scope, settable from user scope)?
_syg_cfg_in_project_exec() {
  local n
  for n in "${_SYG_CFG_PROJECT_EXEC[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# _syg_cfg_valid_path <path>: every dot-separated component is [A-Za-z0-9_-]+
# and non-empty (the accepted bare-key charset; a stray space or quote fails,
# and a trailing dot leaves an empty final component — rejected here).
_syg_cfg_valid_path() {
  local path=$1 comp
  [ -n "$path" ] || return 1
  while [ -n "$path" ]; do
    comp=${path%%.*}
    [[ $comp =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    [ "$comp" = "$path" ] && return 0
    path=${path#*.}
  done
  # Only a trailing dot reaches here (the last component returns above).
  return 1
}

# _syg_cfg_trailing <rest> <key> <file> <lineno>: what follows a complete value
# must be empty or a comment (leading whitespace allowed); anything else is
# unsupported. Prints the warning itself and returns 1 on trailing content.
_syg_cfg_trailing() {
  local rest=$1
  rest=${rest#"${rest%%[![:space:]]*}"}
  case $rest in
    '' | '#'*) return 0 ;;
    *)
      echo "seyag config: $3: line $4: $2: unsupported value: trailing content after the value" >&2
      return 1
      ;;
  esac
}

# _syg_cfg_parse_value <after-equals> <key> <file> <lineno>: sets _SYG_CFG_VAL
# and returns 0, or warns and returns 1. Basic strings decode \\ \" \t \n only;
# any other escape is malformed. Bare values must be one int, float or boolean
# token (true/false export as 1/0); anything else must be quoted.
_syg_cfg_parse_value() {
  local val=$1 key=$2 file=$3 n=$4 c
  _SYG_CFG_VAL=""
  val=${val#"${val%%[![:space:]]*}"}
  case $val in
    '')
      echo "seyag config: $file: line $n: $key: malformed value: missing value" >&2
      return 1
      ;;
    \'\'\'* | \"\"\"*)
      echo "seyag config: $file: line $n: $key: unsupported value: multiline strings are not supported" >&2
      return 1
      ;;
    \{*)
      echo "seyag config: $file: line $n: $key: unsupported value: inline tables are not supported" >&2
      return 1
      ;;
    \[*)
      echo "seyag config: $file: line $n: $key: unsupported value: arrays are not supported" >&2
      return 1
      ;;
    \"*)
      val=${val#\"}
      while [ -n "$val" ]; do
        c=${val:0:1}
        if [ "$c" = '"' ]; then
          val=${val:1}
          _syg_cfg_trailing "$val" "$key" "$file" "$n" || return 1
          return 0
        fi
        if [ "$c" = '\' ]; then
          case ${val:1:1} in
            \\) _SYG_CFG_VAL+='\' ;;
            '"') _SYG_CFG_VAL+='"' ;;
            t) _SYG_CFG_VAL+=$'\t' ;;
            n) _SYG_CFG_VAL+=$'\n' ;;
            *)
              echo "seyag config: $file: line $n: $key: malformed value: unsupported escape" >&2
              return 1
              ;;
          esac
          val=${val:2}
        else
          _SYG_CFG_VAL+=$c
          val=${val:1}
        fi
      done
      echo "seyag config: $file: line $n: $key: malformed value: unterminated string" >&2
      return 1
      ;;
    \'*)
      val=${val#\'}
      case $val in
        *\'*)
          _SYG_CFG_VAL=${val%%\'*}
          _syg_cfg_trailing "${val#*\'}" "$key" "$file" "$n" || return 1
          return 0
          ;;
        *)
          echo "seyag config: $file: line $n: $key: malformed value: unterminated string" >&2
          return 1
          ;;
      esac
      ;;
    *)
      # Bare token: ends at the first whitespace or '#'.
      local tok=$val i
      for ((i = 0; i < ${#val}; i++)); do
        c=${val:i:1}
        if [[ $c == [[:space:]] || $c == '#' ]]; then
          tok=${val:0:i}
          _syg_cfg_trailing "${val:i}" "$key" "$file" "$n" || return 1
          break
        fi
      done
      if [ -z "$tok" ]; then
        echo "seyag config: $file: line $n: $key: malformed value: missing value" >&2
        return 1
      fi
      case $tok in
        true) _SYG_CFG_VAL=1 ;;
        false) _SYG_CFG_VAL=0 ;;
        *)
          if [[ $tok =~ ^-?[0-9]+$ ]] || [[ $tok =~ ^-?[0-9]+\.[0-9]+$ ]]; then
            _SYG_CFG_VAL=$tok
          else
            echo "seyag config: $file: line $n: $key: malformed value: strings and paths must be quoted" >&2
            return 1
          fi
          ;;
      esac
      ;;
  esac
  return 0
}

# _syg_cfg_parse_file <file> <user|project>: one file into _SYG_CFG_MAP (name ->
# value), consulting _SYG_CFG_SETTABLE. Warns per offending line and skips it;
# never returns non-zero, never blocks the caller.
_syg_cfg_parse_file() {
  local file=$1 scope=$2
  local -a lines=()
  if ! [ -r "$file" ] || ! mapfile -t lines 2>/dev/null <"$file"; then
    echo "seyag config: cannot read $file: skipped" >&2
    return 0
  fi
  local -A seen=()
  local -i n=0
  local raw line key val name path comp secpath="" sep disp execknob
  for raw in "${lines[@]}"; do
    n+=1
    line=${raw%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case $line in
      '' | '#'*) continue ;;
      \[*\])
        key=${line#\[}
        key=${key%\]}
        if ! _syg_cfg_valid_path "$key"; then
          echo "seyag config: $file: line $n: [$key]: malformed section: invalid name" >&2
          continue
        fi
        if [ -n "${seen["s:$key"]+x}" ]; then
          echo "seyag config: $file: line $n: [$key]: duplicate section: keys merge, first value per key wins" >&2
        fi
        seen["s:$key"]=1
        secpath=$key
        continue
        ;;
    esac
    case $line in
      *=*) ;;
      *)
        echo "seyag config: $file: line $n: $line: malformed line: expected 'key = value' or a [section] header" >&2
        continue
        ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    if [ -z "$key" ] || ! _syg_cfg_valid_path "$key"; then
      echo "seyag config: $file: line $n: $key: malformed key: invalid name" >&2
      continue
    fi
    # Env name: the whole path (section + dotted key) uppercased, '.' -> '_'.
    path="$secpath${secpath:+.}$key"
    name="" sep=""
    while [ -n "$path" ]; do
      comp=${path%%.*}
      if [ "$comp" = "$path" ]; then path=""; else path=${path#*.}; fi
      name="$name$sep${comp^^}"
      sep=_
    done
    if [ -z "${_SYG_CFG_SETTABLE[$name]+x}" ] || _syg_cfg_is_harness "$name"; then
      disp=$key
      [ -n "$secpath" ] && disp=$secpath.$key
      echo "seyag config: $file: line $n: unknown key '$disp' (not a settable seyag knob; see docs/config.md)" >&2
      continue
    fi
    # Project scope refuses every knob that picks a binary to run: the _CMD
    # suffix class plus the explicit list at the top of this file.
    execknob=0
    case $name in *_CMD) execknob=1 ;; esac
    [ "$execknob" = 0 ] && _syg_cfg_in_project_exec "$name" && execknob=1
    if [ "$scope" = project ] && [ "$execknob" = 1 ]; then
      echo "seyag config: $file: line $n: '$name' cannot be set from project scope (command-execution knob)" >&2
      continue
    fi
    if [ -n "${seen["n:$name"]+x}" ]; then
      echo "seyag config: $file: line $n: $key: duplicate key: first value wins" >&2
      continue
    fi
    if ! _syg_cfg_parse_value "$val" "$key" "$file" "$n"; then
      continue
    fi
    seen["n:$name"]=1
    _SYG_CFG_MAP[$name]=$_SYG_CFG_VAL
  done
  return 0
}

# syg_config_env <plugin_dir>: load the config files, export every mapped knob
# whose env name is unset. Fork-free on the happy path (mapfile and read only).
syg_config_env() {
  local plugin_dir=$1
  [ "${SYG_CONFIG:-}" = 0 ] && return 0

  # With neither XDG_CONFIG_HOME nor HOME set there is no user file (a blank
  # base must not decay to "/seyag/config.toml" at the filesystem root).
  local ufile=""
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then ufile=$XDG_CONFIG_HOME/seyag/config.toml
  elif [ -n "${HOME:-}" ]; then ufile=$HOME/.config/seyag/config.toml; fi
  local pfile=${CLAUDE_PROJECT_DIR:-$PWD}/.claude/seyag.toml
  # The hot path: with neither file present nothing is read and nothing printed.
  { [ -f "$ufile" ] || [ -f "$pfile" ]; } || return 0

  local knobs=$plugin_dir/config/knobs.tsv
  local -a rows=()
  if ! [ -r "$knobs" ] || ! mapfile -t rows 2>/dev/null <"$knobs"; then
    echo "seyag config: cannot read $knobs: skipped" >&2
    return 0
  fi
  declare -gA _SYG_CFG_SETTABLE=()
  local row name scope rest
  for row in "${rows[@]}"; do
    row=${row%$'\r'}
    # Split by expansion, not a here-string read: one per row, per hook call.
    # A tab-less row keeps its whole text as the scope (never "user" alone,
    # guarded below), so it stays skipped exactly as before.
    case $row in *$'\t'*) ;; *) continue ;; esac
    name=${row%%$'\t'*}
    rest=${row#*$'\t'}
    scope=${rest%%$'\t'*}
    [ "$scope" = user ] || continue
    case $name in '' | '#'*) continue ;; esac
    _SYG_CFG_SETTABLE[$name]=1
  done

  declare -gA _SYG_CFG_MAP=()
  [ -f "$ufile" ] && _syg_cfg_parse_file "$ufile" user
  [ -f "$pfile" ] && _syg_cfg_parse_file "$pfile" project
  for name in "${!_SYG_CFG_MAP[@]}"; do
    if [[ -z ${!name+x} ]]; then
      export "$name=${_SYG_CFG_MAP[$name]}"
    fi
  done
  return 0
}
