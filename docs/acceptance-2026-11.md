# Hardware acceptance — 2026-11-03

Device: TASCAM US‑1x2HR (PID 0x806F), firmware 1.00 (build 14), 48 kHz, on macOS 27 (Apple Silicon).
App: `build/US-HR Settings Panel.app` (arm64, ad-hoc signed, hardened runtime), built from `feature/apple-silicon-panel`.
Method: the owner used the app's controls while listening on headphones connected to the interface, with music playing from the Mac. No input source was connected.

| # | Check | Result |
|---|---|---|
| 1 | Monitor Balance: drag fully to "Input", then back to "Computer" | PASS. Music went silent at "Input" and came back at "Computer". |
| 2 | Line Out: balance at "Input", switch Line Out to "Computer Out 1‑2", back to "Monitor Mix", balance back to "Computer" | PASS. Music came back with Computer Out 1‑2, went silent with Monitor Mix, and returned with balance at "Computer". |
| 3 | Loopback on (sub-controls appear, volume set to about the middle) and Auto Power Save on, then quit and relaunch | PASS. After relaunch the app showed Loopback on, volume about the middle, and Auto Power Save on, all read back from the device. |
| 4 | Restore Loopback and Auto Power Save to off, unplug USB, then replug | PASS. The app showed "No Device" with controls disabled, then "Connected" with the restored values after replug. |
| 5 | Direct Monitor Mono/Stereo audible effect | DEFERRED at the owner's request (no input source available). |
| 6 | Audio Input 1/2 toggle meaning and polarity (mute ch 4 idx n) | DEFERRED at the owner's request (no input source available). If the toggle turns out to be inverted, the fix is one line in `PanelCommands.audioInput`. |

Earlier probe checks with the owner (Task 5 Step 6, see `docs/protocol-findings.md`) had already confirmed the balance mapping, the line-out destinations, loopback read/write, auto power save, and loopback in/out mono/stereo by readback.
