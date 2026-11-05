---
name: versioning
description: 'Release mechanics for a versioned project: the PR that completes the batch carries the version bump and the release notes. Use when a merge is about to land in a project that versions, when asked to bump, cut a release or write the changelog/release notes, or when a version-scheme or notes-format question comes up.'
---

# Versioning

In a project that versions, the session driving a merge bumps the version and lands the release notes in the PR that completes the batch (core rules § Driving the work). This skill is the how. For a multi-PR batch, one bump per batch: the completing PR — or a dedicated release PR — carries both.

## Defer to the project

The project's CLAUDE.md names its version file (`plugin.json`, `package.json`, `manifest.json`, ...) and where notes land (`CHANGELOG.md` or the release PR body); it may also pin the version scheme. Unnamed → ask the owner; do not guess. If the notes file already carries a format preamble, the preamble wins over everything below.

## Version scheme

- Pre-1.0: patch per merged batch.
- Post-1.0: semver — breaking → major, behavior → minor, fixes → patch.

## Notes format

One `## <version> - <YYYY-MM-DD>` section per release, newest first. Under it, `###` categories in this fixed order, empty ones omitted: Breaking Changes, Features, Bug Fixes, Improvements, Chores, Tests. Items are `- **scope:** description (#PR)`. Add a compare link when the forge has one.

## Source of truth

Write items from the batch's commit subjects, never from memory — the range is `<prev-release-base>..HEAD` on the PR branch, written before the merge lands:

```bash
git log --format='%s' <prev-release-base>..HEAD
```

Collapse review-round fixups into their parent item: one notes item per user-facing change.

## Two-theme cut

Notes spanning more than two themes read as a grab-bag: propose splitting the batch instead of writing one.

## Floor checklist

A bump that changes a compatibility field — a minimum host version, `engines`, permissions — is a compatibility-floor claim: it cites the probe that verified the floor (core rules § Evidence and claims). No probe, no floor bump.
