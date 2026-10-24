# shellcheck shell=bash
# Shared claim-shape vocabulary, sourced (not executed) by the hooks that
# scan prose for claim-shaped lines: pr-merge-review-check.sh reads the
# comment lines a diff ADDS. A change here changes every scan that sources
# this file — each hook's probe is the test for its half.
#
# CLAIM_SHAPE_CORE_REGEX: certainty/provenance/counted-noun vocabulary common
# to every scanning surface. Every alternative is `\b`-anchored so ordinary
# prose like "whenever" or "spread from" doesn't light the banner (GNU grep
# -E honours `\b` in an ERE; awk and several other ERE engines do not, so
# keep the anchors if this ever moves to another engine).
#
# CLAIM_SHAPE_PR_BODY_EXTRA_REGEX: additions that only make sense in a PR
# body — a closing reference (a hash-prefixed or KEY-prefixed number after "closes") and vocabulary
# ("every caller", "verified") that reads as a claim in a body's prose even
# though it wouldn't necessarily read that way as a code comment.
#
# CLAIM_CITE_EXEMPT_REGEX: a line matching either shape above is NOT flagged
# when it also carries its own evidence (a backticked path, file:line, URL,
# or command) or its own hedge (an explicit unverified/hypothesis marker).
# shellcheck disable=SC2034  # a sourced vocabulary file: consumers read these by name
CLAIM_SHAPE_CORE_REGEX='\balways\b|\bnever\b|\bcannot\b|\bguaranteed\b|\bonly (place|path|caller|writer|reader)\b|\bcomes? from\b|\bderived from\b|\bpopulated (by|from)\b|\bread from\b|\bwritten (only )?by\b|\b(both|all|the) [0-9]+ |\b[0-9]+ (call sites?|tests?|files?|instances?|copies|callers?|places)\b'

# shellcheck disable=SC2034
CLAIM_SHAPE_PR_BODY_EXTRA_REGEX='\bevery (call ?sites?|callers?|files?|modules?|tests?|consumers?|paths?)\b|\bcloses?:? (#[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+)\b|\b(verified|confirmed|measured)\b'

# shellcheck disable=SC2034
CLAIM_CITE_EXEMPT_REGEX='`[^`]*[/:][^`]*`|`(pnpm|git|grep|npx|gh|rg|node|npm|yarn|curl|docker|bash|sh|make|python[0-9.]*) [^`]*`|unverified|not verified|not runtime-confirmed|code-read|hypothesis'
