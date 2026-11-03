import Foundation
import Testing
import USHRProtocol
import USHRPanelCore

final class FakeDevice: USHRControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [[Command]] = []
    private var _queries: [[Command]] = []
    private var _report = DeviceReport()
    private var _sendError: Error?
    private var _gate: CheckedContinuation<Void, Never>?
    private var _gateArmed = false
    private var _gateEntered = false
    private var _finished = 0
    private var _queryError: Error?

    var sent: [[Command]] { lock.withLock { _sent } }
    var queries: [[Command]] { lock.withLock { _queries } }
    var report: DeviceReport {
        get { lock.withLock { _report } }
        set { lock.withLock { _report = newValue } }
    }
    var sendError: Error? {
        get { lock.withLock { _sendError } }
        set { lock.withLock { _sendError = newValue } }
    }
    var finishedSends: Int { lock.withLock { _finished } }
    var queryError: Error? {
        get { lock.withLock { _queryError } }
        set { lock.withLock { _queryError = newValue } }
    }
    var gateEntered: Bool { lock.withLock { _gateEntered } }
    func armGate() { lock.withLock { _gateArmed = true } }
    func openGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _gateArmed = false
            defer { _gate = nil }
            return _gate
        }
        c?.resume()
    }

    func send(_ commands: [Command]) async throws {
        let armed = lock.withLock { () -> Bool in _sent.append(commands); return _gateArmed }
        if armed {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { _gate = c; _gateEntered = true }
            }
        }
        defer { lock.withLock { _finished += 1 } }
        if let e = sendError { throw e }
    }

    func query(_ commands: [Command]) async throws -> DeviceReport {
        lock.withLock { _queries.append(commands) }
        if let e = queryError { throw e }
        return report
    }
}

func makeStore() -> LastSetStore { LastSetStore(defaults: UserDefaults(suiteName: UUID().uuidString)!) }

func baseReport() -> DeviceReport {
    var r = DeviceReport()
    r.autoPowerSave = true
    r.version = 0x64
    r.build = 14
    r.sampleRate = 44100
    r.stereo[Channel(.directMonitorOut, 1)] = .stereo
    r.faders[Channel(.directMonitorOut, 1)] = 27
    r.mutes[Channel(.analogIn, 1)] = true
    r.mutes[Channel(.analogIn, 2)] = false
    r.assignments[Channel(.lineOut, 1)] = Channel(.computerOut, 3)
    return r
}

@MainActor
@Suite struct PanelModelTests {
    func make(_ device: FakeDevice, interval: Duration = .zero, store: LastSetStore? = nil) -> PanelModel {
        PanelModel(store: store ?? makeStore(), sliderInterval: interval)
    }

