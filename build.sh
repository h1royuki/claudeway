#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
APP_OUT="${1:-$ROOT/dist/Claudeway.app}"
[[ "$(basename "$APP_OUT")" == 'Claudeway.app' ]] || { echo 'Output must be named Claudeway.app' >&2; exit 1; }
read -r -a ARCH_LIST <<< "${ARCHS:-$(uname -m)}"
[[ ${#ARCH_LIST[@]} -gt 0 ]] || exit 1
for ARCH in "${ARCH_LIST[@]}"; do
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
done
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
STAGE="$(mktemp -d "$BUILD_DIR/bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
  ARGS=(--package-path "$ROOT" --scratch-path "$BUILD_DIR/$ARCH" --arch "$ARCH" -c release -debug-info-format none
    -Xswiftc -debug-prefix-map -Xswiftc "$BUILD_DIR=/build"
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/source/Claudeway"
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/source/Claudeway")
  swift build "${ARGS[@]}" --product Claudeway
  BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"
  cp "$BIN_DIR/Claudeway" "$STAGE/Claudeway-$ARCH"
  strip -S -x "$STAGE/Claudeway-$ARCH"
  BINARIES+=("$STAGE/Claudeway-$ARCH")
done
APP="$STAGE/Claudeway.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/Claudeway"
else
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Claudeway"
fi
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
ICONSET="$STAGE/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/Assets/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 - "$ICONSET" <<'PY'
# Resizing can add EXIF to PNGs. Keep image/color chunks, remove descriptive
# metadata without re-encoding pixels before packaging the public icon.
from pathlib import Path
import struct
import sys
for path in Path(sys.argv[1]).glob('*.png'):
    data = path.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise SystemExit('Invalid icon PNG')
    chunks = [data[:8]]
    offset = 8
    while offset < len(data):
        size = struct.unpack_from('>I', data, offset)[0]
        end = offset + size + 12
        if end > len(data):
            raise SystemExit('Truncated icon PNG')
        if data[offset + 4:offset + 8] not in {b'eXIf', b'tEXt', b'zTXt', b'iTXt'}:
            chunks.append(data[offset:end])
        offset = end
    path.write_bytes(b''.join(chunks))
PY
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.claude-switcher.macos "$APP"
codesign --verify --deep --strict "$APP"
if [[ -e "$APP_OUT" ]]; then
  [[ ! -L "$APP_OUT" ]] || { echo 'Refusing symlink output' >&2; exit 1; }
  IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_OUT/Contents/Info.plist")"
  [[ "$IDENTIFIER" == 'local.claude-switcher.macos' ]] || exit 1
  rm -rf "$APP_OUT"
fi
mkdir -p "$(dirname "$APP_OUT")"
mv "$APP" "$APP_OUT"
echo "Built: $APP_OUT"
