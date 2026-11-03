#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/US-HR Settings Panel.app"

swift build -c release --product USHRSettingsPanel --arch arm64
BIN="$(swift build -c release --product USHRSettingsPanel --arch arm64 --show-bin-path)/USHRSettingsPanel"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/USHRSettingsPanel"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime -s - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
