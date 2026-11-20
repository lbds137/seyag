---
id: TASK-4
title: 'python bins: shared config loader mirroring hooks/lib/config-env.sh'
status: Done
assignee:
  - seyag-a
created_date: '2026-11-19T14:22:00Z'
updated_date: '2026-11-20T03:41:00Z'
labels:
  - bin
  - skills
dependencies: []
priority: high
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Python bins never load the config file, so scope=user knobs set there are ignored by them
(e.g. a knob honoured by one bin is not honoured by the relay/usage bins). Add a shared
python loader mirroring the shell loader's behavior (precedence, refusals, warnings) and
adopt it in every python bin; drop the "environment only" notes earlier units added to their
docs.

Ride-alongs on the same unit (same files/class):
- session-log folds: malformed agent entries (null/missing session id, null pid, glob
  chars), session-context phantom `[null]` row, empty workspace uri merge case.
- pyiso fixes: `python3 -I` without `-B` writes bytecode caches (PYTHONDONTWRITEBYTECODE does
  not stop it); the lint checks only `-I` (misses `-Bc -uc -Xutf8 -Wignore:: -B<<` and the
  unspaced `-X utf8` form); the Part C bytecode check is vacuous when a cache dir pre-exists;
  a changelog-format probe uses a GNU-sed-only address form (low: CI and the dev machine are
  GNU).

**Disposition (2026-11-20): shipped** - PR #354, merged 2446ff9 as 0.3.194: the loader twin
(lib/config_env.py) adopted by all 17 python bins, the project-secure knob class (owner
ruling), review-r1 fixes (NUL parity, loud garbage alarms), the pyiso/sessionlog ride-alongs,
the (w) parity battery, red-first proven. Ride-alongs carried; deferences honored
(sess-F2/F5a/F5b, pyiso -j race). cfg2b filed as TASK-42.
<!-- SECTION:DESCRIPTION:END -->
