import Foundation
import XCTest
import USHRProtocol

final class FakeTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]]
    private var _outs: [[UInt8]] = []
    private var _outAttempts = 0
    private var _inReads = 0
    private let outBehavior: @Sendable (Int) throws -> Void

    init(ins: [[UInt8]] = [], outBehavior: @escaping @Sendable (Int) throws -> Void = { _ in }) {
        self.queue = ins
        self.outBehavior = outBehavior
    }

    var outs: [[UInt8]] { lock.withLock { _outs } }
    var outAttempts: Int { lock.withLock { _outAttempts } }
    var inReads: Int { lock.withLock { _inReads } }

    func controlOut(_ bytes: [UInt8]) throws {
        let attempt = lock.withLock { () -> Int in
            _outAttempts += 1
            return _outAttempts
        }
        try outBehavior(attempt)
        lock.withLock { _outs.append(bytes) }
    }

    func controlIn(maxLength: Int) throws -> [UInt8] {
        lock.withLock {
            _inReads += 1
            return queue.isEmpty ? [0, 0] : queue.removeFirst()
        }
    }
}

final class SessionTests: XCTestCase {
    func test_send_waitsReadyThenWritesOneMessage() async throws {
        let t = FakeTransport(ins: [[0xA1, 2, 0, 0, 0], [0xA1, 2, 1, 0, 0]])
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.send([.setAutoPowerSave(true)])
        XCTAssertEqual(t.outs, [[0x15, 2, 1, 0, 0]])
        XCTAssertEqual(t.inReads, 2)
    }

    func test_waitReady_noA1Record_isReady() async throws {
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0]])
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.waitReady()
        XCTAssertEqual(t.inReads, 1)
    }

    func test_waitReady_givesUpAfterAttemptLimit() async {
        let t = FakeTransport(ins: Array(repeating: [0xA1, 2, 0, 0, 0], count: 20))
        var timing = SessionTiming.immediate
        timing.readyAttempts = 5
        let s = USHRSession(transport: t, timing: timing)
        do {
            try await s.waitReady()
            XCTFail("expected deviceBusy")
        } catch {
            XCTAssertEqual(error as? SessionError, .deviceBusy)
        }
        XCTAssertEqual(t.inReads, 5)
    }

    func test_send_retriesStallTwiceThenSucceeds() async throws {
        let t = FakeTransport { attempt in if attempt <= 2 { throw TransportError.stalled } }
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.send([.setAutoPowerSave(false)])
        XCTAssertEqual(t.outAttempts, 3)
        XCTAssertEqual(t.outs.count, 1)
    }

    func test_send_givesUpAfterThreeStalls() async {
        let t = FakeTransport { _ in throw TransportError.stalled }
        let s = USHRSession(transport: t, timing: .immediate)
        do {
            try await s.send([.setAutoPowerSave(false)])
            XCTFail("expected stalled")
        } catch {
            XCTAssertEqual(error as? TransportError, .stalled)
        }
        XCTAssertEqual(t.outAttempts, 3)
    }

    func test_send_splitsLongBatchAcrossMessages() async throws {
        let t = FakeTransport()
        let s = USHRSession(transport: t, timing: .immediate)
        let commands = (0..<8).map { Command.setFader(Channel(.computerOut, UInt8($0)), 10) }
        try await s.send(commands)
        XCTAssertEqual(t.outs.count, 2)
        for out in t.outs {
            XCTAssertLessThanOrEqual(out.count, 64)
            XCTAssertEqual(Array(out.suffix(2)), [0, 0])
            // Every message decodes to whole commands (3 records each).
            XCTAssertEqual(try TLV.decode(out).count % 3, 0)
        }
        let all = try t.outs.flatMap { try TLV.decode($0) }
        XCTAssertEqual(all, commands.flatMap(\.records))
    }

    func test_query_returnsParsedReport() async throws {
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0], [0x15, 2, 1, 0, 0]])
        let s = USHRSession(transport: t, timing: .immediate)
        let report = try await s.query([.getAutoPowerSave])
        XCTAssertEqual(report.autoPowerSave, true)
    }

    func test_query_noReply_throws() async {
        let t = FakeTransport()
        var timing = SessionTiming.immediate
        timing.replyAttempts = 3
        let s = USHRSession(transport: t, timing: timing)
        do {
            _ = try await s.query([.getAutoPowerSave])
            XCTFail("expected noReply")
        } catch {
            XCTAssertEqual(error as? SessionError, .noReply)
        }
        // 1 ready read + 3 reply reads
        XCTAssertEqual(t.inReads, 4)
    }

    func test_transportGoneDuringSend_throwsDeviceGone() async {
        let t = FakeTransport { _ in throw TransportError.deviceGone }
        let s = USHRSession(transport: t, timing: .immediate)
        do {
            try await s.send([.setAutoPowerSave(true)])
            XCTFail("expected deviceGone")
        } catch {
            XCTAssertEqual(error as? TransportError, .deviceGone)
        }
        XCTAssertEqual(t.outAttempts, 1)
    }
}
