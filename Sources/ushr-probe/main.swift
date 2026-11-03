import Foundation
import USHRProtocol
import USHRDevice

// ushr-probe: command-line tool for talking to a US-HR device.
// All bytes sent are produced by `Command`; the recorder below only observes.

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// Logs every OUT/IN transfer to stderr; forwards to the wrapped transport unchanged.
final class RecordingTransport: ControlTransport, @unchecked Sendable {
    private let inner: any ControlTransport
    private let quiet: Bool
    init(_ inner: any ControlTransport, quiet: Bool) { self.inner = inner; self.quiet = quiet }

    func controlOut(_ bytes: [UInt8]) throws {
        if !quiet { err("  OUT[\(bytes.count)] \(hex(bytes))") }
        do { try inner.controlOut(bytes) } catch {
            if !quiet { err("  OUT failed: \(error)") }
            throw error
        }
    }

    func controlIn(maxLength: Int) throws -> [UInt8] {
        do {
            let b = try inner.controlIn(maxLength: maxLength)
            if !quiet { err("  IN [\(b.count)] \(hex(b))") }
            return b
        } catch {
            if !quiet { err("  IN failed: \(error)") }
            throw error
        }
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [AttachedDevice] = []
    var all: [AttachedDevice] { lock.lock(); defer { lock.unlock() }; return devices }
    func add(_ d: AttachedDevice) { lock.lock(); devices.append(d); lock.unlock() }
}

func describe(_ e: Error) -> String {
    switch e {
    case SessionError.deviceBusy: return "device busy (never reported ready)"
    case SessionError.noReply: return "no reply from device"
    case TransportError.io(let kr): return "transport I/O error kern_return 0x" + String(UInt32(bitPattern: kr), radix: 16, uppercase: true)
    case TransportError.deviceGone: return "device gone"
    default: return "\(e)"
    }
}

func printReport(_ r: DeviceReport) {
    if let v = r.productName { print("  product name : \(v)") }
    if let v = r.version { print("  version      : \(v) (0x\(String(v, radix: 16)))") }
    if let v = r.build { print("  build        : \(v)") }
    if let v = r.buildDate { print("  build date   : \(v)") }
    if let v = r.buildTime { print("  build time   : \(v)") }
    if let v = r.productSignature { print("  signature    : \(v)") }
    if let v = r.sampleRate { print("  sample rate  : \(v) Hz") }
    if let v = r.autoPowerSave { print("  auto pwr save: \(v ? "on" : "off")") }
    for (c, v) in r.stereo.sorted(by: { ($0.key.type.rawValue, $0.key.index) < ($1.key.type.rawValue, $1.key.index) }) {
        print("  stereo \(c.type) idx \(c.index): \(v)")
    }
    for (c, v) in r.mutes.sorted(by: { ($0.key.type.rawValue, $0.key.index) < ($1.key.type.rawValue, $1.key.index) }) {
        print("  mute   \(c.type) idx \(c.index): \(v)")
    }
    for (c, v) in r.faders.sorted(by: { ($0.key.type.rawValue, $0.key.index) < ($1.key.type.rawValue, $1.key.index) }) {
        print("  fader  \(c.type) idx \(c.index): \(v)")
    }
    for (d, s) in r.assignments.sorted(by: { $0.key.index < $1.key.index }) {
        print("  assign \(s.type) idx \(s.index) -> \(d.type) idx \(d.index)")
    }
}

/// Returns false if any step failed.
func readAll(_ dev: AttachedDevice, session: USHRSession) async -> Bool {
    var ok = true
    for group in PanelCommands.readAll(for: dev.model) {
        print("query: \(group)")
        do {
            let r = try await session.query(group)
            printReport(r)
        } catch {
            ok = false
            print("  FAILED: \(describe(error))")
        }
    }
    return ok
}

func parseSet(_ args: [String]) -> [Command]? {
    guard args.count == 2 else { return nil }
    let v = args[1]
    func onoff() -> Bool? { v == "on" ? true : v == "off" ? false : nil }
    func ms() -> Bool? { v == "stereo" ? true : v == "mono" ? false : nil }
    func num() -> UInt8? { UInt8(v).flatMap { $0 <= 127 ? $0 : nil } }
    switch args[0] {
    case "dm-stereo": return ms().map { PanelCommands.directMonitor(stereo: $0) }
    case "balance": return num().map { PanelCommands.monitorBalance($0) }
    case "lineout":
        switch v {
        case "monitor": return PanelCommands.lineOut(.monitorMix)
        case "pc12": return PanelCommands.lineOut(.computerOut12)
        case "pc34": return PanelCommands.lineOut(.computerOut34)
        default: return nil
        }
    case "loopback": return onoff().map { PanelCommands.loopback(on: $0) }
    case "loopback-volume": return num().map { PanelCommands.loopbackVolume($0) }
    case "loopback-in": return ms().map { PanelCommands.loopbackIn(stereo: $0) }
    case "loopback-out": return ms().map { PanelCommands.loopbackOut(stereo: $0) }
    case "aps": return onoff().map { PanelCommands.autoPowerSave($0) }
    default: return nil
    }
}

let usage = """
usage: ushr-probe [--verbose] <list | info | read-all | raw-read | set <name> <value>>
  set: dm-stereo mono|stereo | balance 0-127 | input <1-4> on|off | lineout monitor|pc12|pc34
       loopback on|off | loopback-volume 0-127 | loopback-in mono|stereo
       loopback-out mono|stereo | aps on|off
"""

var args = Array(CommandLine.arguments.dropFirst())
let verbose = args.contains("--verbose")
args.removeAll { $0 == "--verbose" }
guard let sub = args.first else { err(usage); exit(64) }
let rest = Array(args.dropFirst())

// Validate `set` arguments before touching hardware.
var setCommands: [Command] = []
if sub == "set" {
    if rest.count == 3, rest[0] == "input", let n = UInt8(rest[1]), (1...4).contains(n),
       rest[2] == "on" || rest[2] == "off" {
        setCommands = PanelCommands.audioInput(n, on: rest[2] == "on")
    } else if let c = parseSet(rest) {
        setCommands = c
    } else { err(usage); exit(64) }
} else if !["list", "info", "read-all", "raw-read"].contains(sub) {
    err(usage); exit(64)
}

let found = Box()
let monitor = DeviceMonitor(onAttach: { found.add($0) }, onDetach: { _ in }, onError: { err("monitor: \($0)") })
monitor.start()
let deadline = Date().addingTimeInterval(2)
while found.all.isEmpty && Date() < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.05, false)
}
// Let any further attach notifications for other devices land.
CFRunLoopRunInMode(.defaultMode, 0.1, false)
let devices = found.all
guard let device = devices.first else {
    err("error: no US-HR device found within 2 s")
    exit(2)
}

