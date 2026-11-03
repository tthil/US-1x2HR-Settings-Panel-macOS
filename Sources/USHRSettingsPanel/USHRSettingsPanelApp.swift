import AppKit
import SwiftUI
import USHRPanelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel(store: LastSetStore(defaults: .standard))
    lazy var coordinator = DeviceCoordinator(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct USHRSettingsPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("US\u{2011}HR Settings Panel", id: "panel") {
            PanelView(model: delegate.model)
        }
        .windowResizability(.contentSize)
    }
}
