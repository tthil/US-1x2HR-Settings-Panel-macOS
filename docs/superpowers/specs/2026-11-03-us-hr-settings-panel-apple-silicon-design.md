# US-HR Settings Panel for Apple Silicon — Design

Date: 2026-11-03
Status: draft for approval

## 1. Intent and why

The owner has a **TASCAM US‑1x2HR** USB audio interface. They change its
settings depending on the job (recording vs. streaming/loopback etc.).
TASCAM's official "US‑HR Settings Panel" v1.00 (2020) is an Intel‑only Qt app;
TASCAM has dropped support and current macOS no longer runs Intel apps, so the
interface is now stuck on whatever it was last set to.

We are building a **native Apple Silicon macOS app** that gives back every
control the owner used, by speaking the interface's USB control protocol
directly. The protocol was reverse‑engineered from the shipped binary
(`US-HR_SettingsPanel.app`, SHA‑256 of executable
`ccda87fdb48ce3bb10625e8c6e6a88574849792f65371fc5bba906d5011f63a0`), which
lives untracked in this repo for reference.

Success = the owner plugs in the US‑1x2HR, opens the app, sees the current
state, and can change every setting below with the device responding exactly as
it did with TASCAM's panel.

## 2. Goals

Controls (all that the owner uses today):

1. **Direct Monitor** — mono / stereo.
2. **Monitor Balance** — slider between Input and Computer.
3. **Input / output settings** — the per‑input "Audio Input" toggles and the
   Line Out source selection.
4. **Loopback** — on/off, loopback input mono/stereo, loopback output
   mono/stereo, loopback (broadcast) volume.
5. **Auto Power Save** — on/off.

Plus:

- Detect connect / disconnect live (hot‑plug), show "No Device" when absent.
- On connect, read the device's current state and show it (the device is the
  source of truth, not the app).
- Show device name, firmware version, and current sample rate (read‑only).

## 3. Non‑goals

- No software update checker, no download of TASCAM's update JSON, no news /
  "TASCAM Information" popups.
- No firmware flashing (tags `0x21`–`0x26`), no config erase (`0xA2`), no
  debug commands (`0x13`, `0x17`/`0x18`). These must not be reachable from the
  UI.
- No ASIO buffer‑size control (in the original it is a no‑op on macOS).
- No audio driver; macOS's class‑compliant driver keeps handling audio.
- Not a pixel copy of TASCAM's UI or assets (no TASCAM images/branding reused).

## 4. Anti‑goals (failure even if it "works")

- Anything that could brick or wedge the interface. Only the setter/getter tags
  listed in §6 may ever be sent.
- Requiring Rosetta, a kernel/driver extension, or disabling SIP.
- Fighting the audio driver for the device (e.g. calling `USBDeviceOpen` /
  seizing interfaces) such that audio drops out.

## 5. Constraints and decisions made

- **Platform (owner):** native Apple Silicon macOS app. Owner has Xcode
  installed.
- **Device scope (owner):** US‑1x2HR is the target and the only model that can
  be tested. *My call:* keep the 2x2HR/4x4HR product IDs recognised and the
  protocol layer model‑agnostic, but UI/testing only for the 1x2HR; for other
  models show the controls that apply and a "untested model" note.
- **Language/UI (my call):** Swift + SwiftUI, single window, macOS 14+ deployment
  target, arm64 (universal build is fine if free).
- **USB access (my call):** IOKit `IOUSBDeviceInterface` `DeviceRequest` on
  endpoint 0, **without** `USBDeviceOpen` — exactly what the original does
  (verified: it only calls `GetLocationID` (vtable +0xA0) and
  `DeviceRequest` (+0xD0) on the device interface). Hot‑plug via
  `IOServiceAddMatchingNotification` (`kIOFirstMatchNotification`) +
  `IOServiceAddInterestNotification` for termination. Builder may use
  `IOUSBHost` instead if it works without exclusive open.
- **Sandbox (my call):** app is **not** sandboxed (simplest IOKit access);
  hardened runtime on; ad‑hoc / personal signing is fine — distribution is just
  the owner's machine.
- **Persistence (my call, following the original):** the device is the source of
  truth for every setting it can report. For any setting the probe shows the
  device *cannot* report back, remember the last value this app set (per
  device, in `UserDefaults`) and show it. The original did the same: it saved
  mixer values via `QSettings` (`MainWindow::saveMixerParameter` /
  `loadMixerParameter`). Also remember window position.
