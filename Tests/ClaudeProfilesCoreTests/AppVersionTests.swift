import XCTest
@testable import ClaudeProfilesCore

final class AppVersionTests: XCTestCase {
    func testComparison() {
        XCTAssertTrue(AppVersion.isNewer("v1.2.0", than: "1.1.1"))
        XCTAssertTrue(AppVersion.isNewer("2.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.1.1.1", than: "1.1.1"))
        XCTAssertFalse(AppVersion.isNewer("v1.1.1", than: "1.1.1"))
        XCTAssertFalse(AppVersion.isNewer("1.0.9", than: "1.1"))
        XCTAssertFalse(AppVersion.isNewer("garbage", than: "1.1.1"))
    }
}
