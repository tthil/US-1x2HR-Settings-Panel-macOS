# US-1x2HR-Settings-Panel-macOS

Native Apple Silicon (arm64, macOS 14+) replacement for TASCAM's US-HR Settings Panel.

## Requirements

- Apple Silicon Mac (arm64) running macOS 14 or later.
- To build: Xcode with the Swift 6 toolchain.

## Build and run

`scripts/build-app.sh` builds a release binary and assembles `build/US-HR Settings Panel.app`;
launch it with `open "build/US-HR Settings Panel.app"`. Plug in a TASCAM US-1x2HR and the panel
reads the device state and controls it live. `swift build` and `swift test` build and test all targets.

App icon: the project has its own icon (`Resources/AppIcon.icns`, regenerate with
`swift scripts/make-icon.swift`). For local builds only, `scripts/build-app.sh` uses TASCAM's
original icon instead when the old TASCAM app bundle `US-HR_SettingsPanel.app/` is present in the
repo root (git-ignored; TASCAM's artwork is never committed or distributed).

## Release DMG

`scripts/make-dmg.sh` builds a release bundle (`build-app.sh --release`, project icon) and writes
`build/US-HR-Settings-Panel-<version>.dmg` with an Applications shortcut. The version comes from
`CFBundleShortVersionString` in `Resources/Info.plist`.

The app is ad-hoc signed, not notarized. After downloading, macOS will refuse to open it the first
time: open System Settings → Privacy & Security and click **Open Anyway**, or run
`xattr -dr com.apple.quarantine "/Applications/US-HR Settings Panel.app"`.

The app is unsandboxed (it talks to the device over raw USB control transfers) and is ad-hoc
signed for local use. On first launch macOS may block it: right-click the app and choose Open.

## Not included

- Firmware update.
- Any updater for the app itself.

## Probe CLI

`ushr-probe` is a command-line tool for protocol work. Its read-only subcommands only query the
device; the `set` subcommand changes device settings, so use it deliberately.

## Open items

- Audio Input 1/2 toggle meaning not yet confirmed on hardware; see `docs/acceptance-2026-11.md`.
