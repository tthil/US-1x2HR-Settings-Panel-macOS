import Foundation
import Observation
import USHRProtocol

/// Pure helpers for applying device replies.
public enum PanelState {
    /// Keeps only the parts of `report` that the get-commands in `group` asked for, plus the
    /// documented extras: the (5,1) fader reply also carries loopback faders (6,0)/(6,1), and a
    /// mute get returns all ANALOG_IN mutes 1...inputCount. Stale replies for other keys are dropped.
    public static func filtered(_ report: DeviceReport, for group: [Command], inputCount: Int) -> DeviceReport {
        var out = DeviceReport()
        for command in group {
            switch command {
            case .getFader(let ch):
                out.faders[ch] = report.faders[ch]
                if ch == Channel(.directMonitorOut, 1) {
                    for i: UInt8 in 0...1 {
                        let lb = Channel(.loopback, i)
                        out.faders[lb] = report.faders[lb]
                    }
                }
            case .getMute(let ch):
                if ch.type == .analogIn {
                    for i in 1...max(1, inputCount) {
                        let c = Channel(.analogIn, UInt8(i))
                        out.mutes[c] = report.mutes[c]
                    }
                } else {
                    out.mutes[ch] = report.mutes[ch]
                }
            case .getStereo(let ch): out.stereo[ch] = report.stereo[ch]
            case .getAutoPowerSave: out.autoPowerSave = report.autoPowerSave
            case .getSampleRate: out.sampleRate = report.sampleRate
            case .getInfo:
                out.version = report.version
                out.build = report.build
                out.productName = report.productName
            case .getAssign: out.assignments = report.assignments
            default: break
            }
        }
        return out
    }

    public static func firmwareText(version: UInt16, build: UInt16?) -> String {
        let base = "\(version / 100)." + String(format: "%02d", Int(version % 100))
        if let build { return "\(base) (build \(build))" }
        return base
    }
}

@MainActor @Observable
public final class PanelModel {
    public enum Connection: Equatable { case noDevice, reading, connected, error(String) }

    public private(set) var connection: Connection = .noDevice
    public private(set) var model: USHRModel?
    public private(set) var firmware: String?
    public private(set) var sampleRate: UInt32?
    /// Last failed-send message; connection stays usable. Cleared by a later successful send, attach, detach.
    public private(set) var lastError: String?

    public var directMonitorStereo = false
    /// 0 = "Input" end, 127 = "Computer" end (= 127 - fader).
    public var monitorBalance: Double = 64
    public var audioInputs: [Bool] = []
    public var lineOut: LineOutSource = .monitorMix
    public var loopbackEnabled: Bool?
    public var loopbackVolume: Double?
    public var loopbackInStereo = false
    public var loopbackOutStereo = false
    public var autoPowerSave = false

    @ObservationIgnored private let store: LastSetStore
    @ObservationIgnored private let sliderInterval: Duration
    @ObservationIgnored private let sleeper: @Sendable (Duration) async -> Void
    @ObservationIgnored private var device: (any USHRControlling)?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tail: Task<Void, Never>?

    private enum Slider { case balance, loopbackVolume }
    @ObservationIgnored private var pendingSlider: [Slider: UInt8] = [:]

    public init(
        store: LastSetStore,
        sliderInterval: Duration = .milliseconds(50),
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.sliderInterval = sliderInterval
        self.sleeper = sleeper
    }

    // MARK: attach / detach

    public func attach(device: any USHRControlling, model: USHRModel, key: String) async {
        detach()
        generation += 1
        let token = generation
        self.device = device
        self.model = model
        self.key = key
        connection = .reading
        lastError = nil
        do {
            try await readAll(device: device, model: model, token: token)
            guard token == generation else { return }
            connection = .connected
        } catch {
            guard token == generation else { return }
            connection = .error(String(describing: error))
        }
    }

    public func detach() {
        generation += 1
        tail?.cancel()
        tail = nil
        pendingSlider = [:]
        device = nil
        model = nil
        firmware = nil
        sampleRate = nil
        key = ""
        directMonitorStereo = false
        monitorBalance = 64
        audioInputs = []
        lineOut = .monitorMix
        loopbackEnabled = nil
        loopbackVolume = nil
        loopbackInStereo = false
        loopbackOutStereo = false
        autoPowerSave = false
        lastError = nil
        connection = .noDevice
    }

    /// Waits for all queued sends (and any resulting re-read) to finish.
    public func waitUntilIdle() async {
        while let t = tail {
            await t.value
            if let current = tail, current == t { tail = nil }
        }
    }

    // MARK: reading

