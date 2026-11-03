/// Value carried by one TLV record. Wire type bytes: flag=1, u8=2, u16=3, u32=4, bytes=5.
public enum TLVValue: Equatable, Sendable {
    case flag
    case u8(UInt8)
    case u16(UInt16)
    case u32(UInt32)
    case bytes([UInt8])
}

public struct TLVRecord: Equatable, Sendable {
    public var tag: UInt8
    public var value: TLVValue

    public init(_ tag: UInt8, _ value: TLVValue) {
        self.tag = tag
        self.value = value
    }
}

public enum TLVError: Error, Equatable {
    case messageTooLong(Int)
    case truncated(offset: Int)
    case unknownType(UInt8, offset: Int)
}

/// Codec for the US-HR control message format: `tag, type, payload...` records
/// terminated by `00 00`, at most 64 bytes in total. Multi-byte integers are little-endian.
public enum TLV {
    public static let maxMessageLength = 64

    public static func encode(_ records: [TLVRecord]) throws -> [UInt8] {
        var out: [UInt8] = []
        for record in records {
            out.append(record.tag)
            switch record.value {
            case .flag:
                out.append(1)
            case .u8(let v):
                out += [2, v]
            case .u16(let v):
                out += [3, UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
            case .u32(let v):
                out.append(4)
                for shift in stride(from: 0, to: 32, by: 8) {
                    out.append(UInt8(truncatingIfNeeded: v >> UInt32(shift)))
                }
            case .bytes(let data):
                out += [5, UInt8(truncatingIfNeeded: data.count)] + data
            }
        }
        out += [0, 0]
        guard out.count <= maxMessageLength else { throw TLVError.messageTooLong(out.count) }
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws -> [TLVRecord] {
        var records: [TLVRecord] = []
        var i = 0
        while bytes.count - i >= 2 {
            let tag = bytes[i]
            let type = bytes[i + 1]
            if type == 0 { break }
            let payload = i + 2
            let value: TLVValue
            let size: Int
            switch type {
            case 1:
                value = .flag; size = 0
            case 2:
                guard bytes.count - payload >= 1 else { throw TLVError.truncated(offset: i) }
                value = .u8(bytes[payload]); size = 1
            case 3:
                guard bytes.count - payload >= 2 else { throw TLVError.truncated(offset: i) }
                value = .u16(UInt16(bytes[payload]) | UInt16(bytes[payload + 1]) << 8); size = 2
            case 4:
                guard bytes.count - payload >= 4 else { throw TLVError.truncated(offset: i) }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(bytes[payload + k]) << UInt32(8 * k) }
                value = .u32(v); size = 4
            case 5:
                guard bytes.count - payload >= 1 else { throw TLVError.truncated(offset: i) }
                let n = Int(bytes[payload])
                guard bytes.count - payload - 1 >= n else { throw TLVError.truncated(offset: i) }
                value = .bytes(Array(bytes[(payload + 1)..<(payload + 1 + n)])); size = 1 + n
            default:
                throw TLVError.unknownType(type, offset: i)
            }
            records.append(TLVRecord(tag, value))
            i = payload + size
        }
        return records
    }
}
