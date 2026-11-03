import XCTest
import IOKit
import USHRProtocol
@testable import USHRDevice

final class ErrorMappingTests: XCTestCase {
    func testSuccessMapsToNil() {
        XCTAssertNil(transportError(forKernelReturn: 0))
    }

    func testStallAndTimeout() {
        XCTAssertEqual(transportError(forKernelReturn: Int32(bitPattern: 0xE000404F)), .stalled)
        XCTAssertEqual(transportError(forKernelReturn: Int32(bitPattern: 0xE0004051)), .timeout)
    }

    func testDeviceGoneCodes() {
        for kr in [kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotAttached, kIOReturnAborted] {
            XCTAssertEqual(transportError(forKernelReturn: kr), .deviceGone)
        }
    }

    func testOtherCodesPassThrough() {
        let kr = Int32(bitPattern: 0xE00002C2)
        XCTAssertEqual(transportError(forKernelReturn: kr), .io(kr))
    }
}

final class PersistenceKeyTests: XCTestCase {
    func testKey() {
        XCTAssertEqual(AttachedDevice.persistenceKey(serial: "ABC123", productID: 0x806F), "ABC123")
        for bad in [nil, "", "  ", "no serial number", "No Serial Number "] as [String?] {
            XCTAssertEqual(AttachedDevice.persistenceKey(serial: bad, productID: 0x806F), "pid-32879")
        }
    }
}
