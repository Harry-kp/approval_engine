# Releasing

Releases are automated. Pushing a version tag builds the gem, publishes it to
RubyGems, and cuts a GitHub release — see `.github/workflows/release.yml`.

## One-time setup

Configure this repo as a **trusted publisher** for the gem (no API key needed):

1. Reserve the name with a first manual push, or create the gem page.
2. On RubyGems → the gem → **Trusted Publishers** → add a GitHub Actions
   publisher: repository `Harry-kp/approval_engine`, workflow `release.yml`,
   environment `release`.
3. (Recommended) In GitHub → Settings → Environments, create a `release`
   environment with required reviewers so a publish can't happen accidentally.

> Prefer an API key instead? Drop the trusted-publishing step and add
> `RUBYGEMS_API_KEY` as a secret, then `gem push` in the workflow.

## Cutting a release

1. Update `lib/approval_engine/version.rb`.
2. Add a `## [x.y.z] - YYYY-MM-DD` section to `CHANGELOG.md`, directly above the
   previous release, plus a matching `[x.y.z]: .../releases/tag/vX.Y.Z` link
   reference at the bottom of the file (`test/docs_test.rb` fails the build if a
   version heading has no link reference). This file keeps no `[Unreleased]`
   section: notes are written under their version when the release is cut.

   The date must be the day you push the tag. `release.yml` fires on `v*` and
   publishes within seconds, so a stale date is public before you notice and can
   only be corrected by another commit.
3. Commit, then tag and push:

   ```sh
   git commit -am "Release vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```

The `Release` workflow does the rest. Verify the gem appears on RubyGems and the
GitHub release was created.

## Manual fallback

```sh
bundle exec rake build     # => pkg/approval_engine-X.Y.Z.gem
bundle exec rake release   # tags, pushes, and publishes (needs gem credentials)
```
