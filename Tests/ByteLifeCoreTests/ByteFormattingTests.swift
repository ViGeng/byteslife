import XCTest
@testable import ByteLifeCore

final class ByteFormattingTests: XCTestCase {

    // MARK: bytes

    func testBytesZero() {
        XCTAssertEqual(ByteFormatting.bytes(0), "0 B")
    }

    func testBytesSubKilobyte() {
        XCTAssertEqual(ByteFormatting.bytes(1), "1 B")
        XCTAssertEqual(ByteFormatting.bytes(512), "512 B")
        XCTAssertEqual(ByteFormatting.bytes(1023), "1023 B")
    }

    func testBytesUnitBoundaries() {
        XCTAssertEqual(ByteFormatting.bytes(1024), "1.0 KB")
        XCTAssertEqual(ByteFormatting.bytes(1536), "1.5 KB")
        XCTAssertEqual(ByteFormatting.bytes(1_048_576), "1.0 MB")
        XCTAssertEqual(ByteFormatting.bytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(ByteFormatting.bytes(1_099_511_627_776), "1.0 TB")
        XCTAssertEqual(ByteFormatting.bytes(1_125_899_906_842_624), "1.0 PB")
    }

    func testBytesHugeValueStaysWithinUnits() {
        // Int64.max is roughly 8 EB, so the largest unit must not overflow the units table.
        XCTAssertEqual(ByteFormatting.bytes(Int64.max), "8.0 EB")
    }

    // MARK: tokens

    func testTokens() {
        XCTAssertEqual(ByteFormatting.tokens(0), "0")
        XCTAssertEqual(ByteFormatting.tokens(999), "999")
        XCTAssertEqual(ByteFormatting.tokens(1_000), "1.0K")
        XCTAssertEqual(ByteFormatting.tokens(1_500), "1.5K")
        XCTAssertEqual(ByteFormatting.tokens(1_000_000), "1.0M")
        XCTAssertEqual(ByteFormatting.tokens(2_500_000), "2.5M")
        XCTAssertEqual(ByteFormatting.tokens(3_000_000_000), "3.0B")
    }

    // MARK: duration

    func testDuration() {
        XCTAssertEqual(ByteFormatting.duration(seconds: 0), "0s")
        XCTAssertEqual(ByteFormatting.duration(seconds: 45), "45s")
        XCTAssertEqual(ByteFormatting.duration(seconds: 59), "59s")
        XCTAssertEqual(ByteFormatting.duration(seconds: 60), "1m")
        XCTAssertEqual(ByteFormatting.duration(seconds: 90), "1m")
        XCTAssertEqual(ByteFormatting.duration(seconds: 3_600), "1h 0m")
        XCTAssertEqual(ByteFormatting.duration(seconds: 12_240), "3h 24m")
    }

    func testDurationNegativeClampsToZero() {
        XCTAssertEqual(ByteFormatting.duration(seconds: -5), "0s")
    }

    // MARK: pixel distance

    func testPixelDistance() {
        XCTAssertEqual(ByteFormatting.pixelDistance(milliPixels: 0), "0 px")
        XCTAssertEqual(ByteFormatting.pixelDistance(milliPixels: 512_000), "512 px")
        XCTAssertEqual(ByteFormatting.pixelDistance(milliPixels: 1_500_000), "1.5K px")
        XCTAssertEqual(ByteFormatting.pixelDistance(milliPixels: 2_500_000_000), "2.5M px")
    }
}
