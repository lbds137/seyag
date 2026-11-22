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
# name is a scope=user row of <plugin_dir>/config/knobs.tsv, does not carry the
# `envonly` flag in the 6th `flags` column (refused from both user and project
# config files), and is not one of the harness-owned names below (Claude Code
# or the machine reads those before seyag runs; a config file must not fake
# them). Everything else is an unknown key.
#
# Accepted subset, per line: blank, full-line `#` comment, `[section]` / `[a.b]`
# header, or `key = value` with a quoted string (basic `"`, escapes \\ \" \t \n
# only, or literal `'`, no escapes), an integer, a float, or true/false (exported
# as 1/0). Strings and paths must be quoted; arrays, inline tables, multiline
# strings and trailing content after the value are unsupported. After a
# multiline-string (`"""`/`'''`) opener warning, the body lines are skipped
# until a line containing the closing delimiter. An invalid `[section]` header
# warns and closes the active section (resetting it to top-level); warnings name
# file and line; file content is never echoed; name text is bounded (40
# characters). A symlinked project file gets content-free warnings (its bytes
# are not the repo author's). Each offending
# line warns once on stderr and is skipped: a bad file never blocks a hook or a
# bin, and because the loader runs per call, a bad file warns on every call (loud
# beats silent). Duplicate keys warn (first value wins); duplicate sections
# warn too, and their keys merge (again first value per key). Names ending
# _CMD, and the binary-path knobs in _SYG_CFG_PROJECT_EXEC below, cannot be
# set from the project file (a repo must not choose the executables this
# machine runs), the security-material knobs in _SYG_CFG_PROJECT_SECURE below
# cannot be set from the project file (a repo must not weaken the credential
# store — --with-key downgrades TPM binding, --name can break decrypt — or fake
# the token and route labels its spend is billed and audited by), and rows
# carrying `path` in knobs.tsv's 6th `flags` column cannot be set from the
# project file (a repo must not aim seyag at arbitrary filesystem paths).
# SYG_CONFIG=0 disables the loader entirely.

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

# Credential-store, billing/lane and worktree-cleanup judgment knobs (the keys
# store's --name and --with-key; the z.ai bearer token; the credit route-match
# rule and ledger label; worktree-cleanup judgment knobs and the worktree
# auto-removal set, because a repo must not decide what the cleaner deletes
# without approval): refused from project scope, settable from user scope — a
# repo must not weaken the credential store (--with-key downgrades TPM binding,
# --name can break decrypt), fake the token and route labels its spend is
# billed and audited by, or decide what the cleaner deletes without approval.
# Kept equal to _PROJECT_SECURE in lib/config_env.py by
# tests/config-env.probe.sh (w).
_SYG_CFG_PROJECT_SECURE=(
  SYG_KEYS_NAME
  SYG_KEYS_WITH_KEY
  ZAI_AUTH_TOKEN
  SYG_CREDIT_WHEN
  SYG_CREDIT_ROUTE
  SYG_WORKTREE_BRANCH_RE
  SYG_WORKTREE_LOCK_AGE_MIN
  SYG_WORKTREE_BACKUP_ALLOW_VOLATILE
  SYG_WORKTREE_REGENERABLE
  SYG_WORKTREE_BASE
  SYG_WORKTREE_ELIGIBLE_REASONS
)

