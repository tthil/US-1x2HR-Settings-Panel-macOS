public enum ChannelType: UInt8, Sendable {
    case lineOut = 1, masterOut, computerOut, analogIn, directMonitorOut, loopback
}

public enum StereoMode: UInt8, Sendable {
    case mono = 1
    case stereo = 4
}

public struct Channel: Hashable, Sendable {
    public var type: ChannelType
    public var index: UInt8

    public init(_ type: ChannelType, _ index: UInt8) {
        self.type = type
        self.index = index
    }

    fileprivate var prefix: [TLVRecord] {
        [TLVRecord(0x61, .u8(type.rawValue)), TLVRecord(0x62, .u8(index))]
    }
}

/// The complete set of messages the app can send. Only the tags produced here are ever
/// encodable, so firmware, erase and debug tags are unreachable by construction.
public enum Command: Equatable, Sendable {
    case setFader(Channel, UInt8)
    case setMute(Channel, Bool)
    case setStereo(Channel, StereoMode)
    case setAutoPowerSave(Bool)
    case assign(source: Channel, destination: Channel)
    case getFader(Channel)
    case getMute(Channel)
    case getStereo(Channel)
    case getAutoPowerSave
    case getSampleRate
    case getInfo
    case getAssign

    public var records: [TLVRecord] {
        switch self {
        case .setFader(let ch, let v):
            return ch.prefix + [TLVRecord(0x81, .u8(v))]
        case .setMute(let ch, let on):
            return ch.prefix + [TLVRecord(0x83, .u8(on ? 1 : 0))]
        case .setStereo(let ch, let mode):
            return ch.prefix + [TLVRecord(0x86, .u8(mode.rawValue))]
        case .setAutoPowerSave(let on):
            return [TLVRecord(0x15, .u8(on ? 1 : 0))]
        case .assign(let src, let dst):
            return src.prefix + [TLVRecord(0x41, .flag)]
                + dst.prefix + [TLVRecord(0x42, .flag), TLVRecord(0x43, .flag)]
        case .getFader(let ch):
            return ch.prefix + [TLVRecord(0xC1, .u8(0))]
        case .getMute(let ch):
            return ch.prefix + [TLVRecord(0xC3, .u8(0))]
        case .getStereo(let ch):
            return ch.prefix + [TLVRecord(0xC6, .u8(0))]
        case .getAutoPowerSave:
            return [TLVRecord(0x14, .flag)]
        case .getSampleRate:
            return [TLVRecord(0x18, .flag)]
        case .getInfo:
            return [TLVRecord(0x31, .flag)]
        case .getAssign:
            let zero = [TLVRecord(0x61, .u8(0)), TLVRecord(0x62, .u8(0))]
            return zero + [TLVRecord(0x41, .flag)] + zero + [TLVRecord(0x42, .flag), TLVRecord(0x43, .flag)]
        }
    }
}
