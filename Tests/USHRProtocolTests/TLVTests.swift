import XCTest
@testable import USHRProtocol

final class TLVTests: XCTestCase {
    private var allTypes: [TLVRecord] {
        [.init(0x14, .flag), .init(0x32, .u16(0x0102)), .init(0x17, .u32(48000)), .init(0x34, .bytes(Array("US".utf8)))]
    }

    func test_encode_channelFaderSet() throws {
        XCTAssertEqual(try TLV.encode([.init(0x61, .u8(5)), .init(0x62, .u8(1)), .init(0x81, .u8(0x40))]),
                       [0x61, 2, 5, 0x62, 2, 1, 0x81, 2, 0x40, 0, 0])
    }

    func test_encode_allTypes() throws {
        XCTAssertEqual(try TLV.encode(allTypes),
                       [0x14, 1, 0x32, 3, 0x02, 0x01, 0x17, 4, 0x80, 0xBB, 0, 0, 0x34, 5, 2, 0x55, 0x53, 0, 0])
    }

    func test_encode_over64Bytes_throws() {
        let records = (0..<22).map { TLVRecord(UInt8($0 + 1), .u8(1)) }
        XCTAssertThrowsError(try TLV.encode(records)) {
            XCTAssertEqual($0 as? TLVError, .messageTooLong(68))
        }
    }

    func test_decode_roundTrip() throws {
        XCTAssertEqual(try TLV.decode(try TLV.encode(allTypes)), allTypes)
    }

    func test_decode_skipsUnknownTagsAndStopsAtEnd() throws {
        XCTAssertEqual(try TLV.decode([0x12, 2, 7, 0xA1, 2, 1, 0, 0, 0x99, 2, 9]),
                       [.init(0x12, .u8(7)), .init(0xA1, .u8(1))])
    }

    func test_decode_truncatedRecord_throws() {
        XCTAssertThrowsError(try TLV.decode([0x32, 3, 0x01])) {
            XCTAssertEqual($0 as? TLVError, .truncated(offset: 0))
        }
    }

    func test_decode_unknownType_throws() {
        XCTAssertThrowsError(try TLV.decode([0x10, 9, 0])) {
            XCTAssertEqual($0 as? TLVError, .unknownType(9, offset: 0))
        }
    }

    func test_decode_zeroPaddedBuffer() throws {
        let buf: [UInt8] = [0x15, 2, 1] + [UInt8](repeating: 0, count: 61)
        XCTAssertEqual(try TLV.decode(buf), [.init(0x15, .u8(1))])
    }
}