# _syg_cfg_in_project_secure <NAME>: is NAME a security-material knob (refused
# from project scope, settable from user scope)?
_syg_cfg_in_project_secure() {
  local n
  for n in "${_SYG_CFG_PROJECT_SECURE[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

# _syg_cfg_valid_path <path>: every dot-separated component is [A-Za-z0-9_-]+
# and non-empty (the accepted bare-key charset; rejects empty, leading/trailing
# dot, and bad chars such as a stray space or quote in one O(n) match).
_syg_cfg_valid_path() {
  [[ $1 =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$ ]]
}

# _syg_cfg_disp <text>: sanitize name text for stderr warnings into $disp —
# truncate to the first 40 characters (appending "..." when truncated), then
# strip control characters.
# Echoed names are chosen by the file's author and leak nothing new; echoed content may come from a symlinked foreign file, so it is never echoed.
_syg_cfg_disp() {
  if [ "${#1}" -gt 40 ]; then
    disp="${1:0:40}..."
  else
    disp=$1
  fi
  disp=${disp//[[:cntrl:]]/}
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
  local val=$1 key=$2 file=$3 n=$4 c chunk disp
  _syg_cfg_disp "$key"
  key=$disp
  _SYG_CFG_VAL=""
  # Leading whitespace matters (after "key =" the value usually starts with a
  # space); gate the glob on the first character so long values pay it only
  # when an edge is actually whitespace.
  case ${1:0:1} in [[:space:]]*) val=${val#"${val%%[![:space:]]*}"} ;; esac
  case $val in
    '')
      echo "seyag config: $file: line $n: $key: malformed value: missing value" >&2
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
      # Chunk-wise decode: split at the next quote or backslash. A regex finds
      # it and the literal-strip cuts at it; the bracket-glob form
      # (${val%%[\"\\]*}) costs O(n) per call with a brutal constant
      # (973 ms on a 200 KB value, vs 4 ms here) and made every hook call
      # seconds slow on one long value.
      local __re='"|\\'
      while [ -n "$val" ]; do
        if ! [[ $val =~ $__re ]]; then
          _SYG_CFG_VAL+=$val
          break
        fi
        chunk=${val%%"${BASH_REMATCH[0]}"*}
        if [ -n "$chunk" ]; then
          _SYG_CFG_VAL+=$chunk
          val=${val:${#chunk}}
          [ -n "$val" ] || break
        fi
        c=${val:0:1}
        if [ "$c" = '"' ]; then
          val=${val:1}
          _syg_cfg_trailing "$val" "$key" "$file" "$n" || return 1
          return 0
        fi
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
          elif [[ $tok =~ ^[+-]?[0-9][0-9a-zA-Z_.+-]*$ ]]; then
            echo "seyag config: $file: line $n: $key: unsupported value: number form not supported (use plain digits or a quoted string)" >&2
            return 1
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

# _syg_cfg_parse_file <file> <user|project> [foreign]: one file into
# _SYG_CFG_MAP (name -> value), consulting _SYG_CFG_SETTABLE, _SYG_CFG_ENVONLY
# and _SYG_CFG_PATH. Warns per offending line and skips it; never returns
# non-zero, never blocks the caller.
_syg_cfg_parse_file() {
  local file=$1 scope=$2 foreign=${3:-0}
  local -a lines=()
  if ! [ -r "$file" ] || ! mapfile -t lines 2>/dev/null <"$file"; then
    echo "seyag config: cannot read $file: skipped" >&2
    return 0
  fi
  local -A seen=()
  local -i n=0
  local raw line key dkey val name path secpath="" disp execknob skip_delim="" vstrip vrest
  for raw in "${lines[@]}"; do
    n+=1
    line=${raw%$'\r'}
    if [ -n "$skip_delim" ]; then
      case $line in *"$skip_delim"*) skip_delim="" ;; esac
      continue
    fi
    # Trim edge whitespace only when the edge actually has some: the trim globs
    # cost milliseconds on a very long line even when nothing is trimmed.
    case ${line:0:1} in [[:space:]]*) line=${line#"${line%%[![:space:]]*}"} ;; esac
    case ${line: -1} in [[:space:]]) line=${line%"${line##*[![:space:]]}"} ;; esac
    case $line in
      '' | '#'*) continue ;;
      \[*\])
        key=${line#\[}
        key=${key%\]}
        if ! _syg_cfg_valid_path "$key"; then
          echo "seyag config: $file: line $n: malformed section: invalid name" >&2
          secpath=""
          continue
        fi
        if [ -n "${seen["s:$key"]+x}" ]; then
          if [ "$foreign" != 0 ]; then
            echo "seyag config: $file: line $n: duplicate section: keys merge, first value per key wins" >&2
          else
            _syg_cfg_disp "$key"
            echo "seyag config: $file: line $n: [$disp]: duplicate section: keys merge, first value per key wins" >&2
          fi
        fi
        seen["s:$key"]=1
        secpath=$key
        continue
        ;;
    esac
    case $line in
      *=*) ;;
      *)
        echo "seyag config: $file: line $n: malformed line: expected 'key = value' or a [section] header" >&2
        continue
        ;;
    esac
    key=${line%%=*}
    key=${key%"${key##*[![:space:]]}"}
    val=${line#*=}
    vstrip=${val#"${val%%[![:space:]]*}"}
    case $vstrip in
      \"\"\"* | \'\'\'*)
        skip_delim=${vstrip:0:3}
        vrest=${vstrip:3}
        case $vrest in *"$skip_delim"*) skip_delim="" ;; esac
        if [ "$foreign" != 0 ]; then
          echo "seyag config: $file: line $n: unsupported value: multiline strings are not supported" >&2
        else
          _syg_cfg_disp "$key"
          echo "seyag config: $file: line $n: $disp: unsupported value: multiline strings are not supported" >&2
        fi
        continue
        ;;
    esac
    if [ -z "$key" ] || ! _syg_cfg_valid_path "$key"; then
      echo "seyag config: $file: line $n: malformed key: invalid name" >&2
      continue
    fi
    # Env name: the whole path (section + dotted key) uppercased, '.' -> '_'.
    path="$secpath${secpath:+.}$key"
    name=${path//./_}
    name=${name^^}
    if _syg_cfg_is_harness "$name"; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: unknown key (not a settable seyag knob; see docs/config.md)" >&2
      else
        _syg_cfg_disp "$path"
        echo "seyag config: $file: line $n: unknown key '$disp' (not a settable seyag knob; see docs/config.md)" >&2
      fi
      continue
    fi
    if [ -n "${_SYG_CFG_ENVONLY[$name]+x}" ]; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: a knob is environment only (not settable from a config file)" >&2
      else
        _syg_cfg_disp "$name"
        echo "seyag config: $file: line $n: '$disp' is environment only (not settable from a config file)" >&2
      fi
      continue
    fi
    if [ -z "${_SYG_CFG_SETTABLE[$name]+x}" ]; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: unknown key (not a settable seyag knob; see docs/config.md)" >&2
      else
        _syg_cfg_disp "$path"
        echo "seyag config: $file: line $n: unknown key '$disp' (not a settable seyag knob; see docs/config.md)" >&2
      fi
      continue
    fi
    # Project scope refuses every knob that picks a binary to run: the _CMD
    # suffix class plus the explicit list at the top of this file, followed by
    # any knob carrying the 'path' flag in knobs.tsv.
    execknob=0
    case $name in *_CMD) execknob=1 ;; esac
    [ "$execknob" = 0 ] && _syg_cfg_in_project_exec "$name" && execknob=1
    if [ "$scope" = project ] && [ "$execknob" = 1 ]; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: a knob cannot be set from project scope (command-execution knob)" >&2
      else
        _syg_cfg_disp "$name"
        echo "seyag config: $file: line $n: '$disp' cannot be set from project scope (command-execution knob)" >&2
      fi
      continue
    fi
    if [ "$scope" = project ] && _syg_cfg_in_project_secure "$name"; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: a knob cannot be set from project scope (security-material knob)" >&2
      else
        _syg_cfg_disp "$name"
        echo "seyag config: $file: line $n: '$disp' cannot be set from project scope (security-material knob)" >&2
      fi
      continue
    fi
    if [ "$scope" = project ] && [ -n "${_SYG_CFG_PATH[$name]+x}" ]; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: a knob cannot be set from project scope (path knob)" >&2
      else
        _syg_cfg_disp "$name"
        echo "seyag config: $file: line $n: '$disp' cannot be set from project scope (path knob)" >&2
      fi
      continue
    fi
    if [ -n "${seen["n:$name"]+x}" ]; then
      if [ "$foreign" != 0 ]; then
        echo "seyag config: $file: line $n: duplicate key: first value wins" >&2
      else
        _syg_cfg_disp "$key"
        echo "seyag config: $file: line $n: $disp: duplicate key: first value wins" >&2
      fi
      continue
    fi
    dkey=$key
    [ "$foreign" != 0 ] && dkey=key
    if ! _syg_cfg_parse_value "$val" "$dkey" "$file" "$n"; then
      continue
    fi
    seen["n:$name"]=1
    _SYG_CFG_MAP[$name]=$_SYG_CFG_VAL
  done
  if [ -n "$skip_delim" ]; then
    echo "seyag config: $file: line $n: unterminated multiline string: rest of file skipped" >&2
  fi
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
  local pdir=${CLAUDE_PROJECT_DIR:-$PWD}
  local pfile=$pdir/.claude/seyag.toml
  # The hot path: with neither file present nothing is read and nothing printed.
  { [ -f "$ufile" ] || [ -f "$pfile" ]; } || return 0

  local knobs=$plugin_dir/config/knobs.tsv
  local -a rows=()
  if ! [ -r "$knobs" ] || ! mapfile -t rows 2>/dev/null <"$knobs"; then
    echo "seyag config: cannot read $knobs: skipped" >&2
    return 0
  fi
  declare -gA _SYG_CFG_SETTABLE=()
  declare -gA _SYG_CFG_ENVONLY=()
  declare -gA _SYG_CFG_PATH=()
  local -i n=0
  local row stripped name scope rest flags
  for row in "${rows[@]}"; do
    n+=1
    row=${row%$'\r'}
    stripped=${row#"${row%%[![:space:]]*}"}
    case $stripped in '' | '#'*) continue ;; esac
    # Split by expansion, not a here-string read: one per row, per hook call.
    case $row in
      *$'\t'*) ;;
      *)
        echo "seyag config: $knobs: line $n: malformed row: skipped" >&2
        continue
        ;;
    esac
    name=${row%%$'\t'*}
    rest=${row#*$'\t'}
    scope=${rest%%$'\t'*}
    [ "$scope" = user ] || continue
    case $name in '' | '#'*) continue ;; esac
    flags=""
    case $rest in
      *$'\t'*$'\t'*$'\t'*$'\t'*)
        rest=${rest#*$'\t'}
        rest=${rest#*$'\t'}
        rest=${rest#*$'\t'}
        flags=${rest#*$'\t'}
        flags=${flags%%$'\t'*}
        ;;
      *$'\t'*$'\t'*$'\t'*)
        echo "seyag config: $knobs: line $n: $name: no flags column: path/envonly refusals disabled for this row" >&2
        ;;
    esac
    case " $flags " in *" path "*) _SYG_CFG_PATH[$name]=1 ;; esac
    case " $flags " in
      *" envonly "*) _SYG_CFG_ENVONLY[$name]=1 ;;
      *) _SYG_CFG_SETTABLE[$name]=1 ;;
    esac
  done

  local foreign=0 rpfile rpdir
  [ -L "$pfile" ] && foreign=1
  if [ "$foreign" = 0 ] && [ -f "$pfile" ]; then
    if ! rpfile=$(realpath "$pfile" 2>/dev/null) || ! rpdir=$(realpath "$pdir" 2>/dev/null); then
      foreign=1
    else
      case $rpfile in
        "$rpdir"/*) ;;
        *) foreign=1 ;;
      esac
    fi
  fi
  declare -gA _SYG_CFG_MAP=()
  [ -f "$ufile" ] && _syg_cfg_parse_file "$ufile" user 0
  [ -f "$pfile" ] && _syg_cfg_parse_file "$pfile" project "$foreign"
  for name in "${!_SYG_CFG_MAP[@]}"; do
    if [[ -z ${!name+x} ]]; then
      export "$name=${_SYG_CFG_MAP[$name]}"
    fi
  done
  return 0
}
