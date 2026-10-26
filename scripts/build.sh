#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) OwlMac.app into build/ and a release zip into dist/.
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="build/OwlMac.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

for arch in arm64 x86_64; do
  echo "→ compiling $arch"
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/*.swift -o "build/OwlMac-$arch"
done
lipo -create build/OwlMac-arm64 build/OwlMac-x86_64 -output "$APP/Contents/MacOS/OwlMac"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

echo "→ drawing app icon"
"$APP/Contents/MacOS/OwlMac" --render-iconset build/OwlMac.iconset
iconutil -c icns build/OwlMac.iconset -o "$APP/Contents/Resources/OwlMac.icns"

# Ad-hoc signature: required to run on Apple silicon. Not notarized.
cp LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --sign - "$APP"

rm -f dist/OwlMac.zip
ditto -c -k --keepParent "$APP" dist/OwlMac.zip
echo "✓ $APP"
echo "✓ dist/OwlMac.zip (v$VERSION)"
