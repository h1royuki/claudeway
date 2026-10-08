# Publication privacy audit

## What was prepared

This public tree was assembled from an allowlist of source, synthetic tests and
original artwork. Personal development reports, live account/session identifiers,
conversation titles, screenshots, runtime state, scratch helpers and Finder metadata
were excluded. User-specific prose was replaced with general documentation.

The app is rebuilt from this tree. Existing personal-development binaries are not
reused: release builds disable debug information, map checkout paths to a neutral
source prefix and strip symbols before signing. The final app and archives are
scanned separately, including icon metadata. No user guide is embedded in the app.

## Automated guard

```sh
python3 scripts/test_privacy_audit.py
python3 scripts/privacy_audit.py
python3 scripts/privacy_audit.py --artifacts "dist/Claudeway.app"
```

The guard checks common local home/temp paths, credential signatures, emails,
private/runtime filenames, unexpected literal UUIDs, ZIP contents and unreviewed
PNG metadata. It reports only the rule and filename, never a matching credential.
Synthetic regression fixtures exercise detection. This is an offline standard-
library tool and sends no files to an external scanning service.

Two UUID constants identify public Anthropic OAuth clients. Other allowlisted UUIDs
are deliberately repetitive synthetic test identities. They are not live account,
organization, session or profile IDs. `FAKE-*` credentials and temporary fixtures
are expected in tests. The source icon's EXIF contains only pixel dimensions;
Apple's icon packager also adds a numeric color-space tag to resized images.

## Limits of the conclusion

A clean scan means no findings under these checks in the inspected files. It is not
proof that every possible secret format or identifying detail has been detected.
Manual review is still required before adding screenshots, logs, new fixtures or
attachments. The tool is not a vulnerability scanner or a legal/license assessment.

Build caches and test logs can contain the build machine's paths. They are ignored
and must not be uploaded as release assets. Git author metadata is separate from
source exports; the initial prepared commit uses a project-level contributor
identity. Future contributors should choose their own public or GitHub no-reply
identity deliberately.

The publication audit does not inspect or upload the user's actual credential
contents. Runtime data remains outside this repository. GitHub CI, notification
permission and every supported Desktop/OS combination cannot be certified by a
local packaging run.
