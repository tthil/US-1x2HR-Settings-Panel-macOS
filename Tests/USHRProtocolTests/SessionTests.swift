import Foundation
import XCTest
@testable import USHRProtocol

final class FakeTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[UInt8]]
    private var _outs: [[UInt8]] = []
    private var _outAttempts = 0
    private var _inReads = 0
    enum Event: Equatable { case `in`, out }
    private var _events: [Event] = []
    private let outBehavior: @Sendable (Int) throws -> Void
    private let inBehavior: @Sendable (Int) throws -> Void

    init(ins: [[UInt8]] = [], inBehavior: @escaping @Sendable (Int) throws -> Void = { _ in },
         outBehavior: @escaping @Sendable (Int) throws -> Void = { _ in }) {
        self.inBehavior = inBehavior
        self.queue = ins
        self.outBehavior = outBehavior
    }

    var outs: [[UInt8]] { lock.withLock { _outs } }
    var outAttempts: Int { lock.withLock { _outAttempts } }
    var events: [Event] { lock.withLock { _events } }
    var inReads: Int { lock.withLock { _inReads } }

    func controlOut(_ bytes: [UInt8]) throws {
        let attempt = lock.withLock { () -> Int in
            _outAttempts += 1
            return _outAttempts
        }
        try outBehavior(attempt)
        lock.withLock { _outs.append(bytes); _events.append(.out) }
    }

    func controlIn(maxLength: Int) throws -> [UInt8] {
        let n = lock.withLock { () -> Int in
            _inReads += 1
            _events.append(.in)
            return _inReads
        }
        try inBehavior(n)
        return lock.withLock { queue.isEmpty ? [0, 0] : queue.removeFirst() }
    }
}

final class SessionTests: XCTestCase {
    func test_send_waitsReadyThenWritesOneMessage() async throws {
        let t = FakeTransport(ins: [[0xA1, 2, 0, 0, 0], [0xA1, 2, 1, 0, 0]])
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.send([.setAutoPowerSave(true)])
        XCTAssertEqual(t.outs, [[0x15, 2, 1, 0, 0]])
        XCTAssertEqual(t.inReads, 2)
        XCTAssertEqual(t.events, [.in, .in, .out])
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
        let t = FakeTransport(outBehavior: { attempt in if attempt <= 2 { throw TransportError.stalled } })
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.send([.setAutoPowerSave(false)])
        XCTAssertEqual(t.outAttempts, 3)
        XCTAssertEqual(t.outs.count, 1)
    }

    func test_send_givesUpAfterThreeStalls() async {
        let t = FakeTransport(outBehavior: { _ in throw TransportError.stalled })
        let s = USHRSession(transport: t, timing: .immediate)
        do {
            try await s.send([.setAutoPowerSave(false)])
            XCTFail("expected stalled")
        } catch {
            XCTAssertEqual(error as? TransportError, .stalled)
        }
        XCTAssertEqual(t.outAttempts, 3)
    }

    func test_send_writesOneCommandPerMessage() async throws {
        let t = FakeTransport()
        let s = USHRSession(transport: t, timing: .immediate)
        let commands = (0..<8).map { Command.setFader(Channel(.computerOut, UInt8($0)), 10) }
        try await s.send(commands)
        XCTAssertEqual(t.outs.count, 8)
        for out in t.outs {
            XCTAssertLessThanOrEqual(out.count, 64)
            XCTAssertEqual(Array(out.suffix(2)), [0, 0])
            // Every message decodes to whole commands (3 records each).
            XCTAssertEqual(try TLV.decode(out).count, 3)
        }
        XCTAssertEqual(t.events, Array(repeating: [FakeTransport.Event.in, .out], count: 8).flatMap { $0 })
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
        let t = FakeTransport(outBehavior: { _ in throw TransportError.deviceGone })
        let s = USHRSession(transport: t, timing: .immediate)
        do {
            try await s.send([.setAutoPowerSave(true)])
            XCTFail("expected deviceGone")
        } catch {
            XCTAssertEqual(error as? TransportError, .deviceGone)
        }
        XCTAssertEqual(t.outAttempts, 1)
    }

    func test_pack_singleOversizedGroupThrowsMessageTooLong() {
        let huge = (0..<30).map { TLVRecord(UInt8($0 + 1), .u8(0)) }  // 90 bytes
        XCTAssertThrowsError(try USHRSession.pack([[TLVRecord(0x15, .u8(1))], huge])) {
            guard case TLVError.messageTooLong = $0 else { return XCTFail("wrong error \($0)") }
        }
    }

