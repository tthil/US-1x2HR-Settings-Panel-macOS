import Foundation
import IOKit
import CUSBShim
import USHRProtocol

/// Pure mapping from a kern_return_t to a TransportError (nil for success).
func transportError(forKernelReturn kr: Int32) -> TransportError? {
    if kr == 0 { return nil }
    switch UInt32(bitPattern: kr) {
    case 0xE000404F: return .stalled
    case 0xE0004051: return .timeout
    default: break
    }
    if kr == kIOReturnNoDevice || kr == kIOReturnNotResponding
        || kr == kIOReturnNotAttached || kr == kIOReturnAborted {
        return .deviceGone
    }
    return .io(kr)
}

public final class IOKitTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var dev: OpaquePointer?

    /// Creates the device interface WITHOUT opening the device.
    public init(service: io_service_t) throws {
        var kr: kern_return_t = 0
        guard let d = ushr_dev_create(service, &kr) else {
            throw transportError(forKernelReturn: kr) ?? TransportError.io(kIOReturnError)
        }
        dev = d
    }

    deinit {
        if let dev { ushr_dev_destroy(dev) }
    }

    public func controlOut(_ bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let kr = bytes.withUnsafeBufferPointer {
            ushr_dev_vendor_out(dev, 0x1D, $0.baseAddress, UInt16(clamping: $0.count))
        }
        if let e = transportError(forKernelReturn: kr) { throw e }
    }

    public func controlIn(maxLength: Int) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var buf = [UInt8](repeating: 0, count: max(0, min(maxLength, 64)))
        var actual: UInt16 = 0
        let kr = buf.withUnsafeMutableBufferPointer {
            ushr_dev_vendor_in(dev, 0x1E, $0.baseAddress, UInt16(clamping: $0.count), &actual)
        }
        if let e = transportError(forKernelReturn: kr) { throw e }
        return Array(buf.prefix(Int(actual)))
    }
}
