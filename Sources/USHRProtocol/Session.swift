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

    /// Polls until no `0xA1 == 0` record is present in a reply.
    public func waitReady() async throws {
        for attempt in 0..<timing.readyAttempts {
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

    private func encodedLength(_ records: [TLVRecord]) -> Int {
        do { return try TLV.encode(records).count } catch TLVError.messageTooLong(let n) { return n } catch { return Int.max }
    }

    public func send(_ commands: [Command]) async throws {
        var current: [TLVRecord] = []
        var messages: [[UInt8]] = []
        for command in commands {
            let records = command.records
            if !current.isEmpty, encodedLength(current + records) > TLV.maxMessageLength {
                messages.append(try TLV.encode(current))
                current = []
            }
            current += records
        }
        if !current.isEmpty { messages.append(try TLV.encode(current)) }

        for message in messages {
            try await waitReady()
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
        try await send(commands)
        if commands.contains(.getAssign) { try await pause(timing.assignReadDelay) }

        var report = DeviceReport()
        for _ in 0..<timing.replyAttempts {
            let bytes = try transport.controlIn(maxLength: TLV.maxMessageLength)
            if let records = try? TLV.decode(bytes) {
                report.merge(DeviceReport.parse(records))
            }
            if !report.isEmpty { return report }
        }
        throw SessionError.noReply
    }
}
