# Publishing and releases

The repository is ready for GitHub but contains no personal remote URL, owner,
email or signing secrets. Version 2.6.0 is recorded in Info.plist. The prepared
local repository has one clean initial commit and an annotated `v2.6.0` tag.

## First publication

1. Create an empty GitHub repository, for example `claudeway`.
2. Enable Actions and private vulnerability reporting. Review repository visibility
   and branch-protection settings before sharing it.
3. In the prepared local checkout, add **your own** repository as `origin` and push:

```sh
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
git push origin v2.6.0
```

Replace OWNER/REPOSITORY with the repository you created. These commands publish
source and trigger the release workflow; preparation alone does not run them.
Do not publish the older personal-development folder or its old ZIPs.

CI runs the synthetic suite and native build on Apple Silicon and Intel runners.
The tag workflow packages a universal app and a Git source export, scans both,
computes SHA-256 checksums and creates a **draft** release. Its publishing job has
write access; build/test jobs have read access. Actions are pinned to commit SHAs
and checkout does not persist credentials. No Apple signing credentials are used.

Inspect the workflow results, notes and artifacts, then publish the draft through
GitHub. Do not force-update an existing public tag. Retrying a workflow against an
existing release does not overwrite it; review/remove the draft manually first.

## Local packaging

From a clean checkout whose version tag points at HEAD:

```sh
./scripts/release.sh
```

Artifacts are written to `dist/release/`:

- `Claudeway-VERSION-macos-universal.zip`
- `claudeway-VERSION-source.zip`
- `SHA256SUMS`
- `RELEASE_NOTES.md`

Verify checksums with `shasum -a 256 -c SHA256SUMS`. Source exports use `git archive`
and contain no `.git` metadata. App ZIP creation excludes resource forks and
extended attributes. Binaries use path mapping, disabled debug info and stripping;
the publication audit still checks the final outputs rather than trusting flags.

## Next release

Update CFBundleShortVersionString and increment CFBundleVersion in Info.plist.
Update CHANGELOG.md and add `docs/releases/vVERSION.md`. Run tests/build/audit,
commit, and create an annotated `vVERSION` tag. Push it to create a new draft.
Do not include local test reports, credentials, caches or screenshots of real users.

## Signing status

Community builds are ad-hoc signed, not Developer ID signed or notarized. The
repository neither includes a signing identity nor claims notarization. A future
maintainer can add their own protected signing/notarization process in a separate
change. Do not place certificates, private keys or account credentials in Git.

Runner labels were checked against the official
[GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners):
`macos-15` (arm64) and `macos-15-intel` (Intel). Workflow execution must be verified
in the destination repository; local preparation does not prove a remote CI run.
