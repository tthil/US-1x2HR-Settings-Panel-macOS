#!/bin/bash
# Builds a release app bundle (project icon, no TASCAM artwork) and packs it into
# build/US-HR-Settings-Panel-<version>.dmg with an /Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="build/US-HR Settings Panel.app"
DMG="build/US-HR-Settings-Panel-${VERSION}.dmg"
STAGE="build/dmg-stage"

scripts/build-app.sh --release

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "US-HR Settings Panel ${VERSION}" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null
echo "Built $DMG"
