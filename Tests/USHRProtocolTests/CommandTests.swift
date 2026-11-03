import XCTest
import USHRProtocol

final class CommandTests: XCTestCase {
    private func bytes(_ c: Command) throws -> [UInt8] { try TLV.encode(c.records) }

    func test_setStereo_directMonitorStereo() throws {
        XCTAssertEqual(try bytes(.setStereo(Channel(.directMonitorOut, 1), .stereo)),
                       [0x61, 2, 5, 0x62, 2, 1, 0x86, 2, 4, 0, 0])
    }

    func test_getMute_analogIn2() throws {
        XCTAssertEqual(try bytes(.getMute(Channel(.analogIn, 2))),
                       [0x61, 2, 4, 0x62, 2, 2, 0xC3, 2, 0, 0, 0])
    }

    func test_setAutoPowerSave_on() throws {
        XCTAssertEqual(try bytes(.setAutoPowerSave(true)), [0x15, 2, 1, 0, 0])
    }

    func test_getInfo() throws {
        XCTAssertEqual(try bytes(.getInfo), [0x31, 1, 0, 0])
    }

    func test_getAssign() throws {
        XCTAssertEqual(try bytes(.getAssign),
                       [0x61, 2, 0, 0x62, 2, 0, 0x41, 1, 0x61, 2, 0, 0x62, 2, 0, 0x42, 1, 0x43, 1, 0, 0])
    }

    func test_assign_monitorMixToLineOut1() throws {
        XCTAssertEqual(try bytes(.assign(source: Channel(.directMonitorOut, 1), destination: Channel(.lineOut, 1))),
                       [0x61, 2, 5, 0x62, 2, 1, 0x41, 1, 0x61, 2, 1, 0x62, 2, 1, 0x42, 1, 0x43, 1, 0, 0])
    }

    /// Exhaustive switch: adding a Command case without a sample here fails to compile.
    private func sample(for command: Command) -> Command {
        let ch = Channel(.analogIn, 1)
        switch command {
        case .setFader: return .setFader(ch, 1)
        case .setMute: return .setMute(ch, true)
        case .setStereo: return .setStereo(ch, .stereo)
        case .setAutoPowerSave: return .setAutoPowerSave(true)
        case .assign: return .assign(source: ch, destination: Channel(.lineOut, 1))
        case .getFader: return .getFader(ch)
        case .getMute: return .getMute(ch)
        case .getStereo: return .getStereo(ch)
        case .getAutoPowerSave: return .getAutoPowerSave
        case .getSampleRate: return .getSampleRate
        case .getInfo: return .getInfo
        case .getAssign: return .getAssign
        }
    }

    func test_noCommandEmitsForbiddenTag() {
        let forbidden: Set<UInt8> = [0x13, 0x17, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0xA2]
        let seeds: [Command] = [
            .setFader(Channel(.analogIn, 1), 0), .setMute(Channel(.analogIn, 1), false),
            .setStereo(Channel(.analogIn, 1), .mono), .setAutoPowerSave(false),
            .assign(source: Channel(.analogIn, 1), destination: Channel(.lineOut, 1)),
            .getFader(Channel(.analogIn, 1)), .getMute(Channel(.analogIn, 1)),
            .getStereo(Channel(.analogIn, 1)), .getAutoPowerSave, .getSampleRate, .getInfo, .getAssign,
        ]
        let all = seeds.map(sample(for:))
        XCTAssertEqual(all.count, 12)
        let tags = all.flatMap(\.records).map(\.tag)
        XCTAssertFalse(tags.isEmpty)
        XCTAssertTrue(tags.allSatisfy { !forbidden.contains($0) })
    }
}
