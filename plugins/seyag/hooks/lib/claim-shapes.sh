# shellcheck shell=bash
# shellcheck disable=SC2034  # a sourced vocabulary file: consumers read these by name
# Shared claim-shape vocabulary, sourced (not executed) by two hooks:
# pr-merge-review-check.sh (scans comment lines a diff ADDS) and
# pr-body-ref-gate.sh (scans a PR body's lines). A change here changes BOTH
# scans — each hook's own probe is the test for its half.
#
# CLAIM_SHAPE_CORE_REGEX: certainty/provenance/counted-noun vocabulary common
# to every scanning surface. Every alternative is `\b`-anchored so ordinary
# prose like "whenever" or "spread from" doesn't light the banner (GNU grep
# -E honours `\b` in an ERE; awk and several other ERE engines do not, so
# keep the anchors if this ever moves to another engine).
#
# CLAIM_SHAPE_PR_BODY_EXTRA_REGEX: additions that only make sense in a PR
# body — a closing reference ("closes TASK-N") and vocabulary
# ("every caller", "verified") that reads as a claim in a body's prose even
# though it wouldn't necessarily read that way as a code comment.
#
# CLAIM_CITE_EXEMPT_REGEX: a line matching either shape above is NOT flagged
# when it also carries its own evidence (a backticked path, file:line, URL,
# or command) or its own hedge (an explicit unverified/hypothesis marker).
CLAIM_SHAPE_CORE_REGEX='\balways\b|\bnever\b|\bcannot\b|\bguaranteed\b|\bonly (place|path|caller|writer|reader)\b|\bcomes? from\b|\bderived from\b|\bpopulated (by|from)\b|\bread from\b|\bwritten (only )?by\b|\b(both|all|the) [0-9]+ |\b[0-9]+ (call sites?|tests?|files?|instances?|copies|callers?|places)\b'

CLAIM_SHAPE_PR_BODY_EXTRA_REGEX='\bevery (call ?sites?|callers?|files?|modules?|tests?|consumers?|paths?)\b|\bcloses?:? (TASK|doc)-[0-9]+|\b(verified|confirmed|measured)\b'

CLAIM_CITE_EXEMPT_REGEX='`[^`]*[/:][^`]*`|`(pnpm|git|grep|npx|gh|rg|node|npm|yarn|curl|docker|bash|sh|make|python[0-9.]*) [^`]*`|unverified|not verified|not runtime-confirmed|code-read|hypothesis'
