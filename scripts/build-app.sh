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

# App icon: TASCAM's original artwork, taken from the old TASCAM app bundle kept
# locally in the repo root (git-ignored, never committed). Skipped if absent.
TASCAM_ICON="US-HR_SettingsPanel.app/Contents/Resources/icon.icns"
if [[ -f "$TASCAM_ICON" ]]; then
    cp "$TASCAM_ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: $TASCAM_ICON not found - building without an app icon" >&2
fi

codesign --force --options runtime -s - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
