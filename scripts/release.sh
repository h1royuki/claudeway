#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
TAG="v$VERSION"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo 'Release requires a clean checkout' >&2; exit 1; }
[[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || { echo 'Version tag must point to HEAD' >&2; exit 1; }
NOTES="docs/releases/$TAG.md"
[[ -f "$NOTES" ]] || { echo 'Missing versioned release notes' >&2; exit 1; }
OUT="$ROOT/dist/release"
mkdir -p "$OUT"
python3 scripts/test_privacy_audit.py
python3 scripts/privacy_audit.py
./test.sh
ARCHS='arm64 x86_64' ./build.sh
APP='dist/Claudeway.app'
lipo "$APP/Contents/MacOS/Claudeway" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Claudeway" --check-localizations
python3 scripts/privacy_audit.py --artifacts "$APP"
APP_ZIP="Claudeway-$VERSION-macos-universal.zip"
SOURCE_ZIP="claudeway-$VERSION-source.zip"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr -c -k --keepParent "$APP" "$OUT/$APP_ZIP"
git archive --format=zip --prefix="claudeway-$VERSION/" HEAD -o "$OUT/$SOURCE_ZIP"
cp "$NOTES" "$OUT/RELEASE_NOTES.md"
python3 scripts/privacy_audit.py --artifacts "$OUT/$APP_ZIP" "$OUT/$SOURCE_ZIP" "$OUT/RELEASE_NOTES.md"
(cd "$OUT" && shasum -a 256 "$APP_ZIP" "$SOURCE_ZIP" > SHA256SUMS)
echo "Release artifacts: $OUT"
