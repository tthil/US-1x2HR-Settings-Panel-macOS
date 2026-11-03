# US-HR Settings Panel (Apple Silicon) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native arm64 macOS app (plus a probe CLI) that controls a TASCAM US‑1x2HR over its USB vendor-control protocol, replacing TASCAM's abandoned Intel-only Settings Panel.

**Architecture:** One SwiftPM package. A pure `USHRProtocol` library (TLV codec, the allow-listed `Command` set, reply parsing, an actor `USHRSession` over an abstract transport) is unit-tested with byte fixtures. A thin C shim + `USHRDevice` library does IOKit hot-plug and endpoint‑0 vendor requests. `USHRPanelCore` holds the UI state model (testable with a fake device). The SwiftUI app target and the `ushr-probe` CLI are thin shells; `scripts/build-app.sh` assembles and signs the `.app`.

**Tech Stack:** Swift 6.4 / Xcode 27.2 toolchain (verified on this Mac), SwiftPM, SwiftUI + Observation, IOKit (`IOUSBLib` device interface via C shim), XCTest. macOS 27 host, arm64.

**Spec:** `docs/superpowers/specs/2026-11-03-us-hr-settings-panel-apple-silicon-design.md`

## Global Constraints

- Deployment target macOS 14 (`.macOS(.v14)`), arm64; `swift-tools-version: 6.0`.
- USB: vendor `0x0644`; product IDs `0x806F`, `0x8070`, `0x8071`. `0x806F` is the US‑1x2HR (observed on the owner's device: `idProduct = 32879`).
- Transport: OUT `bmRequestType 0x40, bRequest 0x1D`; IN `bmRequestType 0xC0, bRequest 0x1E`; `wValue 0`, `wIndex 0`, max 64 bytes.
- **Never call `USBDeviceOpen`/seize the device.** If `DeviceRequest` fails without it, stop and report to the owner.
- **Only tags reachable through `Command` may be sent.** Firmware (`0x21`–`0x28`), erase (`0xA2`), debug (`0x13`, `0x17`) must be unencodable. `0x18` (sample-rate read) is allowed as a read only.
- No network access, no update checking, no TASCAM images/branding assets.
- App not sandboxed; hardened runtime on; ad-hoc signing (`codesign -s -`).
- Window title: `US‑HR Settings Panel`.
- Do not commit TASCAM's binaries (`US-HR_SettingsPanel.app/`, `*.dmg`, `*.zip` in repo root).

## Protocol facts the tasks use (from the spec §6 plus additional disassembly done while planning)

- Get requests as the original app sends them (`QUSDevice::us_send`): channel prefix `61 02 <type>`, `62 02 <idx>`, then `<getTag> 02 00` (u8 zero, **not** flag). Device-level gets are flags: `31 01` (info block), `18 01` (sample rate), `14 01` (auto power save).
- Info reply carries records `0x32` version (u16), `0x33` build (u16), `0x34` product name, `0x35` build date, `0x36` build time, `0x37` product signature (strings as type‑5 bytes).
- **Wait-ready semantics:** receive and scan the records; the device is *busy* only if a `0xA1` record with value 0 is present. No `0xA1` record, or `0xA1` ≠ 0 → ready.
- The original only reads back: stereo, mute (ch 4), fader **ch 5 idx 1 only**, assign, auto power save, sample rate, info. **Loopback on/off and loopback volume (ch 6) are write-only** → persisted with `LastSetStore`.
- Both sliders are 0…127, page step 8. Monitor balance sends `127 − v`.
- Line-out combo order: `Monitor Mix` (src ch5 idx1), `Computer Out 1-2` (src ch3 idx1), `Computer Out 3-4` (src ch3 idx3, 4x4 only). Each choice sends two assigns: (srcIdx → LINE_OUT idx 1) and (srcIdx+1 → LINE_OUT idx 2) **[I: dest indices]**.

## Review Focus

1. **Unplugging mid-command** — the app must show "No Device" and not hang or crash; queued commands are dropped. Test: `SessionTests.test_transportGoneDuringSend_throwsDeviceGone` (Task 3) and `PanelModelTests.test_detachDuringPendingSend_endsNoDevice` (Task 6).
2. **Dragging a slider fast** — the device must not be flooded or left at a stale value; the last value wins. Test: `PanelModelTests.test_sliderBurst_sendsLatestValueLast` (Task 6).
3. **Device busy for a long time** (ready never comes) — the app must surface a non-modal error, not freeze the UI. Test: `SessionTests.test_waitReady_givesUpAfterAttemptLimit` (Task 3).
4. **Garbage or truncated reply bytes** — must not crash; unknown tags are skipped and trailing padding is ignored. Tests: `TLVTests.test_decode_truncatedRecord_throws`, `test_decode_skipsUnknownTagsAndStopsAtEnd` (Task 1), `DeviceReportTests.test_parse_ignoresUnknownTags` (Task 2).
5. **App launched with no device, then plugged in (and replugged)** — the state must be read fresh on each attach. Test: `PanelModelTests.test_reattach_rereadsState` (Task 6); manual check in Task 8.

---

### Task 1: Package scaffold and TLV codec

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/USHRProtocol/TLV.swift`, `Tests/USHRProtocolTests/TLVTests.swift`
- Commit also: the spec and this plan (untracked today).

**Interfaces:**
- Produces:
  ```swift
  public enum TLVValue: Equatable, Sendable { case flag, u8(UInt8), u16(UInt16), u32(UInt32), bytes([UInt8]) }
  public struct TLVRecord: Equatable, Sendable { public var tag: UInt8; public var value: TLVValue; public init(_ tag: UInt8, _ value: TLVValue) }
  public enum TLVError: Error, Equatable { case messageTooLong(Int), truncated(offset: Int), unknownType(UInt8, offset: Int) }
  public enum TLV {
      public static let maxMessageLength = 64
      public static func encode(_ records: [TLVRecord]) throws -> [UInt8]   // appends 00 00 terminator; throws messageTooLong if total > 64
      public static func decode(_ bytes: [UInt8]) throws -> [TLVRecord]    // stops at a type-0 record or when < 2 bytes remain
  }
  ```
  Type bytes: flag=1, u8=2, u16=3 (LE), u32=4 (LE), bytes=5 (`len:u8` + data).

- [ ] **Step 1: Create branch** `git checkout -b feature/apple-silicon-panel`.
- [ ] **Step 2: Write `Package.swift`** — products/targets: `USHRProtocol` (lib), `CUSBShim` (C, links `IOKit`, `CoreFoundation`), `USHRDevice` (lib, deps `USHRProtocol`, `CUSBShim`), `USHRPanelCore` (lib, deps `USHRProtocol`), `ushr-probe` (exe, deps `USHRDevice`), `USHRSettingsPanel` (exe, deps `USHRPanelCore`, `USHRDevice`); test targets `USHRProtocolTests`, `USHRPanelCoreTests`. Add placeholder sources only for targets this task builds (`USHRProtocol` + its tests); add the other targets in their own tasks. `.gitignore`: `.build/`, `build/`, `.DS_Store`, `/US-HR_SettingsPanel.app/`, `/*.dmg`, `/*.zip`.
- [ ] **Step 3: Write failing tests** in `TLVTests`:
  ```swift
  func test_encode_channelFaderSet() throws {
      XCTAssertEqual(try TLV.encode([.init(0x61, .u8(5)), .init(0x62, .u8(1)), .init(0x81, .u8(0x40))]),
                     [0x61,2,5, 0x62,2,1, 0x81,2,0x40, 0,0])
  }
  func test_encode_allTypes() throws {
      XCTAssertEqual(try TLV.encode([.init(0x14, .flag), .init(0x32, .u16(0x0102)), .init(0x17, .u32(48000)), .init(0x34, .bytes(Array("US".utf8)))]),
                     [0x14,1, 0x32,3,0x02,0x01, 0x17,4,0x80,0xBB,0,0, 0x34,5,2,0x55,0x53, 0,0])
  }
  func test_encode_over64Bytes_throws()  // 22 u8 records (66 bytes + 2) -> .messageTooLong(68)
  func test_decode_roundTrip()           // decode(encode(x)) == x for the allTypes records
  func test_decode_skipsUnknownTagsAndStopsAtEnd() // [0x12,2,7, 0xA1,2,1, 0,0, 0x99,2,9] -> [(0x12,.u8(7)), (0xA1,.u8(1))]
  func test_decode_truncatedRecord_throws()        // [0x32,3,0x01] -> .truncated(offset: 0)
  func test_decode_unknownType_throws()            // [0x10,9,0] -> .unknownType(9, offset: 0)
  func test_decode_zeroPaddedBuffer()              // 64-byte buffer: [0x15,2,1] + zeros -> [(0x15,.u8(1))]
  ```
- [ ] **Step 4: Run** `swift test --filter TLVTests` — expect FAIL (`TLV` undefined).
- [ ] **Step 5: Implement `TLV.swift`.**
- [ ] **Step 6: Run** `swift test --filter TLVTests` — expect all PASS.
- [ ] **Step 7: Commit** `git add Package.swift .gitignore Sources Tests docs && git commit -m "feat: TLV codec for US-HR control protocol"`

---

### Task 2: Allow-listed commands, UI mapping, and reply parsing

**Files:**
- Create: `Sources/USHRProtocol/Command.swift`, `Sources/USHRProtocol/DeviceReport.swift`, `Sources/USHRProtocol/USHRModel.swift`, `Sources/USHRProtocol/PanelCommands.swift`
- Test: `Tests/USHRProtocolTests/CommandTests.swift`, `Tests/USHRProtocolTests/DeviceReportTests.swift`, `Tests/USHRProtocolTests/PanelCommandsTests.swift`

**Interfaces:**
- Consumes: `TLVRecord`, `TLVValue` (Task 1).
- Produces:
  ```swift
  public enum ChannelType: UInt8, Sendable { case lineOut = 1, masterOut, computerOut, analogIn, directMonitorOut, loopback }
  public enum StereoMode: UInt8, Sendable { case mono = 1, stereo = 4 }
  public struct Channel: Hashable, Sendable { public var type: ChannelType; public var index: UInt8; public init(_ type: ChannelType, _ index: UInt8) }
  public enum Command: Equatable, Sendable {
      case setFader(Channel, UInt8), setMute(Channel, Bool), setStereo(Channel, StereoMode)
      case setAutoPowerSave(Bool), assign(source: Channel, destination: Channel)
      case getFader(Channel), getMute(Channel), getStereo(Channel)
      case getAutoPowerSave, getSampleRate, getInfo, getAssign
      public var records: [TLVRecord] { get }
  }
  public struct DeviceReport: Equatable, Sendable {
      public var busy = false                       // saw 0xA1 == 0
      public var autoPowerSave: Bool?; public var sampleRate: UInt32?
      public var version: UInt16?; public var build: UInt16?
      public var productName: String?; public var buildDate: String?; public var buildTime: String?; public var productSignature: String?
      public var faders: [Channel: UInt8] = [:]; public var mutes: [Channel: Bool] = [:]
      public var stereo: [Channel: StereoMode] = [:]; public var assignments: [Channel: Channel] = [:]  // destination -> source
      public static func parse(_ records: [TLVRecord]) -> DeviceReport
      public mutating func merge(_ other: DeviceReport)   // non-nil / non-empty fields of `other` win
      public var isEmpty: Bool { get }                     // nothing but `busy == false`
  }
  public enum USHRModel: Equatable, Sendable {
      case us1x2HR, us2x2HR, us4x4HR, unknown(UInt16)
      public static let vendorID: UInt16 = 0x0644
      public static let productIDs: [UInt16] = [0x806F, 0x8070, 0x8071]
      public init(productID: UInt16, productName: String?)  // name containing "US-1x2HR"/"US-2x2HR"/"US-4x4HR" wins; else 0x806F→1x2, 0x8070→2x2, 0x8071→4x4
      public var displayName: String { get }               // "US-1x2HR", …, "Unknown US-HR (0x….)"
  }
  public enum LineOutSource: Int, CaseIterable, Sendable { case monitorMix, computerOut12, computerOut34 }  // labels "Monitor Mix", "Computer Out 1-2", "Computer Out 3-4"
  public enum PanelCommands {
      public static func directMonitor(stereo: Bool, pair: UInt8 = 1) -> [Command]   // setStereo((5,pair), stereo ? .stereo : .mono)
      public static func monitorBalance(_ v: UInt8) -> [Command]                      // setFader((5,1), 127 - min(v,127))
      public static func audioInput(_ n: UInt8, on: Bool) -> [Command]                // setMute((4,n), on)  — polarity per protocol-findings.md
      public static func lineOut(_ s: LineOutSource) -> [Command]                     // two .assign: (src, srcIdx)->(LINE_OUT,1), (src, srcIdx+1)->(LINE_OUT,2)
      public static func loopback(on: Bool) -> [Command]                              // setFader((6,0), on ? 1 : 0)
      public static func loopbackVolume(_ v: UInt8) -> [Command]                      // setFader((6,1), min(v,127))
      public static func loopbackIn(stereo: Bool) -> [Command]                        // setStereo((4,1), …)
      public static func loopbackOut(stereo: Bool) -> [Command]                       // setStereo((3,1), …)
      public static func autoPowerSave(_ on: Bool) -> [Command]
      public static func readAll(for model: USHRModel) -> [[Command]]                 // query batches: [getInfo], [getSampleRate, getAutoPowerSave], [stereo (5,1),(4,1),(3,1)], [mutes 1…inputCount], [getFader(5,1)], [getAssign]
      public static func inputCount(for model: USHRModel) -> Int                      // 1x2HR: 2, 2x2HR: 2, 4x4HR: 4, unknown: 2 (adjust per Task 5 findings)
  }
  ```
  Record encodings: channel prefix = `(0x61,.u8(type)), (0x62,.u8(index))`. Sets: param tag `0x81`/`0x83`/`0x86` with `.u8`. Channel gets: `0xC1`/`0xC3`/`0xC6` with `.u8(0)`. `setAutoPowerSave` → `(0x15,.u8)`. `getAutoPowerSave` → `(0x14,.flag)`; `getSampleRate` → `(0x18,.flag)`; `getInfo` → `(0x31,.flag)`. `assign` → `src prefix, (0x41,.flag), dst prefix, (0x42,.flag), (0x43,.flag)`. `getAssign` → `assign` with all-zero channels: `61 02 00 62 02 00 41 01 61 02 00 62 02 00 42 01 43 01`.
  Parse rules: track the current channel from the latest `0x61`+`0x62`; fader from `0x81` or `0xC1` (u8), mute from `0x83`/`0xC3` (u8≠0), stereo from `0x86`/`0xC6` (raw 1/4; ignore other values); APS from `0x14` or `0x15` (u8); `0x18` u32 → sampleRate; `0x32`/`0x33` u16; `0x34`–`0x37` bytes → UTF‑8 with NULs trimmed; `0xA1` u8 0 → busy. Assign: a channel followed by `0x41` is a pending source; channel followed by `0x42` is the destination; `0x43` commits `assignments[dest] = source`. Ignore everything else.

- [ ] **Step 1: Write failing tests** `CommandTests`:
  ```swift
  func test_setStereo_directMonitorStereo() throws {
      XCTAssertEqual(try TLV.encode(Command.setStereo(Channel(.directMonitorOut, 1), .stereo).records),
                     [0x61,2,5, 0x62,2,1, 0x86,2,4, 0,0])
  }
  func test_getMute_analogIn2()    // -> [0x61,2,4, 0x62,2,2, 0xC3,2,0, 0,0]
  func test_setAutoPowerSave_on()  // -> [0x15,2,1, 0,0]
  func test_getInfo()              // -> [0x31,1, 0,0]
  func test_assign_monitorMixToLineOut1() // src (5,1) dst (1,1) -> [0x61,2,5,0x62,2,1,0x41,1, 0x61,2,1,0x62,2,1,0x42,1, 0x43,1, 0,0]
  func test_noCommandEmitsForbiddenTag() {
      let forbidden: Set<UInt8> = [0x13, 0x17, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0xA2]
      // build one instance of every Command case (switch must be exhaustive so new cases break this test)
      XCTAssertTrue(allSampleCommands.flatMap(\.records).allSatisfy { !forbidden.contains($0.tag) })
  }
  ```
  `DeviceReportTests`:
  ```swift
  func test_parse_infoBlock()      // records 0x32 u16 0x0100, 0x34 bytes "US-1x2HR\0" -> version 0x0100, productName "US-1x2HR"
  func test_parse_channelValues()  // 61/62 (5,1) 0xC1 u8 90, 61/62 (4,1) 0xC3 u8 1, 61/62 (3,1) 0xC6 u8 1 -> faders[(5,1)]=90, mutes[(4,1)]=true, stereo[(3,1)]=.mono
  func test_parse_assignPair()     // src(5,1) 41, dst(1,1) 42, 43 -> assignments[(1,1)] == (5,1)
  func test_parse_busyFlag()       // [(0xA1,.u8(0))] -> busy true; [(0xA1,.u8(1))] -> busy false
  func test_parse_ignoresUnknownTags() // [(0x12,.bytes("dbg")), (0x15,.u8(1))] -> autoPowerSave true, nothing else set
  func test_model_fromProductIDAndName() // (0x806F,nil)->.us1x2HR; (0x8070,"US-4x4HR")->.us4x4HR; (0x1234,nil)->.unknown(0x1234)
  ```
  `PanelCommandsTests` — one test per mapping row with exact `Command` values, e.g.:
  ```swift
  func test_monitorBalance_inverts() { XCTAssertEqual(PanelCommands.monitorBalance(0), [.setFader(Channel(.directMonitorOut,1), 127)]); XCTAssertEqual(PanelCommands.monitorBalance(127), [.setFader(Channel(.directMonitorOut,1), 0)]) }
  func test_lineOut_computerOut12() { XCTAssertEqual(PanelCommands.lineOut(.computerOut12), [.assign(source: Channel(.computerOut,1), destination: Channel(.lineOut,1)), .assign(source: Channel(.computerOut,2), destination: Channel(.lineOut,2))]) }
  func test_lineOut_monitorMix()    // [(5,1)->(1,1), (5,2)->(1,2)]
  func test_loopback_on()           // [.setFader(Channel(.loopback,0), 1)]
  func test_loopbackVolume_clamps() // loopbackVolume(200) == [.setFader(Channel(.loopback,1), 127)]
  func test_loopbackIn_stereo()     // [.setStereo(Channel(.analogIn,1), .stereo)]
  func test_loopbackOut_mono()      // [.setStereo(Channel(.computerOut,1), .mono)]
  func test_directMonitor_mono()    // [.setStereo(Channel(.directMonitorOut,1), .mono)]
  func test_audioInput2_on()        // [.setMute(Channel(.analogIn,2), true)]
  ```
- [ ] **Step 2: Run** `swift test --filter "CommandTests|DeviceReportTests|PanelCommandsTests"` — expect FAIL (types undefined).
- [ ] **Step 3: Implement** the four files per the Interfaces block.
- [ ] **Step 4: Run** the same filter — expect PASS; run `swift test` — all PASS.
- [ ] **Step 5: Commit** `git commit -am "feat: allow-listed US-HR commands and reply parsing"` (add new files first).

---

### Task 3: Session (wait-ready, retries, request/response)

**Files:**
- Create: `Sources/USHRProtocol/Session.swift`
- Test: `Tests/USHRProtocolTests/SessionTests.swift` (with a `FakeTransport` in the test target)

**Interfaces:**
- Consumes: `TLV`, `Command`, `DeviceReport` (Tasks 1–2).
- Produces:
  ```swift
  public enum TransportError: Error, Equatable { case stalled, timeout, deviceGone, io(Int32) }
  public protocol ControlTransport: Sendable {
      func controlOut(_ bytes: [UInt8]) throws        // OUT 0x40/0x1D
      func controlIn(maxLength: Int) throws -> [UInt8] // IN 0xC0/0x1E
  }
  public struct SessionTiming: Sendable {
      public var retryDelay: Duration = .milliseconds(10); public var readyAttempts = 1000
      public var sendAttempts = 3; public var replyAttempts = 100; public var assignReadDelay: Duration = .milliseconds(100)
      public static let immediate: SessionTiming   // all delays .zero (tests)
  }
  public enum SessionError: Error, Equatable { case deviceBusy, noReply }
  public protocol USHRControlling: Sendable {
      func send(_ commands: [Command]) async throws
      func query(_ commands: [Command]) async throws -> DeviceReport
  }
  public actor USHRSession: USHRControlling {
      public init(transport: any ControlTransport, timing: SessionTiming = .init())
      public func waitReady() async throws                 // SessionError.deviceBusy after readyAttempts
      public func send(_ commands: [Command]) async throws // packs records greedily into ≤64-byte messages; waitReady before each message
      public func query(_ commands: [Command]) async throws -> DeviceReport
  }
  ```
  `send` retries a message only on `.stalled`/`.timeout`, up to `sendAttempts` total, sleeping `retryDelay`; other errors propagate immediately. `query`: `send`, then (if the commands include `.getAssign`, sleep `assignReadDelay`) receive up to `replyAttempts` times until the parsed report is non-empty, merging; throws `.noReply` if still empty. A `Command`'s records are never split across messages.

- [ ] **Step 1: Write failing tests** (`FakeTransport` records OUT bytes and serves IN replies from a queue; a closure can throw on demand):
  ```swift
  func test_send_waitsReadyThenWritesOneMessage() async throws
      // IN queue: [0xA1,2,0, 0,0], [0xA1,2,1, 0,0]; send([.setAutoPowerSave(true)]) -> outs == [[0x15,2,1,0,0]], ins consumed == 2
  func test_waitReady_noA1Record_isReady() async throws   // IN [0x12,2,0, 0,0] -> returns after 1 read
  func test_waitReady_givesUpAfterAttemptLimit() async    // always [0xA1,2,0,0,0], readyAttempts 5 -> throws .deviceBusy, 5 reads
  func test_send_retriesStallTwiceThenSucceeds() async throws // controlOut throws .stalled, .stalled, then ok -> 3 OUT attempts
  func test_send_givesUpAfterThreeStalls() async          // throws .stalled after exactly 3 attempts
  func test_send_splitsLongBatchAcrossMessages() async throws // 8 setFader commands (9 bytes each) -> 2 OUT messages, each ≤ 64 incl terminator, records not split
  func test_query_returnsParsedReport() async throws      // ready, then reply [0x15,2,1,0,0] -> report.autoPowerSave == true
  func test_query_noReply_throws() async                  // replies always empty [0,0], replyAttempts 3 -> .noReply
  func test_transportGoneDuringSend_throwsDeviceGone() async // controlOut throws .deviceGone -> rethrown, no retry
  ```
  All tests use `SessionTiming.immediate`.
- [ ] **Step 2: Run** `swift test --filter SessionTests` — expect FAIL.
- [ ] **Step 3: Implement `Session.swift`.**
- [ ] **Step 4: Run** `swift test` — all PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: USHRSession with wait-ready and retry semantics"`

---

### Task 4: IOKit transport and hot-plug monitor

**Files:**
- Create: `Sources/CUSBShim/include/ushr_usb.h`, `Sources/CUSBShim/ushr_usb.c`, `Sources/USHRDevice/IOKitTransport.swift`, `Sources/USHRDevice/DeviceMonitor.swift`
- Modify: `Package.swift` (add `CUSBShim`, `USHRDevice` targets; `linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]`)

**Interfaces:**
- Consumes: `ControlTransport`, `TransportError`, `USHRModel` (Tasks 2–3).
- Produces:
  ```c
  typedef struct ushr_dev ushr_dev;
  ushr_dev *ushr_dev_create(io_service_t service, kern_return_t *err); // IOCreatePlugInInterfaceForService(kIOUSBDeviceUserClientTypeID) + QueryInterface(kIOUSBDeviceInterfaceID); NO USBDeviceOpen
  void ushr_dev_destroy(ushr_dev *dev);
  kern_return_t ushr_dev_vendor_out(ushr_dev *dev, uint8_t bRequest, const uint8_t *buf, uint16_t len);               // DeviceRequestTO, bmRequestType 0x40, 1000 ms timeouts
  kern_return_t ushr_dev_vendor_in(ushr_dev *dev, uint8_t bRequest, uint8_t *buf, uint16_t len, uint16_t *actual);    // bmRequestType 0xC0
  ```
  ```swift
  public final class IOKitTransport: ControlTransport, @unchecked Sendable { // serialises calls with an NSLock
      public init(service: io_service_t) throws
      // maps kr 0xE000404F -> .stalled, 0xE0004051 -> .timeout, kIOReturnNoDevice/kIOReturnNotResponding/kIOReturnNotAttached -> .deviceGone, else .io(kr)
  }
  public struct AttachedDevice: Sendable {
      public let registryID: UInt64; public let productID: UInt16; public let productName: String?
      public let serialNumber: String?; public let transport: IOKitTransport
      public var model: USHRModel { get }
      public var persistenceKey: String { get }   // serialNumber ?? "pid-\(productID)"
  }
  public final class DeviceMonitor: @unchecked Sendable {
      public init(onAttach: @escaping @Sendable (AttachedDevice) -> Void, onDetach: @escaping @Sendable (UInt64) -> Void)
      public func start()  // matching "IOUSBHostDevice" with idVendor 0x0644 + each productID; kIOFirstMatchNotification; drains iterator; interest notification for kIOMessageServiceIsTerminated
      public func stop()
  }
  ```
  Run-loop: the monitor owns an `IONotificationPort` scheduled on the main run loop (the app and the probe both run one).

- [ ] **Step 1: Implement the shim and Swift wrappers** (no unit tests: this is the hardware boundary; Task 5 is its test).
- [ ] **Step 2: Run** `swift build` — expect success with no errors (deprecation warnings for `IOUSBLib` are acceptable; note them).
- [ ] **Step 3: Commit** `git commit -m "feat: IOKit vendor-request transport and hot-plug monitor"`

---

### Task 5: Probe CLI and hardware verification

**Files:**
- Create: `Sources/ushr-probe/main.swift`, `docs/protocol-findings.md`
- Modify: `Package.swift` (add `ushr-probe`)

**Interfaces:**
- Consumes: `DeviceMonitor`, `AttachedDevice` (Task 4); `USHRSession`, `Command`, `DeviceReport` (Tasks 2–3).
- Produces: CLI `ushr-probe <subcommand>`:
  - `list` — prints each attached device: model, product name, serial, registry ID.
  - `info` — `query([.getInfo])`, `query([.getSampleRate])`, `query([.getAutoPowerSave])`; prints report.
  - `read-all` — queries stereo (5,1) (4,1) (3,1), mute (4,1…4), fader (5,1), assign, APS; prints each with raw reply hex.
  - `raw-read` — one `controlIn(64)` hex dump (no OUT).
  - `set <name> <value>` — exactly one of: `dm-stereo mono|stereo`, `balance 0-127`, `input <1-4> on|off`, `lineout monitor|pc12|pc34`, `loopback on|off`, `loopback-volume 0-127`, `loopback-in mono|stereo`, `loopback-out mono|stereo`, `aps on|off`; maps through `PanelCommands` (Task 2). Prints the result of a follow-up `read-all`.
  Exits non-zero with a clear message on `.deviceBusy`, `.noReply`, `.deviceGone`, or no device found within 2 s.

- [ ] **Step 1: Implement `main.swift`** (start `DeviceMonitor`, wait up to 2 s on the run loop for the first attach, run subcommand on a `Task`, exit).
- [ ] **Step 2: Build** `swift build --product ushr-probe` — expect success.
- [ ] **Step 3: Run** `.build/debug/ushr-probe list` with the US‑1x2HR attached — expect one line containing `US-1x2HR` and PID `0x806F`. If `DeviceRequest`-based calls later fail with `kIOReturnExclusiveAccess` or `kIOReturnNotPrivileged`: **stop, record in findings, ask the owner** (Global Constraints).
- [ ] **Step 4: Run** `.build/debug/ushr-probe info` — expect product name, firmware version, sample rate (e.g. 48000), APS. If `.noReply`: try `raw-read` and record what arrives.
- [ ] **Step 5: Run** `.build/debug/ushr-probe read-all` — record which mute indices, stereo channels, fader and assign values the 1x2HR reports.
- [ ] **Step 6: Reversible set checks** (owner present to listen): for each `set` command, note the before value from `read-all`, set the opposite, confirm by `read-all` (where readable) and by the owner, then restore the original value. Confirm specifically: Audio Input on/off meaning and polarity; line-out destination indices (1,2); loopback ch 6 idx 0/1 behaviour.
- [ ] **Step 7: Write `docs/protocol-findings.md`** — table of each spec [I] item → confirmed value / correction, with the raw hex observed. If any value differs from this plan, update the constants in `Command.swift`/`PanelCommands` and the matching test fixtures, re-run `swift test`.
- [ ] **Step 8: Commit** `git commit -m "feat: ushr-probe CLI and hardware protocol findings"`

---

### Task 6: Panel state model

**Files:**
- Create: `Sources/USHRPanelCore/LastSetStore.swift`, `Sources/USHRPanelCore/PanelModel.swift`
- Test: `Tests/USHRPanelCoreTests/PanelModelTests.swift` (with `FakeDevice: USHRControlling`)
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `USHRControlling`, `Command`, `Channel`, `StereoMode`, `DeviceReport`, `USHRModel`, `LineOutSource`, `PanelCommands` (Tasks 2–3).
- Produces:
  ```swift
  public final class LastSetStore: @unchecked Sendable {
      public init(defaults: UserDefaults = .standard)
      public func loopbackEnabled(_ key: String) -> Bool?;  public func setLoopbackEnabled(_ v: Bool, _ key: String)
      public func loopbackVolume(_ key: String) -> UInt8?;  public func setLoopbackVolume(_ v: UInt8, _ key: String)
  }  // UserDefaults keys: "device.<key>.loopbackEnabled", "device.<key>.loopbackVolume"
  @MainActor @Observable public final class PanelModel {
      public enum Connection: Equatable { case noDevice, reading, connected, error(String) }
      public private(set) var connection: Connection = .noDevice
      public private(set) var model: USHRModel?; public private(set) var firmware: String?; public private(set) var sampleRate: UInt32?
      public var directMonitorStereo = false; public var monitorBalance: Double = 64      // 0…127
      public var audioInputs: [Bool] = []; public var lineOut: LineOutSource = .monitorMix
      public var loopbackEnabled: Bool? ; public var loopbackVolume: Double? ; public var loopbackInStereo = false; public var loopbackOutStereo = false
      public var autoPowerSave = false
      public init(store: LastSetStore, sliderInterval: Duration = .milliseconds(50))
      public func attach(device: any USHRControlling, model: USHRModel, key: String) async   // sets .reading, runs readAll batches, applies report, loads loopback values from store, sets .connected (or .error)
      public func detach()                                                                     // drops pending sends, clears values, .noDevice
      public func setDirectMonitorStereo(_ v: Bool); public func setMonitorBalance(_ v: Double)
      public func setAudioInput(_ n: Int, _ on: Bool); public func setLineOut(_ s: LineOutSource)
      public func setLoopback(_ on: Bool); public func setLoopbackVolume(_ v: Double)
      public func setLoopbackIn(stereo: Bool); public func setLoopbackOut(stereo: Bool); public func setAutoPowerSave(_ on: Bool)
  }
  ```
  Setters update state immediately (optimistic) and send via a single serial `Task` chain; sliders coalesce: at most one send per `sliderInterval`, and the final value is always sent. A send error sets `.error(message)` and triggers a re-read. Firmware text: `"\(version >> 8).\(String(format: "%02d", version & 0xFF))"` plus build if present (owner sees e.g. "1.00 (0022)", matching the original's `"1.00 0022"` style).

- [ ] **Step 1: Write failing `PanelModelTests`** (use `sliderInterval: .zero` except the burst test; `UserDefaults(suiteName: UUID().uuidString)!`):
  ```swift
  func test_attach_appliesDeviceReport()       // FakeDevice returns stereo (5,1)=.stereo, fader (5,1)=27, APS true -> directMonitorStereo true, monitorBalance 100, autoPowerSave true, connection .connected
  func test_attach_loopbackFromStore_orNil()   // empty store -> loopbackEnabled nil; after setLoopback(true) and reattach -> true
  func test_setter_sendsMappedCommand()        // setAutoPowerSave(false) -> device.sent.last == [.setAutoPowerSave(false)]
  func test_sliderBurst_sendsLatestValueLast() // interval 50ms; setMonitorBalance 10,20,30 quickly -> last sent == monitorBalance(30), sends ≤ 2
  func test_sendError_setsErrorAndRereads()    // device throws .deviceBusy on send -> connection .error(_), readAll called again
  func test_detachDuringPendingSend_endsNoDevice() // detach while a send is suspended -> connection .noDevice, no crash, values cleared
  func test_reattach_rereadsState()            // attach, detach, attach with different report -> new values shown
  ```
- [ ] **Step 2: Run** `swift test --filter PanelModelTests` — expect FAIL.
- [ ] **Step 3: Implement** `LastSetStore.swift` and `PanelModel.swift`.
- [ ] **Step 4: Run** `swift test` — all PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: panel state model with command mapping and coalescing"`

---

### Task 7: SwiftUI app and app bundle

**Files:**
- Create: `Sources/USHRSettingsPanel/USHRSettingsPanelApp.swift`, `Sources/USHRSettingsPanel/PanelView.swift`, `Sources/USHRSettingsPanel/DeviceCoordinator.swift`, `Resources/Info.plist`, `scripts/build-app.sh`
- Modify: `Package.swift`, `README.md` (build/run instructions)

**Interfaces:**
- Consumes: `PanelModel`, `LastSetStore`, `LineOutSource`, `PanelCommands.inputCount` (Task 6); `DeviceMonitor`, `AttachedDevice` (Task 4); `USHRSession` (Task 3).
- Produces: `build/US-HR Settings Panel.app` (bundle ID `com.codeworx.ushr-settings-panel`, `LSMinimumSystemVersion 14.0`, `CFBundleExecutable USHRSettingsPanel`).

`DeviceCoordinator` (`@MainActor`): owns `DeviceMonitor`; on attach of the first device creates `USHRSession(transport:)` and calls `model.attach(device:model:key:)`; on detach of that registry ID calls `model.detach()`; ignores extra devices. `PanelView` layout per spec §7: header (connection state / model / firmware / sample rate "48 kHz"), sections Direct Monitor (Mono/Stereo segmented), Monitor Balance (slider 0…127 labelled "Input" ↔ "Computer"), Inputs (toggle per `inputCount`), Line Out (picker; hide `computerOut34` unless 4x4), Loopback (toggle; when on: volume slider 0…127, Input Mono/Stereo, Output Mono/Stereo; nil values shown as "not read from device" caption), Power (Auto Power Save toggle). All controls disabled unless `.connected`; `.error` shown as an inline banner. Use a single `Window` scene (id `"panel"`, title `US‑HR Settings Panel`, `.windowResizability(.contentSize)`); SwiftUI's built-in frame autosave covers "remember window position" (spec §5).

`scripts/build-app.sh`: `swift build -c release --product USHRSettingsPanel --arch arm64`, create bundle `Contents/{MacOS,Resources}`, copy binary and `Resources/Info.plist`, then `codesign --force --options runtime -s - "build/US-HR Settings Panel.app"`, then `codesign --verify --strict` it.

- [ ] **Step 1: Implement** the three Swift files, Info.plist, script; update README.
- [ ] **Step 2: Run** `swift build` and `swift test` — all PASS.
- [ ] **Step 3: Run** `scripts/build-app.sh` — expect `build/US-HR Settings Panel.app` and `codesign --verify` silent success; `file` on the binary reports `arm64`.
- [ ] **Step 4: Run** `open "build/US-HR Settings Panel.app"` with the device attached — window shows `US-1x2HR`, firmware, sample rate and the values from `ushr-probe read-all`.
- [ ] **Step 5: Commit** `git commit -m "feat: SwiftUI settings panel app and bundle script"`

---

### Task 8: Hardware acceptance with the owner

**Files:**
- Create: `docs/acceptance-2026-11.md` (checklist results)

- [ ] **Step 1:** With the owner, for each control (Direct Monitor, Monitor Balance, each Audio Input, Line Out, Loopback on/off/volume/in/out, Auto Power Save): change it in the app and confirm the device behaves as it did with TASCAM's panel (owner's ears/meters are the oracle). Record pass/fail.
- [ ] **Step 2:** Unplug during use → "No Device" within ~1 s, no hang; replug → state re-read and shown.
- [ ] **Step 3:** Quit and relaunch → loopback values restored from `LastSetStore`; other values read from device.
- [ ] **Step 4:** Fix any failure (back to the owning task's tests first), rerun `swift test` and `scripts/build-app.sh`.
- [ ] **Step 5: Commit** `git commit -m "docs: hardware acceptance results"`