    func test_waitReady_stalledAndTimeoutAreNotReady_thenReady() async throws {
        let t = FakeTransport(inBehavior: { n in
            if n == 1 { throw TransportError.stalled }
            if n == 2 { throw TransportError.timeout }
        })
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.waitReady()
        XCTAssertEqual(t.inReads, 3)
    }

    func test_waitReady_otherTransportErrorPropagates() async {
        let t = FakeTransport(inBehavior: { _ in throw TransportError.deviceGone })
        let s = USHRSession(transport: t, timing: .immediate)
        do {
            try await s.waitReady()
            XCTFail("expected deviceGone")
        } catch {
            XCTAssertEqual(error as? TransportError, .deviceGone)
        }
        XCTAssertEqual(t.inReads, 1)
    }

    func test_waitReady_malformedReplyIsNotReady() async throws {
        let t = FakeTransport(ins: [[0x12, 9, 0, 0], [0x12, 2, 0, 0, 0]])  // unknown type 9
        let s = USHRSession(transport: t, timing: .immediate)
        try await s.waitReady()
        XCTAssertEqual(t.inReads, 2)
    }

    func test_query_malformedReplyIsRetried() async throws {
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0], [0x12, 9, 0, 0], [0x15, 2, 1, 0, 0]])
        let s = USHRSession(transport: t, timing: .immediate)
        let report = try await s.query([.getAutoPowerSave])
        XCTAssertEqual(report.autoPowerSave, true)
        XCTAssertEqual(t.inReads, 3)
    }

    func test_query_getAssign_waitsAssignReadDelay() async throws {
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0], [0x61, 2, 5, 0x62, 2, 1, 0x41, 1, 0x61, 2, 1, 0x62, 2, 1, 0x42, 1, 0x43, 1, 0, 0]])
        var timing = SessionTiming.immediate
        timing.assignReadDelay = .milliseconds(60)
        let s = USHRSession(transport: t, timing: timing)
        let start = ContinuousClock.now
        _ = try await s.query([.getAssign])
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(55))

        let t2 = FakeTransport(ins: [[0x12, 2, 0, 0, 0], [0x15, 2, 1, 0, 0]])
        let s2 = USHRSession(transport: t2, timing: timing)
        let start2 = ContinuousClock.now
        _ = try await s2.query([.getAutoPowerSave])
        XCTAssertLessThan(ContinuousClock.now - start2, .milliseconds(55))
    }

    func test_concurrentSendDuringQueryDelay_doesNotStealReplyOrInterleave() async throws {
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0], [0x61, 2, 5, 0x62, 2, 1, 0x41, 1, 0x61, 2, 1, 0x62, 2, 1, 0x42, 1, 0x43, 1, 0, 0]])
        var timing = SessionTiming.immediate
        timing.assignReadDelay = .milliseconds(50)
        let s = USHRSession(transport: t, timing: timing)
        let q = Task { try await s.query([.getAssign]) }
        try await Task.sleep(for: .milliseconds(10))
        let sender = Task { try await s.send([.setAutoPowerSave(false)]) }
        let report = try await q.value
        try await sender.value
        XCTAssertEqual(report.assignments[Channel(.lineOut, 1)], Channel(.directMonitorOut, 1))
        // query: ready, write, reply; then send: ready, write
        XCTAssertEqual(t.events, [.in, .out, .in, .in, .out])
        XCTAssertEqual(t.outs.last, [0x15, 2, 0, 0, 0])
    }

    func test_query_staleReplyForOtherChannelIsSkipped() async throws {
        let stale: [UInt8] = [0x61, 2, 5, 0x62, 2, 1, 0xC6, 2, 4, 0, 0]       // (5,1) stereo
        let right: [UInt8] = [0x61, 2, 4, 0x62, 2, 1, 0xC6, 2, 1, 0, 0]       // (4,1) mono
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0], stale, right])
        let s = USHRSession(transport: t, timing: .immediate)
        let report = try await s.query([.getStereo(Channel(.analogIn, 1))])
        XCTAssertEqual(report.stereo[Channel(.analogIn, 1)], .mono)
    }

    func test_query_neverAnswered_throwsNoReply() async {
        let stale: [UInt8] = [0x61, 2, 5, 0x62, 2, 1, 0xC6, 2, 4, 0, 0]
        let t = FakeTransport(ins: [[0x12, 2, 0, 0, 0]] + Array(repeating: stale, count: 10))
        var timing = SessionTiming.immediate
        timing.replyAttempts = 5
        let s = USHRSession(transport: t, timing: timing)
        do {
            _ = try await s.query([.getStereo(Channel(.analogIn, 1))])
            XCTFail("expected noReply")
        } catch {
            XCTAssertEqual(error as? SessionError, .noReply)
        }
    }
}
