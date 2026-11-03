# Protocol findings (hardware: US-1x2HR, PID 0x806F, firmware 0x64 build 14)

Observed with `ushr-probe list | info | read-all | raw-read` on 2026-11-03. Read-only: no set command has been sent.
Vendor control transfers (OUT 0x40/0x1D, IN 0xC0/0x1E) succeed through `IOUSBHostDevice` interface without `USBDeviceOpen`
(no exclusive-access or privilege error) while the audio driver owns the device.

## Findings table

| Item (spec) | Status | Observed raw hex | Notes |
|---|---|---|---|
| DeviceRequest without USBDeviceOpen (§10) | confirmed | n/a | All OUT/IN transfers returned success. |
| PID to model (§6.1) | confirmed | n/a | PID 0x806F, USB product name `US-1x2HR`, no serial number string (USB string is the literal `no serial number`; `persistenceKey` treats it as absent and uses `pid-32879`). |
| Info block framing `31 01` (§6.5) | confirmed | OUT `31 01 00 00`; IN `A1 03 01 00 32 03 64 00 33 03 0E 00 34 05 08 "US-1x2HR\0" 37 05 08 "US-1x2HR\0" 35 05 0B "Sep  2 2020\0" 36 05 08 "17:42:40\0" 00 00` | version 0x0064, build 14. Tag order in reply: 32, 33, 34, 37, 35, 36. Strings are NUL-terminated within the length. |
| Sample-rate read `18 01` (§6.5) | confirmed | OUT `18 01 00 00`; IN `A1 03 01 00 18 04 80 BB 00 00 00 00` | reply tag 0x18, u32 LE 0xBB80 = 48000 Hz. |
| Auto power save get `14 01` | confirmed | OUT `14 01 00 00`; IN `A1 03 01 00 15 02 00` | reply tag 0x15 (not 0x14), u8 0 = off. |
| Get request framing `<getTag> 02 00` (not flag) | confirmed | OUT `61 02 05 62 02 01 C6 02 00 00 00` | Device answers; flag form was not tried. |
| Get-reply tag values (§6.4) | confirmed: reply echoes the GET tag | stereo `61 02 05 62 02 01 C6 02 04`; mute `... C3 02 00`; fader `... C1 02 00` | Reply tag is C6/C3/C1, not 86/83/81. Parser already accepted both. |
| Ready marker 0xA1 (§6.2) | corrected | idle IN `A1 03 01 00 00 00 ...` | 0xA1 is a **u16** (type 3), value 1 = ready, not u8. Parser only inspected `.u8`, so a u16 0 (busy) would have been missed. Parser now treats u8 or u16 zero as busy. A busy reply was never observed. |
| Direct Monitor stereo (5,1) | observed | `61 02 05 62 02 01 C6 02 04` | STEREO (4). |
| Loopback Input stereo (4,1) | observed | `61 02 04 62 02 01 C6 02 04` | STEREO (4). |
| Loopback Output stereo (3,1) | observed | `61 02 03 62 02 01 C6 02 04` | STEREO (4). |
| Multi-get in one message | corrected | 3 stereo gets in one OUT (29 bytes) `61 02 05 62 02 01 C6 02 00 61 02 04 ... 00 00` returned only `61 02 03 62 02 01 C6 02 04` | Device answers only the **last** get of a message. `PanelCommands.readAll` now issues one get per query, including sample rate and auto power save (original sends each get separately). |
| Mute indices reported (ch 4) | observed | one get (idx 1 or idx 2) returns `61 02 04 62 02 01 C3 02 00 ... 62 02 04 C3 02 00` | A single mute get returns **all four** ANALOG_IN idx 1-4, all 0 (unmuted/false), even on the 1x2HR. Same reply for get idx 1 and idx 2. |
| Fader (5,1) | observed | `61 02 05 62 02 01 C1 02 00` | value 0. |
| Loopback ch 6 is write-only (global context) | corrected (readable) | fader get (5,1) reply also contains `61 02 06 62 02 00 C1 02 00 61 02 06 62 02 01 C1 02 7F` | Device appends ch6 idx0 = 0 (loopback off) and ch6 idx1 = 0x7F (127, loopback volume). Loopback state is therefore readable through the (5,1) fader get; parser already exposes them in `faders`. Whether these track writes is pending Step 6. |
| Assign get (§6.6) | confirmed | OUT `61 02 00 62 02 00 41 01 61 02 00 62 02 00 42 01 43 01 00 00`; IN `61 02 05 62 02 01 41 01 61 02 01 62 02 01 42 01 43 01 61 02 05 62 02 02 41 01 61 02 01 62 02 02 42 01 43 01 61 02 03 62 02 03 41 01 61 02 01 62 02 03 42 01 43 01 61 02 03 62 02 04` (64-byte cut) | Pairs: DM(5,1)->LINE_OUT 1, DM(5,2)->LINE_OUT 2, COMP(3,3)->LINE_OUT 3, and (3,4)->LINE_OUT 4 (truncated at 64 bytes). Current routing is Monitor Mix. |
| Line-out destination indices (§6.6) | consistent with (1,2); pending owner check (Step 6) | see above | Reported L/R destinations are LINE_OUT 1 and 2 and sources are srcIdx and srcIdx+1. Dest 3/4 also listed by hardware. Effect of writing pending. |
| Audio Input toggle meaning/polarity | pending owner check (Step 6) | all four mutes read 0 | No input is currently muted by any definition, i.e. default 0. |
| Loopback ch 6 idx 0/1 behaviour | pending owner check (Step 6) | see ch 6 row | |
| Slider ranges (§10) | partly observed | loopback vol 0x7F | 127 seen as the loopback volume; ranges otherwise unchanged. |
| Multiple set records in one message | not used | n/a | One Command per OUT message by design (as the original app); nothing pending. |
| Stale IN buffer | note | `raw-read` after a query returns the previous reply | The device keeps the last reply in the IN buffer; bytes after the `00 00` terminator are leftovers of earlier replies and must be ignored (decoder stops at the terminator). `USHRSession.query` keeps reading until each get's key is present (`Command.isAnswered`); a stale reply for the *same* key cannot be distinguished. |

## Corrections made in code

1. `DeviceReport.parse`: accept `0xA1` as u16 (real device) in addition to u8.
2. `PanelCommands.readAll`: one channel get per query group (device answers only the last get per message).
Tests: `DeviceReportTests` real-capture fixtures, `PanelCommandsTests.test_readAll_batches`.
