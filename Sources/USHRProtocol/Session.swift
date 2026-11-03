public enum TransportError: Error, Equatable {
    case stalled, timeout, deviceGone, io(Int32)
}

public protocol ControlTransport: Sendable {
    /// OUT, bmRequestType 0x40, bRequest 0x1D.
    func controlOut(_ bytes: [UInt8]) throws
    /// IN, bmRequestType 0xC0, bRequest 0x1E.
    func controlIn(maxLength: Int) throws -> [UInt8]
}

public struct SessionTiming: Sendable {
    public var retryDelay: Duration = .milliseconds(10)
    public var readyAttempts = 1000
    public var sendAttempts = 3
    public var replyAttempts = 100
    public var assignReadDelay: Duration = .milliseconds(100)

    public init() {}

    public static var immediate: SessionTiming {
        var t = SessionTiming()
        t.retryDelay = .zero
        t.assignReadDelay = .zero
        return t
    }
}

public enum SessionError: Error, Equatable {
    case deviceBusy, noReply
}

public protocol USHRControlling: Sendable {
    func send(_ commands: [Command]) async throws
    func query(_ commands: [Command]) async throws -> DeviceReport
}

public actor USHRSession: USHRControlling {
    private let transport: any ControlTransport
    private let timing: SessionTiming

    public init(transport: any ControlTransport, timing: SessionTiming = .init()) {
        self.transport = transport
        self.timing = timing
    }

    private func pause(_ duration: Duration) async throws {
        if duration != .zero { try await Task.sleep(for: duration) }
    }

    // FIFO single-flight lock: public operations hold it across suspension points so
    // actor reentrancy cannot interleave their transport traffic.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Polls until no `0xA1 == 0` record is present in a reply.
    public func waitReady() async throws {
        await acquire()
        defer { release() }
        try await pollReady()
    }

    private func pollReady() async throws {
        for attempt in 0..<timing.readyAttempts {
            try Task.checkCancellation()
            do {
                let bytes = try transport.controlIn(maxLength: TLV.maxMessageLength)
                // A malformed reply carries no busy marker we can trust; treat as not ready.
                if let records = try? TLV.decode(bytes), !DeviceReport.parse(records).busy {
                    return
                }
            } catch let error as TransportError where error == .stalled || error == .timeout {
                // Not ready; keep polling.
            }
            if attempt + 1 < timing.readyAttempts { try await pause(timing.retryDelay) }
        }
        throw SessionError.deviceBusy
    }

    private static func encodedLength(_ records: [TLVRecord]) -> Int {
        do { return try TLV.encode(records).count } catch TLVError.messageTooLong(let n) { return n } catch { return Int.max }
    }

    /// Greedily packs whole record groups into messages of at most 64 bytes.
    static func pack(_ groups: [[TLVRecord]]) throws -> [[UInt8]] {
        var current: [TLVRecord] = []
        var messages: [[UInt8]] = []
        for records in groups {
            if !current.isEmpty, encodedLength(current + records) > TLV.maxMessageLength {
                messages.append(try TLV.encode(current))
                current = []
            }
            current += records
        }
        if !current.isEmpty { messages.append(try TLV.encode(current)) }
        return messages
    }

    public func send(_ commands: [Command]) async throws {
        await acquire()
        defer { release() }
        try await sendLocked(commands)
    }

    private func sendLocked(_ commands: [Command]) async throws {
        let messages = try Self.pack(commands.map(\.records))
        for message in messages {
            try await pollReady()
            try await write(message)
        }
    }

    private func write(_ message: [UInt8]) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try transport.controlOut(message)
                return
            } catch let error as TransportError where error == .stalled || error == .timeout {
                if attempt >= timing.sendAttempts { throw error }
                try await pause(timing.retryDelay)
            }
        }
    }

    public func query(_ commands: [Command]) async throws -> DeviceReport {
        await acquire()
        defer { release() }
        try await sendLocked(commands)
        if commands.contains(.getAssign) { try await pause(timing.assignReadDelay) }

        var report = DeviceReport()
        for _ in 0..<timing.replyAttempts {
            try Task.checkCancellation()
            let bytes = try transport.controlIn(maxLength: TLV.maxMessageLength)
            if let records = try? TLV.decode(bytes) {
                report.merge(DeviceReport.parse(records))
            }
            if !report.isEmpty { return report }
        }
        throw SessionError.noReply
    }
}