    @Test func attach_appliesDeviceReport() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        #expect(m.connection == .connected)
        #expect(m.directMonitorStereo)
        #expect(m.monitorBalance == 100)
        #expect(m.autoPowerSave)
        #expect(m.audioInputs == [true, false])
        #expect(m.lineOut == .computerOut34)
        #expect(m.firmware == "1.00 (build 14)")
        #expect(m.sampleRate == 44100)
        #expect(m.model == .us1x2HR)
    }

    @Test func attach_loopbackFromDevice() async {
        let d = FakeDevice()
        var r = baseReport()
        r.faders[Channel(.loopback, 0)] = 1
        r.faders[Channel(.loopback, 1)] = 64
        d.report = r
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        #expect(m.loopbackEnabled == true)
        #expect(m.loopbackVolume == 64)
    }

    @Test func attach_loopbackMissingFromReport_usesStoreOrNil() async {
        let d = FakeDevice(); d.report = baseReport()
        let store = makeStore()
        let m = make(d, store: store)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        #expect(m.loopbackEnabled == nil)
        #expect(m.loopbackVolume == nil)
        m.setLoopback(true)
        m.setLoopbackVolume(40)
        await m.waitUntilIdle()
        m.detach()
        await m.attach(device: d, model: .us1x2HR, key: "k")
        #expect(m.loopbackEnabled == true)
        #expect(m.loopbackVolume == 40)
    }

    @Test func setter_sendsMappedCommand() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        m.setAutoPowerSave(false)
        await m.waitUntilIdle()
        #expect(d.sent.last == [.setAutoPowerSave(false)])
        #expect(m.autoPowerSave == false)
        m.setAudioInput(2, true)
        await m.waitUntilIdle()
        #expect(d.sent.last == PanelCommands.audioInput(2, on: true))
        #expect(m.audioInputs == [true, true])
        m.setLineOut(.monitorMix)
        await m.waitUntilIdle()
        #expect(d.sent.last == PanelCommands.lineOut(.monitorMix))
    }

    @Test func sliderBurst_sendsLatestValueLast() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d, interval: .milliseconds(50))
        await m.attach(device: d, model: .us1x2HR, key: "k")
        m.setMonitorBalance(10); m.setMonitorBalance(20); m.setMonitorBalance(30)
        await m.waitUntilIdle()
        #expect(d.sent.last == PanelCommands.monitorBalance(30))
        #expect(d.sent.count <= 2)
    }

    @Test func sendError_setsLastErrorRereadsAndRecovers() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        let before = d.queries.count
        d.sendError = SessionError.deviceBusy
        m.setAutoPowerSave(false)
        await m.waitUntilIdle()
        #expect(m.connection == .connected)
        #expect(m.lastError != nil)
        #expect(d.queries.count > before)
        #expect(m.autoPowerSave == true)  // re-read restored device truth
        d.sendError = nil
        m.setAutoPowerSave(false)
        await m.waitUntilIdle()
        #expect(m.lastError == nil)
        #expect(m.connection == .connected)
    }

    @Test func rereadFailureAfterSendError_setsConnectionError() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        d.sendError = SessionError.deviceBusy
        d.queryError = SessionError.noReply
        m.setAutoPowerSave(false)
        await m.waitUntilIdle()
        #expect(m.lastError != nil)
        if case .error = m.connection {} else { Issue.record("expected error, got \(m.connection)") }
    }

    @Test func detachDuringPendingSend_endsNoDevice() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        d.armGate()
        d.sendError = SessionError.deviceBusy
        m.setAutoPowerSave(false)
        m.setAudioInput(1, false)
        while !d.gateEntered { await Task.yield() }
        m.detach()
        d.openGate()
        // Wait for the suspended send to actually finish (throw), then let the model's catch run.
        while d.finishedSends < 1 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(m.connection == .noDevice)
        #expect(m.lastError == nil)
        #expect(m.model == nil)
        #expect(m.audioInputs.isEmpty)
        #expect(m.firmware == nil)
        #expect(m.autoPowerSave == false)
        #expect(d.sent.count == 1)
        let q = d.queries.count
        for _ in 0..<20 { await Task.yield() }
        #expect(d.queries.count == q)
    }

    @Test func lateFailureFromOldDevice_doesNotTouchNewAttach() async {
        let old = FakeDevice(); old.report = baseReport()
        let new = FakeDevice(); new.report = baseReport()
        let m = make(old)
        await m.attach(device: old, model: .us1x2HR, key: "k")
        old.armGate()
        old.sendError = SessionError.deviceBusy
        m.setAutoPowerSave(false)
        while !old.gateEntered { await Task.yield() }
        await m.attach(device: new, model: .us1x2HR, key: "k")
        let q = new.queries.count
        old.openGate()
        while old.finishedSends < 1 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(m.connection == .connected)
        #expect(m.lastError == nil)
        #expect(m.autoPowerSave == true)
        #expect(new.queries.count == q)
    }

    @Test func reattach_rereadsState() async {
        let d = FakeDevice(); d.report = baseReport()
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        m.detach()
        var r = baseReport()
        r.autoPowerSave = false
        r.faders[Channel(.directMonitorOut, 1)] = 0
        d.report = r
        await m.attach(device: d, model: .us1x2HR, key: "k")
        #expect(m.autoPowerSave == false)
        #expect(m.monitorBalance == 127)
    }

    @Test func attachFailure_setsError() async {
        struct Failing: USHRControlling {
            func send(_ c: [Command]) async throws {}
            func query(_ c: [Command]) async throws -> DeviceReport { throw SessionError.noReply }
        }
        let m = PanelModel(store: makeStore(), sliderInterval: .zero)
        await m.attach(device: Failing(), model: .us1x2HR, key: "k")
        if case .error = m.connection {} else { Issue.record("expected error") }
    }

    @Test func filter_ignoresUnrelatedStaleKeys() {
        var r = baseReport()
        r.faders[Channel(.lineOut, 1)] = 99
        r.mutes[Channel(.analogIn, 3)] = true
        r.stereo[Channel(.computerOut, 1)] = .stereo
        r.autoPowerSave = true
        let f = PanelState.filtered(r, for: [.getMute(Channel(.analogIn, 1))], inputCount: 2)
        #expect(f.mutes == [Channel(.analogIn, 1): true, Channel(.analogIn, 2): false])
        #expect(f.faders.isEmpty && f.stereo.isEmpty && f.autoPowerSave == nil && f.assignments.isEmpty)
        var r2 = baseReport()
        r2.faders[Channel(.loopback, 0)] = 1
        r2.faders[Channel(.loopback, 1)] = 9
        let g = PanelState.filtered(r2, for: [.getFader(Channel(.directMonitorOut, 1))], inputCount: 2)
        #expect(g.faders.count == 3)
        let h = PanelState.filtered(r2, for: [.getFader(Channel(.lineOut, 1))], inputCount: 2)
        #expect(h.faders.isEmpty)
    }

    @Test func staleKeysInReport_doNotLeakIntoState() async {
        let d = FakeDevice()
        var r = DeviceReport()
        r.autoPowerSave = true   // answers getAutoPowerSave
        r.version = 0x64
        r.mutes[Channel(.analogIn, 1)] = false
        r.mutes[Channel(.analogIn, 2)] = false
        r.stereo[Channel(.directMonitorOut, 1)] = .mono
        r.faders[Channel(.directMonitorOut, 1)] = 127
        r.faders[Channel(.loopback, 0)] = 1
        d.report = r
        let m = make(d)
        await m.attach(device: d, model: .us1x2HR, key: "k")
        // loopback ch6 only honored via the (5,1) fader group, which is in readAll.
        #expect(m.loopbackEnabled == true)
        #expect(m.monitorBalance == 0)
    }
}
