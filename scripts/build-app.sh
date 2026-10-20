#!/bin/bash
# Builds NotchWave.app into ./build so it runs like a normal Mac app
# (own permissions entry, no Terminal window, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Compiling (release)…"
swift build -c release

APP="build/NotchWave.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/NotchWave" "$APP/Contents/MacOS/NotchWave"
cp Support/Info.plist "$APP/Contents/Info.plist"

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it with:  open $APP"
