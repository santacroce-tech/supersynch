import XCTest
@testable import SyncthingKit

final class SmokeTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(SyncthingKit.bundle.bundleIdentifier)
    }
}
