import XCTest
import USHRProtocol

final class PanelCommandsTests: XCTestCase {
    func test_monitorBalance_inverts() {
        XCTAssertEqual(PanelCommands.monitorBalance(0), [.setFader(Channel(.directMonitorOut, 1), 127)])
        XCTAssertEqual(PanelCommands.monitorBalance(127), [.setFader(Channel(.directMonitorOut, 1), 0)])
        XCTAssertEqual(PanelCommands.monitorBalance(255), [.setFader(Channel(.directMonitorOut, 1), 0)])
    }

    func test_lineOut_computerOut12() {
        XCTAssertEqual(PanelCommands.lineOut(.computerOut12), [
            .assign(source: Channel(.computerOut, 1), destination: Channel(.lineOut, 1)),
            .assign(source: Channel(.computerOut, 2), destination: Channel(.lineOut, 2)),
        ])
    }

    func test_lineOut_computerOut34() {
        XCTAssertEqual(PanelCommands.lineOut(.computerOut34), [
            .assign(source: Channel(.computerOut, 3), destination: Channel(.lineOut, 1)),
            .assign(source: Channel(.computerOut, 4), destination: Channel(.lineOut, 2)),
        ])
    }

    func test_lineOut_monitorMix() {
        XCTAssertEqual(PanelCommands.lineOut(.monitorMix), [
            .assign(source: Channel(.directMonitorOut, 1), destination: Channel(.lineOut, 1)),
            .assign(source: Channel(.directMonitorOut, 2), destination: Channel(.lineOut, 2)),
        ])
    }

    func test_loopback_on() {
        XCTAssertEqual(PanelCommands.loopback(on: true), [.setFader(Channel(.loopback, 0), 1)])
        XCTAssertEqual(PanelCommands.loopback(on: false), [.setFader(Channel(.loopback, 0), 0)])
    }

    func test_loopbackVolume_clamps() {
        XCTAssertEqual(PanelCommands.loopbackVolume(200), [.setFader(Channel(.loopback, 1), 127)])
        XCTAssertEqual(PanelCommands.loopbackVolume(50), [.setFader(Channel(.loopback, 1), 50)])
    }

    func test_loopbackIn_stereo() {
        XCTAssertEqual(PanelCommands.loopbackIn(stereo: true), [.setStereo(Channel(.analogIn, 1), .stereo)])
    }

    func test_loopbackOut_mono() {
        XCTAssertEqual(PanelCommands.loopbackOut(stereo: false), [.setStereo(Channel(.computerOut, 1), .mono)])
    }

    func test_directMonitor_mono() {
        XCTAssertEqual(PanelCommands.directMonitor(stereo: false), [.setStereo(Channel(.directMonitorOut, 1), .mono)])
        XCTAssertEqual(PanelCommands.directMonitor(stereo: true, pair: 2), [.setStereo(Channel(.directMonitorOut, 2), .stereo)])
    }

    func test_audioInput2_on() {
        XCTAssertEqual(PanelCommands.audioInput(2, on: true), [.setMute(Channel(.analogIn, 2), true)])
    }

    func test_autoPowerSave() {
        XCTAssertEqual(PanelCommands.autoPowerSave(true), [.setAutoPowerSave(true)])
    }

    func test_inputCount() {
        XCTAssertEqual(PanelCommands.inputCount(for: .us1x2HR), 2)
        XCTAssertEqual(PanelCommands.inputCount(for: .us2x2HR), 2)
        XCTAssertEqual(PanelCommands.inputCount(for: .us4x4HR), 4)
        XCTAssertEqual(PanelCommands.inputCount(for: .unknown(1)), 2)
    }

    func test_readAll_batches() {
        XCTAssertEqual(PanelCommands.readAll(for: .us1x2HR), [
            [.getInfo],
            [.getSampleRate, .getAutoPowerSave],
            [.getStereo(Channel(.directMonitorOut, 1))],
            [.getStereo(Channel(.analogIn, 1))],
            [.getStereo(Channel(.computerOut, 1))],
            [.getMute(Channel(.analogIn, 1))],
            [.getMute(Channel(.analogIn, 2))],
            [.getFader(Channel(.directMonitorOut, 1))],
            [.getAssign],
        ])
        XCTAssertEqual(PanelCommands.readAll(for: .us4x4HR).count, 11)
        // Hardware answers only the last get of a multi-get message, so each get is its own query.
        XCTAssertTrue(PanelCommands.readAll(for: .us4x4HR).dropFirst(2).dropLast().allSatisfy { $0.count == 1 })
    }

    func test_lineOutSource_labels() {
        XCTAssertEqual(LineOutSource.allCases.map(\.label), ["Monitor Mix", "Computer Out 1-2", "Computer Out 3-4"])
    }
}
