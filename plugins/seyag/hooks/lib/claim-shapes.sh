# shellcheck shell=bash
# Shared claim-shape vocabulary, sourced (not executed) by the hook that
# scans prose for claim-shaped lines: pr-merge-review-check.sh reads the
# comment lines a diff ADDS. A change here changes every scan that sources
# this file, and the consumer's probe is the test for its half. The file
# carries only what this hook consumes; a future consumer (the queued
# PR-body scan port) adds its own vocabulary with its own tests.
#
# CLAIM_SHAPE_CORE_REGEX: certainty/provenance/counted-noun vocabulary common
# to every scanning surface. Every alternative is `\b`-anchored so ordinary
# prose like "whenever" or "spread from" doesn't light the banner (GNU grep
# -E honours `\b` in an ERE; awk and several other ERE engines do not, so
# keep the anchors if this ever moves to another engine).
# shellcheck disable=SC2034  # a sourced vocabulary file: consumers read these by name
CLAIM_SHAPE_CORE_REGEX='\balways\b|\bnever\b|\bcannot\b|\bguaranteed\b|\bonly (place|path|caller|writer|reader)\b|\bcomes? from\b|\bderived from\b|\bpopulated (by|from)\b|\bread from\b|\bwritten (only )?by\b|\b(both|all|the) [0-9]+ |\b[0-9]+ (call sites?|tests?|files?|instances?|copies|callers?|places)\b'
