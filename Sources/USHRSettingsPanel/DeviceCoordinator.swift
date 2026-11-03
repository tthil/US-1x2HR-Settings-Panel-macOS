import Foundation
import Observation
import USHRDevice
import USHRPanelCore
import USHRProtocol

/// Owns the hot-plug monitor and wires the first attached device into the panel model.
@MainActor @Observable
final class DeviceCoordinator {
    @ObservationIgnored let model: PanelModel
    /// Monitor failure to show while no device is connected; cleared on successful attach.
    private(set) var deviceMessage: String?
    @ObservationIgnored private var monitor: DeviceMonitor?
    @ObservationIgnored private var activeID: UInt64?
    /// Devices attached while another was active, in attach order; promoted when the active one detaches.
    @ObservationIgnored private var waiting: [AttachedDevice] = []
    @ObservationIgnored private var attachTask: Task<Void, Never>?

    init(model: PanelModel) {
        self.model = model
    }

    func start() {
        guard monitor == nil else { return }
        let m = DeviceMonitor(
            onAttach: { [weak self] device in
                // Callbacks arrive on the main run loop.
                Task { @MainActor in self?.handleAttach(device) }
            },
            onDetach: { [weak self] id in
                Task { @MainActor in self?.handleDetach(id) }
            },
            onError: { [weak self] message in
                FileHandle.standardError.write(Data("device monitor: \(message)\n".utf8))
                Task { @MainActor in self?.deviceMessage = message }
            }
        )
        monitor = m
        m.start()
    }

    func stop() {
        attachTask?.cancel()
        attachTask = nil
        monitor?.stop()
        monitor = nil
        model.detach()
        activeID = nil
        waiting = []
    }

    private func handleAttach(_ device: AttachedDevice) {
        guard monitor != nil else { return }
        guard activeID == nil else {
            if !waiting.contains(where: { $0.registryID == device.registryID }) { waiting.append(device) }
            return
        }
        activate(device)
    }

    private func activate(_ device: AttachedDevice) {
        activeID = device.registryID
        let session = USHRSession(transport: device.transport)
        let m = model
        let kind = device.model
        let key = device.persistenceKey
        let id = device.registryID
        attachTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.monitor != nil, self.activeID == id else { return }
            self.deviceMessage = nil
            await m.attach(device: session, model: kind, key: key)
        }
    }

    private func handleDetach(_ id: UInt64) {
        waiting.removeAll { $0.registryID == id }
        guard id == activeID else { return }
        activeID = nil
        attachTask?.cancel()
        attachTask = nil
        model.detach()
        if !waiting.isEmpty { activate(waiting.removeFirst()) }
    }
}
