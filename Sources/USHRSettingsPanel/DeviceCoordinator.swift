import Foundation
import USHRDevice
import USHRPanelCore
import USHRProtocol

/// Owns the hot-plug monitor and wires the first attached device into the panel model.
@MainActor
final class DeviceCoordinator {
    let model: PanelModel
    private var monitor: DeviceMonitor?
    private var activeID: UInt64?

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
            onError: { message in
                FileHandle.standardError.write(Data("device monitor: \(message)\n".utf8))
            }
        )
        monitor = m
        m.start()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
        model.detach()
        activeID = nil
    }

    private func handleAttach(_ device: AttachedDevice) {
        guard activeID == nil else { return } // extra devices are ignored
        activeID = device.registryID
        let session = USHRSession(transport: device.transport)
        let m = model
        let kind = device.model
        let key = device.persistenceKey
        Task { @MainActor in
            await m.attach(device: session, model: kind, key: key)
        }
    }

    private func handleDetach(_ id: UInt64) {
        guard id == activeID else { return }
        activeID = nil
        model.detach()
    }
}
