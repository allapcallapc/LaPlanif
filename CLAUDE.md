# CLAUDE.md

Guidance for Claude Code when working in this repository.

## PR titles must follow Conventional Commits

Releases are automated by [release-please](https://github.com/googleapis/release-please-action) (`.github/workflows/release-please.yml`), which decides the next version and writes the changelog by parsing commit messages - specifically the PR title, since PRs are squash-merged into a single commit.

Every PR title must start with one of:

- `fix: ...` - bug fix, bumps the patch version (0.1.0 -> 0.1.1)
- `feat: ...` - new feature, bumps the minor version (0.1.0 -> 0.2.0)
- `feat!: ...` or `fix!: ...` - breaking change, bumps the major version (0.1.0 -> 1.0.0)
- `chore: ...`, `refactor: ...`, `docs: ...`, `test: ...`, `ci: ...` - no version bump, but still recorded

A PR title without one of these prefixes won't be picked up by release-please at all - the change merges normally but is invisible to the changelog/version bump.

## Release flow

1. Merging a correctly-titled PR updates release-please's running "Release PR" (changelog + next version).
2. Merging that Release PR is the only manual release step: it creates the release (published immediately - `draft: false` in `release-please-config.json`, unlike SplitBalance which drafts until an APK is attached), which triggers `deploy.yml` to deploy the web build to GitHub Pages.
3. Do not create GitHub Releases manually via the UI, and do not push tags directly - either bypasses release-please's version tracking and can conflict with GitHub's immutable-releases restriction (once a tag name has been used by a published release, it can never have a release re-attached to it, even if that release is deleted).

## Current scope: web only

This app currently only targets Flutter web - there's no Android/iOS build or release pipeline yet (no `release-apk.yml`, no signing secrets). If/when a mobile build is added, mirror `SplitBalance`'s `release-apk.yml` + `.github/actions/generate-app-icons` pattern and switch `release-please-config.json` back to `draft: true` so the APK can be attached before the release publishes.