    private func readAll(device: any USHRControlling, model: USHRModel, token: Int) async throws {
        let count = PanelCommands.inputCount(for: model)
        var seenLoopbackEnabled = false
        var seenLoopbackVolume = false
        var inputs = [Bool](repeating: false, count: count)
        for group in PanelCommands.readAll(for: model) {
            let raw = try await device.query(group)
            guard token == generation else { throw CancellationError() }
            let r = PanelState.filtered(raw, for: group, inputCount: count)
            if let v = r.version { firmware = PanelState.firmwareText(version: v, build: r.build) }
            if let s = r.sampleRate { sampleRate = s }
            if let a = r.autoPowerSave { autoPowerSave = a }
            if let s = r.stereo[Channel(.directMonitorOut, 1)] { directMonitorStereo = s == .stereo }
            if let s = r.stereo[Channel(.analogIn, 1)] { loopbackInStereo = s == .stereo }
            if let s = r.stereo[Channel(.computerOut, 1)] { loopbackOutStereo = s == .stereo }
            for i in 1...count {
                if let m = r.mutes[Channel(.analogIn, UInt8(i))] { inputs[i - 1] = m }
            }
            if let f = r.faders[Channel(.directMonitorOut, 1)] { monitorBalance = Double(127 - min(f, 127)) }
            if let f = r.faders[Channel(.loopback, 0)] { loopbackEnabled = f != 0; seenLoopbackEnabled = true }
            if let f = r.faders[Channel(.loopback, 1)] { loopbackVolume = Double(f); seenLoopbackVolume = true }
            if let src = r.assignments[Channel(.lineOut, 1)] {
                switch (src.type, src.index) {
                case (.directMonitorOut, 1): lineOut = .monitorMix
                case (.computerOut, 1): lineOut = .computerOut12
                case (.computerOut, 3): lineOut = .computerOut34
                default: break
                }
            }
        }
        audioInputs = inputs
        if !seenLoopbackEnabled { loopbackEnabled = store.loopbackEnabled(key) }
        if !seenLoopbackVolume { loopbackVolume = store.loopbackVolume(key).map(Double.init) }
    }

    // MARK: sending

    private func enqueue(_ op: @escaping @MainActor (_ token: Int) async -> Void) {
        guard device != nil else { return }
        let token = generation
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, token == self.generation else { return }
            await op(token)
        }
    }

    private func send(_ commands: [Command]) {
        enqueue { [weak self] token in
            guard let self, let device = self.device else { return }
            do {
                try await device.send(commands)
                if token == self.generation { self.lastError = nil }
            } catch {
                guard token == self.generation, let model = self.model else { return }
                self.lastError = String(describing: error)
                do {
                    try await self.readAll(device: device, model: model, token: token)
                    if token == self.generation { self.connection = .connected }
                } catch {
                    if token == self.generation { self.connection = .error(String(describing: error)) }
                }
            }
        }
    }

    private func sendSlider(_ slider: Slider, _ value: Double) {
        let v = UInt8(max(0, min(127, value.rounded())))
        let alreadyScheduled = pendingSlider[slider] != nil
        pendingSlider[slider] = v
        if alreadyScheduled { return }
        enqueue { [weak self] token in
            guard let self else { return }
            if self.sliderInterval != .zero { await self.sleeper(self.sliderInterval) }
            guard token == self.generation, let latest = self.pendingSlider.removeValue(forKey: slider) else { return }
            switch slider {
            case .balance: self.send(PanelCommands.monitorBalance(latest))
            case .loopbackVolume: self.send(PanelCommands.loopbackVolume(latest))
            }
        }
    }

    // MARK: setters

    public func setDirectMonitorStereo(_ v: Bool) {
        directMonitorStereo = v
        send(PanelCommands.directMonitor(stereo: v))
    }

    public func setMonitorBalance(_ v: Double) {
        monitorBalance = max(0, min(127, v))
        sendSlider(.balance, monitorBalance)
    }

    public func setAudioInput(_ n: Int, _ on: Bool) {
        guard n >= 1, n <= audioInputs.count else { return }
        audioInputs[n - 1] = on
        send(PanelCommands.audioInput(UInt8(n), on: on))
    }

    public func setLineOut(_ s: LineOutSource) {
        lineOut = s
        send(PanelCommands.lineOut(s))
    }

    public func setLoopback(_ on: Bool) {
        loopbackEnabled = on
        store.setLoopbackEnabled(on, key)
        send(PanelCommands.loopback(on: on))
    }

    public func setLoopbackVolume(_ v: Double) {
        let c = max(0, min(127, v))
        loopbackVolume = c
        store.setLoopbackVolume(UInt8(c.rounded()), key)
        sendSlider(.loopbackVolume, c)
    }

    public func setLoopbackIn(stereo: Bool) {
        loopbackInStereo = stereo
        send(PanelCommands.loopbackIn(stereo: stereo))
    }

    public func setLoopbackOut(stereo: Bool) {
        loopbackOutStereo = stereo
        send(PanelCommands.loopbackOut(stereo: stereo))
    }

    public func setAutoPowerSave(_ on: Bool) {
        autoPowerSave = on
        send(PanelCommands.autoPowerSave(on))
    }
}
