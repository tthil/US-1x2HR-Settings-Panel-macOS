public enum USHRModel: Equatable, Sendable {
    case us1x2HR, us2x2HR, us4x4HR, unknown(UInt16)

    public static let vendorID: UInt16 = 0x0644
    public static let productIDs: [UInt16] = [0x806F, 0x8070, 0x8071]

    /// A product name containing a known model string wins over the USB product ID.
    public init(productID: UInt16, productName: String?) {
        if let name = productName {
            if name.contains("US-1x2HR") { self = .us1x2HR; return }
            if name.contains("US-2x2HR") { self = .us2x2HR; return }
            if name.contains("US-4x4HR") { self = .us4x4HR; return }
        }
        switch productID {
        case 0x806F: self = .us1x2HR
        case 0x8070: self = .us2x2HR
        case 0x8071: self = .us4x4HR
        default: self = .unknown(productID)
        }
    }

    public var displayName: String {
        switch self {
        case .us1x2HR: return "US-1x2HR"
        case .us2x2HR: return "US-2x2HR"
        case .us4x4HR: return "US-4x4HR"
        case .unknown(let id):
            let hex = String(id, radix: 16, uppercase: true)
            return "Unknown US-HR (0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + ")"
        }
    }
}
