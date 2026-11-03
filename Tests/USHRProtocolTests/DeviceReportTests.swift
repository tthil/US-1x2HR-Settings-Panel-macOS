import XCTest
import USHRProtocol

final class DeviceReportTests: XCTestCase {
    private func ch(_ t: ChannelType, _ i: UInt8) -> [TLVRecord] {
        [TLVRecord(0x61, .u8(t.rawValue)), TLVRecord(0x62, .u8(i))]
    }

    func test_parse_infoBlock() {
        let r = DeviceReport.parse([
            TLVRecord(0x32, .u16(0x0100)),
            TLVRecord(0x34, .bytes(Array("US-1x2HR".utf8) + [0])),
        ])
        XCTAssertEqual(r.version, 0x0100)
        XCTAssertEqual(r.productName, "US-1x2HR")
        XCTAssertFalse(r.isEmpty)
    }

    func test_parse_channelValues() {
        let r = DeviceReport.parse(
            ch(.directMonitorOut, 1) + [TLVRecord(0xC1, .u8(90))]
            + ch(.analogIn, 1) + [TLVRecord(0xC3, .u8(1))]
            + ch(.computerOut, 1) + [TLVRecord(0xC6, .u8(1))])
        XCTAssertEqual(r.faders[Channel(.directMonitorOut, 1)], 90)
        XCTAssertEqual(r.mutes[Channel(.analogIn, 1)], true)
        XCTAssertEqual(r.stereo[Channel(.computerOut, 1)], .mono)
    }

    func test_parse_ignoresInvalidStereo() {
        let r = DeviceReport.parse(ch(.computerOut, 1) + [TLVRecord(0xC6, .u8(2))])
        XCTAssertTrue(r.stereo.isEmpty)
    }

    func test_parse_assignPair() {
        let r = DeviceReport.parse(
            ch(.directMonitorOut, 1) + [TLVRecord(0x41, .flag)]
            + ch(.lineOut, 1) + [TLVRecord(0x42, .flag), TLVRecord(0x43, .flag)])
        XCTAssertEqual(r.assignments[Channel(.lineOut, 1)], Channel(.directMonitorOut, 1))
    }

    func test_parse_busyFlag() {
        XCTAssertTrue(DeviceReport.parse([TLVRecord(0xA1, .u8(0))]).busy)
        XCTAssertFalse(DeviceReport.parse([TLVRecord(0xA1, .u8(1))]).busy)
    }

    func test_parse_ignoresUnknownTags() {
        let r = DeviceReport.parse([TLVRecord(0x12, .bytes(Array("dbg".utf8))), TLVRecord(0x15, .u8(1))])
        var expected = DeviceReport()
        expected.autoPowerSave = true
        XCTAssertEqual(r, expected)
    }

    func test_parse_sampleRate() {
        XCTAssertEqual(DeviceReport.parse([TLVRecord(0x18, .u32(48000))]).sampleRate, 48000)
    }

    func test_isEmpty_andMerge() {
        XCTAssertTrue(DeviceReport().isEmpty)
        var a = DeviceReport(); a.sampleRate = 44100; a.autoPowerSave = false
        a.faders[Channel(.directMonitorOut, 1)] = 5
        var b = DeviceReport(); b.autoPowerSave = true
        b.faders[Channel(.directMonitorOut, 1)] = 9
        b.faders[Channel(.loopback, 1)] = 3
        a.merge(b)
        XCTAssertEqual(a.sampleRate, 44100)
        XCTAssertEqual(a.autoPowerSave, true)
        XCTAssertEqual(a.faders[Channel(.directMonitorOut, 1)], 9)
        XCTAssertEqual(a.faders[Channel(.loopback, 1)], 3)
    }

    func test_model_fromProductIDAndName() {
        XCTAssertEqual(USHRModel(productID: 0x806F, productName: nil), .us1x2HR)
        XCTAssertEqual(USHRModel(productID: 0x8070, productName: "US-4x4HR"), .us4x4HR)
        XCTAssertEqual(USHRModel(productID: 0x8070, productName: nil), .us2x2HR)
        XCTAssertEqual(USHRModel(productID: 0x8071, productName: nil), .us4x4HR)
        XCTAssertEqual(USHRModel(productID: 0x1234, productName: nil), .unknown(0x1234))
        XCTAssertEqual(USHRModel.us1x2HR.displayName, "US-1x2HR")
        XCTAssertEqual(USHRModel.unknown(0x1234).displayName, "Unknown US-HR (0x1234)")
        XCTAssertEqual(USHRModel.vendorID, 0x0644)
    }
}
