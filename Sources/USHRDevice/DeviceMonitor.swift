import Foundation
import IOKit
import USHRProtocol

public struct AttachedDevice: Sendable {
    public let registryID: UInt64
    public let productID: UInt16
    public let productName: String?
    public let serialNumber: String?
    public let transport: IOKitTransport

    public var model: USHRModel { USHRModel(productID: productID, productName: productName) }
    public var persistenceKey: String { serialNumber ?? "pid-\(productID)" }
}

/// Watches for US-HR devices on the main run loop. Callbacks arrive on the main thread.
public final class DeviceMonitor: @unchecked Sendable {
    /// Refcon for per-device interest notifications.
    private final class Context {
        let monitor: DeviceMonitor
        let registryID: UInt64
        init(_ m: DeviceMonitor, _ id: UInt64) { monitor = m; registryID = id }
    }

    private struct Watch {
        let notification: io_object_t
        let context: Unmanaged<Context>
    }

    /// kIOMessageServiceIsTerminated (iokit_common_msg(0x010)); the macro is not imported into Swift.
    private static let serviceIsTerminated: UInt32 = 0xE000_0010

    private let onAttach: @Sendable (AttachedDevice) -> Void
    private let onDetach: @Sendable (UInt64) -> Void
    private let onError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var port: IONotificationPortRef?
    private var matchIterators: [io_iterator_t] = []
    private var watches: [UInt64: Watch] = [:]

    public init(onAttach: @escaping @Sendable (AttachedDevice) -> Void,
                onDetach: @escaping @Sendable (UInt64) -> Void,
                onError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onAttach = onAttach
        self.onDetach = onDetach
        self.onError = onError
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        if port != nil { lock.unlock(); return }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { lock.unlock(); return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(),
                           .defaultMode)
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var iterators: [io_iterator_t] = []
        for pid in USHRModel.productIDs {
            guard let dict = IOServiceMatching("IOUSBHostDevice") else { continue }
            let d = dict as NSMutableDictionary
            d["idVendor"] = Int(USHRModel.vendorID)
            d["idProduct"] = Int(pid)
            var it: io_iterator_t = 0
            let kr = IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, dict, { refCon, iterator in
                guard let refCon else { return }
                Unmanaged<DeviceMonitor>.fromOpaque(refCon).takeUnretainedValue().drain(iterator)
            }, refCon, &it)
            if kr == 0 { iterators.append(it) }
        }
        matchIterators = iterators
        lock.unlock()
        for it in iterators { drain(it) }
    }

    public func stop() {
        lock.lock()
        let p = port
        port = nil
        let its = matchIterators
        matchIterators = []
        let ws = watches
        watches = [:]
        lock.unlock()
        guard let p else { return }
        for it in its { IOObjectRelease(it) }
        for w in ws.values {
            IOObjectRelease(w.notification)
            w.context.release()
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(),
                              .defaultMode)
        IONotificationPortDestroy(p)
    }

    // MARK: - Internals

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            attach(service)
        }
    }

    private func attach(_ service: io_service_t) {
        var rid: UInt64 = 0
        let ridKR = IORegistryEntryGetRegistryEntryID(service, &rid)
        guard ridKR == 0 else {
            onError("Could not read registry entry ID of a matched device: \(Self.hex(ridKR))")
            return
        }
        guard let pid = Self.intProperty(service, "idProduct") else {
            onError("Matched device \(rid) has no idProduct property")
            return
        }
        let transport: IOKitTransport
        do {
            transport = try IOKitTransport(service: service)
        } catch {
            onError("Could not create USB device interface for device \(rid): \(Self.describe(error))")
            return
        }

        lock.lock()
        guard let p = port, watches[rid] == nil else { lock.unlock(); return }
        let ctx = Unmanaged.passRetained(Context(self, rid))
        var note: io_object_t = 0
        let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, { refCon, _, messageType, _ in
            guard let refCon, messageType == DeviceMonitor.serviceIsTerminated else { return }
            let c = Unmanaged<Context>.fromOpaque(refCon).takeUnretainedValue()
            c.monitor.terminated(c.registryID)
        }, ctx.toOpaque(), &note)
        if kr == 0 {
            watches[rid] = Watch(notification: note, context: ctx)
        } else {
            ctx.release()
        }
        lock.unlock()
        guard kr == 0 else {
            onError("Could not register removal notification for device \(rid): \(Self.hex(kr))")
            return  // transport is released on scope exit; device is not reported as attached
        }

        let name = Self.stringProperty(service, ["USB Product Name", "kUSBProductString"])
        let serial = Self.stringProperty(service, ["USB Serial Number", "kUSBSerialNumberString"])
        onAttach(AttachedDevice(registryID: rid, productID: UInt16(truncatingIfNeeded: pid),
                                productName: name, serialNumber: serial, transport: transport))
    }

    private func terminated(_ rid: UInt64) {
        lock.lock()
        let w = watches.removeValue(forKey: rid)
        lock.unlock()
        onDetach(rid)
        if let w {
            IOObjectRelease(w.notification)
            w.context.release()
        }
    }

    private static func hex(_ kr: Int32) -> String {
        "kern_return 0x" + String(UInt32(bitPattern: kr), radix: 16, uppercase: true)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case TransportError.io(let kr): return hex(kr)
        case let t as TransportError: return "\(t)"
        default: return "\(error)"
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ keys: [String]) -> String? {
        for k in keys {
            if let s = property(service, k) as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