- **Where it's built and tested (my call):** built and run on the owner's own
  Mac (Xcode installed) with the US‑1x2HR plugged in. The builder runs the probe
  tool directly. The owner only confirms audible/metered behaviour in step 5.
  Ad‑hoc/local signing is sufficient. If `DeviceRequest` fails without
  `USBDeviceOpen`, the builder stops and reports to the owner before trying
  anything else.

## 6. The USB protocol (reverse‑engineered)

Confidence legend: **[O]** observed in disassembly; **[I]** inferred, verify
on hardware.

### 6.1 Device matching [O]

| Model | idVendor | idProduct |
|---|---|---|
| (one of) US‑1x2HR / 2x2HR / 4x4HR | `0x0644` (TEAC) | `0x806F`, `0x8070`, `0x8071` |

Mapping PID→model is **[I]**; read the product name (§6.5) to identify the
model rather than relying on PID. Original matches IOKit class `IOUSBDevice`
(on modern macOS use `IOUSBHostDevice` / `kIOUSBDeviceClassName`).

### 6.2 Transport [O]

Vendor control transfers to the device, endpoint 0:

| Direction | bmRequestType | bRequest | wValue | wIndex | wLength |
|---|---|---|---|---|---|
| Send (OUT) | `0x40` | `0x1D` | 0 | 0 | message length (≤ 64) |
| Receive (IN) | `0xC0` | `0x1E` | 0 | 0 | 64 |

- On send failure with pipe‑stall (`0xE000404F`) or timeout (`0xE0004051`),
  wait 10 ms and retry, up to 3 attempts total.
- **Wait‑ready before every send:** poll Receive; parse records; if a record
  with tag `0xA1` is present and its value ≠ 0, device is ready. Otherwise
  sleep 10 ms and retry, max 1000 tries (≈10 s) → error.
- All I/O must be serialised (one transaction in flight) and off the main
  thread. The original used a dedicated worker thread.

### 6.3 Message format (TLV) [O]

A message is a sequence of records, terminated by `00 00`. Max 64 bytes.

```
record = tag:u8  type:u8  payload
type 0: end      (tag must be 0, no payload)
type 1: flag     (no payload; used for "get" requests)
type 2: u8       1 byte
type 3: u16      2 bytes, little endian
type 4: u32      4 bytes, little endian
type 5: bytes    len:u8 then len bytes
```

Parsers must skip unknown tags (reply buffers can contain other records,
e.g. tag `0x12` debug text, `0xA1` ready status).

### 6.4 Channel addressing [O]

Per‑channel parameters are sent as a channel prefix followed by the
parameter record:

```
61 02 <chType>   62 02 <chIndex>   <paramTag> 02 <value>   00 00
```

`chType` enum (names present in binary as `USMSG_DATA_CH_*`):

| value | name |
|---|---|
| 1 | LINE_OUT |
| 2 | MASTER_OUT |
| 3 | COMPUTER_OUT |
| 4 | ANALOG_IN |
| 5 | DIRECTMONITOR_OUT |
| 6 | (unnamed; used for loopback) |

Parameter tags (set / get):

| Param | Set tag | Get tag | Value |
|---|---|---|---|
| Fader | `0x81` | `0xC1` | u8 |
| Mute | `0x83` | `0xC3` | u8 bool |
| Stereo/Mono | `0x86` | `0xC6` | u8: `1` = MONO, `4` = STEREO |

Get requests send the prefix plus `<getTag> 01` (flag), then receive and
look for the matching `0x61`/`0x62` prefix followed by the value record
[O for request shape; reply tag value **[I]** — expected to be the set tag].

### 6.5 Device‑level commands [O]

| Purpose | Request | Reply |
|---|---|---|
| Get auto power save | `14 01` | record tag `0x15`, u8 bool |
| Set auto power save | `15 02 <0/1>` | — |
| Device info | via helper: `31 01` + info tag (see below) | type‑5 string / u16 |
| Info tags | `0x32` version (u16), `0x33` build (u16), `0x34` product name, `0x35` build date, `0x36` build time, `0x37` product signature | |
| Sample rate | QUSDevice `request_hz` (exact tag **[I]**; debug getter uses `18 01` → reply tag `0x18` u32 Hz) | |

Exact framing of the info helper (`sub_10001d9a0`) and the sample‑rate read
are **[I]**: the builder must confirm with the probe tool (§8 step 1).

### 6.6 Line‑out routing (assign) [O for request; I for semantics]

