import XCTest
@testable import ByteLifeCore

final class AppShortNameTests: XCTestCase {
    func testTakesLastDotComponent() {
        XCTAssertEqual(AppShortName.short(bundleID: "com.apple.Safari"), "Safari")
        XCTAssertEqual(AppShortName.short(bundleID: "com.microsoft.VSCode"), "VSCode")
        XCTAssertEqual(AppShortName.short(bundleID: "com.apple.dt.Xcode"), "Xcode")
    }

    func testNoDotReturnsWholeString() {
        XCTAssertEqual(AppShortName.short(bundleID: "Terminal"), "Terminal")
    }

    func testBlankReadsAsUnknown() {
        XCTAssertEqual(AppShortName.short(bundleID: ""), "Unknown")
        XCTAssertEqual(AppShortName.short(bundleID: "   "), "Unknown")
    }

    func testTrailingDotIsIgnored() {
        // Splitting drops the empty trailing component, so the last real segment stands.
        XCTAssertEqual(AppShortName.short(bundleID: "com.apple."), "apple")
    }
}
