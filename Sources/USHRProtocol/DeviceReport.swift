/// State decoded from device replies. Unknown tags are ignored.
public struct DeviceReport: Equatable, Sendable {
    public var busy = false
    public var autoPowerSave: Bool?
    public var sampleRate: UInt32?
    public var version: UInt16?
    public var build: UInt16?
    public var productName: String?
    public var buildDate: String?
    public var buildTime: String?
    public var productSignature: String?
    public var faders: [Channel: UInt8] = [:]
    public var mutes: [Channel: Bool] = [:]
    public var stereo: [Channel: StereoMode] = [:]
    public var assignments: [Channel: Channel] = [:]  // destination -> source

    public init() {}

    public var isEmpty: Bool {
        var probe = self
        probe.busy = false
        return probe == DeviceReport()
    }

    public static func parse(_ records: [TLVRecord]) -> DeviceReport {
        var report = DeviceReport()
        var typeByte: UInt8?
        var indexByte: UInt8?
        var pendingSource: Channel?
        var pendingDestination: Channel?

        func current() -> Channel? {
            guard let t = typeByte, let i = indexByte, let type = ChannelType(rawValue: t) else { return nil }
            return Channel(type, i)
        }
        func text(_ bytes: [UInt8]) -> String {
            String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
        }

        for record in records {
            switch (record.tag, record.value) {
            case (0x61, .u8(let v)): typeByte = v
            case (0x62, .u8(let v)): indexByte = v
            case (0x81, .u8(let v)), (0xC1, .u8(let v)):
                if let ch = current() { report.faders[ch] = v }
            case (0x83, .u8(let v)), (0xC3, .u8(let v)):
                if let ch = current() { report.mutes[ch] = v != 0 }
            case (0x86, .u8(let v)), (0xC6, .u8(let v)):
                if let ch = current(), let mode = StereoMode(rawValue: v) { report.stereo[ch] = mode }
            case (0x14, .u8(let v)), (0x15, .u8(let v)):
                report.autoPowerSave = v != 0
            case (0x18, .u32(let v)): report.sampleRate = v
            case (0x32, .u16(let v)): report.version = v
            case (0x33, .u16(let v)): report.build = v
            case (0x34, .bytes(let b)): report.productName = text(b)
            case (0x35, .bytes(let b)): report.buildDate = text(b)
            case (0x36, .bytes(let b)): report.buildTime = text(b)
            case (0x37, .bytes(let b)): report.productSignature = text(b)
            case (0xA1, .u8(let v)): if v == 0 { report.busy = true }
            case (0x41, _): pendingSource = current()
            case (0x42, _): pendingDestination = current()
            case (0x43, _):
                if let src = pendingSource, let dst = pendingDestination { report.assignments[dst] = src }
                pendingSource = nil
                pendingDestination = nil
            default: break
            }
        }
        return report
    }

    /// Non-nil / non-empty fields of `other` win.
    public mutating func merge(_ other: DeviceReport) {
        if other.busy { busy = true }
        autoPowerSave = other.autoPowerSave ?? autoPowerSave
        sampleRate = other.sampleRate ?? sampleRate
        version = other.version ?? version
        build = other.build ?? build
        productName = other.productName ?? productName
        buildDate = other.buildDate ?? buildDate
        buildTime = other.buildTime ?? buildTime
        productSignature = other.productSignature ?? productSignature
        faders.merge(other.faders) { _, new in new }
        mutes.merge(other.mutes) { _, new in new }
        stereo.merge(other.stereo) { _, new in new }
        assignments.merge(other.assignments) { _, new in new }
    }
}