Line Out combo choices on 1x2HR: **Monitor Mix**, **Computer Out 1‑2**
(and on 4x4: Computer Out 3‑4). Source table in binary:

| combo index | source chType | source index |
|---|---|---|
| 0 Monitor Mix | 5 DIRECTMONITOR_OUT | 1 |
| 1 Computer Out 1‑2 | 3 COMPUTER_OUT | 1 |
| 2 Computer Out 3‑4 | 3 COMPUTER_OUT | 3 |

Two assign messages are sent (left and right, source index and index+1) to
destination LINE_OUT. Assign message:

```
61 02 <srcType> 62 02 <srcIdx> 41 01   61 02 <dstType> 62 02 <dstIdx> 42 01   43 01   00 00
```

Get‑assign: send assign with all zeros, wait 100 ms, receive and parse
`src → dst` pairs. Destination indices for L/R are **[I]** (likely 1 and 2).

### 6.7 UI → protocol mapping [O]

| UI control | Command |
|---|---|
| Direct Monitor IN1‑2 mono/stereo | Stereo, ch 5, idx 1, MONO=1 / STEREO=4 |
| (4x4 only) Direct Monitor IN3‑4 | Stereo, ch 5, idx 3 |
| Monitor Balance slider `v` (0…127, Input↔Computer) | Fader, ch 5, idx 1, value = `127 − v` |
| Audio Input *n* toggle (n = 1…4) | Mute, ch 4 (ANALOG_IN), idx n, value = toggle state as sent by original **[I: polarity/meaning to confirm on hardware]** |
| Loopback on/off | Fader, ch 6, idx 0, value 0/1 |
| Loopback volume (broadcast slider) | Fader, ch 6, idx 1, value u8 |
| Loopback Input mono/stereo | Stereo, ch 4, idx 1, MONO=1 / STEREO=4 |
| Loopback Output mono/stereo | Stereo, ch 3, idx 1, MONO=1 / STEREO=4 |
| Line Out 1‑2 source | Assign (§6.6) |
| Auto Power Save | `15 02 <bool>` |

Original UI shows the loopback sub‑controls only while Loopback is on. Which
controls appear per model comes from `MainWindow::setUiScreenForEachDevice`
(builder: mirror its show/hide logic, 1x2HR set takes priority).

Slider ranges other than Monitor Balance (0…127) are **[I]**; read them from
the Qt UI setup (`setMaximum` calls in `Ui_MainWindow::setupUi`) or the
device's reported values.

## 7. Product shape

- Single SwiftUI window, title "US‑HR Settings Panel".
- Header: connection state, model name, firmware version, sample rate.
- Sections: Direct Monitor, Monitor Balance, Inputs, Line Out, Loopback
  (sub‑controls revealed when on), Power (Auto Power Save).
- Controls disabled with "No Device" when nothing is connected.
- Slider changes are coalesced (send latest value, not every tick).
- Errors (device busy/timeout) shown inline, non‑modal; app re‑reads state on
  error.

## 8. Build order the builder should follow

1. **Protocol probe CLI first** (Swift command‑line target sharing the protocol
   package): list device, dump info tags, read every getter in §6, and allow a
   single explicit set. Run against the owner's 1x2HR to confirm every **[I]**
   item before UI work. Never sends firmware/erase/debug tags.
2. Protocol library (TLV encode/decode, transport, wait‑ready, retries) with
   unit tests over byte fixtures from §6 — no hardware needed.
3. Device manager (hot‑plug, serial I/O queue, state model).
4. SwiftUI app.
5. Manual hardware check with the owner: each control changes the device as
   the old panel did (owner's ears/meters are the oracle).

## 9. Left to the builder

- Project layout (Xcode project vs. SwiftPM + app target), naming, internal
  architecture, concurrency model (actor vs. serial queue).
- Exact SwiftUI styling and layout within §7.
- IOKit vs. IOUSBHost API choice, as long as no exclusive open is needed.
- How unknown/unsupported models are presented.

## 10. Open items requiring hardware

Resolved with the probe tool in step 1, not by asking the owner:

- Get‑reply tag values and info helper framing (§6.4, §6.5).
- Sample‑rate read command.
- Meaning/polarity of the Audio Input toggle.
- Line‑out destination indices; slider ranges.
- Whether `DeviceRequest` without `USBDeviceOpen` succeeds on current macOS
  while the audio driver owns the device (expected yes; if not, stop and report
  — do not seize the device).
