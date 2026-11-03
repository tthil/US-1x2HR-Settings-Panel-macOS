# US-1x2HR-Settings-Panel-macOS

Native Apple Silicon (arm64, macOS 14+) replacement for TASCAM's US-HR Settings Panel.

## Build and run

```sh
swift build        # debug build of all targets
swift test         # run unit tests
scripts/build-app.sh   # release build -> build/US-HR Settings Panel.app (ad-hoc signed)
open "build/US-HR Settings Panel.app"
```

`ushr-probe` is a command-line tool for inspecting a connected device (`swift run ushr-probe read-all`).
