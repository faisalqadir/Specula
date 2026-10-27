#!/bin/bash
# Builds Specula.app (release) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Specula
swift build -c "$CONFIG" --product speculatool
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Specula.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Specula" "$APP/Contents/MacOS/Specula"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN/speculatool" icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Tools/Info.plist "$APP/Contents/Info.plist"
cp docs/THIRD-PARTY.md "$APP/Contents/Resources/" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
