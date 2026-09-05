#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project MacTree.xcodeproj -scheme MacTree -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
mkdir -p dist
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto build/Build/Products/Release/MacTree.app "$stage/MacTree.app"
# Build all standard Dock/Finder icon sizes from the approved source artwork.
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$stage/MacTree.app/Contents/Resources"
iconutil -c icns "$iconset" -o "$stage/MacTree.app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$stage/MacTree.app/Contents/Info.plist"
rm -rf "$iconset"
# Ad-hoc signing makes a testable bundle, not a notarized distribution.
# Set MACTREE_SIGN_IDENTITY to an installed Developer ID for release signing.
codesign --force --options runtime --timestamp=none \
  --sign "${MACTREE_SIGN_IDENTITY:--}" "$stage/MacTree.app"
codesign --verify --deep --strict "$stage/MacTree.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname MacTree -srcfolder "$stage" -ov -format UDZO dist/MacTree.dmg
ditto -c -k --sequesterRsrc --keepParent "$stage/MacTree.app" dist/MacTree-app.zip
shasum -a 256 dist/MacTree.dmg dist/MacTree-app.zip > dist/SHA256SUMS.txt
