import XCTest
@testable import BuiltinCtlCore

final class DisplayIdentityTests: XCTestCase {
    func testRecognizesMacOSUnplugPlaceholder() {
        XCTAssertTrue(DisplayIdentity.isUnplugPlaceholder(
            vendor: 0x756e6b6e,
            model: 0x76697274
        ))
    }

    func testRequiresBothExactValues() {
        XCTAssertFalse(DisplayIdentity.isUnplugPlaceholder(
            vendor: 0x756e6b6e,
            model: 0x12345678
        ))
        XCTAssertFalse(DisplayIdentity.isUnplugPlaceholder(
            vendor: 0x12345678,
            model: 0x76697274
        ))
    }
}
