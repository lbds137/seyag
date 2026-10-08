#!/bin/bash
# Stop and SessionEnd hook (seyag plugin): records a metered session's API spend.
#
# Opt-in: inert until SYG_CREDIT_LEDGER names a ledger file. Then
# `api-credit hook` reads this event's session_id and transcript_path, recomputes
# that session's spend from its transcripts (subagents included; token counts
# exact per request and per model, cost an estimate at the price table's rates,
# with the gaps bin/api-credit names) and upserts its ledger entries, when the route rule
# matches (SYG_CREDIT_WHEN, else the metered API-key test; see bin/api-credit).
# It fires in headless `claude -p` runs too, which render no statusline, so this
# hook, not the statusline, is what records.
#
# Never blocks: `api-credit hook` exits 0 even when recording fails. stdout
# stays empty (a Stop hook's stdout must), stderr carries a one-line note.

[ -n "${SYG_CREDIT_LEDGER:-}" ] || exit 0
# Cheap route pre-filter in bash, so a non-metered session never starts python at
# a turn end. It mirrors api-credit's route_matches; python still runs the full
# check (the base-URL host test included).
if [ "${SYG_CREDIT_FORCE:-}" != 1 ]; then
  if [ -n "${SYG_CREDIT_WHEN:-}" ]; then
    [[ "$SYG_CREDIT_WHEN" == *=* ]] || exit 0
    cw_name=${SYG_CREDIT_WHEN%%=*} cw_value=${SYG_CREDIT_WHEN#*=}
    [[ "$cw_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 0
    [ -n "${!cw_name+x}" ] && [ "${!cw_name-}" = "$cw_value" ] || exit 0
  else
    [ -n "${ANTHROPIC_API_KEY:-}" ] || exit 0
  fi
fi
exec python3 "$(dirname "${BASH_SOURCE[0]}")/../bin/api-credit" hook >/dev/null
