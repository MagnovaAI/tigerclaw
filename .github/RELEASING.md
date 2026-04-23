# Releasing

This project ships binaries on tag push. The pipeline is defined in
`.github/workflows/release.yml`.

## Cutting a release

1. Update `CHANGELOG.md`: add a new `## [X.Y.Z] — YYYY-MM-DD` section
   that describes the diff since the previous tag. The release
   workflow extracts this section verbatim and uses it as the GitHub
   release body, so write it for end users.
2. Commit the CHANGELOG change.
3. Tag:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   ```
4. Push:
   ```sh
   git push origin main
   git push origin vX.Y.Z
   ```
5. The release workflow runs automatically. Watch
   <https://github.com/OWNER/tigerclaw/actions>.

## What the workflow produces

- Cross-compiled binaries for `darwin-arm64`, `darwin-x86_64`,
  `linux-x86_64`, and `linux-aarch64`, built with
  `-Doptimize=ReleaseSmall`.
- A `.sha256` checksum file alongside each binary so consumers
  (including `scripts/install.sh`) can verify the download.
- A GitHub release named `tigerclaw vX.Y.Z` with the matching
  CHANGELOG section as the body and the binaries + checksums attached
  as assets.

The job fails loudly if `CHANGELOG.md` has no section for the tagged
version — there is no silent fallback, so an unreleased tag cannot
ship without release notes.

## Rolling back

If a release goes out broken:

1. Delete the GitHub release in the UI (Releases → ⋯ → Delete).
2. Delete the tag locally and on origin:
   ```sh
   git tag -d vX.Y.Z
   git push origin :refs/tags/vX.Y.Z
   ```
3. Fix the issue, bump the patch number, cut a new release.

Do not force-push a tag to a new commit. Consumers cache release
artifacts by tag and a silently-moved tag ships a confusing upgrade
experience; a fresh patch version is always the right answer.

## Signing

v0.1.0 releases ship `.sha256` checksums only. Apple Developer ID
signing and notarization of the `darwin-*` binaries are deliberately
out of scope for the first release; ops operators verify integrity
via the checksum file.
