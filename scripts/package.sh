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
# Ad-hoc signing makes a testable bundle, not a notarized distribution.
# Set MACTREE_SIGN_IDENTITY to an installed Developer ID for release signing.
codesign --force --options runtime --timestamp=none \
  --sign "${MACTREE_SIGN_IDENTITY:--}" "$stage/MacTree.app"
codesign --verify --deep --strict "$stage/MacTree.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname MacTree -srcfolder "$stage" -ov -format UDZO dist/MacTree.dmg
ditto -c -k --sequesterRsrc --keepParent "$stage/MacTree.app" dist/MacTree-app.zip
shasum -a 256 dist/MacTree.dmg dist/MacTree-app.zip > dist/SHA256SUMS.txt