nonisolated(unsafe) var exitCode: Int32 = 0
nonisolated(unsafe) var finished = false

let work = Task {
    let quiet = !(verbose || sub == "read-all" || sub == "info")
    let session = USHRSession(transport: RecordingTransport(device.transport, quiet: quiet))
    switch sub {
    case "list":
        for d in devices {
            print("\(d.model.displayName)  name=\(d.productName ?? "?")  pid=0x\(String(d.productID, radix: 16, uppercase: true))  serial=\(d.serialNumber ?? "?")  registryID=\(d.registryID)")
        }
    case "info":
        for group in [[Command.getInfo], [.getSampleRate], [.getAutoPowerSave]] {
            print("query: \(group)")
            do { printReport(try await session.query(group)) } catch {
                print("  FAILED: \(describe(error))"); exitCode = 1
            }
        }
    case "read-all":
        if !(await readAll(device, session: session)) { exitCode = 1 }
    case "raw-read":
        do {
            let b = try device.transport.controlIn(maxLength: 64)
            print("IN [\(b.count)] \(hex(b))")
        } catch { print("FAILED: \(describe(error))"); exitCode = 1 }
    case "set":
        do {
            try await session.send(setCommands)
            print("sent: \(setCommands)")
        } catch { print("FAILED: \(describe(error))"); exitCode = 1 }
        print("-- read-all after set --")
        if !(await readAll(device, session: session)) { exitCode = 1 }
    default: break
    }
    finished = true
}
_ = work
while !finished { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
monitor.stop()
exit(exitCode)
