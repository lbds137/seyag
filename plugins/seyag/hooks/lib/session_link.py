"""The Claude session-link pattern: one copy, shared by hooks/session-url-gate.sh
(the text guard) and git-hooks/pre-push (the enforcement on the bytes git
sends).

SECRET: `claude.ai/code/session_` followed by an id character [A-Za-z0-9]
(host part case-insensitive, the rest case-sensitive), so prose naming the
bare prefix followed by a space, backtick or quote does not match. `mask`
replaces the id of every link with `…`; the full link is never echoed.

No top-level side effects: importing this module runs nothing.
"""

import re

SECRET = re.compile(r"(?i:claude\.ai)/code/session_[A-Za-z0-9]")
MASK = re.compile(r"(?i:claude\.ai)/code/session_[A-Za-z0-9_-]*")


def mask(text):
    return MASK.sub("claude.ai/code/session_…", text)
