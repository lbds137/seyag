---
name: versioning
description: 'Release mechanics for a versioned project: the merge PR carries the version bump and the release notes. Use when a merge is about to land in a project that versions, when asked to bump, cut a release or write the changelog/release notes, or when a version-scheme or notes-format question comes up.'
---

# Versioning

In a project that versions, the session driving a merge bumps the version and lands the release notes in the same PR (core rules § Driving the work). This skill is the how.

## Defer to the project

The project's CLAUDE.md names its version file (`plugin.json`, `package.json`, `manifest.json`, ...) and where notes land (`CHANGELOG.md` or the release PR body). Unnamed → ask the owner; do not guess. If the notes file already carries a format preamble, the preamble wins over everything below.

## Version scheme

- Pre-1.0: patch per merged batch, minor per behavior change.
- Post-1.0: semver — breaking → major, behavior → minor, fixes → patch.

## Notes format

One `## <version> - <YYYY-MM-DD>` section per release, newest first. Under it, `###` categories in this fixed order, empty ones omitted: Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests. Items are `- **scope:** description (#PR)`. Add a compare link when the forge has one.

## Source of truth

Write items from the batch's merged commit subjects, never from memory:

```bash
git log --format='%s' <prev-release-base>..<merge-sha>
```

## Two-theme cut

Notes spanning more than two themes read as a grab-bag: propose splitting the batch instead of writing one.

## Floor checklist

A bump that changes any field besides the version — a minimum host version, `engines`, permissions — is a compatibility-floor claim: it cites the probe that verified the floor (core rules § Evidence). No probe, no floor bump.
